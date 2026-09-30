//
//  ConfigurationView.swift
//  osaurus
//
//  The "General" sidebar tab (upstream #2950 layout): everyday app
//  behaviour up top (hotkey, login, dock, updates, the Core Model,
//  notifications), notification details and Data & Storage under a
//  collapsed Advanced section, and Factory Reset last.
//
//  Intel differences from upstream's page (docs/SETTINGS_REDESIGN_INTEL.md):
//  - No "Models on This Mac", Models Directory or Model Sources rows (local
//    MLX models need Apple Silicon).
//  - Notification position, timeout and stack size stay editable (upstream
//    hid them); they sit under Advanced with the background task limit.
//  - No Legal links: upstream's pages cover upstream's own service.
//  - The chat settings moved to Conversation (`ChatSettingsView`), the
//    command-line tool to Developer Tools → Server → Overview, and the
//    Storage tab into Advanced → Data & Storage. The old Work generation
//    sliders and the Capability Search picker were dropped: nothing on
//    Intel reads them (upstream's local agent loop and preflight search are
//    not compiled).
//

import AppKit
import SwiftUI

// MARK: - Configuration View
struct ConfigurationView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @EnvironmentObject private var updater: UpdaterViewModel

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var tempStartAtLogin: Bool = false
    @State private var tempHideDockIcon: Bool = false
    @State private var isResetting = false

    @State private var tempChatHotkey: Hotkey? = nil
    @State private var tempCoreModelProvider: String = ""
    @State private var tempCoreModelName: String = ""
    @State private var coreModelPickerItems: [ModelPickerItem] = []
    @State private var isCoreModelMenuPresented = false

    // Notifications (saved immediately on change, outside the form baseline).
    @State private var tempToastPosition: ToastPosition = .topRight
    @State private var tempToastTimeout: String = ""
    @State private var tempToastEnabled: Bool = true
    @State private var tempToastMaxVisible: String = ""
    @State private var tempToastMaxConcurrent: String = ""

    /// Baseline of the save-relevant fields as last loaded or saved; the
    /// debounced auto-save only runs when the live form differs.
    @State private var savedFormState: SaveableFormState?
    @State private var autoSaveTask: Task<Void, Never>?

    /// Landing anchors rendered inside the Advanced disclosure, so a search
    /// result for one of them opens it before scrolling.
    static let advancedAnchorIds: Set<String> = [
        "settings.notifications.timeout", "settings.notifications.maxVisible",
        "settings.notifications.maxConcurrentTasks", "storage.encryption", "storage.backup",
    ]

    var body: some View {
        ZStack {
            SettingsPage {
                ManagerHeader(
                    title: L("General"),
                    subtitle: L("App behavior, the Core Model, notifications, and data")
                )
            } content: {
                generalSection
                coreModelSection
                notificationsSection
                advancedSection
                resetSection
            }

            if isResetting {
                factoryResetOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear { loadConfiguration() }
        .onReceive(ModelPickerItemCache.shared.$items) { options in
            coreModelPickerItems = options
        }
        .onChange(of: currentFormState) { _ in scheduleAutoSave() }
        .onDisappear { flushPendingSave() }
    }

    // MARK: - Sections

    private var generalSection: some View {
        SettingsSection(title: "General", icon: "gear") {
            SettingsRow(
                title: L("Global Hotkey"), description: "Open Osaurus from anywhere",
                anchorId: "settings.general.hotkey"
            ) {
                HotkeyRecorder(value: $tempChatHotkey)
            }

            SettingsToggle(
                title: L("Start at Login"),
                description: "Launch Osaurus when you sign in",
                anchorId: "settings.general.login",
                isOn: $tempStartAtLogin
            )

            SettingsToggle(
                title: L("Hide Dock Icon"),
                description: "Run in menu bar only (requires restart)",
                anchorId: "settings.general.dock",
                isOn: $tempHideDockIcon
            )

            SettingsToggle(
                title: L("Beta Updates"),
                description: "Receive pre-release updates with new features before they're generally available",
                anchorId: "settings.general.updates",
                isOn: $updater.isBetaChannel
            )
        }
    }

    private var coreModelSection: some View {
        SettingsSection(title: "Core Model", icon: "cube", anchorId: "settings.general.coreModel") {
            VStack(alignment: .leading, spacing: 8) {
                coreModelPicker
                Text(
                    "Model used in the background for memory, chat titles and transcription cleanup. If unset, your active chat model is used.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var notificationsSection: some View {
        SettingsSection(title: "Notifications", icon: "bell") {
            SettingsToggle(
                title: L("Show Toast Notifications"),
                description: "Display notifications for background tasks and events",
                anchorId: "settings.notifications.toasts",
                isOn: $tempToastEnabled
            )
            .onChange(of: tempToastEnabled) { _ in saveToastConfig() }

            SettingsRow(
                title: L("Toast Position"), description: "Where toasts appear on screen",
                anchorId: "settings.notifications.position"
            ) {
                ToastPositionPicker(selection: $tempToastPosition)
                    .frame(width: 190)
                    .onChange(of: tempToastPosition) { _ in saveToastConfig() }
            }

            SettingsRow(title: L("Test Toast"), description: "Show a sample notification") {
                Button(action: showTestToast) {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.badge")
                            .font(.system(size: 12))
                        Text("Test Toast", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(SettingsButtonStyle())
            }
        }
    }

    private var advancedSection: some View {
        SettingsAdvancedDisclosure(anchorIds: Self.advancedAnchorIds) {
            StyledSettingsTextField(
                label: "Default Timeout",
                text: $tempToastTimeout,
                placeholder: "5.0",
                help: "Seconds before a toast dismisses itself. Empty uses the default of 5 seconds.",
                anchorId: "settings.notifications.timeout"
            )
            .onChange(of: tempToastTimeout) { _ in saveToastConfig() }

            StyledSettingsTextField(
                label: "Max Visible Toasts",
                text: $tempToastMaxVisible,
                placeholder: "5",
                help: "Maximum toasts shown at once. Empty uses default 5",
                anchorId: "settings.notifications.maxVisible"
            )
            .onChange(of: tempToastMaxVisible) { _ in saveToastConfig() }

            StyledSettingsTextField(
                label: "Max Concurrent Tasks",
                text: $tempToastMaxConcurrent,
                placeholder: "5",
                help: "How many background tasks (indexing, scheduled runs, watchers) may run at once. Empty uses the default of 5.",
                anchorId: "settings.notifications.maxConcurrentTasks"
            )
            .onChange(of: tempToastMaxConcurrent) { _ in saveToastConfig() }

            SettingsSubsection(label: "Data & Storage") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("How your local data is protected on disk.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    StorageSettingsView(embedded: true)
                }
            }
        }
    }

    private var resetSection: some View {
        SettingsDestructiveZone(title: "Reset", anchorId: "settings.general.maintenance") {
            SettingsDestructiveRow(
                title: "Factory Reset",
                description:
                    "Permanently deletes all data and settings — chat history, agents, memory, and your identity keys — then quits Osaurus. This cannot be undone.",
                actionTitle: "Factory Reset…"
            ) {
                showFactoryResetConfirmation()
            }
        }
    }

    private var factoryResetOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(theme.accentColor)

                VStack(spacing: 8) {
                    Text("Resetting Osaurus", bundle: .module)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(theme.primaryText)

                    Text("Deleting data and preferences. Please wait…", bundle: .module)
                        .font(.system(size: 14))
                        .foregroundColor(theme.secondaryText)
                }
            }
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(theme.cardBackground)
                    .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(theme.cardBorder, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .zIndex(100)
    }

    // MARK: - Persistence

    struct SaveableFormState: Equatable {
        var startAtLogin: Bool
        var hideDockIcon: Bool
        var hotkey: Hotkey?
        var coreModelProvider: String
        var coreModelName: String
    }

    private var currentFormState: SaveableFormState {
        SaveableFormState(
            startAtLogin: tempStartAtLogin,
            hideDockIcon: tempHideDockIcon,
            hotkey: tempChatHotkey,
            coreModelProvider: tempCoreModelProvider,
            coreModelName: tempCoreModelName
        )
    }

    private func loadConfiguration() {
        let server = ServerConfigurationStore.load() ?? ServerConfiguration.default
        tempStartAtLogin = server.startAtLogin
        tempHideDockIcon = server.hideDockIcon

        let chat = ChatConfigurationStore.load()
        tempChatHotkey = chat.hotkey
        tempCoreModelProvider = chat.coreModelProvider ?? ""
        tempCoreModelName = chat.coreModelName ?? ""

        let toast = ToastConfigurationStore.load()
        let defaults = ToastConfiguration.default
        tempToastPosition = toast.position
        tempToastEnabled = toast.enabled
        tempToastTimeout = toast.defaultTimeout == defaults.defaultTimeout ? "" : String(toast.defaultTimeout)
        tempToastMaxVisible =
            toast.maxVisibleToasts == defaults.maxVisibleToasts ? "" : String(toast.maxVisibleToasts)
        tempToastMaxConcurrent =
            toast.maxConcurrentTasks == defaults.maxConcurrentTasks ? "" : String(toast.maxConcurrentTasks)

        savedFormState = currentFormState
    }

    private func scheduleAutoSave() {
        guard let savedFormState, savedFormState != currentFormState else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            saveConfiguration()
        }
    }

    private func flushPendingSave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        if let savedFormState, savedFormState != currentFormState { saveConfiguration() }
    }

    /// Writes only the General-owned fields: login/dock on the server
    /// configuration, the hotkey and Core Model on the shared chat
    /// configuration (Conversation owns the rest of it).
    private func saveConfiguration() {
        let form = currentFormState
        let previousServer = ServerConfigurationStore.load() ?? ServerConfiguration.default
        var server = previousServer
        server.startAtLogin = form.startAtLogin
        server.hideDockIcon = form.hideDockIcon
        if server != previousServer {
            ServerConfigurationStore.save(server)
            if previousServer.startAtLogin != server.startAtLogin {
                LoginItemService.shared.applyStartAtLogin(server.startAtLogin)
            }
            Task { @MainActor in AppDelegate.shared?.serverController.configuration = server }
        }

        let chat = ChatConfigurationStore.load()
        // Intel's `ChatConfiguration` is a shared class: capture the old
        // hotkey as a value before mutating it.
        let previousHotkey = chat.hotkey
        chat.hotkey = form.hotkey
        chat.coreModelProvider = form.coreModelProvider.isEmpty ? nil : form.coreModelProvider
        chat.coreModelName = form.coreModelName.isEmpty ? nil : form.coreModelName
        ChatConfigurationStore.save(chat)
        if previousHotkey != form.hotkey {
            AppDelegate.shared?.applyChatHotkey()
        }
        savedFormState = form
    }

    // MARK: - Factory Reset

    private func showFactoryResetConfirmation() {
        let alert = NSAlert()
        alert.messageText = L("Factory Reset Osaurus?")
        alert.informativeText =
            L(
                "This will permanently delete all your data, including chat history, agents, memory, and your identity keys. This action cannot be undone and the application will close."
            )
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Factory Reset")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task { @MainActor in
                withAnimation(.easeIn(duration: 0.3)) {
                    isResetting = true
                }
                // Yield so the overlay paints before the deletion starts.
                try? await Task.sleep(nanoseconds: 100_000_000)
                await OnboardingService.shared.performFactoryReset()
            }
        }
    }

    // MARK: - Core Model Picker

    private var coreModelIdentifierBinding: Binding<String> {
        Binding(
            get: {
                if tempCoreModelName.isEmpty { return "" }
                return tempCoreModelProvider.isEmpty
                    ? tempCoreModelName
                    : "\(tempCoreModelProvider)/\(tempCoreModelName)"
            },
            set: { newValue in
                if newValue.isEmpty {
                    tempCoreModelProvider = ""
                    tempCoreModelName = ""
                    return
                }
                let parts = newValue.split(separator: "/", maxSplits: 1)
                if parts.count == 2 {
                    tempCoreModelProvider = String(parts[0])
                    tempCoreModelName = String(parts[1])
                } else {
                    tempCoreModelProvider = ""
                    tempCoreModelName = newValue
                }
            }
        )
    }

    private var coreModelPicker: some View {
        let selectedIdentifier = coreModelIdentifierBinding.wrappedValue

        return Button {
            isCoreModelMenuPresented.toggle()
        } label: {
            HStack(spacing: 10) {
                Text(
                    CoreModelSelectionPresentation.title(
                        identifier: selectedIdentifier,
                        items: coreModelPickerItems
                    )
                )
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)

                Spacer(minLength: 8)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.inputBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 280)
        .popover(isPresented: $isCoreModelMenuPresented, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    coreModelOption(
                        title: "Use chat model (default)",
                        identifier: "",
                        selectedIdentifier: selectedIdentifier
                    )

                    if !selectedIdentifier.isEmpty,
                        !coreModelPickerItems.contains(where: { $0.id == selectedIdentifier })
                    {
                        Divider().padding(.vertical, 2)
                        coreModelOption(
                            title: "\(selectedIdentifier) (unavailable)",
                            identifier: selectedIdentifier,
                            selectedIdentifier: selectedIdentifier
                        )
                    }

                    if !coreModelPickerItems.isEmpty { Divider().padding(.vertical, 2) }
                    ForEach(coreModelPickerItems) { option in
                        coreModelOption(
                            title: option.displayName,
                            identifier: option.id,
                            selectedIdentifier: selectedIdentifier
                        )
                    }
                }
                .padding(8)
            }
            .frame(width: 280)
            .frame(maxHeight: 320)
            .background(theme.cardBackground)
            .environment(\.theme, themeManager.currentTheme)
        }
    }

    private func coreModelOption(
        title: String,
        identifier: String,
        selectedIdentifier: String
    ) -> some View {
        Button {
            coreModelIdentifierBinding.wrappedValue = identifier
            isCoreModelMenuPresented = false
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if selectedIdentifier == identifier {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Notifications

    private func saveToastConfig() {
        let defaults = ToastConfiguration.default

        let trimmedTimeout = tempToastTimeout.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedTimeout: TimeInterval = {
            guard !trimmedTimeout.isEmpty, let v = Double(trimmedTimeout) else {
                return defaults.defaultTimeout
            }
            return max(1.0, min(30.0, v))
        }()

        let trimmedMaxVisible = tempToastMaxVisible.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedMaxVisible: Int = {
            guard !trimmedMaxVisible.isEmpty, let v = Int(trimmedMaxVisible) else {
                return defaults.maxVisibleToasts
            }
            return max(1, min(10, v))
        }()

        let trimmedMaxConcurrent = tempToastMaxConcurrent.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedMaxConcurrent: Int = {
            guard !trimmedMaxConcurrent.isEmpty, let v = Int(trimmedMaxConcurrent) else {
                return defaults.maxConcurrentTasks
            }
            return max(1, min(50, v))
        }()

        let config = ToastConfiguration(
            position: tempToastPosition,
            defaultTimeout: parsedTimeout,
            maxVisibleToasts: parsedMaxVisible,
            groupByAgent: true,
            enabled: tempToastEnabled,
            maxConcurrentTasks: parsedMaxConcurrent
        )

        ToastManager.shared.updateConfiguration(config)
    }

    private func showTestToast() {
        ToastManager.shared.success(
            "Test Notification",
            message: "Toast notifications are working!"
        )
    }
}

enum CoreModelSelectionPresentation {
    static func title(identifier: String, items: [ModelPickerItem]) -> String {
        guard !identifier.isEmpty else { return "Use chat model (default)" }
        if let selected = items.first(where: { $0.id == identifier }) {
            return selected.displayName
        }
        return "\(identifier) (unavailable)"
    }
}

// MARK: - Toast Position Picker

private struct ToastPositionPicker: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Binding var selection: ToastPosition

    @State private var isHovered = false

    var body: some View {
        Menu {
            ForEach(ToastPosition.allCases, id: \.self) { position in
                Button(action: { selection = position }) {
                    HStack {
                        Text(position.displayName)
                        if selection == position {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: positionIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.accentColor)

                Text(selection.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.primaryText)

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isHovered
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isHovered ? 1.5 : 1
                            )
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var positionIcon: String {
        switch selection {
        case .topRight, .topLeft, .topCenter:
            return "arrow.up.square"
        case .bottomRight, .bottomLeft, .bottomCenter:
            return "arrow.down.square"
        }
    }
}
