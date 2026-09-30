//
//  SettingsSearchIndex.swift
//  osaurus
//
//  Declarative index of searchable settings across the Intel management tabs
//  (upstream #49, `53c24678a`). The sidebar search field queries this index
//  and shows cross-tab results, so a setting is findable from anywhere, not
//  just from the General page. Selecting a result opens its tab; entries on
//  the General page also scroll to and glow the exact control
//  (`settingsLandingAnchor`).
//
//  Intel: upstream's entries describe upstream's pages (a separate Chat tab,
//  Channels, Workspaces, local models, voice…). This list is written from the
//  Intel UI instead, and `SettingsSearchIndexTests` checks that every title
//  is a string the Intel views actually show and that every tab is visible
//  here. Keep entries in sync when a setting moves or is renamed.
//

import Foundation

/// A single searchable setting, addressable by the tab (and human-readable
/// section) it lives in. `keywords` widen matching beyond the visible title.
public struct SettingsSearchEntry: Identifiable, Sendable, Hashable {
    public let id: String
    public let tab: ManagementTab
    /// Human-readable area within the tab, e.g. "Chat". Empty for flat tabs.
    public let section: String
    /// The setting's visible title, e.g. "Global Hotkey".
    public let title: String
    /// Extra match terms (synonyms, related words) beyond title/section/tab.
    public let keywords: [String]
    /// Short "not this" note when names collide.
    public let disambiguation: String?
    /// Label of the settings control that hosts this entry when it differs
    /// from `title` (e.g. the "Tools" subsection hosts "Disable tools").
    public let anchorLabel: String?
    /// Voice sub-tab to open (a `VoiceTab` raw value), as upstream does.
    public let subTab: String?

    public init(
        id: String,
        tab: ManagementTab,
        section: String = "",
        title: String,
        anchorLabel: String? = nil,
        keywords: [String] = [],
        disambiguation: String? = nil,
        subTab: String? = nil
    ) {
        self.id = id
        self.tab = tab
        self.section = section
        self.title = title
        self.keywords = keywords
        self.disambiguation = disambiguation
        self.anchorLabel = anchorLabel
        self.subTab = subTab
    }

    /// Breadcrumb shown in results, e.g. ["General", "Chat", "Temperature"].
    /// A section that repeats the tab label is collapsed.
    public var breadcrumb: [String] {
        section.isEmpty || section == tab.label
            ? [tab.label, title]
            : [tab.label, section, title]
    }

    /// Path to quote in help text, e.g. `General › Chat › Temperature`.
    public var breadcrumbPath: String {
        breadcrumb.joined(separator: " › ")
    }

    /// True for rows that open a tab rather than a single control.
    public var isTabLevel: Bool { SettingsSearchIndex.tabLevelEntryIDs.contains(id) }
}

public enum SettingsSearchIndex {

    /// Entries matching `query`, ranked so title hits come before
    /// section/keyword hits, then tab-name hits. Every whitespace-separated
    /// word must match (substring, case- and diacritic-insensitive).
    public static func search(_ query: String) -> [SettingsSearchEntry] {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map { String($0) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        func matches(_ text: String) -> Bool {
            tokens.allSatisfy { token in
                text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        func matchesAny(_ texts: [String]) -> Bool {
            let joined = texts.joined(separator: " ")
            return matches(joined)
        }

        var ranked: [(entry: SettingsSearchEntry, rank: Int)] = []
        for entry in entries {
            if matches(entry.title) {
                ranked.append((entry, 0))
            } else if matchesAny([entry.title, entry.section] + entry.keywords) {
                ranked.append((entry, 1))
            } else if matchesAny([entry.title, entry.section, entry.tab.label] + entry.keywords) {
                ranked.append((entry, 2))
            }
        }
        return
            ranked
            .enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map { $0.element.entry }
    }

    /// Landing anchor for the control labelled `label` inside the settings
    /// section titled `section`, if the index points at it.
    public static func anchorID(section: String, label: String) -> String? {
        anchorsBySectionAndLabel["\(section)\u{1}\(label)"]
    }

    private static let anchorsBySectionAndLabel: [String: String] = {
        var map: [String: String] = [:]
        for entry in entries where !entry.isTabLevel && !entry.section.isEmpty {
            map["\(entry.section)\u{1}\(entry.anchorLabel ?? entry.title)"] = entry.id
        }
        return map
    }()

    /// Rows that land on a tab rather than a single control.
    public static let tabLevelEntryIDs: Set<String> = [
        "themes.overview", "providers.overview", "agents.overview", "search.overview",
        "knowledge.overview", "tools.overview", "skills.overview", "commands.overview",
        "plugins.overview", "schedules.overview", "watchers.overview", "insights.overview",
        "permissions.overview",
    ]

    public static let entries: [SettingsSearchEntry] = [
        // MARK: General (upstream #2950 layout)
        .init(
            id: "settings.general.hotkey", tab: .settings, section: "General",
            title: "Global Hotkey", keywords: ["shortcut", "keybinding", "hotkey", "summon"]),
        .init(
            id: "settings.general.login", tab: .settings, section: "General",
            title: "Start at Login", keywords: ["launch", "startup", "autostart", "boot"]),
        .init(
            id: "settings.general.dock", tab: .settings, section: "General",
            title: "Hide Dock Icon", keywords: ["dock", "menu bar", "menubar", "hide"]),
        .init(
            id: "settings.general.updates", tab: .settings, section: "General",
            title: "Beta Updates", keywords: ["beta", "prerelease", "updates", "channel", "sparkle"]),
        .init(
            id: "settings.general.coreModel", tab: .settings, section: "Core Model",
            title: "Core Model",
            keywords: ["default model", "background model", "titles", "memory model", "utility model"]),
        .init(
            id: "settings.notifications.toasts", tab: .settings, section: "Notifications",
            title: "Show Toast Notifications", keywords: ["toast", "notifications", "popups"]),
        .init(
            id: "settings.notifications.position", tab: .settings, section: "Notifications",
            title: "Toast Position", keywords: ["toast", "corner", "placement"]),
        .init(
            id: "settings.notifications.timeout", tab: .settings, section: "Advanced",
            title: "Default Timeout", keywords: ["toast", "duration", "dismiss", "notifications"]),
        .init(
            id: "settings.notifications.maxVisible", tab: .settings, section: "Advanced",
            title: "Max Visible Toasts", keywords: ["toast", "stack", "notifications"]),
        .init(
            id: "settings.notifications.maxConcurrentTasks", tab: .settings, section: "Advanced",
            title: "Max Concurrent Tasks", keywords: ["background tasks", "parallel", "schedules"]),
        .init(
            id: "storage.backup", tab: .settings, section: "Advanced", title: "Backup & key",
            keywords: ["backup", "export data", "encryption key", "rotate key", "storage key", "data & storage"]),
        .init(
            id: "storage.encryption", tab: .settings, section: "Advanced", title: "About encrypted storage",
            keywords: ["encryption", "sqlcipher", "keychain", "at rest", "storage", "data & storage"]),
        .init(
            id: "settings.general.maintenance", tab: .settings, section: "Reset",
            title: "Factory Reset", keywords: ["factory reset", "reset", "wipe", "erase", "maintenance"]),

        // MARK: Conversation
        .init(
            id: "settings.chat.spellCheck", tab: .chat, section: "Appearance",
            title: "Check Spelling While Typing",
            keywords: ["spelling", "spell check", "spellcheck", "typos", "underline", "typing"]),
        .init(
            id: "settings.chat.titles", tab: .chat, section: "Behavior",
            title: "Automatically Name Chats", keywords: ["chat titles", "rename", "auto title"]),
        .init(
            id: "settings.chat.agentDescriptions", tab: .chat, section: "Behavior",
            title: "Fill In Missing Agent Descriptions",
            keywords: ["agent description", "purpose", "backfill", "orchestrator"]),
        .init(
            id: "settings.chat.clipboard", tab: .chat, section: "Behavior",
            title: "Clipboard Monitoring", keywords: ["clipboard", "paste", "grab selection"]),
        .init(
            id: "settings.chat.newChatShortcut", tab: .chat, section: "Behavior",
            title: "⌘+N Starts a New Chat in the Current Window",
            keywords: ["cmd n", "command n", "new chat", "new window", "shortcut"]),
        .init(
            id: "settings.chat.disableTools", tab: .chat, section: "Behavior",
            title: "Disable Tools", keywords: ["tools", "tool calling", "no tools", "plain chat"]),
        .init(
            id: "settings.chat.memory", tab: .chat, section: "Behavior",
            title: "Enable Memory", keywords: ["memory", "remember", "recall", "pinned facts"],
            disambiguation: "Turns memory on or off for chats; the Memory tab has the details."),
        .init(
            id: "settings.chat.greetings", tab: .chat, section: "Greetings",
            title: "AI-Generated Greetings",
            keywords: ["greeting", "empty state", "quick actions", "personality"]),
        .init(
            id: "settings.work.permissions", tab: .chat, section: "Folder Tool Permissions",
            title: "Folder Tool Permissions",
            keywords: ["file", "shell", "git", "write", "delete", "approve", "folder tools", "permissions"],
            disambiguation: "Approvals for folder file, shell and git tools, not macOS permissions."),
        .init(
            id: "settings.chat.systemPrompt", tab: .chat, section: "Advanced",
            title: "System Prompt", keywords: ["instructions", "persona", "orchestrator prompt"],
            disambiguation: "Used by the Orchestrator when it has no prompt of its own."),
        .init(
            id: "settings.chat.temperature", tab: .chat, section: "Advanced",
            title: "Temperature", keywords: ["creativity", "randomness", "sampling"],
            disambiguation: "The Orchestrator's fallback; agents have their own."),
        .init(
            id: "settings.chat.maxTokens", tab: .chat, section: "Advanced",
            title: "Max Tokens", keywords: ["output length", "response length", "limit"]),
        .init(
            id: "settings.chat.contextLength", tab: .chat, section: "Advanced",
            title: "Context Length", keywords: ["context window", "history", "tokens"]),
        .init(
            id: "settings.chat.topP", tab: .chat, section: "Advanced",
            title: "Top P Override", keywords: ["top p", "nucleus", "sampling"]),
        .init(
            id: "settings.chat.maxToolAttempts", tab: .chat, section: "Advanced",
            title: "Max Tool Attempts", keywords: ["tool calls", "loop", "retries", "tool limit"]),

        // MARK: Developer Tools › Server
        .init(
            id: "server.cli", tab: .server,
            title: "Command Line Tool", keywords: ["cli", "terminal", "symlink", "install"]),

        // MARK: Themes, Credits, Identity, Permissions
        .init(
            id: "themes.overview", tab: .themes, title: "Themes",
            keywords: ["appearance", "colors", "dark mode", "light mode", "fonts", "accent"]),
        .init(
            id: "themes.create", tab: .themes, title: "Create Theme",
            keywords: ["custom theme", "theme editor", "new theme"]),
        .init(
            id: "credits.balance", tab: .credits, title: "Credit balance",
            keywords: ["credits", "wallet", "top up", "add credits", "billing"]),
        .init(
            id: "credits.router", tab: .credits, title: "Osaurus Router",
            keywords: ["router", "hosted models", "turn off router"]),
        .init(
            id: "credits.premiumSearch", tab: .credits, title: "Premium web search",
            keywords: ["premium search", "search credits", "wallet"]),
        .init(
            id: "credits.activity", tab: .credits, title: "Recent activity",
            keywords: ["usage", "requests", "cost", "cached input", "export diagnostics"]),
        .init(
            id: "identity.address", tab: .identity, title: "Master Address",
            keywords: ["identity", "address", "keys", "agent address"]),
        .init(
            id: "identity.recovery", tab: .identity, title: "View recovery phrase",
            keywords: ["recovery phrase", "24 words", "backup identity", "seed"]),
        .init(
            id: "identity.restore", tab: .identity, title: "Restore from recovery phrase",
            keywords: ["restore identity", "another mac", "import identity"]),
        .init(
            id: "permissions.overview", tab: .permissions, title: "Permissions",
            keywords: ["accessibility", "screen recording", "calendar", "contacts", "microphone", "tcc"],
            disambiguation: "macOS system permissions for Osaurus."),

        // MARK: Models and agents
        .init(
            id: "providers.overview", tab: .providers, title: "Cloud Models",
            keywords: ["providers", "api key", "openai", "deepseek", "anthropic", "router", "remote models"]),
        .init(
            id: "providers.claudeCode", tab: .providers, title: "Claude Code",
            keywords: ["claude", "cli", "sign in"]),
        .init(
            id: "orchestrator.prompt", tab: .orchestrator, title: "System Prompt",
            keywords: ["orchestrator", "default agent", "instructions"]),
        .init(
            id: "orchestrator.delegation", tab: .orchestrator, title: "Delegation",
            keywords: ["delegate", "subagents", "targets", "roster"]),
        .init(
            id: "orchestrator.delegation.addAllAgents", tab: .orchestrator, title: "Add all agents",
            keywords: [
                "add all agents", "empty allowlist", "allowed custom agents", "cannot delegate",
                "orchestrator cannot delegate", "restore delegation", "agents not in list",
            ],
            disambiguation:
                "Shown only while no custom agent is allowed; allows every listed agent (their models still need to be admitted)."),
        .init(
            id: "orchestrator.declarative", tab: .orchestrator, title: "Declarative Configuration",
            keywords: ["osaurus config", "configuration", "yaml", "apply plan"]),
        .init(
            id: "agents.overview", tab: .agents, title: "Agents",
            keywords: ["create agent", "new agent", "agent settings", "abilities", "database", "bundles"]),

        // MARK: Capabilities
        .init(
            id: "search.overview", tab: .search, title: "Web Search",
            keywords: ["search providers", "brave", "tavily", "api key", "internet"]),
        .init(
            id: "search.custom", tab: .search, title: "Add custom provider",
            keywords: ["rest api", "custom search", "json definition"]),
        .init(
            id: "knowledge.overview", tab: .knowledge, title: "Knowledge",
            keywords: ["documents", "collections", "rag", "folders", "index"]),
        .init(
            id: "memory.budget", tab: .memory, title: "Memory Budget",
            keywords: ["memory", "recall", "tokens"]),
        .init(
            id: "memory.retention", tab: .memory, title: "Episode Retention",
            keywords: ["episodes", "days", "forget"]),
        .init(
            id: "memory.embeddings", tab: .memory, title: "Embeddings",
            keywords: ["on-device", "vector", "semantic"]),
        .init(
            id: "memory.distillation", tab: .memory, title: "Distillation",
            keywords: ["summaries", "pinned facts", "backfill"]),
        .init(
            id: "memory.clear", tab: .memory, title: "Clear All Memory",
            keywords: ["delete memory", "wipe", "forget everything"]),
        .init(
            id: "tools.overview", tab: .tools, title: "Tools",
            keywords: ["tool permissions", "ask", "deny", "auto", "mcp", "approval"]),
        .init(
            id: "skills.overview", tab: .skills, title: "Skills",
            keywords: ["skill", "instructions", "github import"]),
        .init(
            id: "commands.overview", tab: .commands, title: "Commands",
            keywords: ["slash commands", "shortcuts", "/"]),
        .init(
            id: "plugins.overview", tab: .plugins, title: "Plugins",
            keywords: ["extensions", "native plugins", "install"]),

        // MARK: Automation
        .init(
            id: "schedules.overview", tab: .schedules, title: "Schedules",
            keywords: ["cron", "recurring", "daily", "run now", "automation"]),
        .init(
            id: "watchers.overview", tab: .watchers, title: "Watchers",
            keywords: ["folder watcher", "fsevents", "file changes", "automation"]),

        // MARK: Developer tools
        .init(
            id: "server.url", tab: .server, title: "Server URL",
            keywords: ["local server", "port", "api", "localhost"]),
        .init(
            id: "server.accessKeys", tab: .server, title: "Access Keys",
            keywords: ["api keys", "tokens", "authentication", "revoke"]),
        .init(
            id: "server.endpoints", tab: .server, title: "API Endpoints",
            keywords: ["openai compatible", "rest", "documentation", "test endpoint"]),
        .init(
            id: "insights.overview", tab: .insights, title: "Insights",
            keywords: ["logs", "requests", "latency", "tokens", "diagnostics"]),
        // MARK: Voice (subTab values are VoiceTab raw values; Intel titles)
        .init(
            id: "voice.stt.language", tab: .voice, section: "Recognition",
            title: "Recognition language",
            keywords: ["speech recognition", "apple speech", "dictation", "transcription", "language"],
            subTab: "Models"),
        .init(
            id: "voice.stt.server", tab: .voice, section: "Recognition",
            title: "Use Apple's servers when needed",
            keywords: ["apple servers", "server recognition", "privacy", "on device"],
            subTab: "Models"),
        .init(
            id: "voice.stt.hotkey", tab: .voice, section: "Speech to Text",
            title: "Activation Hotkey",
            keywords: [
                "dictation hotkey", "push to talk", "voice hotkey", "transcription mode", "dictate",
            ],
            subTab: "Speech To Text"),
        .init(
            id: "voice.stt.chat", tab: .voice, section: "Speech to Text",
            title: "Voice Input in Chat",
            keywords: ["microphone", "mic", "speak to chat", "voice input"],
            subTab: "Speech To Text"),
        .init(
            id: "voice.stt.cleanup", tab: .voice, section: "Speech to Text",
            title: "Clean Up Transcription",
            keywords: ["filler words", "uh", "um", "post-process", "tidy"],
            subTab: "Speech To Text"),
        .init(
            id: "voice.stt.pause", tab: .voice, section: "Speech to Text",
            title: "Pause Detection",
            keywords: ["pause", "auto stop", "auto send", "stop after silence"],
            subTab: "Speech To Text"),
        .init(
            id: "voice.stt.vad", tab: .voice, section: "VAD Mode",
            title: "VAD Mode",
            keywords: ["wake word", "always listening", "hey", "voice activation", "vad"],
            subTab: "VAD Mode"),
        .init(
            id: "voice.setup.sensitivity", tab: .voice, section: "Setup",
            title: "Voice Sensitivity",
            keywords: ["sensitivity", "noise", "quiet speech"],
            subTab: "Setup"),
        .init(
            id: "voice.setup.input", tab: .voice, section: "Setup",
            title: "Audio Input",
            keywords: ["microphone", "input device", "system audio"],
            subTab: "Setup"),
        .init(
            id: "voice.tts.enable", tab: .voice, section: "Text to Speech",
            title: "Enable Text-to-Speech",
            keywords: ["tts", "read aloud", "speak", "speaker button", "speech synthesis"],
            subTab: "Text To Speech"),
        .init(
            id: "voice.tts.remote", tab: .voice, section: "Text to Speech",
            title: "OpenAI-Compatible Server",
            keywords: ["remote tts", "tts endpoint", "openai tts", "kokoro", "edge tts"],
            subTab: "Text To Speech"),
    ]
}
