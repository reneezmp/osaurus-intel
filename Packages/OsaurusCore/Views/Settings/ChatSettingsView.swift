//
//  ChatSettingsView.swift
//  osaurus
//
//  The "Conversation" sidebar tab (`ManagementTab.chat`, upstream #2950):
//  how chats look and behave. Everyday switches sit in the open; the
//  generation defaults and limits sit under a collapsed Advanced section.
//
//  Intel version, not upstream's file. It hosts the chat settings that used
//  to crowd Intel's General page:
//  - Upstream's smooth streaming, activity roll-up, expand-thinking,
//    keep-awake, follow-up and compaction-model switches are not here: Intel
//    lacks those features (backlog `W-chat-ux`, `W-ui-misc`).
//  - Intel keeps switches upstream moved elsewhere because Intel has no
//    other home for them yet: Disable Tools and Enable Memory (upstream:
//    Agents / Memory), Folder Tool Permissions (upstream: Tools & MCP,
//    step 3 of docs/SETTINGS_REDESIGN_INTEL.md), Context Length (upstream:
//    Server → Cache, which Intel hides) and the Orchestrator fallbacks
//    (System Prompt / Temperature / Max Tokens feed the built-in agent when
//    it has no value of its own).
//  - Generative greetings stay (an Intel feature upstream no longer shows).
//
//  Persistence: debounced auto-save of the fields this page owns,
//  load-modify-write on the shared `ChatConfiguration` so the General page's
//  hotkey and Core Model are never clobbered.
//

import SwiftUI

struct ChatSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    // `ChatConfiguration`-backed fields (debounced auto-save).
    @State private var tempSystemPrompt: String = ""
    @State private var tempChatTemperature: String = ""
    @State private var tempChatMaxTokens: String = ""
    @State private var tempChatContextLength: String = ""
    @State private var tempChatTopP: String = ""
    @State private var tempChatMaxToolAttempts: String = ""
    @State private var tempDisableTools: Bool = true
    @State private var tempEnableClipboardMonitoring: Bool = false
    @State private var tempAutoGenerateChatTitles: Bool = true
    @State private var tempBackfillAgentDescriptions: Bool = false
    @State private var tempGenerativeGreetingsEnabled: Bool = false
    @State private var tempGreetingPersona: String = ""
    /// `MemoryConfiguration.enabled` (same debounced save).
    @State private var tempMemoryEnabled: Bool = false

    // `UserDefaults`-backed switches, applied immediately.
    @AppStorage(NewChatShortcutSetting.defaultsKey)
    private var cmdNStartsNewChatInCurrentWindow: Bool = false
    @AppStorage(ComposerSpellCheckSetting.defaultsKey)
    private var composerSpellCheckEnabled: Bool = ComposerSpellCheckSetting.defaultValue

    /// Baseline of the save-relevant fields as last loaded or saved; a
    /// pristine page never writes to disk.
    @State private var savedFormState: SaveableFormState?
    @State private var autoSaveTask: Task<Void, Never>?

    /// Landing anchors rendered inside the Advanced disclosure, so a search
    /// result for one of them opens it before scrolling.
    nonisolated static let advancedAnchorIds: Set<String> = [
        "settings.chat.systemPrompt", "settings.chat.temperature", "settings.chat.maxTokens",
        "settings.chat.contextLength", "settings.chat.topP", "settings.chat.maxToolAttempts",
    ]

    var body: some View {
        SettingsPage {
            ManagerHeader(
                title: L("Conversation"),
                subtitle: L("How chats look and behave. The Orchestrator's own persona lives under Orchestrator.")
            )
        } content: {
            appearanceSection
            behaviorSection
            greetingsSection
            folderToolsSection
            advancedSection
        }
        .onAppear { loadConfiguration() }
        .onChange(of: currentFormState) { _ in scheduleAutoSave() }
        .onDisappear { flushPendingSave() }
    }

    // MARK: - Sections

    private var appearanceSection: some View {
        SettingsSection(title: "Appearance", icon: "text.bubble") {
            SettingsToggle(
                title: L("Check Spelling While Typing"),
                description:
                    "Underline misspelled words in the chat input and offer corrections on right-click, using your macOS language and dictionary.",
                anchorId: "settings.chat.spellCheck",
                isOn: $composerSpellCheckEnabled
            )
        }
    }

    private var behaviorSection: some View {
        SettingsSection(title: "Behavior", icon: "sparkles") {
            SettingsToggle(
                title: L("Automatically Name Chats"),
                description:
                    "Give each chat a short descriptive title after its first reply. Runs in the background; manual renames always win.",
                anchorId: "settings.chat.titles",
                isOn: $tempAutoGenerateChatTitles
            )

            SettingsLinkRow(
                title: "Core Model",
                description: "Chat titles are written by the Core Model set under General.",
                icon: "arrow.right",
                actionTitle: "Change"
            ) {
                SettingsHighlightCoordinator.shared.request("settings.general.coreModel")
                ManagementStateManager.shared.selectedTab = .settings
            }

            SettingsToggle(
                title: L("Fill In Missing Agent Descriptions"),
                description:
                    "For agents without a description, write a one-line purpose from their instructions in the background, so the Orchestrator and agent lists can show what each agent is for. Uses each agent's cloud model (a small paid request per agent, again only when its instructions change). Descriptions you write always win.",
                anchorId: "settings.chat.agentDescriptions",
                isOn: $tempBackfillAgentDescriptions
            )

            SettingsToggle(
                title: L("Clipboard Monitoring"),
                description:
                    "Offer text you've just copied in any app as context, and grab the current selection when you summon Osaurus.",
                anchorId: "settings.chat.clipboard",
                isOn: $tempEnableClipboardMonitoring
            )

            SettingsToggle(
                title: L("⌘+N Starts a New Chat in the Current Window"),
                description:
                    "New Window moves to ⇧+⌘+N, matching other chat apps. Turn off to keep ⌘+N opening a new window.",
                anchorId: "settings.chat.newChatShortcut",
                isOn: $cmdNStartsNewChatInCurrentWindow
            )

            SettingsToggle(
                title: L("Disable Tools"),
                description:
                    "Send messages directly to the model with no tool specs or capability injection. Turn off to let agents use built-in and plugin tools.",
                anchorId: "settings.chat.disableTools",
                isOn: $tempDisableTools
            )

            SettingsToggle(
                title: L("Enable Memory"),
                description:
                    "Inject persistent memory (identity, pinned facts, episodes) into chats. A relevance gate decides per turn whether memory is needed. The Memory tab has the details.",
                anchorId: "settings.chat.memory",
                isOn: $tempMemoryEnabled
            )
        }
    }

    private var greetingsSection: some View {
        SettingsSection(title: "Greetings", icon: "hand.wave") {
            SettingsToggle(
                title: L("AI-Generated Greetings"),
                description:
                    "Each empty chat generates a fresh greeting and quick actions on the Core Model. The static greeting still shows instantly. Per-agent settings still win.",
                anchorId: "settings.chat.greetings",
                isOn: $tempGenerativeGreetingsEnabled
            )

            if tempGenerativeGreetingsEnabled {
                personalityEditorBlock
            }
        }
    }

    private var folderToolsSection: some View {
        SettingsSection(title: "Folder Tool Permissions", icon: "folder") {
            FolderToolPermissionsList()
                .settingsLandingAnchor("settings.work.permissions")
        }
    }

    private var advancedSection: some View {
        SettingsAdvancedDisclosure(anchorIds: Self.advancedAnchorIds) {
            StyledSettingsTextArea(
                label: "System Prompt",
                text: $tempSystemPrompt,
                placeholder: "Enter instructions for the Orchestrator...",
                hint: "Used by the Orchestrator when it has no prompt of its own (Orchestrator settings)."
            )
            .settingsLandingAnchor("settings.chat.systemPrompt")

            SettingsSliderField(
                label: "Temperature",
                help: "Randomness (0–2) for the Orchestrator when it has no value of its own.",
                text: $tempChatTemperature,
                range: 0 ... 2,
                step: 0.1,
                defaultValue: 0.7,
                formatString: "%.1f",
                anchorId: "settings.chat.temperature"
            )
            SettingsStepperField(
                label: "Max Tokens",
                help: "Maximum response tokens for the Orchestrator when it has no value of its own.",
                text: $tempChatMaxTokens,
                range: 1 ... 65536,
                step: 1024,
                defaultValue: 16384,
                anchorId: "settings.chat.maxTokens"
            )
            SettingsStepperField(
                label: "Context Length",
                help: "Context window assumed for remote models.",
                text: $tempChatContextLength,
                range: 2048 ... 256000,
                step: 1024,
                defaultValue: 128000,
                anchorId: "settings.chat.contextLength"
            )
            SettingsSliderField(
                label: "Top P Override",
                help: "Sampling diversity (0–1) for chats.",
                text: $tempChatTopP,
                range: 0 ... 1,
                step: 0.05,
                defaultValue: 1.0,
                formatString: "%.2f",
                anchorId: "settings.chat.topP"
            )
            SettingsStepperField(
                label: "Max Tool Attempts",
                help: "Maximum consecutive tool calls per turn before the agent must answer.",
                text: $tempChatMaxToolAttempts,
                range: 1 ... 50,
                step: 1,
                defaultValue: 15,
                anchorId: "settings.chat.maxToolAttempts"
            )
        }
    }

    // MARK: - Greeting personality

    /// Label row + multi-line editor + hint. The editor is prefilled with the
    /// built-in default so it is never empty; an unedited default is stored
    /// as "" so future default updates still reach the user.
    private var personalityEditorBlock: some View {
        let defaultText = GenerativeGreetingService.defaultPersonaInstruction
        let isAtDefault =
            tempGreetingPersona.trimmingCharacters(in: .whitespacesAndNewlines)
            == defaultText.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Personality (default for all agents)", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Spacer()
                if !isAtDefault {
                    Button {
                        tempGreetingPersona = defaultText
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Reset to Default", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            TextEditor(text: $tempGreetingPersona)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 100, maxHeight: 200)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )

            Text(
                "Shapes the voice of AI-generated empty-state greetings and quick actions. Each agent can override this in its Customization tab.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
        }
    }

    // MARK: - Persistence

    struct SaveableFormState: Equatable {
        var systemPrompt: String
        var temperature: String
        var maxTokens: String
        var contextLength: String
        var topP: String
        var maxToolAttempts: String
        var disableTools: Bool
        var clipboard: Bool
        var autoTitles: Bool
        var backfillDescriptions: Bool
        var greetingsEnabled: Bool
        var greetingPersona: String
        var memoryEnabled: Bool
    }

    private var currentFormState: SaveableFormState {
        SaveableFormState(
            systemPrompt: tempSystemPrompt,
            temperature: tempChatTemperature,
            maxTokens: tempChatMaxTokens,
            contextLength: tempChatContextLength,
            topP: tempChatTopP,
            maxToolAttempts: tempChatMaxToolAttempts,
            disableTools: tempDisableTools,
            clipboard: tempEnableClipboardMonitoring,
            autoTitles: tempAutoGenerateChatTitles,
            backfillDescriptions: tempBackfillAgentDescriptions,
            greetingsEnabled: tempGenerativeGreetingsEnabled,
            greetingPersona: tempGreetingPersona,
            memoryEnabled: tempMemoryEnabled
        )
    }

    private func loadConfiguration() {
        let chat = ChatConfigurationStore.load()
        tempSystemPrompt = chat.systemPrompt
        tempChatTemperature = chat.temperature.map { String($0) } ?? ""
        tempChatMaxTokens = chat.maxTokens.map(String.init) ?? ""
        tempChatContextLength = chat.contextLength.map(String.init) ?? ""
        tempChatTopP = chat.topPOverride.map { String($0) } ?? ""
        tempChatMaxToolAttempts = chat.maxToolAttempts.map(String.init) ?? ""
        tempDisableTools = chat.disableTools
        tempEnableClipboardMonitoring = chat.enableClipboardMonitoring
        tempAutoGenerateChatTitles = chat.autoGenerateChatTitles
        tempBackfillAgentDescriptions = chat.backfillAgentDescriptions
        tempGenerativeGreetingsEnabled = chat.generativeGreetingsEnabled
        tempGreetingPersona =
            chat.greetingPersona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? GenerativeGreetingService.defaultPersonaInstruction
            : chat.greetingPersona
        tempMemoryEnabled = MemoryConfigurationStore.load().enabled
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

    private func saveConfiguration() {
        let form = currentFormState
        let chat = ChatConfigurationStore.load()
        let backfillTurnedOn = form.backfillDescriptions && !chat.backfillAgentDescriptions
        Self.apply(form, to: chat)
        ChatConfigurationStore.save(chat)
        if backfillTurnedOn { AgentDescriptionBackfill.shared.scheduleAll() }

        var memory = MemoryConfigurationStore.load()
        if memory.enabled != form.memoryEnabled {
            memory.enabled = form.memoryEnabled
            MemoryConfigurationStore.save(memory)
        }
        savedFormState = form
    }

    /// Writes only the Conversation-owned fields (the hotkey and Core Model
    /// belong to General). Blank numeric fields mean "use the default".
    nonisolated static func apply(_ form: SaveableFormState, to chat: ChatConfiguration) {
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        chat.systemPrompt = form.systemPrompt
        chat.temperature = Float(trimmed(form.temperature)).map { max(0, min(2, $0)) }
        chat.maxTokens = Int(trimmed(form.maxTokens)).map { max(1, $0) }
        chat.contextLength = Int(trimmed(form.contextLength)).map { max(2048, $0) }
        chat.topPOverride = Double(trimmed(form.topP)).map { max(0, min(1, $0)) }
        chat.maxToolAttempts = Int(trimmed(form.maxToolAttempts)).map { max(1, min(50, $0)) }
        chat.disableTools = form.disableTools
        chat.enableClipboardMonitoring = form.clipboard
        chat.autoGenerateChatTitles = form.autoTitles
        chat.backfillAgentDescriptions = form.backfillDescriptions
        chat.generativeGreetingsEnabled = form.greetingsEnabled
        let persona = trimmed(form.greetingPersona)
        chat.greetingPersona =
            persona == trimmed(GenerativeGreetingService.defaultPersonaInstruction) ? "" : form.greetingPersona
    }
}

// MARK: - Styled Settings Text Area

struct StyledSettingsTextArea: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    @Binding var text: String
    let placeholder: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.primaryText)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(LocalizedStringKey(placeholder), bundle: .module)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.placeholderText)
                        .padding(.top, 12)
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100, maxHeight: 160)
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                    )
            )

            Text(LocalizedStringKey(hint), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
        }
    }
}

// MARK: - Folder tool permissions

/// Approval policy for the folder tools that change files or run commands.
/// Moved from Intel's old General → Work section; upstream shows these on
/// Tools & MCP (step 3 of the redesign).
struct FolderToolPermissionsList: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var refreshId = UUID()

    // (name, display, desc, destructive, defaultPolicy)
    static let folderTools:
        [(name: String, display: String, desc: String, destructive: Bool, defaultPolicy: ToolPermissionPolicy)] = [
            ("file_write", "Write Files", "Create and modify files", false, .auto),
            ("file_edit", "Edit Files", "Edit file content with search/replace", false, .auto),
            ("shell_run", "Run Shell Commands", "Execute shell commands in the folder", true, .ask),
            ("git_commit", "Git Commit", "Commit changes to git repository", true, .ask),
        ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Control how folder tools execute when chat has access to a working folder.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(themeManager.currentTheme.tertiaryText)

            VStack(spacing: 0) {
                ForEach(Self.folderTools, id: \.name) { tool in
                    FolderToolPermissionRow(
                        name: tool.name,
                        displayName: tool.display,
                        description: tool.desc,
                        isDestructive: tool.destructive,
                        defaultPolicy: tool.defaultPolicy,
                        onPolicyChange: { refreshId = UUID() }
                    )
                }
            }
            .id(refreshId)

            HStack {
                Spacer()
                Button(action: resetAllToDefault) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11))
                        Text("Reset All to Default", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(SettingsButtonStyle())
                .localizedHelp("Reset all work tool permissions to default")
            }
        }
    }

    private func resetAllToDefault() {
        for tool in Self.folderTools {
            ToolRegistry.shared.clearPolicy(for: tool.name)
        }
        refreshId = UUID()
    }
}

private struct FolderToolPermissionRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    /// Observing `ToolRegistry` lets the row read the configured policy from
    /// memory instead of a `tools.json` read in every body evaluation.
    @ObservedObject private var toolRegistry = ToolRegistry.shared
    @State private var configuredPolicy: ToolPermissionPolicy?

    let name: String
    let displayName: String
    let description: String
    let isDestructive: Bool
    let defaultPolicy: ToolPermissionPolicy
    let onPolicyChange: () -> Void

    private var effectivePolicy: ToolPermissionPolicy {
        configuredPolicy ?? defaultPolicy
    }

    var body: some View {
        HStack(spacing: 12) {
            if isDestructive {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.warningColor)
                    .frame(width: 16)
            } else {
                Color.clear.frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(displayName), bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                Text(LocalizedStringKey(description), bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
            }

            Spacer()

            ThemedSegmentedPicker(
                selection: Binding(
                    get: { effectivePolicy },
                    set: { newValue in
                        toolRegistry.setPolicy(newValue, for: name)
                        configuredPolicy = toolRegistry.configuredPolicy(for: name)
                        onPolicyChange()
                    }
                ),
                options: [
                    (ToolPermissionPolicy.auto, "Auto"),
                    (ToolPermissionPolicy.ask, "Ask"),
                    (ToolPermissionPolicy.deny, "Deny"),
                ],
                fontSize: 11
            )
            .frame(width: 170)
        }
        .padding(.vertical, 8)
        .onAppear {
            configuredPolicy = toolRegistry.configuredPolicy(for: name)
        }
        .onReceive(toolRegistry.objectWillChange) { _ in
            let latest = toolRegistry.configuredPolicy(for: name)
            if latest != configuredPolicy {
                configuredPolicy = latest
            }
        }
    }
}
