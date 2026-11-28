//
//  PrivacyView.swift
//  osaurus / PrivacyFilter
//
//  Top-level "Privacy" management tab. Always renders
//  `ManagerHeaderWithTabs` + three sub-tabs (Filter / Rules / Models) so
//  the surface scans like Server and Voice instead of a long card scroll.
//  Filter = what Osaurus collects + the redaction filter (including the
//  per-provider overrides and the non-interactive review policy under
//  Advanced); Rules = what the matcher looks for; Models = the optional
//  on-device detector. At-rest encryption and file history live under
//  General → Advanced → Data & Storage.
//
//  The on-device AI model is OPTIONAL: the regex / preset / custom-rule
//  layer works with zero download, so the panel is never gated on the
//  bundle. The install + status UI lives in the Models tab, and the
//  AI-detection toggle on Filter is the only control that needs the
//  bundle (disabled with an Install link until the model verifies).
//
//  Intel fork (`W-privacy-filter` stage 4, `docs/W_PRIVACY_FILTER_PLAN.md`):
//  both on-device detectors (OpenAI privacy-filter, Rampart) are MLX models
//  and cannot run on macOS 13 x86_64, so the Models tab and the AI-detection
//  toggle show "Incompatible: needs an Apple Silicon Mac" instead of install
//  controls (never hidden). The Data Collection and Activity Log sections
//  stay where Intel has them (General), reached through a link row here.
//
//  Persistence: `save()` is intentionally synchronous now. The previous
//  `Task.detached { ... }` hop let the master toggle race app quit,
//  which is why the "Enable Privacy Filter" switch kept resetting to
//  off across restarts. See `PrivacyFilterStorePersistenceTests`.
//

import SwiftUI

/// Per-view holder for the debounced-save `DispatchWorkItem`. Lives
/// in a class so SwiftUI's `@StateObject` keeps the same instance
/// across view re-renders, and so the `deinit` flush has a clear
/// owner. `Sendable` because all writes happen on the main queue.
@MainActor
final class PrivacyViewSaveDebouncer: ObservableObject {
    /// Window matches the visible tick rate of the sliders / preset
    /// toggles; faster and the JSON write fires per-keystroke on a
    /// drag, slower and the user perceives a lag between flipping
    /// and the filter actually picking up the new value.
    static let debounceInterval: TimeInterval = 0.3

    private var pendingWork: DispatchWorkItem?
    private var pendingBlock: (@Sendable () -> Void)?

    /// Cancel any pending write and schedule a new one. The closure
    /// is captured by the work item, so each call snapshots the
    /// configuration at scheduling time — the trailing-edge value
    /// wins, which is the standard slider-drag behavior.
    func schedule(_ work: @escaping @Sendable () -> Void) {
        pendingWork?.cancel()
        pendingBlock = work
        let item = DispatchWorkItem { [weak self] in
            self?.pendingBlock = nil
            work()
        }
        pendingWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: item)
    }

    /// Run any pending work right now and drop the work item.
    /// Called from `onDisappear` and on app-quit notifications so
    /// a debounced write can't be lost if the user closes the
    /// settings sheet or quits within the debounce window.
    func flush() {
        // Intel (`W-privacy-filter` stage 4): upstream called `perform()` on a
        // cancelled `DispatchWorkItem`, which never runs its block, so a flush
        // dropped the pending write. Run the stored block directly instead.
        pendingWork?.cancel()
        pendingWork = nil
        if let block = pendingBlock {
            pendingBlock = nil
            block()
        }
    }

    // No `deinit` cancel: `DispatchWorkItem` is non-`Sendable` so
    // the nonisolated default deinit can't touch `pendingWork`,
    // and a custom deinit would have to hop to MainActor. The
    // `onDisappear` + `willTerminate` hooks on `PrivacyView`
    // already cover the graceful flush paths; if neither fires
    // (e.g. SwiftUI tears the view down silently), the work item
    // simply runs after the view is gone — its closure only
    // touches the file system, not view state, so that's a safe
    // tail.
}

struct PrivacyView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var providerManager = RemoteProviderManager.shared
    @StateObject private var saveDebouncer = PrivacyViewSaveDebouncer()
    @ObservedObject private var managementState = ManagementStateManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var configuration: PrivacyFilterConfiguration = PrivacyFilterStore.snapshot()
    @State private var hasAppeared = false
    @State private var forgetActionMessage: String?
    @State private var customRuleEditorContext: CustomRuleEditorContext?
    @State private var selectedTab: PrivacyTab = .overview

    /// Always false on Intel: no model detector can run on macOS 13 x86_64
    /// (`PrivacyDetectorSupport`). Kept as a property so the tabs read the
    /// same way as upstream's.
    private var isModelReady: Bool { PrivacyDetectorSupport.modelDetectorsRunnable }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            // The tabbed surface is ALWAYS shown — the regex /
            // custom-rule layer works without the on-device model, so
            // gating the whole panel on `isModelReady` would have
            // hidden the rules a no-download user can fully use. The
            // model's install / status UI lives in the Models tab.
            ScrollView {
                selectedTabContent
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .settingsLandingAnchor("privacy.tab")
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            configuration = PrivacyFilterStore.snapshot()
            applySubTabRequest(managementState.privacySubTabRequest)
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .onDisappear {
            // Flush any pending debounced write so closing Settings
            // (or the user navigating away) never strands a
            // half-second-old slider value off-disk. The flush also
            // runs naturally in the debouncer's `deinit`, but we
            // can't reach the MainActor from there, so the
            // disappear path is the canonical hook.
            saveDebouncer.flush()
        }
        .onChange(of: managementState.privacySubTabRequest) { newValue in
            applySubTabRequest(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .privacyFilterConfigurationChanged)) { _ in
            configuration = PrivacyFilterStore.snapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // Belt-and-suspenders for the user-quits-while-sheet-open
            // race that motivated the synchronous master toggle.
            // `onDisappear` doesn't fire when the entire app
            // process is going down.
            saveDebouncer.flush()
        }
        .sheet(item: $customRuleEditorContext) { context in
            PrivacyCustomRuleEditor(
                initialRule: context.rule,
                onSave: { savedRule in
                    apply(editedRule: savedRule, replacing: context.rule?.id)
                    customRuleEditorContext = nil
                },
                onCancel: { customRuleEditorContext = nil }
            )
            .environment(\.theme, themeManager.currentTheme)
        }
    }

    private func applySubTabRequest(_ requested: String?) {
        guard let requested else { return }
        managementState.privacySubTabRequest = nil
        // Encryption / file history moved to General → Advanced → Data &
        // Storage; forward the retired "storage" sub-tab there so older
        // deep links and guide paths still land on the controls.
        if requested == "storage" {
            SettingsHighlightCoordinator.shared.request("storage.encryption")
            managementState.selectedTab = .settings
            return
        }
        guard let tab = PrivacyTab.resolved(from: requested) else { return }
        selectedTab = tab
    }

    // MARK: - Header

    /// Tabbed header so users can jump between Filter / Rules / Models
    /// without scrolling. No header actions — install/verify/remove all
    /// live in the Models tab.
    private var headerView: some View {
        ManagerHeaderWithTabs(
            title: L("Privacy"),
            subtitle: L("What leaves your Mac and what Osaurus collects.")
        ) {
            EmptyView()
        } tabsRow: {
            HeaderTabsRow(selection: $selectedTab)
        }
    }

    // MARK: - Tab dispatch

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .overview:
            PrivacyOverviewTab(
                configuration: $configuration,
                save: save,
                saveDebounced: saveDebounced,
                isModelReady: isModelReady,
                providers: providerManager.configuration.providers,
                onOpenModels: { selectedTab = .model },
                onOpenProviders: { ManagementStateManager.shared.selectedTab = .providers },
                forgetActionMessage: forgetActionMessage,
                forgetAllRedactions: forgetAllRedactions
            )
        case .rules:
            PrivacyRulesTab(
                configuration: $configuration,
                save: save,
                saveDebounced: saveDebounced,
                isModelReady: isModelReady,
                customRuleEditorContext: $customRuleEditorContext,
                onDeleteCustomRule: deleteCustomRule(id:),
                onToggleCustomRule: setCustomRuleEnabled(id:enabled:)
            )
        case .model:
            PrivacyModelIncompatibleTab()
                .settingsLandingAnchor("privacy.models")
        }
    }

    // MARK: - Install action routing

    // MARK: - Custom rule mutations

    private func setCustomRuleEnabled(id: UUID, enabled: Bool) {
        guard let idx = configuration.customRules.firstIndex(where: { $0.id == id })
        else { return }
        configuration.customRules[idx].enabled = enabled
        save()
    }

    private func deleteCustomRule(id: UUID) {
        configuration.customRules.removeAll { $0.id == id }
        save()
    }

    private func apply(editedRule rule: PrivacyRule, replacing existingId: UUID?) {
        if let existingId,
            let idx = configuration.customRules.firstIndex(where: { $0.id == existingId })
        {
            configuration.customRules[idx] = rule
        } else {
            configuration.customRules.append(rule)
        }
        save()
    }

    // MARK: - Forget redactions

    private func forgetAllRedactions() {
        Task { @MainActor in
            await SessionRedactionStore.shared.invalidateAll()
            forgetActionMessage = L("privacy.forget.cleared")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            forgetActionMessage = nil
        }
    }

    // MARK: - Persistence

    /// Synchronous on purpose. The previous `Task.detached { ... }`
    /// hop let the user toggle the master switch ON and then quit the
    /// app before the JSON write landed on disk — on next launch the
    /// store fell back to `enabled: false` (see
    /// `PrivacyFilterStorePersistenceTests`). JSON encode + atomic
    /// write of the ~1KB config is microseconds; this matches how
    /// `MemoryConfigurationStore.save` works in the rest of the app.
    ///
    /// Use this for fields where the user's perceived state MUST
    /// match the on-disk state immediately (master toggle,
    /// requireReview, master alwaysApprove). Slider-shaped or
    /// preset-toggle-shaped fields go through `saveDebounced()` so
    /// dragging a slider doesn't issue 60 atomic writes per second.
    private func save() {
        saveDebouncer.flush()
        PrivacyFilterStore.save(configuration)
    }

    /// Debounced variant. Each call snapshots `configuration`
    /// at scheduling time and cancels any pending write — only the
    /// trailing-edge value is written. If the view disappears or
    /// the user quits within `PrivacyViewSaveDebouncer.debounceInterval`,
    /// the `onDisappear` hook flushes synchronously so the change
    /// still lands.
    private func saveDebounced() {
        let snapshot = configuration
        saveDebouncer.schedule {
            PrivacyFilterStore.save(snapshot)
        }
    }
}

// MARK: - Privacy Tab

/// The three sub-sections of the Privacy tab. Raw values are stable
/// deep-link ids (`privacySubTabRequest`, settings-search `subTab`); the
/// visible titles differ, so use `resolved(from:)` for inbound requests.
///
/// `Hashable` is synthesized from the `String` raw value, which is
/// what `AnimatedTabItem`'s `ForEach(id: \.self)` needs.
enum PrivacyTab: String, CaseIterable, AnimatedTabItem {
    /// Consent + the redaction filter (per-provider overrides folded in).
    case overview
    case rules
    case model

    var title: String {
        switch self {
        case .overview: return L("Filter")
        case .rules: return L("Rules")
        case .model: return L("Models")
        }
    }

    /// Accepts the visible titles and the retired `providers` sub-tab (its
    /// toggles now live on Filter). `"storage"` is handled by the caller,
    /// which forwards to General.
    static func resolved(from rawValue: String) -> PrivacyTab? {
        if let tab = PrivacyTab(rawValue: rawValue) { return tab }
        switch rawValue.lowercased() {
        case "filter", "providers", "provider": return .overview
        case "models": return .model
        default: return nil
        }
    }
}

// MARK: - Models tab (Intel: incompatible)

/// Intel replacement for upstream's `PrivacyModelSelector`. Both detectors
/// (Rampart ~37 MB, OpenAI Privacy Filter ~2.8 GB) are MLX models that need
/// Apple Silicon, so each is listed with an "Incompatible" status and no
/// install action. Pattern rules in the Rules tab work without any model.
private struct PrivacyModelIncompatibleTab: View {
    @Environment(\.theme) private var theme

    private struct Detector: Identifiable {
        let id: String
        let name: String
        let size: String
        let summary: String
    }

    private var detectors: [Detector] {
        [
            Detector(
                id: "rampart",
                name: "Rampart",
                size: "~37 MB",
                summary: L("Tiny and fast. Catches names, addresses, and IDs/secrets. No date detection.")
            ),
            Detector(
                id: "openai",
                name: "OpenAI Privacy Filter",
                size: "~2.8 GB",
                summary: L(
                    "Highest coverage. Adds names, addresses, dates, and free-form secrets beyond pattern rules."
                )
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                "Choose the on-device model that powers AI detection. Pattern rules in the Rules tab work without any model.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)

            SettingsSection(title: L("Available"), icon: "square.and.arrow.down") {
                VStack(spacing: 8) {
                    ForEach(detectors) { detector in
                        row(detector)
                    }
                }
            }

            Text("privacy.model.incompatible.note", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private func row(_ detector: Detector) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundColor(theme.warningColor)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: detector.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(verbatim: "\(detector.size) · \(detector.summary)")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("privacy.model.incompatible", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.warningColor)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsRowChrome()
    }
}

// MARK: - Overview Tab

/// The "Filter" tab: data-collection consent, the master scrub toggle,
/// the AI-detection layer toggle (with one link to Models), review
/// behaviour, per-provider overrides, the conversation-level Forget
/// Redactions verb, and — under Advanced — the non-interactive review
/// policy. These are the most-touched controls so they live one tap
/// away from the header.
private struct PrivacyOverviewTab: View {
    @Environment(\.theme) private var theme
    @Binding var configuration: PrivacyFilterConfiguration
    let save: () -> Void
    /// Provider-toggle writes funnel through here so flipping a handful
    /// of providers in a row doesn't issue a JSON write per toggle.
    let saveDebounced: () -> Void
    /// Whether the on-device detection model is installed + verified.
    /// Gates the AI-detection toggle: AI can't be turned on without
    /// the bundle (an AI-on + no-model state would fail-close every
    /// cloud send), so when this is false we show an install prompt.
    let isModelReady: Bool
    /// Configured remote providers, for the per-provider override rows.
    let providers: [RemoteProvider]
    /// Jump to the Models tab (install a bundle / pick a backend).
    let onOpenModels: () -> Void
    /// Jump to the Providers manager so the user can add one.
    let onOpenProviders: () -> Void
    /// Read-only — the parent owns this `@State` and re-renders the
    /// tab when it changes; the tab never writes back to it.
    let forgetActionMessage: String?
    let forgetAllRedactions: () -> Void

    private static let advancedAnchorIds: Set<String> = ["privacy.filter.nonInteractive"]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            dataStorageLinkSection

            SettingsSection(title: L("Filter"), icon: "lock.shield.fill") {
                SettingsToggle(
                    title: L("Scrub PII before sending to cloud providers"),
                    description: L(
                        "Detects PII in your messages and asks you to review before any cloud-bound request. Local models (MLX, Foundation) and on-device tools bypass the filter."
                    ),
                    anchorId: "privacy.filter.enabled",
                    isOn: Binding(
                        get: { configuration.enabled },
                        set: { newValue in
                            configuration.enabled = newValue
                            save()
                        }
                    )
                )

                if configuration.enabled {
                    // Intel: shown but disabled, never hidden. No model
                    // detector can run on macOS 13 x86_64, and the filter
                    // never turns the AI layer on by itself.
                    SettingsToggle(
                        title: L("AI detection (on-device model)"),
                        description: L("privacy.model.incompatible"),
                        anchorId: "privacy.filter.aiDetection",
                        isOn: .constant(false)
                    )
                    .disabled(true)
                    .opacity(0.6)

                    SettingsLinkRow(
                        title: "Detection Model",
                        description: L("privacy.model.incompatible"),
                        icon: "arrow.right",
                        actionTitle: "Details"
                    ) {
                        onOpenModels()
                    }
                }

                if configuration.enabled && !hasActiveDetector {
                    noDetectorNote
                }

                SettingsToggle(
                    title: L("Skip Code Blocks"),
                    description: L("Don't scan fenced (```) or inline (`) code spans."),
                    anchorId: "privacy.filter.skipCode",
                    isOn: Binding(
                        get: { configuration.skipCodeBlocks },
                        set: { newValue in
                            configuration.skipCodeBlocks = newValue
                            save()
                        }
                    )
                )

                SettingsToggle(
                    title: L("Always Approve by Default"),
                    description: L("Skip the review sheet — still redact, just don't ask each turn."),
                    anchorId: "privacy.filter.alwaysApprove",
                    isOn: Binding(
                        get: { configuration.alwaysApproveByDefault },
                        set: { newValue in
                            configuration.alwaysApproveByDefault = newValue
                            save()
                        }
                    )
                )
            }

            if configuration.enabled {
                SettingsSection(title: L("Per-Provider"), icon: "cloud", anchorId: "privacy.filter.providers") {
                    providerOverrides
                }
            }

            SettingsSection(
                title: L("Conversation Privacy"),
                icon: "person.crop.circle.fill.badge.minus"
            ) {
                forgetCard
            }

            SettingsAdvancedDisclosure(anchorIds: Self.advancedAnchorIds) {
                SettingsToggle(
                    title: L("Require Review for Background Requests"),
                    description:
                        "Also hold cloud-bound requests from the HTTP API, schedules, and other non-interactive callers until you review them. Turn off to let those requests auto-approve silently after redaction.",
                    anchorId: "privacy.filter.nonInteractive",
                    isOn: Binding(
                        get: { configuration.requireReviewForNonInteractive },
                        set: { newValue in
                            configuration.requireReviewForNonInteractive = newValue
                            save()
                        }
                    )
                )
            }
        }
    }

    // MARK: - Data collection and activity log

    /// Intel keeps the usage-data / crash-report switches and the Activity
    /// Log (retention, stored content) under General → Data & Storage, where
    /// the fork already had them; this row points to Insights.
    private var dataStorageLinkSection: some View {
        SettingsSection(title: L("Activity Log"), icon: "list.bullet.clipboard") {
            SettingsLinkRow(
                title: L("Review Activity in Insights"),
                description: L("Filter, verify the tamper-evident chain, and export the log for outside review."),
                icon: "chart.bar.doc.horizontal",
                actionTitle: "Open Insights"
            ) {
                ManagementStateManager.shared.selectedTab = .insights
            }
        }
    }

    /// True when at least one detection source would actually run for
    /// an outbound send: the AI layer (model installed + enabled) or
    /// any active regex source (a built-in category, an enabled preset,
    /// or an enabled custom rule).
    private var hasActiveDetector: Bool {
        if isModelReady && configuration.aiDetectionEnabled { return true }
        let anyBuiltin = PrivacyFilterConfiguration.builtinPatternCategories
            .contains { configuration.isBuiltinPatternEnabled($0) }
        if anyBuiltin { return true }
        let anyPreset = PrivacyRulePresets.all.contains { configuration.isPresetEnabled($0.id) }
        if anyPreset { return true }
        return configuration.customRules.contains { $0.enabled }
    }

    /// Real informational note (not a gate): the filter is on but no
    /// detector would fire, so nothing gets redacted. Points the user
    /// at the two ways to fix it.
    private var noDetectorNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.warningColor)
            Text(
                "privacy.filter.noDetector.intel",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Per-provider override toggles. With no remote providers configured,
    /// a single link row points at the Providers manager instead of an
    /// empty list.
    @ViewBuilder
    private var providerOverrides: some View {
        if providers.isEmpty {
            SettingsLinkRow(
                title: L("privacy.providers.empty.title"),
                description: L("privacy.providers.empty.subtitle"),
                icon: "cloud.fill",
                actionTitle: "Open Providers"
            ) {
                onOpenProviders()
            }
        } else {
            ForEach(providers) { provider in
                SettingsToggle(
                    title: provider.name,
                    description: providerDescription(provider),
                    isOn: Binding(
                        get: { configuration.providerOverrides[provider.id.uuidString] ?? true },
                        set: { newValue in
                            configuration.setProviderEnabled(provider.id, enabled: newValue)
                            saveDebounced()
                        }
                    )
                )
            }
        }
    }

    private func providerDescription(_ provider: RemoteProvider) -> String {
        let host = provider.host.isEmpty ? provider.providerType.rawValue : provider.host
        return String(format: L("privacy.providers.row.subtitle %@"), host)
    }

    private var forgetCard: some View {
        SettingsRow(
            title: L("Forget Redactions in Every Conversation"),
            // `forgetActionMessage` is already localized by the parent.
            description: forgetActionMessage
                ?? L("Clear every interned placeholder for every open conversation. Future sends mint fresh placeholders."),
            anchorId: "privacy.filter.forget"
        ) {
            Button(action: forgetAllRedactions) {
                Text("Forget", bundle: .module)
            }
            .buttonStyle(SettingsButtonStyle())
        }
    }
}

// MARK: - Rules Tab

/// Detection patterns + preset rules + custom rules. Keeps all the
/// "what does the matcher look for" controls in one place so users
/// don't have to hop between sub-tabs to enable a preset and then
/// add a custom regex.
private struct PrivacyRulesTab: View {
    @Environment(\.theme) private var theme
    @Binding var configuration: PrivacyFilterConfiguration
    let save: () -> Void
    /// Slider-shaped writes (preset toggles, built-in category
    /// toggles) route through this so a fast user-interaction
    /// (e.g. enabling four presets in a row) coalesces into one
    /// JSON write instead of four. Falls through to `save` on
    /// `onDisappear` / quit.
    let saveDebounced: () -> Void
    /// Lets the dry-run tester include the on-device model's spans
    /// when it's installed + loaded (otherwise it previews the regex
    /// layer alone).
    let isModelReady: Bool
    @Binding var customRuleEditorContext: CustomRuleEditorContext?
    let onDeleteCustomRule: (UUID) -> Void
    let onToggleCustomRule: (UUID, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            detectionPatternsSection
            PrivacyRegionsSection(configuration: $configuration, save: save)
            PrivacyPresetRulesSection(configuration: $configuration, saveDebounced: saveDebounced)
            customRulesSection
            PrivacyDryRunTester(configuration: configuration, isModelReady: isModelReady)
        }
    }

    // MARK: Detection patterns

    private var detectionPatternsSection: some View {
        SettingsSection(title: L("Detection Patterns"), icon: "ruler", anchorId: "privacy.rules.detectionPatterns") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Built-in deterministic detectors run alongside the on-device model. Turning a category off stops Osaurus from flagging it AND from blocking sends when it leaks past redaction.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

                builtinPatternToggle(
                    category: .phone,
                    title: L("Phone numbers"),
                    description: L(
                        "International phone numbers: +country-code, national 0-prefixed, and North American formats."
                    )
                )
                builtinPatternToggle(
                    category: .email,
                    title: L("Email addresses"),
                    description: L("Standard local@domain.tld addresses.")
                )
                builtinPatternToggle(
                    category: .url,
                    title: L("URLs"),
                    description: L("http(s) URLs that include a scheme.")
                )
                builtinPatternToggle(
                    category: .accountNumber,
                    title: L("Account numbers"),
                    description: L(
                        "Luhn-valid credit and debit card numbers. National ID numbers are in Preset Rules."
                    )
                )
            }
        }
    }

    private func builtinPatternToggle(
        category: EntityCategory,
        title: String,
        description: String
    ) -> some View {
        SettingsToggle(
            title: title,
            description: description,
            isOn: Binding(
                get: { configuration.isBuiltinPatternEnabled(category) },
                set: { newValue in
                    configuration.builtinPatternEnabled[category] = newValue
                    saveDebounced()
                }
            )
        )
    }

    // MARK: Custom rules

    private var customRulesSection: some View {
        SettingsSection(title: L("Custom Rules"), icon: "wand.and.rays", anchorId: "privacy.rules.custom") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Catch internal codenames, customer IDs, or anything the built-ins miss. Build a rule with no regex, or write your own pattern.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

                if configuration.customRules.isEmpty {
                    HStack {
                        Text("No custom rules yet.", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                        Spacer()
                        addCustomRuleButton
                    }
                    .settingsRowChrome()
                } else {
                    VStack(spacing: 8) {
                        ForEach(configuration.customRules) { rule in
                            customRuleRow(rule)
                        }
                    }
                    HStack {
                        Spacer()
                        addCustomRuleButton
                    }
                }
            }
        }
    }

    private var addCustomRuleButton: some View {
        Button {
            customRuleEditorContext = CustomRuleEditorContext(rule: nil)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                Text("Add Rule", bundle: .module)
            }
        }
        .buttonStyle(SettingsButtonStyle(isPrimary: true))
    }

    /// Compact icon-tile button for the per-row Edit/Delete actions.
    /// Matches the app's tertiary icon-tile language (28pt rounded
    /// surface) instead of system `.bordered` buttons; `destructive`
    /// swaps the neutral chrome for a tinted error treatment.
    private func ruleRowIconButton(
        systemName: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(destructive ? theme.errorColor : theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(destructive ? theme.errorColor.opacity(0.10) : theme.tertiaryBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    destructive ? theme.errorColor.opacity(0.25) : theme.inputBorder,
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func customRuleRow(_ rule: PrivacyRule) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: rule.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    PrivacyCategoryBadge(category: rule.category)
                }
                Text(verbatim: rule.pattern)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            HStack(spacing: 6) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { rule.enabled },
                        set: { newValue in
                            onToggleCustomRule(rule.id, newValue)
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)

                ruleRowIconButton(systemName: "pencil") {
                    customRuleEditorContext = CustomRuleEditorContext(rule: rule)
                }
                .localizedHelp("Edit this rule.")

                ruleRowIconButton(systemName: "trash", destructive: true) {
                    onDeleteCustomRule(rule.id)
                }
                .localizedHelp("Delete this rule.")
            }
        }
        .settingsRowChrome()
    }
}

// MARK: - Dry-run Tester

/// All-rules dry-run tester. Paste sample text and preview exactly
/// what the live configuration would redact — the deterministic regex
/// layer always, plus the on-device model when it's installed + the
/// user has AI detection on. Runs the real `PrivacyFilterEngine.detect`
/// against a throwaway `RedactionMap` so the previewed placeholder
/// tokens match what an actual send would mint.
private struct PrivacyDryRunTester: View {
    @Environment(\.theme) private var theme
    let configuration: PrivacyFilterConfiguration
    let isModelReady: Bool

    @State private var sample: String = ""
    @State private var results: [DetectedEntity] = []
    @State private var didRun: Bool = false
    @State private var isRunning: Bool = false

    var body: some View {
        SettingsSection(title: L("Test Your Rules"), icon: "play.circle.fill", anchorId: "privacy.rules.test") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Paste sample text to preview exactly what Osaurus would redact with your current rules — before anything reaches a provider.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

                TextField(L("Paste text to test…"), text: $sample, axis: .vertical)
                    .lineLimit(3 ... 8)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Button(action: runTest) {
                        Text("Run test", bundle: .module)
                    }
                    .buttonStyle(SettingsButtonStyle(isPrimary: true))
                    .disabled(sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning)

                    if isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Text(verbatim: layerNote)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }

                if didRun {
                    resultsView
                }
            }
        }
    }

    /// Which detection layers the next run will use, so the user isn't
    /// surprised that model-only categories (names, addresses) don't
    /// appear when AI detection is off or the bundle isn't installed.
    private var layerNote: String {
        return L("Using pattern rules only")
    }

    @ViewBuilder
    private var resultsView: some View {
        Divider().padding(.vertical, 2)
        if results.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(theme.tertiaryText)
                Text("No matches — nothing would be redacted.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: summaryText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                ForEach(EntityCategory.allCases, id: \.self) { category in
                    let items = uniqueResults.filter { $0.category == category }
                    if !items.isEmpty {
                        categoryGroup(category: category, items: items)
                    }
                }
            }
        }
    }

    private func categoryGroup(category: EntityCategory, items: [DetectedEntity]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PrivacyCategoryBadge(category: category)
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Text(verbatim: item.original)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundColor(theme.tertiaryText)
                    Text(verbatim: item.placeholder.token)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.accentColor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsRowChrome()
    }

    /// De-duplicate by minted token: the same original appearing twice
    /// in the sample interns to one placeholder, so show it once.
    private var uniqueResults: [DetectedEntity] {
        var seen = Set<String>()
        var out: [DetectedEntity] = []
        for entity in results where seen.insert(entity.placeholder.token).inserted {
            out.append(entity)
        }
        return out
    }

    private var summaryText: String {
        let count = uniqueResults.count
        return count == 1
            ? L("1 item would be redacted", comment: "Dry-run match count")
            : L("\(count) items would be redacted", comment: "Dry-run match count")
    }

    private func runTest() {
        let text = sample
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isRunning = true
        Task { @MainActor in
            let map = RedactionMap(conversationID: UUID())
            let ruleset = RegexEntityDetector.EffectiveRuleSet.build(from: configuration)
            // Intel: pattern rules only; no model detector can run here.
            let detected =
                (try? await PrivacyFilterEngine.shared.detect(
                    in: text,
                    map: map,
                    skipCodeBlocks: configuration.skipCodeBlocks,
                    ruleset: ruleset,
                    useModel: false
                )) ?? []
            results = detected
            didRun = true
            isRunning = false
        }
    }
}

// MARK: - Category Badge

/// Tiny accent pill used in rule rows (preset + custom) and the dry-run
/// tester. Factored out of the old in-line helper so every call site
/// uses the same component without re-passing a theme instance.
struct PrivacyCategoryBadge: View {
    @Environment(\.theme) private var theme
    let category: EntityCategory

    var body: some View {
        Text(LocalizedStringKey(category.localizationKey), bundle: .module)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundColor(theme.accentColor)
            .background(Capsule().fill(theme.accentColor.opacity(0.12)))
            .overlay(Capsule().stroke(theme.accentColor.opacity(0.25), lineWidth: 0.5))
    }
}

/// `sheet(item:)` requires an `Identifiable` payload — wrap the
/// optional `PrivacyRule` so we can present add (`rule == nil`) and
/// edit (`rule != nil`) modes with one binding. The `id` is a fresh
/// `UUID` per presentation so the sheet animates correctly when
/// editing different rules back-to-back.
private struct CustomRuleEditorContext: Identifiable {
    let id = UUID()
    let rule: PrivacyRule?
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        PrivacyView()
    }
#endif
