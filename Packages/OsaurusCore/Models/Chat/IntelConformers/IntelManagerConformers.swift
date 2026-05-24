//
//  IntelManagerConformers.swift
//  OsaurusCore
//
//  M10 Phase 4d + M10.5 Phase 3: Intel-lite manager conformers for ChatView.
//  Signatures byte-for-byte from original excluded source files.
//

#if OSAURUS_INTEL

import Foundation

// MARK: - IntelAgentManager

final class IntelAgentManager: AgentManagerProtocol, @unchecked Sendable {
    static let shared = IntelAgentManager()

    private var defaultModel = "deepseek-v4-pro"

    struct AgentInfo: AgentInfoProtocol {
        let id: UUID
        let name: String
        let isBuiltIn: Bool = true
        let autoSpeak: Bool = false
    }

    var activeAgentId: UUID = UUID()

    // MARK: Agent lookup
    func agent(for id: UUID) -> (any AgentInfoProtocol)? {
        AgentInfo(id: id, name: "Agent")
    }

    func agent(byAddress address: String) -> (any AgentInfoProtocol)? {
        nil
    }

    func resolveAgentId(_ identifier: String) -> UUID? {
        UUID(uuidString: identifier)
    }

    func agentsList() -> [any AgentInfoProtocol] {
        [AgentInfo(id: UUID(), name: "Default")]
    }

    // MARK: Lifecycle
    func refresh() {}

    func setActiveAgent(_ id: UUID) {
        activeAgentId = id
    }

    func add(_ agent: Any) {}
    func update(_ agent: Any) {}

    func delete(id: UUID) async -> Any? {
        nil
    }

    // MARK: Configuration
    func updateDefaultModel(for agentId: UUID, model: String) {
        if agentId == activeAgentId { defaultModel = model }
    }

    func effectiveModel(for agentId: UUID) -> String? {
        defaultModel
    }

    func effectiveTemperature(for agentId: UUID) -> Double? {
        nil
    }

    func effectiveMaxTokens(for agentId: UUID) -> Int? {
        nil
    }

    func effectiveSystemPrompt(for agentId: UUID) -> String {
        ""
    }

    func effectiveToolsDisabled(for agentId: UUID) -> Bool {
        false
    }

    func effectiveDBEnabled(for agentId: UUID) -> Bool {
        false
    }

    func effectiveMemoryDisabled(for agentId: UUID) -> Bool {
        true
    }

    func effectiveToolSelectionMode(for agentId: UUID) -> Any? {
        nil
    }

    func effectiveEnabledToolNames(for agentId: UUID) -> [String]? {
        nil
    }

    func effectiveEnabledSkillNames(for agentId: UUID) -> [String]? {
        nil
    }

    func effectiveAutonomousExec(for agentId: UUID) -> AgentAutoExecInfo? {
        AgentAutoExecInfo(enabled: false)
    }

    func ttsVoice(for agentId: UUID) -> Any? {
        nil
    }

    func themeId(for agentId: UUID) -> UUID? {
        nil
    }
}

// MARK: - IntelModelPickerItemCache

final class IntelModelPickerItemCache: ModelPickerItemCacheProtocol, @unchecked Sendable {
    static let shared = IntelModelPickerItemCache()

    private struct Item: ModelPickerItemProtocol {
        let id: String
        let source: ModelPickerSource
        let isVLM: Bool
    }

    var isLoaded: Bool = false
    private(set) var items: [any ModelPickerItemProtocol] = []

    func buildModelPickerItems() async -> [any ModelPickerItemProtocol] {
        let built: [any ModelPickerItemProtocol] = [
            Item(id: "deepseek-v4-pro", source: .builtIn, isVLM: false),
            Item(id: "deepseek-v4-flash", source: .builtIn, isVLM: false),
        ]
        items = built
        isLoaded = true
        return built
    }

    func prewarm() {
        Task { await buildModelPickerItems() }
    }

    func prewarmModelCache() async {
        _ = await buildModelPickerItems()
    }

    func invalidateCache() {
        isLoaded = false
    }
}

// MARK: - IntelChatSessionData

struct IntelChatSessionData: ChatSessionDataProtocol, Identifiable, @unchecked Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    let agentId: UUID
    var source: Any?
    var sourcePluginId: String?
    var externalSessionKey: String?
    var dispatchTaskId: UUID?
    var archived: Bool
    var selectedModel: String?
    var turns: [any ChatTurnProtocol]
    var capabilities: Any? = nil

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        selectedModel: String? = nil,
        turns: [any ChatTurnProtocol] = [],
        agentId: UUID = UUID(),
        source: Any? = nil,
        sourcePluginId: String? = nil,
        externalSessionKey: String? = nil,
        dispatchTaskId: UUID? = nil,
        archived: Bool = false,
        capabilities: Any? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.agentId = agentId
        self.archived = archived
        self.selectedModel = selectedModel
        self.turns = turns
        self.source = source
        self.sourcePluginId = sourcePluginId
        self.externalSessionKey = externalSessionKey
        self.dispatchTaskId = dispatchTaskId
    }

    static func generateTitle(from turnData: [any ChatTurnProtocol]) -> String {
        "Chat"
    }
}

// MARK: - IntelChatSessionsManager

final class IntelChatSessionsManager: ChatSessionsManagerProtocol, @unchecked Sendable {
    static let shared = IntelChatSessionsManager()
    private var sessions: [UUID: IntelChatSessionData] = [:]

    func save(_ data: any ChatSessionDataProtocol) {
        if let d = data as? IntelChatSessionData {
            sessions[d.id] = d
        }
    }

    func delete(id: UUID) {
        sessions.removeValue(forKey: id)
    }

    func rename(id: UUID, title: String) {
        sessions[id]?.title = title
    }

    func setArchived(id: UUID, archived: Bool) {
        sessions[id]?.archived = archived
    }

    func refresh() {}

    func createNew(selectedModel: String? = nil, agentId: UUID? = nil) -> UUID {
        let id = UUID()
        sessions[id] = IntelChatSessionData(id: id, agentId: agentId ?? UUID())
        return id
    }

    func sessions(for agentId: UUID?) -> [any ChatSessionDataProtocol] {
        Array(sessions.values)
    }

    func session(for id: UUID) -> IntelChatSessionData? {
        sessions[id]
    }
}

// MARK: - IntelChatConfiguration

final class IntelChatConfiguration: ChatConfigurationProtocol, @unchecked Sendable {
    static let shared = IntelChatConfiguration()

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

    static func load() -> any ChatConfigurationProtocol {
        shared
    }
}

typealias AgentManager = IntelAgentManager
typealias ModelPickerItemCache = IntelModelPickerItemCache
typealias ChatSessionData = IntelChatSessionData
typealias ChatSessionsManager = IntelChatSessionsManager
typealias ChatConfiguration = IntelChatConfiguration

#endif
