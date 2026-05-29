//
//  IntelManagerConformers.swift
//  OsaurusCore
//
//  M10.5 Phase A: Intel-lite manager conformers — concretized.
//  All types use concrete types, no protocol existentials.
//  Protocol conformances dropped — ChatView accesses these directly by type name.
//

#if OSAURUS_INTEL

import Foundation

// MARK: - AgentManager

final class AgentManager: ObservableObject, @unchecked Sendable {
    static let shared = AgentManager()

    private var defaultModel = "deepseek-v4-pro"

    struct AgentInfo: Identifiable, Sendable {
        let id: UUID
        let name: String
        let isBuiltIn: Bool = true
        let autoSpeak: Bool? = false
        var ttsVoice: String? { nil }
    }

    @Published var activeAgentId: UUID = UUID()
    @Published var agents: [Agent] = [Agent(id: UUID(), name: "Default", systemPrompt: "", themeId: nil)]

    func agent(for id: UUID) -> Agent? {
        Agent(id: id, name: "Agent", systemPrompt: "", themeId: nil)
    }

    func agent(byAddress address: String) -> Agent? {
        nil
    }

    func resolveAgentId(_ identifier: String) -> UUID? {
        UUID(uuidString: identifier)
    }

    func agentsList() -> [Agent] {
        [Agent(id: UUID(), name: "Default")]
    }

    func refresh() {}
    func setActiveAgent(_ id: UUID) { activeAgentId = id }
    func add(_ agent: Any) {}
    func update(_ agent: Any) {}
    func delete(id: UUID) async -> Any? { nil }

    func updateDefaultModel(for agentId: UUID, model: String) {
        if agentId == activeAgentId { defaultModel = model }
    }

    func effectiveModel(for agentId: UUID) -> String? { defaultModel }
    func effectiveTemperature(for agentId: UUID) -> Double? { nil }
    func effectiveMaxTokens(for agentId: UUID) -> Int? { nil }
    func effectiveSystemPrompt(for agentId: UUID) -> String { "" }
    func effectiveToolsDisabled(for agentId: UUID) -> Bool { false }
    func effectiveDBEnabled(for agentId: UUID) -> Bool { false }
    func effectiveMemoryDisabled(for agentId: UUID) -> Bool { true }
    func effectiveToolSelectionMode(for agentId: UUID) -> ToolSelectionMode? { nil }
    func effectiveEnabledToolNames(for agentId: UUID) -> [String]? { nil }
    func effectiveEnabledSkillNames(for agentId: UUID) -> [String]? { nil }
    func effectiveAutonomousExec(for agentId: UUID) -> AgentAutoExecInfo? { AgentAutoExecInfo(enabled: false) }
    func ttsVoice(for agentId: UUID) -> Any? { nil }
    func themeId(for agentId: UUID) -> UUID? { nil }
}

// MARK: - ModelPickerItemCache

final class ModelPickerItemCache: @unchecked Sendable {
    static let shared = ModelPickerItemCache()

    /// Stable synthetic UUID for the built-in DeepSeek provider. The Intel
    /// build's `RemoteProviderManager` doesn't configure user-facing
    /// providers (the API key is read from `DEEPSEEK_API_KEY` and the URL
    /// is hard-coded in `CloudChatEngine`), but `ModelPickerItem.Source`
    /// still wants a UUID and `ChatView`'s `source.remoteProviderId`
    /// filter still compares against it — so we pin a stable value here.
    static let deepSeekProviderId = UUID(uuidString: "00000000-0000-0000-0000-DEEDEEDEEDEE")!

    var isLoaded: Bool = false
    private(set) var items: [ModelPickerItem] = []

    func buildModelPickerItems() async -> [ModelPickerItem] {
        let provider: ModelPickerItem.Source = .remote(
            providerName: "DeepSeek",
            providerId: Self.deepSeekProviderId
        )
        let built: [ModelPickerItem] = [
            ModelPickerItem(
                id: "deepseek-v4-pro",
                displayName: "DeepSeek V4 Pro",
                source: provider,
                isVLM: false,
                description: "DeepSeek's flagship chat model"
            ),
            ModelPickerItem(
                id: "deepseek-v4-flash",
                displayName: "DeepSeek V4 Flash",
                source: provider,
                isVLM: false,
                description: "DeepSeek's fast tier"
            ),
        ]
        items = built
        isLoaded = true
        return built
    }

    func prewarm() { Task { await buildModelPickerItems() } }
    func prewarmModelCache() async { _ = await buildModelPickerItems() }
    func invalidateCache() { isLoaded = false }
}

// MARK: - ChatSessionData

struct ChatSessionData: Identifiable, @unchecked Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    let agentId: UUID
    var source: SessionSource
    var sourcePluginId: String?
    var externalSessionKey: String?
    var dispatchTaskId: UUID?
    var archived: Bool
    var selectedModel: String?
    var turns: [ChatTurnData]
    var capabilities: Set<SessionCapability> = []

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        selectedModel: String? = nil,
        turns: [ChatTurnData] = [],
        agentId: UUID? = nil,
        source: SessionSource = .chat,
        sourcePluginId: String? = nil,
        externalSessionKey: String? = nil,
        dispatchTaskId: UUID? = nil,
        archived: Bool = false,
        capabilities: Set<SessionCapability> = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.agentId = agentId ?? UUID()
        self.archived = archived
        self.selectedModel = selectedModel
        self.turns = turns
        self.source = source
        self.sourcePluginId = sourcePluginId
        self.externalSessionKey = externalSessionKey
        self.dispatchTaskId = dispatchTaskId
        self.capabilities = capabilities
    }

    static func generateTitle(from turnData: [ChatTurnData]) -> String { "Chat" }
}

// MARK: - ChatSessionsManager

final class ChatSessionsManager: ObservableObject, @unchecked Sendable {
    static let shared = ChatSessionsManager()
    /// `@Published` so `ChatWindowState.observeSessionsManager()` can subscribe
    /// via `$sessions` and refresh the sidebar when a turn lands during an
    /// active stream — without this, the sidebar only updates on explicit
    /// user actions (e.g., clicking "New Chat"). Renamed-from-private to
    /// `internal` so observers can read it.
    @Published var sessions: [UUID: ChatSessionData] = [:]

    func save(_ data: ChatSessionData) { sessions[data.id] = data }
    func delete(id: UUID) { sessions.removeValue(forKey: id) }
    func rename(id: UUID, title: String) {
        if var s = sessions[id] {
            s.title = title
            sessions[id] = s
        }
    }
    func setArchived(id: UUID, archived: Bool) {
        if var s = sessions[id] {
            s.archived = archived
            sessions[id] = s
        }
    }
    func refresh() {}

    func createNew(selectedModel: String? = nil, agentId: UUID? = nil) -> UUID {
        let id = UUID()
        sessions[id] = ChatSessionData(id: id, agentId: agentId ?? UUID())
        return id
    }

    func sessions(for agentId: UUID?) -> [ChatSessionData] {
        Array(sessions.values).sorted { $0.updatedAt > $1.updatedAt }
    }
    func session(for id: UUID) -> ChatSessionData? { sessions[id] }
}

// MARK: - ChatConfiguration

final class ChatConfiguration: @unchecked Sendable {
    static let shared = ChatConfiguration()

    let disableTools: Bool = false
    let maxToolAttempts: Int = 5
    let topPOverride: Double? = nil
    var systemPrompt: String = ""
    var temperature: Float? = nil
    var maxTokens: Int? = nil
    var contextLength: Int? = 128000
    var defaultModel: String? = nil
    var generativeGreetingsEnabled: Bool = false
    var enableClipboardMonitoring: Bool = true
    var defaultToolSelectionMode: Any? = nil
    var defaultManualToolNames: [String]? = nil
    var defaultManualSkillNames: [String]? = nil

    static func load() -> ChatConfiguration { shared }
}

#endif
