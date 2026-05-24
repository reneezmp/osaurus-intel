//
//  IntelDataConformers.swift
//  OsaurusCore
//
//  M10 Phase 4d: Intel-lite data type conformers for ChatView protocols.
//

#if OSAURUS_INTEL

import Foundation

// MARK: - ChatTurn

struct IntelChatTurn: ChatTurnProtocol, Identifiable, @unchecked Sendable, Equatable {
    let id: UUID
    var turnId: UUID?
    var role: ChatTurnRole
    var content: String
    var toolCalls: [ToolCall]?
    var toolResults: [String: String]
    var toolCallId: String?
    let thinking: String?
    var unclosedReasoning: Bool
    var hasRenderableThinking: Bool { !(thinking ?? "").isEmpty }
    var visibleContent: String { content }
    var contentIsBlank: Bool { content.trimmingCharacters(in: .whitespaces).isEmpty }
    var thinkingIsBlank: Bool { (thinking ?? "").isEmpty }
    var contentIsEmpty: Bool { content.isEmpty }
    var contentLength: Int { content.count }
    var attachments: [any AttachmentProtocol]
    var imageData: Data? { nil }
    var generationTokenCount: Int?
    var generationTokensPerSecond: Double?
    var timeToFirstToken: TimeInterval?
    var completedAt: Date?
    var pendingToolName: String?
    var pendingToolArgFragmentCount: Int = 0
    var preflightCapabilities: Any?

    private var _pendingToolArgs: String = ""

    init(role: ChatTurnRole, content: String, attachments: [any AttachmentProtocol] = [], toolCalls: [ToolCall]? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.attachments = attachments
        self.toolCalls = toolCalls
        self.toolResults = [:]
        self.thinking = nil
        self.unclosedReasoning = false
        self.completedAt = role == .user ? Date() : nil
    }

    mutating func consolidateContent() {}
    mutating func clearPendingToolArgs() { _pendingToolArgs = "" }
    mutating func appendToolArgFragment(_ arg: String) {
        _pendingToolArgs += arg
        pendingToolArgFragmentCount += 1
    }
}

// MARK: - Attachment

struct IntelAttachment: AttachmentProtocol, Identifiable, Sendable {
    let id: UUID
    var filename: String?
    let isDocument: Bool
    var documentContent: String?
    let isAudio: Bool
    let isVideo: Bool
    var audioFormat: String?
    var estimatedTokens: Int = 0
    var imageData: Data?

    init(filename: String? = nil, isDocument: Bool = false, documentContent: String? = nil) {
        self.id = UUID()
        self.filename = filename
        self.isDocument = isDocument
        self.documentContent = documentContent
        self.isAudio = false
        self.isVideo = false
    }

    func loadAudioData() async throws -> Data? { nil }
    func loadVideoData() async throws -> Data? { nil }
}

// MARK: - ContentBlock

enum ContentBlockKind: Equatable {
    case sharedArtifact(Any)
    case userMessage(String, Any?)
    case assistantMessage(String)
    case thinking(String)
    case toolCall(String, String)
}

struct IntelContentBlock: ContentBlockProtocol, Identifiable, @unchecked Sendable {
    let id: UUID
    var kind: ContentBlockKind { .assistantMessage("") }
    init() { self.id = UUID() }
}

// MARK: - ModelOptionValue

struct IntelModelOptionValue: ModelOptionValueProtocol, Sendable {
    let boolValue: Bool?
    init(boolValue: Bool?) { self.boolValue = boolValue }
}

// MARK: - ChatTurnData

struct IntelChatTurnData: ChatTurnProtocol, ChatTurnDataProtocol, Sendable, Equatable {
    init(from turn: any ChatTurnProtocol) {}
}

// MARK: - Type aliases
typealias ChatTurn = IntelChatTurn
typealias Attachment = IntelAttachment
typealias ContentBlock = IntelContentBlock
typealias ModelOptionValue = IntelModelOptionValue
typealias ChatTurnData = IntelChatTurnData

struct IntelModelPickerItem: Identifiable, @unchecked Sendable {
    let id: String
    var source: ModelPickerSource
    var isVLM: Bool
}

typealias ModelPickerItem = IntelModelPickerItem

extension Array where Element == IntelModelPickerItem {
    var firstChatCapable: IntelModelPickerItem? { first { !$0.isVLM } }
}

// MARK: - Additional stubs

struct DiscoveredAgent: Identifiable, Sendable {
    public let id = UUID()
    var token: String? { nil }
    var relayToken: String? { nil }
    var providerId: UUID? { nil }
    var displayName: String { "" }
    var name: String { "" }
    var host: String { "" }
    var port: Int? { nil }
    var address: String { "" }
    var kind: String { "" }
    var providerType: String { "" }
}

struct PairedRelayAgent: Identifiable, Sendable {
    public let id = UUID()
    var token: String? { nil }
    var remoteAgentId: UUID? { nil }
    var remoteAgentAddress: String { "" }
    var providerId: UUID? { nil }
    var address: String { "" }
    var name: String { "" }
    var host: String { "" }
    var port: Int? { nil }
    var kind: String { "relay" }
    var providerType: String { "" }
}

final class ContextBudgetManager: @unchecked Sendable {
    static let shared = ContextBudgetManager()
    static func estimateOutputTokens(for turns: [Any]) -> Int { 0 }
    static func estimateTokens(for items: [Any]) -> Int { 0 }
}

struct ToolEnvelope: Sendable {
    init() {}
    static func success(tool: String, text: String) -> Any { ["ok": true] }
    static func successPayload(_ result: Any) -> [String: Any]? { nil }
    enum Kind: Sendable { case success, failure, invalidArgs, executionError }
}

final class SessionToolStateStore: @unchecked Sendable {
    static let shared = SessionToolStateStore()
    func invalidate(_ key: Any) async {}
    func invalidateIfFingerprintChanged(key: Any, fingerprint: Any) async {}
    func get(_ key: Any) async -> Any? { nil }
}

final class TTSService: @unchecked Sendable {
    func toggleSpeak(_ text: String, messageId: String) {}
    var playingMessageId: String? { nil }
    static let shared = TTSService()
    func refreshModelState() {}
    var selectedVoice: Any? { nil }
    var isSpeaking: Bool { false }
    var selectedModel: Any? { nil }
}

struct MockChatData: Sendable {
    init() {}
    static var isEnabled: Bool { false }
    static let shared = MockChatData()
    static func mockTurnsForPerformanceTest(count: Int = 10) -> [IntelChatTurn] { [] }
}

struct ServiceToolInvocation: Sendable { init() {} }

final class PromptQueue: ObservableObject, @unchecked Sendable {
    var current: Any? { nil }
    func enqueue(_ item: Any) {}
    func drainAll() {}
    func advance() {}
}
typealias ServiceToolInvocations = [ServiceToolInvocation]

struct ClarifyPayload: Sendable, Equatable {
    let question: String = ""
    let options: [String] = []
    let allowMultiple: Bool = false
}

final class BlockMemoizer: @unchecked Sendable {
    init() {}
    static let shared = BlockMemoizer()
    func blocks(from turns: [Any] = [], streamingTurnId: Any? = nil, agentName: String = "", thinkingEnabled: Bool = false) -> [Any] { [] }
    var groupHeaderMap: [UUID: UUID] { [:] }
    func memoized<T>(forKey key: String, build: () -> T) -> T { build() }
    func clear() {}
}

struct ToolCallDone: Sendable { let callId: String; let result: String = "" }
struct StreamingToolHint: Sendable {
    init() {}
    static func decodeDone(_ delta: Any) -> ToolCallDone? { nil }
    static func decode(_ delta: Any) -> String? { nil }
    static func decodeArgs(_ delta: Any) -> String? { nil }
}

struct StreamingDeltaProcessor: @unchecked Sendable {
    init(turn: IntelChatTurn, onChange: @escaping @Sendable () -> Void = {}) {}
    mutating func finalize() {}
    mutating func receiveReasoning(_ text: String) {}
    mutating func receiveDelta(_ delta: Any) {}
}
struct StreamingReasoningHint: Sendable {
    init() {}
    static func decode(_ delta: Any) -> String? { nil }
}

final class SystemPromptComposer: @unchecked Sendable {
    static let shared = SystemPromptComposer()
    static func composePreviewContext(agentId: Any? = nil, executionMode: Any? = nil, model: String = "") -> ComposedContext { ComposedContext() }
}

struct ComposedContext: Sendable { init() {} }

struct ContextBreakdown: Sendable {
    var total: Int = 0
    var kind: String = ""
    var name: String = ""
    var tokenCount: Int = 0
    init() {}
    static func from(turns: [Any] = [], estimatedOutput: Int = 0, conversation: Int = 0, memory: Int = 0, system: Int = 0, instructions: Int = 0) -> ContextBreakdown { ContextBreakdown() }
}

final class ContextBudgetTracker: @unchecked Sendable {
    init() {}
    func clear() {}
    var estimatedTokens: Int { 0 }
    func activeBreakdown(isActive: Bool = false, outputTurn: Any? = nil) -> ContextBreakdown? { nil }
}

final class LiveVoiceAudioInputRegistry: @unchecked Sendable {
    static let shared = LiveVoiceAudioInputRegistry()
    func samples(for id: UUID) -> Any? { nil }
}

final class MemoryDatabase: @unchecked Sendable {
    static let shared = MemoryDatabase()
    var isOpen = false
    var memoryDisabled: Bool { true }
    func open() throws {}
    func insertTranscriptTurn(_ turn: Any, sessionId: UUID) throws {}
}

final class ServerController: @unchecked Sendable {
    static let shared = ServerController()
    static func signalGenerationStart() {}
    static func signalGenerationEnd() {}
    var configuration: Any? { nil }
    var port: Int { 1337 }
    var isRunning: Bool { true }
}



// Notification names
extension NSNotification.Name {
    static let remoteProviderModelsChanged = NSNotification.Name("remoteProviderModelsChanged")
    static let localModelsChanged = NSNotification.Name("localModelsChanged")
    static let chatOverlayActivated = NSNotification.Name("chatOverlayActivated")
    static let chatViewClosed = NSNotification.Name("chatViewClosed")
    static let toolsListChanged = NSNotification.Name("toolsListChanged")
}

#endif
