//
//  IntelDataConformers.swift
//  OsaurusCore
//
//  M10 Phase 4d: Intel-lite data type conformers for ChatView protocols.
//

#if OSAURUS_INTEL

import Foundation
import SwiftUI

// MARK: - ChatTurn

final class IntelChatTurn: ChatTurnProtocol, ObservableObject, Identifiable, @unchecked Sendable, Equatable {
    let id: UUID
    let role: MessageRole
    let createdAt: Date
    var completedAt: Date?

    @Published var content: String {
        didSet { _contentLength = content.count }
    }
    var contentLength: Int { _contentLength }
    private var _contentLength: Int

    var contentIsEmpty: Bool { _contentLength == 0 }
    var contentIsBlank: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @Published var thinking: String {
        didSet { _thinkingLength = thinking.count }
    }
    var thinkingLength: Int { _thinkingLength }
    private var _thinkingLength: Int

    var thinkingIsEmpty: Bool { _thinkingLength == 0 }
    var thinkingIsBlank: Bool {
        thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasThinking: Bool { _thinkingLength > 0 }
    var hasRenderableThinking: Bool { hasThinking && !thinkingIsBlank }

    @Published var attachments: [any AttachmentProtocol] = []
    @Published var toolCalls: [ToolCall]? = nil
    var toolCallId: String? = nil
    @Published var toolResults: [String: String] = [:]

    var pendingToolName: String? = nil
    var pendingToolArgPreview: String? = nil
    var pendingToolArgSize: Int = 0
    var pendingToolArgFragmentCount: Int = 0
    var preflightCapabilities: Any? = nil

    var timeToFirstToken: TimeInterval?
    var generationTokensPerSecond: Double?
    var generationTokenCount: Int?
    var unclosedReasoning: Bool = false

    var turnId: UUID? { id }
    var imageData: Data? { nil }
    var hasAttachments: Bool { !attachments.isEmpty }
    var visibleContent: String { content }

    init(role: MessageRole, content: String, attachments: [any AttachmentProtocol] = [], id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.createdAt = createdAt
        self.content = content
        self._contentLength = content.count
        self.thinking = ""
        self._thinkingLength = 0
        self.attachments = attachments
        self.completedAt = role == .user ? Date() : nil
    }

    func appendContent(_ s: String) {
        guard !s.isEmpty else { return }
        content += s
    }

    func appendContentAndNotify(_ s: String) {
        appendContent(s)
        objectWillChange.send()
    }

    func appendThinking(_ s: String) {
        guard !s.isEmpty else { return }
        thinking += s
    }

    func appendThinkingAndNotify(_ s: String) {
        appendThinking(s)
        objectWillChange.send()
    }

    func notifyContentChanged() {
        objectWillChange.send()
    }

    func consolidateContent() {}
    func clearPendingToolArgs() {
        pendingToolArgPreview = nil
        pendingToolArgSize = 0
        pendingToolArgFragmentCount = 0
    }

    func appendToolArgFragment(_ fragment: String) {
        pendingToolArgSize += fragment.utf8.count
        pendingToolArgFragmentCount += 1
    }

    func trimTrailingFunctionCallLeakage(toolName: String) {}

    static func == (lhs: IntelChatTurn, rhs: IntelChatTurn) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Attachment

struct IntelAttachment: AttachmentProtocol, Identifiable, Sendable, Equatable {
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

struct SharedArtifactStub: Equatable, @unchecked Sendable {
    let id: String = ""
    let isImage: Bool = false
    let hostPath: String = ""
}

enum ContentBlockKind: Equatable {
    case sharedArtifact(Any)
    case userMessage(String, Any?)
    case assistantMessage(String)
    case thinking(String)
    case toolCall(String, String)

    static func == (lhs: ContentBlockKind, rhs: ContentBlockKind) -> Bool {
        switch (lhs, rhs) {
        case (.sharedArtifact, .sharedArtifact): return true
        case let (.userMessage(lText, _), .userMessage(rText, _)): return lText == rText
        case let (.assistantMessage(lText), .assistantMessage(rText)): return lText == rText
        case let (.thinking(lText), .thinking(rText)): return lText == rText
        case let (.toolCall(lName, lArgs), .toolCall(rName, rArgs)): return lName == rName && lArgs == rArgs
        default: return false
        }
    }
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

struct IntelChatTurnData: ChatTurnProtocol, ChatTurnDataProtocol, @unchecked Sendable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: String
    var attachments: [any AttachmentProtocol] = []
    var toolCalls: [ToolCall]?
    var toolCallId: String?
    var toolResults: [String: String]
    var thinking: String
    let createdAt: Date
    var completedAt: Date?
    var generationTokenCount: Int?
    var timeToFirstToken: TimeInterval?
    var generationTokensPerSecond: Double?
    var pendingToolName: String?
    var pendingToolArgFragmentCount: Int = 0
    var unclosedReasoning: Bool = false
    var preflightCapabilities: Any? = nil

    var turnId: UUID? { id }
    var imageData: Data? { nil }
    var hasRenderableThinking: Bool { !thinking.isEmpty }
    var hasThinking: Bool { !thinking.isEmpty }
    var contentIsBlank: Bool { content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var thinkingIsBlank: Bool { thinking.isEmpty }
    var contentIsEmpty: Bool { content.isEmpty }
    var contentLength: Int { content.count }
    var visibleContent: String { content }

    init(from turn: any ChatTurnProtocol) {
        self.id = turn.id
        self.role = turn.role
        self.content = turn.content
        self.attachments = turn.attachments
        self.toolCalls = turn.toolCalls
        self.toolCallId = turn.toolCallId
        self.toolResults = turn.toolResults
        self.thinking = turn.thinking
        self.createdAt = turn.createdAt
        self.completedAt = turn.completedAt
        self.generationTokenCount = turn.generationTokenCount
        self.timeToFirstToken = turn.timeToFirstToken
        self.generationTokensPerSecond = turn.generationTokensPerSecond
        self.preflightCapabilities = turn.preflightCapabilities
    }

    static func == (lhs: IntelChatTurnData, rhs: IntelChatTurnData) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content
    }

    func consolidateContent() {}
    func clearPendingToolArgs() {}
    func appendToolArgFragment(_ arg: String) {}
}

// MARK: - Type aliases
typealias ChatTurn = IntelChatTurn
typealias Attachment = IntelAttachment
typealias ContentBlock = IntelContentBlock

final class AppConfiguration: @unchecked Sendable { static let shared = AppConfiguration(); var chatConfig = AppChatConfigStub(); var foundationModelAvailable: Bool { false } }
struct AppChatConfigStub: Sendable { var generativeGreetingsEnabled = false; var disableTools = false; var maxToolAttempts = 5; var topPOverride: Double? = nil }

final class CapabilityLoadBuffer: @unchecked Sendable { static let shared = CapabilityLoadBuffer(); func loadInBackground() {} }

final class ChatConfigurationStore: @unchecked Sendable { static func load() -> ChatConfiguration { IntelChatConfiguration.shared } }

final class ChatSessionExportCoordinator: @unchecked Sendable { static let shared = ChatSessionExportCoordinator() }

struct ClarifyPromptState: Sendable { init() {} }
struct ClarifyTool: Sendable { init() {}; static func parse(argumentsJSON json: String) -> ClarifyPayload? { nil } }

final class FolderContextService: @unchecked Sendable { static let shared = FolderContextService(); var currentContext: Any? { nil } }

struct ImageFullScreenView: View { init(_ args: Any...) {}; var body: some View { EmptyView() } }

final class MemoryContextAssembler: @unchecked Sendable { static let shared = MemoryContextAssembler(); static func assembleContext(agentId: String = "", config: Any? = nil) async -> Any? { nil } }
final class MemorySearchService: @unchecked Sendable { static let shared = MemorySearchService(); func initialize() async {} }

final class ModelOptionsStore: @unchecked Sendable { static let shared = ModelOptionsStore(); func loadOptions(for model: String) -> [ModelOptionValue] { [] } }
final class ModelProfileRegistry: @unchecked Sendable { static let shared = ModelProfileRegistry(); static func thinkingEnabled(for model: String, values: [String: ModelOptionValue]) -> Bool? { nil }; static func normalizedOptions(for model: String, persisted: [String: ModelOptionValue]) -> [String: ModelOptionValue] { persisted } }
final class ModelRuntime: @unchecked Sendable { static let shared = ModelRuntime(); func unloadModelsNotIn(_ names: [String]) {}; var runtimeSettings: Any? { nil } }

final class PluginInstructionsResolver: @unchecked Sendable { static let shared = PluginInstructionsResolver() }

final class SandboxAgentProvisioner: @unchecked Sendable { static let shared = SandboxAgentProvisioner(); static func linuxName(for agentId: String) -> String { "agent" } }
final class SandboxToolRegistrar: @unchecked Sendable { static let shared = SandboxToolRegistrar(); func registerTools(for agentId: UUID) async {} }

struct ScrollToBottomButton: View { init(_ args: Any...) {}; var body: some View { EmptyView() } }

struct SecretPromptParser: Sendable { init() {} }
struct SecretPromptState: Sendable { init() {} }
struct SecretToolResult: Sendable { init() {} }

struct SessionCapability: Sendable { init() {}; static func derive(from turnData: Any? = nil) -> [SessionCapability] { [] } }
struct SessionToolState: Sendable { init() {} }

final class SkillManager: @unchecked Sendable { static let shared = SkillManager() }
final class SlashCommandRegistry: @unchecked Sendable { static let shared = SlashCommandRegistry() }

enum StreamingStatsHint: Sendable {
    static func encode(tokenCount: Int, tokensPerSecond: Double, unclosedReasoning: Bool = false, stopReason: String? = nil) -> String { "" }
    static func decode(_ delta: String) -> (tokenCount: Int, tokensPerSecond: Double, unclosedReasoning: Bool, stopReason: String?)? { nil }
}

enum SessionSource: Sendable { case chat, dispatch, schedule, watcher }
struct LocalAudioSamples: Sendable, Equatable { init() {} }

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
    func toggleSpeak(_ text: String, messageId: String, voiceOverride: Any? = nil) {}
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

struct StreamingToolHint: Sendable {
    static func encode(_ toolName: String) -> String { toolName }
    static func encodeArgs(_ fragment: String) -> String { fragment }
    static func encodeDone(callId: String, name: String, arguments: String, result: String) -> String { "" }
    static func decodeDone(_ delta: String) -> ToolCallDone? { nil }
    static func isSentinel(_ delta: String) -> Bool { false }
    static func decode(_ delta: String) -> String? { nil }
    static func decodeArgs(_ delta: String) -> String? { nil }
}

struct ToolCallDone: Sendable, Equatable {
    let callId: String
    let name: String
    let arguments: String
    let result: String
}

struct StreamingDeltaProcessor: @unchecked Sendable {
    init(turn: IntelChatTurn, onChange: @escaping @Sendable () -> Void = {}) {}
    mutating func finalize() {}
    mutating func receiveReasoning(_ text: String) {}
    mutating func receiveDelta(_ delta: Any) {}
}
enum StreamingReasoningHint: Sendable {
    static func encode(_ text: String) -> String { text }
    static func decode(_ delta: String) -> String? { nil }
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
    static func from(turns: [Any] = [], estimatedOutput: Any? = nil, conversation: Any? = nil, memory: Int = 0, system: Int = 0, instructions: Int = 0) -> ContextBreakdown { ContextBreakdown() }
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
