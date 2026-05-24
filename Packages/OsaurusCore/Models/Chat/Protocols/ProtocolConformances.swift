//
//  ProtocolConformances.swift
//  OsaurusCore
//
//  M10 Phase 4c: Apple Silicon concrete types conform to M10 protocols.
//  Wrapped in #if !OSAURUS_INTEL since concrete types are excluded on Intel.
//

#if !OSAURUS_INTEL

// MARK: - ChatTurn

extension ChatTurn: ChatTurnProtocol {
    var imageData: Data? { nil }
}

// MARK: - Attachment

extension Attachment: AttachmentProtocol {}

// MARK: - ModelPickerItem

extension ModelPickerItem: ModelPickerItemProtocol {}

// MARK: - AgentManager

extension AgentManager: AgentManagerProtocol {
    func agentsList() -> [any AgentInfoProtocol] { agents }
    func ttsVoice(for agentId: UUID) -> Any? { agent(for: agentId)?.ttsVoice }
}

// MARK: - SpeechService

extension SpeechService: SpeechServiceProtocol {}

// MARK: - ChatWindowManager

extension ChatWindowManager: ChatWindowManagerProtocol {}

// MARK: - ModelPickerItemCache

extension ModelPickerItemCache: ModelPickerItemCacheProtocol {}

// MARK: - RemoteProviderManager

extension RemoteProviderManager: RemoteProviderManagerProtocol {}

extension RemoteProviderConfiguration: RemoteProviderConfigInfoProtocol {
    var providers: [any RemoteProviderInfoProtocol] { [] }
}

extension RemoteProvider: RemoteProviderInfoProtocol {}

// MARK: - ToolRegistry

extension ToolRegistry: ToolRegistryProtocol {}

// MARK: - ChatSessionData

extension ChatSessionData: ChatSessionDataProtocol {}

// MARK: - ChatSessionsManager

extension ChatSessionsManager: ChatSessionsManagerProtocol {}

// MARK: - MemoryService

extension MemoryService: MemoryServiceProtocol {}

// MARK: - ChatConfiguration

extension ChatConfiguration: ChatConfigurationProtocol {
    static func load() -> any ChatConfigurationProtocol { ChatConfigurationStore.load() }
}

// MARK: - GenerativeGreeting

extension GenerativeGreetingPool: GenerativeGreetingPoolProtocol {}

extension GenerativeGreetingService: GenerativeGreetingServiceProtocol {}

// MARK: - SharedArtifact

extension SharedArtifact: SharedArtifactProtocol {}

// MARK: - PluginManager

extension PluginManager: PluginManagerProtocol {}

// MARK: - ContentBlock

extension ContentBlock: ContentBlockProtocol {}

// MARK: - ModelOptionValue

extension ModelOptionValue: ModelOptionValueProtocol {}

// MARK: - ChatTurnData

extension ChatTurnData: ChatTurnDataProtocol {}

#endif
