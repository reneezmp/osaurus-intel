//
//  IntelManagerConformers.swift
//  OsaurusCore
//
//  M10 Phase 4d: Intel-lite manager conformers for ChatView.
//

#if OSAURUS_INTEL

import Foundation

// MARK: - IntelAgentManager

final class IntelAgentManager: AgentManagerProtocol, @unchecked Sendable {
    static let shared = IntelAgentManager()

    private let defaultAgentId = UUID()
    private var defaultModel = "deepseek-v4-pro"

    private struct AgentInfo: AgentInfoProtocol {
        let id: UUID
        let name: String
    }

    private let agents: [AgentInfo] = [
        AgentInfo(id: UUID(), name: "Default"),
    ]

    func agent(for id: UUID) -> (any AgentInfoProtocol)? {
        agents.first
    }

    func agentsList() -> [any AgentInfoProtocol] {
        agents
    }

    func updateDefaultModel(for agentId: UUID, model: String) {
        defaultModel = model
    }

    func effectiveModel(for agentId: UUID) -> String? {
        defaultModel
    }

    func effectiveMemoryDisabled(for agentId: UUID) -> Bool {
        true  // Memory disabled on Intel (VecturaKit required)
    }

    func effectiveAutonomousExec(for agentId: UUID) -> AgentAutoExecInfo? {
        AgentAutoExecInfo(enabled: false)
    }

    func effectiveToolSelectionMode(for agentId: UUID) -> Any? {
        nil
    }

    func effectiveMaxTokens(for agentId: UUID) -> Int? {
        nil
    }

    func effectiveTemperature(for agentId: UUID) -> Double? {
        nil
    }

    func ttsVoice(for agentId: UUID) -> Any? {
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
    var dispatchTaskId: String?
    var archived: Bool
    var selectedModel: String?
    var turns: [any ChatTurnProtocol]

    init(id: UUID = UUID(), title: String = "New Chat", agentId: UUID = UUID(), turns: [any ChatTurnProtocol] = []) {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.agentId = agentId
        self.archived = false
        self.turns = turns
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
}

// MARK: - IntelChatConfiguration

final class IntelChatConfiguration: ChatConfigurationProtocol, @unchecked Sendable {
    static let shared = IntelChatConfiguration()

    let disableTools: Bool = false
    let maxToolAttempts: Int = 5
    let topPOverride: Double? = nil

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
