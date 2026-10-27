//
//  OnboardingConfigureAIView.swift
//  osaurus
//
//  Onboarding step 3 — Figma screen 3 ("A private brain that runs on your
//  Mac"). Left column: brain dino, title, subtitle, and the step CTA ("Set
//  up later" until a brain is committed, then "Continue to Osaurus"). Right
//  panel: the recommended-model card ("Picked for your Mac" badge, meta
//  chips, Download + Change model) with an in-card downloading state, then
//  the provider chips (OpenAI, Anthropic, xAI, OpenRouter, Gemini, + More)
//  that drill into a per-provider connect screen whose option rows open the
//  connect dialog (browser sign-in or pasted API key).
//
//  Split into:
//   - `ConfigureAIState`: ObservableObject holding the committed brain
//     source, the provider drill-in, connection-test progress, and dialog
//     state (lives at the OnboardingView level so it survives step
//     transitions).
//   - `ConfigureAIStepView`: the full-window step layout.
//   - `ProviderConnectDialog` / `ConfigureModelChooserModal`: window-root
//     dialogs hosted by `OnboardingView`.
//
//  Intel (2026-10-27, `W-ui-misc` onboarding): the local MLX path is gone
//  (Apple Silicon only): no recommended-model card, model chooser, download
//  progress or disk preflight. The home card is "Osaurus Cloud" (the managed
//  Router), above upstream's provider chips, Claude Code and Custom.
//
//  Apple Intelligence was removed from this step: it's too limited (no tools,
//  no web, no agent work) to be a first-class first-run option. Users with
//  `FoundationModelService` available can still configure it post-onboarding
//  from Settings.
//

import SwiftUI

// MARK: - Screen / substates

/// The top-level screen within the Configure AI step. `home` recommends a
/// local model with the provider chips below; `byok` is the per-provider
/// connect drill-in.
enum ConfigureScreen: Equatable {
    case home
    case byok
    case claudeCode
}

/// Bring-your-own-key drill-in depth (inside `ConfigureScreen.byok`).
enum APISubstate: Equatable {
    case picker
    /// "Use an API key" drill-in: grouped list of API-key vendors, the local
    /// Ollama option, and the custom OpenAI-compatible escape hatch.
    case apiKeyPicker
    case keyForm(ProviderPreset)
    case customForm
}

enum APITestResult: Equatable {
    case success
    case failure(String)
}

/// Which connect dialog is open over the provider drill-in: the browser
/// sign-in confirmation or the paste-an-API-key form.
enum ConnectDialogKind: Equatable {
    case oauth
    case apiKey
}

// MARK: - Resolved provider config

struct ResolvedProviderConfig {
    let name: String
    let host: String
    let port: Int?
    let basePath: String
    let providerType: RemoteProviderType
    let providerProtocol: RemoteProviderProtocol
    let authType: RemoteProviderAuthType
}

struct CustomProviderForm: Equatable {
    var name: String = ""
    var host: String = ""
    var protocolKind: RemoteProviderProtocol = .https
    var port: String = ""
    var basePath: String = "/v1"

    mutating func reset() { self = CustomProviderForm() }

    /// Parses a pasted endpoint URL into the form's fields. Delegates the
    /// decomposition to the Settings sheet's `parsePastedEndpoint` so both
    /// surfaces share one parser (query/fragment stripping, IPv6 literals,
    /// operation-suffix normalization like /v1/chat/completions -> /v1),
    /// then layers onboarding's forgiving defaults on top: the scheme is
    /// optional (local machine and LAN hosts default to http, everything
    /// else https) and a missing path defaults to /v1. Returns an empty
    /// form (host == "") when no host can be extracted, which keeps
    /// `canTestAPI` false.
    static func parse(_ urlString: String) -> CustomProviderForm {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return CustomProviderForm() }
        var form = CustomProviderForm()
        if let components = parsePastedEndpoint(trimmed) {
            form.host = components.host
            form.port = components.port.map(String.init) ?? ""
            form.basePath = components.basePath ?? "/v1"
            form.protocolKind = components.providerProtocol ?? form.inferredScheme
        } else if !trimmed.contains("://"), !trimmed.contains("/") {
            // A bare host ("localhost", "myserver.internal") has no pieces
            // to split, so the shared parser declines it; take it verbatim.
            form.host = trimmed
            form.basePath = "/v1"
            form.protocolKind = form.inferredScheme
        }
        return form
    }

    /// Best-guess scheme for input pasted without one: the local machine
    /// and LAN addresses virtually never serve TLS; domains and public IPs
    /// default to https.
    private var inferredScheme: RemoteProviderProtocol {
        let h = host.lowercased()
        let isPrivateLAN =
            h.hasPrefix("192.168.") || h.hasPrefix("10.") || h.hasSuffix(".local")
        return (isLocalhost || isPrivateLAN) ? .http : .https
    }

    var endpointPreview: String {
        var url = (protocolKind == .https ? "https://" : "http://") + host
        if !port.isEmpty { url += ":\(port)" }
        url += basePath.isEmpty ? "/v1" : basePath
        return url
    }

    /// Treat localhost-style hosts as "no auth required" — covers Ollama, LM
    /// Studio, llama.cpp server, vLLM, etc. when the user wires them up via
    /// the custom form.
    var isLocalhost: Bool {
        // `parsePastedEndpoint` keeps IPv6 literals bracketed ("[::1]").
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " []"))
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "0.0.0.0"
    }

    func resolved(displayName: String, apiKey: String) -> ResolvedProviderConfig {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let authType: RemoteProviderAuthType = (isLocalhost && trimmedKey.isEmpty) ? .none : .apiKey
        return ResolvedProviderConfig(
            name: name.isEmpty ? displayName : name,
            host: host,
            port: port.isEmpty ? nil : Int(port),
            basePath: basePath.isEmpty ? "/v1" : basePath,
            providerType: .openaiLegacy,
            providerProtocol: protocolKind,
            authType: authType
        )
    }
}

// MARK: - State

@MainActor
final class ConfigureAIState: ObservableObject {
    /// The screen currently shown. Starts at `home` with the recommended local
    /// model and the provider chips.
    @Published var screen: ConfigureScreen = .home

    /// Bring-your-own-key drill-in depth. Only meaningful while
    /// `screen == .byok`.
    @Published var apiSubstate: APISubstate = .picker

    /// The brain the user committed to on this step. Recorded at the proceed
    /// moment for each path (with no payment side effect) and read by
    /// `finishOnboarding` to pin routing and persist the analytics dimension for
    /// the first `message_sent`.
    @Published var selectedBrainSource: BrainSource? = nil

    /// The remote provider whose first chat-capable model should become the
    /// active agent's default when the user finished onboarding on the
    /// bring-your-own-key / OAuth path. `nil` for non-provider brain sources.
    /// The provider's catalog populates asynchronously after connect, so
    /// `finishOnboarding` polls `RemoteProviderManager.firstChatCapableModelId`
    /// before pinning.
    var providerModelPinTarget: UUID? {
        guard case .providerKey = selectedBrainSource else { return nil }
        return addedProviderId
    }

    /// Direction the next screen transition should travel. Mirrors the global
    /// step `OnboardingDirection` so the sub-screen slide reads as a natural
    /// continuation of the outer navigation language.
    @Published var substateDirection: OnboardingDirection = .forward

    // MARK: Connect dialog / provider chips

    /// The connect dialog open over the provider drill-in, if any. Hosted at
    /// the OnboardingView window root so it dims the whole window.
    @Published var connectDialog: ConnectDialogKind? = nil

    /// Whether the "+ More" chip has expanded the provider grid with the
    /// remaining API-key presets.
    @Published var showAllProviders = false

    // API
    @Published var apiKey: String = ""
    /// The connection method pinned for the selected provider, set at
    /// option-row tap time (OAuth for the browser sign-in row, `.apiKey` for
    /// the paste-a-key row). Drives the dialog CTA, key field, and
    /// save/test branches.
    @Published var selectedAuthMethod: ProviderPickerAuthMethod = .apiKey
    @Published var oauthTokens: RemoteProviderOAuthTokens? = nil
    /// The id of the provider added by `saveProviderAndContinue`. Read by
    /// `finishOnboarding` (via `providerModelPinTarget`) to pin the new agent's
    /// default model to the just-connected provider's first chat-capable model.
    /// Cleared by `clearAPICredentials()` so an abandoned selection never pins.
    @Published var addedProviderId: UUID? = nil

    /// The OAuth flavor of the current selection, if any.
    var selectedOAuthKind: ProviderOAuthKind? {
        if case .oauth(let kind) = selectedAuthMethod { return kind }
        return nil
    }
    @Published var customForm = CustomProviderForm()
    /// The raw pasted endpoint URL backing the custom connect dialog's single
    /// field; `customForm` is derived from it on every edit.
    @Published var customEndpointURL = "" {
        didSet { customForm = CustomProviderForm.parse(customEndpointURL) }
    }
    @Published var isTesting = false
    @Published var isSaving = false
    @Published var testResult: APITestResult? = nil
    /// One-shot latch so the Continue CTA can't finalize twice. Reset whenever
    /// credentials are cleared (back / reselect).
    var hasFinalizedAPI = false

    /// "Set up later": start on Osaurus Cloud (with the free welcome credit)
    /// instead of downloading anything. There is nothing to download or
    /// connect here — identity + router connect are prepared in the
    /// background by `OnboardingView` and finalized at finish.
    func chooseOsaurusAndContinue(onComplete: () -> Void) {
        selectedBrainSource = .osaurus
        OnboardingTelemetry.brainSourceSelected(.osaurus)
        onComplete()
    }

    // MARK: Navigation

    /// Home → bring-your-own-provider flow (forward slide).
    func showBYOK() {
        substateDirection = .forward
        apiSubstate = .picker
        screen = .byok
    }

    /// Provider-chip tap: drill straight into the provider's connect screen
    /// (no intermediate picker — the chips on the home screen ARE the picker).
    func enterProvider(_ preset: ProviderPreset) {
        substateDirection = .forward
        clearAPICredentials()
        apiSubstate = .keyForm(preset)
        screen = .byok
    }

    /// "Custom" chip tap: open the endpoint-form connect dialog directly over
    /// the home screen. Unlike preset providers there is no drill-in — the
    /// chip has no logo/option rows worth a page, so one tap goes straight to
    /// the form.
    func enterCustomProvider() {
        clearAPICredentials()
        apiSubstate = .customForm
        connectDialog = .apiKey
    }

    func enterClaudeCode() {
        substateDirection = .forward
        screen = .claudeCode
    }

    func chooseClaudeCodeAndContinue(onComplete: () -> Void) {
        selectedBrainSource = .claudeCode
        OnboardingTelemetry.brainSourceSelected(.claudeCode)
        onComplete()
    }

    /// Open the connect dialog for the current provider, pinning the auth
    /// method the tapped option row represents.
    func openConnectDialog(_ kind: ConnectDialogKind) {
        guard let preset = currentAPIProvider else { return }
        testResult = nil
        if kind == .oauth,
            let entry = ProviderCatalog.entry(for: preset),
            let oauthKind = entry.primaryOAuthKind
        {
            selectedAuthMethod = .oauth(oauthKind)
        } else {
            selectedAuthMethod = .apiKey
        }
        connectDialog = kind
    }

    /// Close the connect dialog. A failed / abandoned attempt clears the
    /// stale result so re-opening starts fresh; a verified connection keeps
    /// its green state for the drill-in's check and the Continue CTA.
    func closeConnectDialog() {
        connectDialog = nil
        if !isAPISuccess {
            testResult = nil
            apiKey = ""
            // The custom dialog opens straight over the home grid with no
            // drill-in behind it; an abandoned attempt pops the substate too
            // so no half-filled form lingers under the next chip tap.
            if screen == .home, apiSubstate == .customForm {
                apiSubstate = .picker
                customEndpointURL = ""
                customForm.reset()
            }
        }
    }

    /// Provider drill-in → the recommended local setup (backward slide).
    /// Clears any entered credentials so a stale secret never leaks across
    /// selections.
    func popBYOKToHome() {
        resetAPIState(direction: .backward)
        screen = .home
    }

    // MARK: API

    var currentAPIProvider: ProviderPreset? {
        switch apiSubstate {
        case .keyForm(let p): return p
        case .customForm: return .custom
        case .picker, .apiKeyPicker: return nil
        }
    }

    var canTestAPI: Bool {
        guard let provider = currentAPIProvider else { return false }
        if provider == .custom {
            guard !customForm.host.isEmpty else { return false }
            // Localhost endpoints typically don't authenticate — let users
            // press Connect with an empty key (Ollama, LM Studio, etc.).
            return customForm.isLocalhost || apiKey.count > 5
        }
        // A browser sign-in is connectable as soon as the provider is picked —
        // the OAuth flow itself collects the credential.
        if selectedAuthMethod.isOAuth {
            return true
        }
        // Presets that don't require auth (e.g. Ollama) are connectable as soon
        // as they're selected.
        if provider.configuration.authType == .none {
            return true
        }
        return apiKey.count > 10
    }

    var isAPISuccess: Bool {
        if case .success = testResult { return true }
        return false
    }

    /// Resets the API substate back to the picker. Direction defaults to
    /// `.backward` so the slide reads as "popping out", but callers can pass
    /// `.forward` when this is invoked as a side-effect of a forward switch.
    func resetAPIState(direction: OnboardingDirection = .backward) {
        substateDirection = direction
        apiSubstate = .picker
        clearAPICredentials()
    }

    /// Clear entered credentials, auth-mode selections, and the last test
    /// result. Shared by every "back out" path so stale secrets never leak
    /// across provider selections.
    private func clearAPICredentials() {
        apiKey = ""
        selectedAuthMethod = .apiKey
        oauthTokens = nil
        addedProviderId = nil
        customEndpointURL = ""
        customForm.reset()
        testResult = nil
        hasFinalizedAPI = false
    }

    func resolvedAPIConfig() -> ResolvedProviderConfig? {
        guard let provider = currentAPIProvider else { return nil }
        if provider == .custom {
            return customForm.resolved(displayName: L("Custom Provider"), apiKey: apiKey)
        }
        let cfg = provider.configuration
        return ResolvedProviderConfig(
            name: cfg.name,
            host: cfg.host,
            port: cfg.port,
            basePath: cfg.basePath,
            providerType: cfg.providerType,
            providerProtocol: cfg.providerProtocol,
            authType: cfg.authType
        )
    }

    func testAPIConnection() {
        guard let config = resolvedAPIConfig() else { return }
        isTesting = true
        testResult = nil

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let result: APITestResult
            do {
                switch self.selectedAuthMethod {
                case .oauth(.openAICodex):
                    let tokens = try await OpenAICodexOAuthService.signIn()
                    self.oauthTokens = tokens
                case .oauth(.openRouter):
                    // The browser sign-in IS the test: it returns a freshly minted
                    // OpenRouter API key, which we stash in `apiKey` for the save
                    // step to persist via the standard apiKey path.
                    let key = try await OpenRouterOAuthService.signIn()
                    self.apiKey = key
                case .oauth(.xai):
                    // Grok sign-in returns access/refresh tokens stashed for the
                    // save step to persist via the `.xaiOAuth` path.
                    let tokens = try await XAIOAuthService.signIn()
                    self.oauthTokens = tokens
                case .apiKey, .none:
                    _ = try await RemoteProviderManager.shared.testConnection(
                        host: config.host,
                        providerProtocol: config.providerProtocol,
                        port: config.port,
                        basePath: config.basePath,
                        authType: config.authType,
                        providerType: config.providerType,
                        apiKey: config.authType == .apiKey ? self.apiKey : nil,
                        headers: [:]
                    )
                }
                result = .success
            } catch {
                result = .failure(error.localizedDescription)
            }
            self.testResult = result
            self.isTesting = false
        }
    }

    func saveProviderAndContinue(onComplete: () -> Void) {
        // One-shot: the Continue CTA remains tappable briefly while saving, so
        // both routes funnel through this latch to avoid adding the provider
        // (and advancing) twice.
        guard !hasFinalizedAPI else { return }
        guard let config = resolvedAPIConfig() else { return }
        hasFinalizedAPI = true
        isSaving = true

        // Record the bring-your-own-key brain source for the funnel. The
        // provider type (closed enum) is the only identifying bit sent.
        if let preset = currentAPIProvider {
            selectedBrainSource = .providerKey(preset)
            OnboardingTelemetry.brainSourceSelected(.providerKey(preset))
        }

        // OpenAI Codex and xAI persist OAuth tokens via a service-provided
        // provider config; OpenRouter's OAuth mints a plain key handled by the
        // standard apiKey path below.
        if selectedOAuthKind == .openAICodex {
            let provider = OpenAICodexOAuthService.makeProvider()
            addedProviderId = provider.id
            RemoteProviderManager.shared.addProvider(provider, apiKey: nil, oauthTokens: oauthTokens)
            isSaving = false
            onComplete()
            return
        }

        if selectedOAuthKind == .xai {
            let provider = XAIOAuthService.makeProvider()
            addedProviderId = provider.id
            RemoteProviderManager.shared.addProvider(provider, apiKey: nil, oauthTokens: oauthTokens)
            isSaving = false
            onComplete()
            return
        }

        let provider = RemoteProvider(
            name: config.name,
            host: config.host,
            providerProtocol: config.providerProtocol,
            port: config.port,
            basePath: config.basePath,
            customHeaders: [:],
            authType: config.authType,
            providerType: config.providerType,
            enabled: true,
            autoConnect: true,
            timeout: 60
        )
        addedProviderId = provider.id
        RemoteProviderManager.shared.addProvider(
            provider,
            apiKey: config.authType == .apiKey ? apiKey : nil
        )
        isSaving = false
        onComplete()
    }
}

// MARK: - Step view

struct ConfigureAIStepView: View {
    @ObservedObject var state: ConfigureAIState
    let onComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingStepLayout {
            ConfigureAILeftColumn(state: state, onComplete: onComplete)
        } right: {
            rightPanel
        }
    }

    // MARK: Right panel

    private var rightPanel: some View {
        OnboardingRightPanel {
            ZStack {
                screenContainer
                    .id(substateID)
                    .transition(substateTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(
                RoundedRectangle(cornerRadius: OnboardingLayout.panelRadius, style: .continuous)
            )
            .animation(OnboardingMotion.gentle, value: substateID)
        }
    }

    private var substateID: String {
        switch state.screen {
        case .home: return "home"
        case .byok: return "provider-\(state.currentAPIProvider?.rawValue ?? "none")"
        case .claudeCode: return "claude-code"
        }
    }

    /// Direction-aware push-fade — the same motion language as the outer
    /// step transitions (crossfade under Reduce Motion).
    private var substateTransition: AnyTransition {
        OnboardingMotion.pushFade(
            direction: state.substateDirection,
            reduceMotion: reduceMotion
        )
    }

    @ViewBuilder
    private var screenContainer: some View {
        switch state.screen {
        case .home:
            ConfigureAIHomePanel(state: state, onComplete: onComplete)
        case .byok:
            ConfigureAIProviderPanel(state: state)
        case .claudeCode:
            ClaudeCodeSetupStep(
                onBack: {
                    state.substateDirection = .backward
                    state.screen = .home
                },
                onDone: {
                    state.chooseClaudeCodeAndContinue(onComplete: onComplete)
                },
                completionTitle: "Use Claude Code",
                requiresUsableCLI: true
            )
        }
    }
}

// MARK: - Left column

/// Brain dino + title + subtitle + the step CTA. The CTA swaps from "Set up
/// later" (start on Osaurus Cloud) to "Continue to Osaurus" once a provider
/// is verified. Intel: upstream's download speech bubble and local-model
/// copy are gone with the local path.
private struct ConfigureAILeftColumn: View {
    @ObservedObject var state: ConfigureAIState
    let onComplete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image("osaurus-brain", bundle: .module)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 106)
                .onboardingEntrance(0, scaleFrom: 0.96)

            Spacer().frame(height: 24)

            Text(title, bundle: .module)
                .font(OnboardingTypography.heroTitle)
                .tracking(0.4)
                .foregroundColor(OnboardingPalette.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .onboardingEntrance(1)

            Spacer().frame(height: 16)

            Text(subtitle, bundle: .module)
            .font(OnboardingTypography.subtitle)
            .foregroundColor(OnboardingPalette.labelSecondary)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .onboardingEntrance(2)

            Spacer().frame(height: 40)

            cta
                .onboardingEntrance(3)
        }
    }

    private var title: LocalizedStringKey {
        state.screen == .claudeCode
            ? "Use your Claude Code account"
            : "Give your Dino a brain"
    }

    private var subtitle: LocalizedStringKey {
        state.screen == .claudeCode
            ? "Osaurus delegates sign-in and requests to Anthropic's Claude Code CLI. Credentials stay with the CLI; model requests run in the cloud."
            : "Start on Osaurus Cloud, or connect the AI provider you already use. Your chats, files, and keys stay on your Mac."
    }

    @ViewBuilder
    private var cta: some View {
        if state.isAPISuccess {
            OnboardingPillButton(
                title: "Continue to Osaurus",
                style: .primary,
                size: .large,
                isEnabled: !state.isSaving,
                action: { state.saveProviderAndContinue(onComplete: onComplete) }
            )
        } else {
            OnboardingPillButton(
                title: "Set up later",
                style: .secondary,
                size: .large,
                action: { state.chooseOsaurusAndContinue(onComplete: onComplete) }
            )
        }
    }
}

// MARK: - Home panel

/// The right panel's home screen: recommended model card + provider chips.
private struct ConfigureAIHomePanel: View {
    @ObservedObject var state: ConfigureAIState
    let onComplete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OsaurusCloudCard(state: state, onComplete: onComplete)
                .onboardingEntrance(0, scaleFrom: 0.98)

            Spacer().frame(height: 28)

            Text("Prefer to connect your AI Provider?", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(OnboardingPalette.labelPrimary)
                .onboardingEntrance(2)

            Spacer().frame(height: 12)

            providerChips

            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The five Figma-featured providers, in frame order.
    private static let featuredPresets: [ProviderPreset] = [
        .openai, .anthropic, .xai, .openrouter, .google,
    ]

    /// Remaining connectable presets revealed by "+ More": every API-key
    /// picker preset not already featured. The custom OpenAI-compatible
    /// endpoint has its own always-visible chip next to Claude Code.
    private static var morePresets: [ProviderPreset] {
        ProviderPreset.apiKeyPickerGroups(includeAzure: false)
            .flatMap(\.presets)
            .filter { !featuredPresets.contains($0) && $0 != .custom }
    }

    private var visiblePresets: [ProviderPreset] {
        state.showAllProviders
            ? Self.featuredPresets + Self.morePresets
            : Self.featuredPresets
    }

    /// Featured chips cascade in with a tight stagger after the card and
    /// header; the chips revealed by "+ More" instead pop in with the
    /// expansion animation itself.
    private var providerChips: some View {
        ChipFlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(Array(visiblePresets.enumerated()), id: \.element.id) { index, preset in
                let chip = OnboardingProviderChip(
                    logo: { OnboardingProviderLogo(preset: preset, size: 16) },
                    label: preset == .google ? "Gemini" : preset.name
                ) {
                    state.enterProvider(preset)
                }
                if index < Self.featuredPresets.count {
                    chip.onboardingEntrance(3 + index)
                } else {
                    chip.transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }

            OnboardingProviderChip(
                logo: {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(OnboardingPalette.labelPrimary)
                },
                label: "Claude Code"
            ) {
                state.enterClaudeCode()
            }
            .onboardingEntrance(3 + Self.featuredPresets.count)

            OnboardingProviderChip(
                logo: { OnboardingProviderLogo(preset: .custom, size: 16) },
                label: L("Custom")
            ) {
                state.enterCustomProvider()
            }
            .onboardingEntrance(4 + Self.featuredPresets.count)

            if !state.showAllProviders {
                OnboardingProviderChip(
                    logo: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(OnboardingPalette.labelPrimary)
                    },
                    label: L("More")
                ) {
                    // `smooth`: the chip grid reflows on expansion, and a
                    // wobbling layout reads as jank rather than character.
                    withAnimation(OnboardingMotion.smooth) {
                        state.showAllProviders = true
                    }
                }
                .transition(.scale(scale: 0.85).combined(with: .opacity))
                .onboardingEntrance(5 + Self.featuredPresets.count)
            }
        }
    }
}

// MARK: - Osaurus Cloud card

/// Intel: takes the place of upstream's recommended local-model card (MLX
/// models are Apple Silicon only). The managed Osaurus Router is the
/// ready-now brain on Intel: hosted models, the welcome credit, nothing to
/// download or paste. Same surface, badge and pill styles as upstream's card.
private struct OsaurusCloudCard: View {
    @ObservedObject var state: ConfigureAIState
    let onComplete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingPickedBadge(text: "Ready now")

            Spacer().frame(height: 12)

            Text("Osaurus Cloud", bundle: .module)
                .font(OnboardingTypography.cardTitle)
                .foregroundColor(OnboardingPalette.labelPrimary)

            Spacer().frame(height: 6)

            Text(
                "Hosted models with your welcome credit. Nothing to download or set up; connect your own provider any time in Settings.",
                bundle: .module
            )
            .font(OnboardingTypography.cardCaption)
            .foregroundColor(OnboardingPalette.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 16)

            OnboardingPillButton(
                title: "Use Osaurus Cloud",
                style: .primary,
                size: .compact,
                leadingSymbol: "cloud",
                action: { state.chooseOsaurusAndContinue(onComplete: onComplete) }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: OnboardingLayout.cardRadius, style: .continuous)
                .fill(OnboardingPalette.fill5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingLayout.cardRadius, style: .continuous)
                .strokeBorder(OnboardingPalette.fill8, lineWidth: 1)
        )
    }
}

// MARK: - Provider drill-in panel

/// Per-provider connect screen: back row, centered logo card, then the
/// connect option rows (browser sign-in and/or API key). A verified method
/// shows the green check; the left CTA (outside this panel) becomes
/// "Continue to Osaurus".
private struct ConfigureAIProviderPanel: View {
    @ObservedObject var state: ConfigureAIState

    private var preset: ProviderPreset? { state.currentAPIProvider }

    private var oauthKind: ProviderOAuthKind? {
        guard let preset else { return nil }
        return ProviderCatalog.entry(for: preset)?.primaryOAuthKind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            backRow

            if let preset {
                Spacer().frame(height: 24)

                HStack {
                    Spacer(minLength: 0)
                    OnboardingLogoCard(
                        logo: { OnboardingProviderLogo(preset: preset, size: 28) },
                        caption: displayName(preset)
                    )
                    Spacer(minLength: 0)
                }

                Spacer().frame(height: 40)

                optionRows(preset)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var backRow: some View {
        Button {
            state.popBYOKToHome()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("Back", bundle: .module)
                    .font(OnboardingTypography.cardCaption)
            }
            .foregroundColor(OnboardingPalette.labelSecondary)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .localizedHelp("Back")
    }

    private func displayName(_ preset: ProviderPreset) -> String {
        preset == .google ? "Gemini" : preset.name
    }

    @ViewBuilder
    private func optionRows(_ preset: ProviderPreset) -> some View {
        VStack(spacing: 12) {
            if oauthKind != nil {
                OnboardingOptionRow(
                    title: oauthRowTitle(preset),
                    caption: oauthRowCaption(preset),
                    isVerified: state.isAPISuccess && state.selectedAuthMethod.isOAuth
                ) {
                    state.openConnectDialog(.oauth)
                }
            }

            if preset.configuration.authType == .none {
                // Local presets (Ollama) — no key, one connect action.
                OnboardingOptionRow(
                    title: LocalizedStringKey(L("Connect to \(displayName(preset))")),
                    caption: "No API key required — connects to your local server",
                    isVerified: state.isAPISuccess && !state.selectedAuthMethod.isOAuth
                ) {
                    state.openConnectDialog(.apiKey)
                }
            } else {
                OnboardingOptionRow(
                    title: LocalizedStringKey(L("Provide an \(displayName(preset)) API Key")),
                    caption: keyRowCaption(preset),
                    isVerified: state.isAPISuccess && !state.selectedAuthMethod.isOAuth
                ) {
                    state.openConnectDialog(.apiKey)
                }
            }
        }
    }

    private func oauthRowTitle(_ preset: ProviderPreset) -> LocalizedStringKey {
        switch oauthKind {
        case .openAICodex: return "Sign in with a ChatGPT account"
        case .openRouter: return "Sign in with your OpenRouter account"
        case .xai: return "Sign in with your Grok account"
        case nil: return ""
        }
    }

    private func oauthRowCaption(_ preset: ProviderPreset) -> LocalizedStringKey {
        switch oauthKind {
        case .openAICodex: return "This will use your ChatGPT Plus/Pro subscription"
        case .openRouter: return "This will use your OpenRouter account"
        case .xai: return "This will use your SuperGrok or X Premium+ subscription"
        case nil: return ""
        }
    }

    private func keyRowCaption(_ preset: ProviderPreset) -> LocalizedStringKey {
        switch preset {
        case .openai: return "Paste a key from platform.openai.com"
        case .anthropic: return "Paste a key from console.anthropic.com"
        case .google: return "Paste a key from aistudio.google.com"
        case .xai: return "Paste a key from console.x.ai"
        case .openrouter: return "Paste a key from openrouter.ai"
        default: return "Paste a key from your provider dashboard"
        }
    }
}

// MARK: - Connect dialog

/// Centered connect dialog over the whole window (Figma connect frames):
/// provider logo card, title, caption, then either the browser sign-in
/// button (idle → "Authenticating…" with spinner) or the API-key field +
/// Connect button. Success closes the dialog; the drill-in shows the green
/// check and the left CTA becomes "Continue to Osaurus".
struct ProviderConnectDialog: View {
    @ObservedObject var state: ConfigureAIState

    private var preset: ProviderPreset? { state.currentAPIProvider }
    private var isOAuth: Bool { state.connectDialog == .oauth }

    var body: some View {
        OnboardingDialog(
            isDismissable: !state.isTesting,
            onClose: { state.closeConnectDialog() }
        ) {
            VStack(spacing: 0) {
                if let preset {
                    OnboardingLogoCard(
                        logo: { OnboardingProviderLogo(preset: preset, size: 24) },
                        caption: displayName(preset),
                        logoSize: 24
                    )

                    Spacer().frame(height: 24)

                    Text(title(preset))
                        .font(OnboardingTypography.cardTitle)
                        .foregroundColor(OnboardingPalette.labelWhite)
                        .multilineTextAlignment(.center)

                    Spacer().frame(height: 8)

                    Text(caption(preset))
                        .font(OnboardingTypography.cardCaption)
                        .foregroundColor(OnboardingPalette.labelSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if !isOAuth {
                        if preset == .custom {
                            Spacer().frame(height: 20)
                            customEndpointForm
                        } else if preset.configuration.authType == .apiKey {
                            Spacer().frame(height: 20)
                            keyField(preset)
                        }
                    }

                    if case .failure(let message) = state.testResult {
                        Spacer().frame(height: 12)
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.4))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 320)
                    }

                    Spacer().frame(height: 24)

                    actionButton(preset)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
        }
        .onChange(of: state.isAPISuccess) { success in  // Intel: single-value onChange (macOS 13)
            // A verified connection closes the dialog after a beat so the
            // user sees the state settle; the drill-in's check + the left
            // "Continue to Osaurus" CTA carry it from there.
            guard success else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                state.closeConnectDialog()
            }
        }
    }

    private func displayName(_ preset: ProviderPreset) -> String {
        preset == .google ? "Gemini" : preset.name
    }

    private func title(_ preset: ProviderPreset) -> String {
        if isOAuth {
            // Authenticating shortens the title to the account brand, per the
            // Figma authenticating frame.
            if state.isTesting, state.selectedOAuthKind == .openAICodex {
                return "ChatGPT"
            }
            switch state.selectedOAuthKind {
            case .openAICodex: return L("Sign in with a ChatGPT account")
            case .openRouter: return L("Sign in with your OpenRouter account")
            case .xai: return L("Sign in with your Grok account")
            case nil: return ""
            }
        }
        if preset == .custom {
            return L("Connect a custom endpoint")
        }
        if preset.configuration.authType == .none {
            return L("Connect to \(displayName(preset))")
        }
        return L("Provide an \(displayName(preset)) API Key")
    }

    private func caption(_ preset: ProviderPreset) -> String {
        if isOAuth {
            switch state.selectedOAuthKind {
            case .openAICodex: return L("This will use your ChatGPT Plus/Pro subscription")
            case .openRouter: return L("This will use your OpenRouter account")
            case .xai: return L("This will use your SuperGrok or X Premium+ subscription")
            case nil: return ""
            }
        }
        if preset == .custom {
            return L("Paste the URL of any OpenAI-compatible server. Local endpoints don't need a key.")
        }
        if preset.configuration.authType == .none {
            return L("No API key required — connects to your local server")
        }
        return L("Your key is stored securely in the macOS Keychain")
    }

    private func keyField(_ preset: ProviderPreset) -> some View {
        SecureField(L("sk-..."), text: $state.apiKey)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(OnboardingPalette.labelPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(OnboardingPalette.fill5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(OnboardingPalette.fill10, lineWidth: 1)
            )
            .frame(maxWidth: 300)
            .onChange(of: state.apiKey) { _ in state.testResult = nil }
    }

    /// Single paste-the-URL form for the custom OpenAI-compatible endpoint.
    /// The URL is parsed into scheme/host/port/path behind the scenes
    /// (`CustomProviderForm.parse`); a resolved preview confirms how the
    /// paste was understood. Optional key below for authenticated servers.
    private var customEndpointForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            formField("http://localhost:11434/v1", text: $state.customEndpointURL)

            SecureField(L("API key (optional for local servers)"), text: $state.apiKey)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(OnboardingPalette.labelPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OnboardingPalette.fill5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(OnboardingPalette.fill10, lineWidth: 1)
                )

            // Confirm how the paste was understood, but only when parsing
            // actually added something (scheme, default /v1) beyond the
            // literal input — echoing an identical URL back is noise.
            if !state.customForm.host.isEmpty,
                state.customForm.endpointPreview
                    != state.customEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
            {
                Text(state.customForm.endpointPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(OnboardingPalette.labelSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: 320)
        .onChange(of: state.customForm) { _ in state.testResult = nil }
        .onChange(of: state.apiKey) { _ in state.testResult = nil }
    }

    private func formField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(OnboardingPalette.labelPrimary)
            .autocorrectionDisabled()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(OnboardingPalette.fill5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(OnboardingPalette.fill10, lineWidth: 1)
            )
    }

    @ViewBuilder
    private func actionButton(_ preset: ProviderPreset) -> some View {
        if state.isTesting {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(
                    isOAuth
                        ? LocalizedStringKey("Authenticating...")
                        : LocalizedStringKey("Connecting..."),
                    bundle: .module
                )
                .font(OnboardingTypography.chip)
                .foregroundColor(OnboardingPalette.labelPrimary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(OnboardingPalette.fill8))
        } else if state.isAPISuccess {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text("Connected", bundle: .module)
                    .font(OnboardingTypography.chip)
            }
            .foregroundColor(OnboardingPalette.dinoGreen)
            .padding(.vertical, 8)
        } else {
            OnboardingPillButton(
                title: idleButtonTitle,
                style: .primary,
                size: .compact,
                isEnabled: state.canTestAPI,
                action: { state.testAPIConnection() }
            )
        }
    }

    private var idleButtonTitle: LocalizedStringKey {
        if isOAuth, let kind = state.selectedOAuthKind {
            return LocalizedStringKey(kind.ctaTitle)
        }
        if case .failure = state.testResult { return "Try again" }
        return "Connect"
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingConfigureAIView_Previews: PreviewProvider {
        static var previews: some View {
            ZStack {
                OnboardingPalette.windowBackground
                ConfigureAIStepView(state: ConfigureAIState(), onComplete: {})
            }
            .frame(width: OnboardingMetrics.windowWidth, height: OnboardingMetrics.windowHeight)
        }
    }
#endif
