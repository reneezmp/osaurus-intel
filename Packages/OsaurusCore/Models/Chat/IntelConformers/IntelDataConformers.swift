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

final class ChatTurn: ChatTurnProtocol, ObservableObject, Identifiable, @unchecked Sendable, Equatable {
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

    @Published var attachments: [Attachment] = []
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

    init(role: MessageRole, content: String, attachments: [Attachment] = [], id: UUID = UUID(), createdAt: Date = Date()) {
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

    convenience init(from turn: any ChatTurnProtocol) {
        self.init(role: turn.role, content: turn.content, attachments: turn.attachments, id: turn.id, createdAt: turn.createdAt)
        self.completedAt = turn.completedAt
        self.toolCalls = turn.toolCalls
        self.toolResults = turn.toolResults
        self.thinking = turn.thinking
        self.generationTokenCount = turn.generationTokenCount
        self.timeToFirstToken = turn.timeToFirstToken
        self.generationTokensPerSecond = turn.generationTokensPerSecond
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

    static func == (lhs: ChatTurn, rhs: ChatTurn) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Attachment
//
// `Models/Chat/Attachment.swift` is now compiled directly on Intel
// (removed from Package.swift's exclude list as part of Phase 8C-prep).
// The old `struct Attachment: AttachmentProtocol, ...` stub that used to
// live here is gone — the real 525-line upstream definition with the
// `Kind` enum (image/document/audio/video plus spillover refs) and the
// full Codable surface is what Intel sees now.

// MARK: - VLMDetection (Intel stub)
//
// Upstream `Models/Configuration/MLXModel.swift` lives behind the
// excluded MLX layer, so `VLMDetection.isVLM(at:)` (used by upstream
// `ModelInfo.swift` to mark local Vision-Language models) is amputated
// on Intel. Always-false stub: Intel has no local models, no VLMs.
enum VLMDetection {
    static func isVLM(at directory: URL) -> Bool { false }
}

// MARK: - DirectoryPickerService (Intel stub)
//
// Upstream's `Services/DirectoryPickerService.swift` is excluded
// because it drives the local-model directory picker (NSOpenPanel +
// the on-disk MLX cache). Intel has no local cache to point at, but
// `ModelInfo.findModelDirectory` still calls it as part of its
// directory-scan path. Stub returns `~/.osaurus/models` so it has a
// valid URL to traverse (the directory just won't ever exist on
// Intel — `fileExists` returns false and the scan bails).
enum DirectoryPickerService {
    static func effectiveModelsDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".osaurus/models", isDirectory: true)
    }
}

// MARK: - LocalReasoningCapability (Intel stub)
//
// Upstream's `Services/LocalReasoningCapability.swift` introspects
// the local MLX model's tokenizer / template to decide whether it
// supports thinking-toggle. Intel has no local models, so the
// always-no-thinking capability is the correct answer — keeps
// `AutoThinkingProfile.matches()` from ever firing on Intel.
enum LocalReasoningCapability {
    struct Capability {
        let isToggleableThinking: Bool
    }
    static func capability(forModelId modelId: String) -> Capability {
        Capability(isToggleableThinking: false)
    }
}

// MARK: - NSImage.pngData (Intel-only shim)
//
// The upstream `FloatingInputCard.swift` defines an
// `extension NSImage { func pngData() -> Data? { ... } }` inside its
// `#if !OSAURUS_INTEL` branch, which means on Intel the helper is
// invisible — and the un-excluded `DocumentParser.swift` and
// `ClipboardService.swift` both call it. We mirror the upstream
// implementation here, gated `#if OSAURUS_INTEL`, so both call sites
// link cleanly. Phase 8C-main will lift this extension out of
// `FloatingInputCard.swift` into a shared file at which point this
// shim should be deleted.
extension NSImage {
    func pngData() -> Data? {
        guard let tiff = self.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

// MARK: - AttachmentBlobStore (Intel stub)
//
// Upstream `AttachmentBlobStore` (in the excluded
// `Storage/AttachmentBlobStore.swift`) handles encrypted spill of large
// attachment payloads to disk. On Intel that whole layer is amputated —
// every Attachment payload lives inline. We provide a throw-only stub so
// the four `try? AttachmentBlobStore.read(hash)` call sites in
// `Attachment.swift`'s ref-variant hydration paths convert cleanly to
// `nil` without dragging the whole storage layer in.
enum AttachmentBlobStore {
    static func read(_ hash: String) throws -> Data {
        throw NSError(
            domain: "OsaurusIntel.AttachmentBlobStore",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey:
                "Attachment blob store is amputated on Intel; spillover refs cannot be hydrated."
            ]
        )
    }
}

// MARK: - ContentBlock

enum BlockPosition: Equatable {
    case only, first, middle, last
}

struct ToolCallItem: Equatable {
    let call: ToolCall
    let result: String?
    static func == (lhs: ToolCallItem, rhs: ToolCallItem) -> Bool {
        lhs.call.id == rhs.call.id && lhs.result == rhs.result
    }
}

struct PreflightCapabilityItem: Equatable, Sendable {
    enum CapabilityType: String, Equatable, Sendable {
        case method, tool, skill

        var icon: String {
            switch self {
            case .method: return "doc.text"
            case .tool: return "wrench"
            case .skill: return "lightbulb"
            }
        }
    }

    let id: String = ""
    let name: String = ""
    let type: CapabilityType = .tool
    let description: String = ""
}

enum ContentBlockKind: Equatable {
    case header(role: MessageRole, agentName: String, isFirstInGroup: Bool)
    case paragraph(index: Int, text: String, isStreaming: Bool, role: MessageRole)
    case toolCallGroup(calls: [ToolCallItem])
    case thinking(index: Int, text: String, isStreaming: Bool)
    case userMessage(text: String, attachments: [Attachment])
    case sharedArtifact(artifact: SharedArtifact)
    case pendingToolCall(toolName: String, argPreview: String?, argSize: Int)
    case preflightCapabilities(items: [PreflightCapabilityItem])
    case generationStats(ttft: TimeInterval?, tokensPerSecond: Double?, tokenCount: Int?, unclosedReasoning: Bool)
    case typingIndicator
    case groupSpacer
    case chart(spec: ChartSpec)
    case assistantActions(turnId: UUID)

    static func == (lhs: ContentBlockKind, rhs: ContentBlockKind) -> Bool {
        switch (lhs, rhs) {
        case let (.header(lRole, lName, lFirst), .header(rRole, rName, rFirst)):
            return lRole == rRole && lName == rName && lFirst == rFirst
        case let (.paragraph(lIdx, lText, lStream, lRole), .paragraph(rIdx, rText, rStream, rRole)):
            return lIdx == rIdx && lText == rText && lStream == rStream && lRole == rRole
        case let (.toolCallGroup(lCalls), .toolCallGroup(rCalls)):
            return lCalls == rCalls
        case let (.thinking(lIdx, lText, lStream), .thinking(rIdx, rText, rStream)):
            return lIdx == rIdx && lText == rText && lStream == rStream
        case let (.userMessage(lText, lAttach), .userMessage(rText, rAttach)):
            return lText == rText && lAttach.count == rAttach.count
        case let (.sharedArtifact(lArt), .sharedArtifact(rArt)):
            return lArt == rArt
        case let (.pendingToolCall(lName, _, lSize), .pendingToolCall(rName, _, rSize)):
            return lName == rName && lSize == rSize
        case let (.preflightCapabilities(lItems), .preflightCapabilities(rItems)):
            return lItems == rItems
        case let (.generationStats(lTtft, lTps, lCount, lUnclosed), .generationStats(rTtft, rTps, rCount, rUnclosed)):
            return lTtft == rTtft && lTps == rTps && lCount == rCount && lUnclosed == rUnclosed
        case (.typingIndicator, .typingIndicator), (.groupSpacer, .groupSpacer): return true
        case let (.chart(lSpec), .chart(rSpec)): return lSpec == rSpec
        case let (.assistantActions(lId), .assistantActions(rId)): return lId == rId
        default: return false
        }
    }
}

struct ContentBlock: Identifiable, Equatable, @unchecked Sendable {
    let id: String
    let turnId: UUID
    let kind: ContentBlockKind
    var position: BlockPosition = .only

    var role: MessageRole {
        switch kind {
        case let .header(role, _, _): return role
        case let .paragraph(_, _, _, role): return role
        case .toolCallGroup, .thinking, .sharedArtifact, .pendingToolCall, .preflightCapabilities,
             .generationStats, .typingIndicator, .groupSpacer, .chart, .assistantActions:
            return .assistant
        case .userMessage: return .user
        }
    }
}

// MARK: - ModelOptionValue
//
// Now provided by upstream `Models/Configuration/ModelOptions.swift`
// (un-excluded as part of Phase 8C-prep-2). The Intel `struct
// ModelOptionValue` stub that used to live here has been removed.

// MARK: - ChatTurnData

struct ChatTurnData: ChatTurnProtocol, ChatTurnDataProtocol, @unchecked Sendable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: String
    var attachments: [Attachment] = []
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

    static func == (lhs: ChatTurnData, rhs: ChatTurnData) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content
    }

    func consolidateContent() {}
    func clearPendingToolArgs() {}
    func appendToolArgFragment(_ arg: String) {}
}

// MARK: - Type aliases

// Agent from Agent.swift is NOT excluded; add conformance to AgentInfoProtocol
extension Agent: AgentInfoProtocol {}

final class AppConfiguration: @unchecked Sendable { static let shared = AppConfiguration(); var chatConfig = AppChatConfigStub(); var foundationModelAvailable: Bool { false } }
struct AppChatConfigStub: Sendable { var generativeGreetingsEnabled = false; var disableTools = false; var maxToolAttempts = 5; var topPOverride: Double? = nil }

final class CapabilityLoadBuffer: @unchecked Sendable { static let shared = CapabilityLoadBuffer(); func loadInBackground() {}; func drain() -> [IntelTool] { [] } }

final class ChatConfigurationStore: @unchecked Sendable { static func load() -> ChatConfiguration { ChatConfiguration.shared } }

final class ChatSessionExportCoordinator: @unchecked Sendable { static let shared = ChatSessionExportCoordinator() }

struct ClarifyPromptState: Sendable {
    init(question: String = "", options: [String] = [], allowMultiple: Bool = false, onSubmit: ((String) -> Void)? = nil) {}
    func cancel() {}
}

struct SecretPromptState: Sendable {
    init() {}
    init(key: String = "", description: String = "", instructions: String = "", agentId: UUID? = nil, onSubmit: ((String) -> Void)? = nil) {}
    var key: String { "" }
    var description: String { "" }
    var instructions: String { "" }
    var agentId: UUID? { nil }
    func cancel() {}
}

struct ClarifyTool: Sendable { init() {}; static func parse(argumentsJSON json: String) -> ClarifyPayload? { nil } }

final class FolderContextService: @unchecked Sendable { static let shared = FolderContextService(); var currentContext: FolderContext? { nil } }

struct ImageFullScreenView: View { var image: Any? = nil; var altText: String = ""; var body: some View { EmptyView() } }

extension View {
    func imageFullScreenSheetPresentation() -> some View {
        frame(
            minWidth: 320,
            idealWidth: 960,
            maxWidth: .infinity,
            minHeight: 240,
            idealHeight: 720,
            maxHeight: .infinity
        )
        .presentationSizing(.fitted)
    }
}

final class MemoryContextAssembler: @unchecked Sendable { static let shared = MemoryContextAssembler(); static func assembleContext(agentId: String = "", config: Any? = nil) async -> Any? { nil } }
final class MemorySearchService: @unchecked Sendable { static let shared = MemorySearchService(); func initialize() async {}; func indexTranscriptTurn(_ turn: Any) async {} }

// `ModelOptionsStore` and `ModelProfileRegistry` are now provided by
// upstream (un-excluded as part of Phase 8C-prep-2). The Intel stubs
// that used to live here have been removed.
final class ModelRuntime: @unchecked Sendable { static let shared = ModelRuntime(); func unloadModelsNotIn(_ names: Set<String>) {}; var runtimeSettings: Any? { nil } }

final class PluginInstructionsResolver: @unchecked Sendable { static let shared = PluginInstructionsResolver(); static func instructions(pluginId: String, agentId: Any? = nil) -> String? { nil } }

final class SandboxAgentProvisioner: @unchecked Sendable { static let shared = SandboxAgentProvisioner(); static func linuxName(for agentId: String) -> String { "agent" } }
final class SandboxToolRegistrar: @unchecked Sendable { static let shared = SandboxToolRegistrar(); func registerTools(for agentId: UUID) async {} }

struct SecretPromptParser: Sendable {
    init() {}
    static func parse(_ text: String) -> SecretPromptState? { nil }
}
struct SecretToolResult: Sendable {
    init() {}
    static func stored(key: String) -> String { "" }
    static func cancelled(key: String) -> String { "" }
}

enum SessionCapability: String, Codable, Hashable, Sendable, CaseIterable {
    case vision
    case voice
    case code
    case search

    var iconName: String {
        switch self {
        case .vision: return "eye.fill"
        case .voice: return "waveform"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .search: return "magnifyingglass"
        }
    }

    var label: String {
        switch self {
        case .vision: return "Vision"
        case .voice: return "Voice"
        case .code: return "Code"
        case .search: return "Search"
        }
    }

    /// No-op derive used by the Intel `ChatSession` path. Capability badges
    /// stay empty on Intel until a fuller turn-inspection pipeline lands.
    static func derive(from turnData: Any? = nil) -> Set<SessionCapability> { [] }
}
struct SessionToolState: Sendable {
    init() {}
    static func fingerprint(executionMode: Any?, toolMode: Any?) -> String { "" }
    var initialPreflight: Any? { nil }
    var loadedToolNames: [String]? { nil }
    var initialAlwaysLoadedNames: Any? { nil }
}

struct IntelSkillInfo: Sendable {
    let id: UUID
    let name: String
}

final class SkillManager: @unchecked Sendable {
    static let shared = SkillManager()
    func skill(for id: UUID) -> IntelSkillInfo? { nil }
    func buildFullInstructions(for skill: IntelSkillInfo, agentId: Any? = nil) -> String? { nil }
}

final class SlashCommandRegistry: @unchecked Sendable { static let shared = SlashCommandRegistry(); var isPopupVisible: Bool { false } }

enum StreamingStatsHint: Sendable {
    static func encode(tokenCount: Int, tokensPerSecond: Double, unclosedReasoning: Bool = false, stopReason: String? = nil) -> String { "" }
    static func decode(_ delta: String) -> (tokenCount: Int, tokensPerSecond: Double, unclosedReasoning: Bool, stopReason: String?)? { nil }
}

enum SessionSource: String, Codable, CaseIterable, Sendable {
    case chat, plugin, http, schedule, watcher, selfSchedule = "self_schedule"

    var iconName: String {
        switch self {
        case .chat: return "bubble.left.fill"
        case .plugin: return "puzzlepiece.extension.fill"
        case .http: return "network"
        case .schedule: return "clock.fill"
        case .watcher: return "eye.fill"
        case .selfSchedule: return "alarm.fill"
        }
    }

    var shortLabel: String {
        switch self {
        case .chat: return "Chat"
        case .plugin: return "Plugin"
        case .http: return "API"
        case .schedule: return "Schedule"
        case .watcher: return "Watcher"
        case .selfSchedule: return "Self-scheduled"
        }
    }

    func originLabel(pluginDisplayName: String? = nil) -> String? {
        switch self {
        case .chat: return nil
        case .plugin:
            if let name = pluginDisplayName, !name.isEmpty { return "via \(name)" }
            return "via plugin"
        case .http: return "via API"
        case .schedule: return "scheduled"
        case .watcher: return "watcher"
        case .selfSchedule: return "self-scheduled"
        }
    }
}

/// Intel-side mirror of upstream `PluginDisplayNameResolver` (lives in the
/// excluded `SessionSource.swift`). Falls through to the raw plugin id since
/// `PluginManager` is amputated on Intel and we have nothing to look up.
@MainActor
enum PluginDisplayNameResolver {
    static func displayName(for pluginId: String) -> String {
        if pluginId.hasPrefix("sandbox:") {
            return String(pluginId.dropFirst("sandbox:".count))
        }
        return pluginId
    }
}

enum SearchService {
    static func matches(query: String, in text: String) -> Bool {
        guard !query.isEmpty else { return true }
        return text.localizedCaseInsensitiveContains(query)
    }
}
struct LocalAudioSamples: Sendable, Equatable { init() {} }


// `ModelPickerItem`, `ModelPickerSource`, and the
// `Array<ModelPickerItem>.firstChatCapable` extension are now provided
// by upstream `Models/Configuration/ModelPickerItem.swift` (un-excluded
// in Phase 8C-prep-2). The Intel duplicates that used to live here have
// been removed.
//
// Note: `Array<Attachment>.images` is similarly provided by upstream
// `Attachment.swift` (un-excluded in Phase 8C-prep-1).

/// Intel-side ergonomic shim on upstream `ModelPickerItem.Source` so the
/// few `item.source.remoteProviderId == providerId` filter call sites in
/// `ChatView` (and friends) don't need to pattern-match the enum directly.
/// Upstream doesn't expose this because the upstream code uses different
/// matching idioms in those spots; on Intel we kept the simpler form.
extension ModelPickerItem.Source {
    var remoteProviderId: UUID? {
        if case .remote(_, let providerId) = self { return providerId }
        return nil
    }
}

// MARK: - Additional stubs

struct DiscoveredAgent: Identifiable, Sendable {
    public let id = UUID()
    var token: String? { nil }
    var relayToken: String? { nil }
    var providerId: UUID? { nil }
    var displayName: String { "" }
    var name: String { "" }
    var host: String? { nil }
    var port: Int? { nil }
    var address: String? { nil }
    var kind: String { "" }
    var providerType: String { "" }
}

struct PairedRelayAgent: Identifiable, Sendable {
    public let id = UUID()
    var token: String? { nil }
    var remoteAgentId: UUID? { nil }
    var remoteAgentAddress: String { "" }
    var providerId: UUID { UUID() }
    var address: String { "" }
    var name: String { "" }
    var host: String { "" }
    var port: Int? { nil }
    var kind: String { "relay" }
    var providerType: String { "" }
}

final class ContextBudgetManager: @unchecked Sendable {
    static let shared = ContextBudgetManager()
    static func estimateOutputTokens(for turns: [ChatTurn]) -> Int { 0 }
    static func estimateTokens(for turns: [ChatTurn]) -> Int { 0 }
    static func estimateTokens(for text: String) -> Int { max(1, text.count / 4) }
    static func estimateTokens(for item: Any?) -> Int { 0 }
}

struct ToolEnvelope: Sendable {
    init() {}
    static func isError(_ result: String) -> Bool { false }
    static func fromError(_ error: Error, tool: String? = nil) -> String { "{\"ok\":false}" }
    static func success(tool: String? = nil, text: String, warnings: [String]? = nil) -> String { "{\"ok\":true,\"result\":{\"text\":\"\(text)\"}}" }
    static func success(tool: String? = nil, result: Any? = nil, warnings: [String]? = nil) -> String { "{\"ok\":true}" }
    static func successPayload(_ result: String) -> Any? { nil }
    static func failure(kind: Kind, message: String, field: String? = nil, expected: String? = nil, tool: String? = nil, retryable: Bool = false, metadata: [String: Any]? = nil) -> String {
        "{\"ok\":false,\"kind\":\"\(kind.rawValue)\",\"message\":\"\(message)\"}"
    }
    enum Kind: String, Sendable { case success, failure, invalidArgs, executionError, rejected, timeout, toolNotFound, unavailable, userDenied }
}

final class SessionToolStateStore: @unchecked Sendable {
    static let shared = SessionToolStateStore()
    func invalidate(_ key: Any) async {}
    func invalidateIfFingerprintChanged(_ key: Any, liveFingerprint: Any) async {}
    func get(_ key: Any) async -> SessionToolState? { nil }
    func setInitial(_ key: Any, preflight: Any?, alwaysLoadedNames: Any?, fingerprint: String) async {}
    func recordSend(sessionId: Any, cacheHint: Any?, trace: Any?) async {}
    func appendLoadedTools(_ key: Any, names: [String], fallbackPreflight: Any?, fallbackAlwaysLoadedNames: Any?) async {}
}

final class TTSService: @unchecked Sendable {
    func toggleSpeak(text: String, messageId: UUID, voiceOverride: Any? = nil) {}
    var playingMessageId: UUID? { nil }
    var activeSpeakCallId: String? { nil }
    static let shared = TTSService()
    func refreshModelState() {}
    var selectedVoice: Any? { nil }
    var isSpeaking: Bool { false }
    var selectedModel: Any? { nil }
    var isModelReady: Bool { false }
}

struct MockChatData: Sendable {
    init() {}
    static var isEnabled: Bool { false }
    static let shared = MockChatData()
    static func mockTurnsForPerformanceTest(count: Int = 10) -> [ChatTurn] { [] }
}

struct ServiceToolInvocation: Sendable {
    init() {}
    var toolCallId: String? { nil }
    var toolName: String { "" }
    var jsonArguments: String { "" }
    var geminiThoughtSignature: String? { nil }
}

struct ServiceToolInvocations: Error, Sendable {
    let invocations: [ServiceToolInvocation]
}

enum PromptQueueItem: Identifiable, Sendable {
    case secret(SecretPromptState)
    case clarify(ClarifyPromptState)

    var id: String {
        switch self {
        case .secret: return "secret"
        case .clarify: return "clarify"
        }
    }
}

final class PromptQueue: ObservableObject, @unchecked Sendable {
    var current: PromptQueueItem? { nil }
    func enqueue(_ item: PromptQueueItem) {}
    func drainAll() {}
    func advance() {}
}

struct ClarifyPayload: Sendable, Equatable {
    let question: String = ""
    let options: [String] = []
    let allowMultiple: Bool = false
}

final class BlockMemoizer: @unchecked Sendable {
    init() {}
    static let shared = BlockMemoizer()
    func blocks(from turns: [ChatTurn], streamingTurnId: UUID? = nil, agentName: String = "", version: Int = 0, thinkingEnabled: Bool = false) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var groupId: UUID?
        for (i, turn) in turns.enumerated() {
            let isUser = turn.role == .user
            let isFirstInGroup = turn.id != groupId
            if isFirstInGroup { groupId = turn.id }

            // Header for first turn in group
            if isFirstInGroup {
                blocks.append(ContentBlock(
                    id: "header-\(turn.id.uuidString)",
                    turnId: turn.id,
                    kind: .header(role: turn.role, agentName: agentName, isFirstInGroup: i == 0 || turns[i-1].role != turn.role)
                ))
            }

            // Thinking
            if !turn.thinking.isEmpty {
                blocks.append(ContentBlock(
                    id: "thinking-\(turn.id.uuidString)",
                    turnId: turn.id,
                    kind: .thinking(index: blocks.count, text: turn.thinking, isStreaming: turn.id == streamingTurnId)
                ))
            }

            // User message
            if isUser && !turn.content.isEmpty {
                blocks.append(ContentBlock(
                    id: "user-\(turn.id.uuidString)",
                    turnId: turn.id,
                    kind: .userMessage(text: turn.content, attachments: turn.attachments)
                ))
            }

            // Assistant message (paragraph with role)
            if !isUser && !turn.content.isEmpty {
                blocks.append(ContentBlock(
                    id: "assistant-\(turn.id.uuidString)",
                    turnId: turn.id,
                    kind: .paragraph(
                        index: blocks.count,
                        text: turn.content,
                        isStreaming: turn.id == streamingTurnId,
                        role: .assistant
                    )
                ))
            }
        }
        return blocks
    }
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

@MainActor
final class StreamingDeltaProcessor: @unchecked Sendable {
    private let turn: ChatTurn
    private let onChange: @MainActor @Sendable () -> Void

    init(turn: ChatTurn, onChange: @escaping @MainActor @Sendable () -> Void = {}) {
        self.turn = turn
        self.onChange = onChange
    }

    func finalize() {
        onChange()
    }

    func receiveReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        turn.appendThinking(text)
    }

    func receiveDelta(_ delta: Any) {
        guard let text = delta as? String, !text.isEmpty else { return }
        turn.appendContent(text)
        onChange()
    }
}
enum StreamingReasoningHint: Sendable {
    static func encode(_ text: String) -> String { text }
    static func decode(_ delta: String) -> String? { nil }
}

final class SystemPromptComposer: @unchecked Sendable {
    static let shared = SystemPromptComposer()
    static func composePreviewContext(agentId: Any? = nil, executionMode: Any? = nil, model: String? = nil) -> ComposedContext { ComposedContext() }
    static func composeChatContext(agentId: Any? = nil, executionMode: Any? = nil, model: String? = nil, query: String? = nil, messages: [Any] = [], toolsDisabled: Bool = false, cachedPreflight: Any? = nil, additionalToolNames: [String] = [], frozenAlwaysLoadedNames: Any? = nil, trace: Any? = nil) async -> ComposedContext { ComposedContext() }
    static func injectMemoryPrefix(_ section: String?, into messages: inout [ChatMessage]) {}
}

struct PromptManifest: Sendable { init() {} }
struct IntelTool: Codable, Sendable {
    struct ToolFunction: Codable, Sendable {
        let name: String
        let description: String?
    }
    let function: ToolFunction
    var type: String { "function" }
}

typealias Tool = IntelTool

enum ToolChoiceOption: Codable, Sendable {
    case auto
    case none
    case function(String)
}

struct ToolFunction: Codable, Sendable {
    let name: String
    let description: String?
}

struct ComposedContext: @unchecked Sendable {
    let prompt: String
    let manifest: PromptManifest
    let toolTokens: Int
    var tools: [IntelTool]
    var preflight: Any?
    var alwaysLoadedNames: Any?
    var preflightItems: [Any]
    var memorySection: String?
    var cacheHint: Any?
    init(prompt: String = "", manifest: PromptManifest = PromptManifest(), toolTokens: Int = 0, tools: [IntelTool] = [], preflight: Any? = nil, alwaysLoadedNames: Any? = nil, preflightItems: [Any] = [], memorySection: String? = nil, cacheHint: Any? = nil) {
        self.prompt = prompt
        self.manifest = manifest
        self.toolTokens = toolTokens
        self.tools = tools
        self.preflight = preflight
        self.alwaysLoadedNames = alwaysLoadedNames
        self.preflightItems = preflightItems
        self.memorySection = memorySection
        self.cacheHint = cacheHint
    }
}
struct ContextDisableInfo: Sendable { init() {} }

struct ContextBreakdown: Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        var tokens: Int
        let tint: ContextBreakdown.Tint
        init(id: String, label: String, tokens: Int, tint: ContextBreakdown.Tint = .gray) {
            self.id = id; self.label = label; self.tokens = tokens; self.tint = tint
        }
    }
    enum Tint: String, Sendable { case purple, blue, orange, green, gray, cyan, teal, indigo }
    var context: [Entry] = []
    var messages: [Entry] = []
    var disable: ContextDisableInfo? = nil
    var total: Int { context.reduce(0) { $0 + $1.tokens } + messages.reduce(0) { $0 + $1.tokens } }
    var allEntries: [Entry] { context + messages }
    static let zero = ContextBreakdown()

    init(context: [Entry] = [], messages: [Entry] = [], disable: ContextDisableInfo? = nil) {
        self.context = context; self.messages = messages; self.disable = disable
    }

    static func from(
        context composed: ComposedContext,
        conversationTokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0
    ) -> ContextBreakdown {
        ContextBreakdown()
    }

    static func from(
        manifest: PromptManifest,
        toolTokens: Int = 0,
        memoryTokens: Int = 0,
        conversationTokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0
    ) -> ContextBreakdown {
        ContextBreakdown()
    }

    static func tint(for sectionId: String) -> Tint { .gray }
}

final class ContextBudgetTracker: @unchecked Sendable {
    init() {}
    func clear() {}
    var estimatedTokens: Int { 0 }
    func activeBreakdown(isActive: Bool = false, outputTurn: ChatTurn? = nil) -> ContextBreakdown? { nil }
    func snapshot(context: ComposedContext) {}
    func updateConversation(tokens: Int, finishedOutputTurn: ChatTurn?) {}
}

final class LiveVoiceAudioInputRegistry: @unchecked Sendable {
    static let shared = LiveVoiceAudioInputRegistry()
    func samples(for id: UUID) -> LocalAudioSamples? { nil }
}

final class MemoryDatabase: @unchecked Sendable {
    static let shared = MemoryDatabase()
    var isOpen = false
    var memoryDisabled: Bool { true }
    func open() throws {}
    func insertTranscriptTurn(agentId: String, conversationId: String, chunkIndex: Int, role: String, content: String, tokenCount: Int, title: String? = nil, createdAt: String? = nil) throws {}
}

final class ServerController: @unchecked Sendable {
    static let shared = ServerController()
    static func signalGenerationStart() {}
    static func signalGenerationEnd() {}
    var configuration: Any? { nil }
    var port: Int { 1337 }
    var isRunning: Bool { true }
}

extension ChatMessage {
    init(role: String, text: String, imageData: [Data]) {
        self.init(role: role, content: text.isEmpty ? nil : text)
    }

    init(
        role: String,
        text: String,
        imageData: [Data],
        audios: [(data: Data, format: String)],
        localAudioSamples: [LocalAudioSamples?] = [],
        videos: [(data: Data, mimeSubtype: String)]
    ) {
        self.init(role: role, content: text.isEmpty ? nil : text)
    }
}



struct RemoteProviderServiceError: Error, Sendable {}


// Notification names
extension NSNotification.Name {
    static let remoteProviderModelsChanged = NSNotification.Name("remoteProviderModelsChanged")
    static let localModelsChanged = NSNotification.Name("localModelsChanged")
    static let chatOverlayActivated = NSNotification.Name("chatOverlayActivated")
    static let chatToolbarSelectDiscoveredAgent = NSNotification.Name("chatToolbarSelectDiscoveredAgent")
    static let chatToolbarSelectRelayAgent = NSNotification.Name("chatToolbarSelectRelayAgent")
    static let vadStartNewSession = NSNotification.Name("vadStartNewSession")
    static let chatViewClosed = NSNotification.Name("chatViewClosed")
    static let toolsListChanged = NSNotification.Name("toolsListChanged")
    static let ttsPlaybackStateChanged = NSNotification.Name("osaurus.ttsPlaybackStateChanged")
}
#endif

#if OSAURUS_INTEL

// MARK: - ThreadCache Intel conformer
// Mirrors the excluded Managers/ThreadCache.swift. No-op caching:
// always cache-miss → forces re-parse per render. Correctness preserved.
//
// ParsedMarkdown is replicated here because the upstream type lives inside
// the excluded ThreadCache.swift. MessageBlock + ContentSegment stubs are
// minimal — real definitions live in MarkdownMessageView.swift (un-body-
// swapped in Phase 4-0c, simultaneous with this commit).

import AppKit

struct ParsedMarkdown {
    let blocks: [MessageBlock]
    let segments: [ContentSegment]
}

final class ThreadCache: @unchecked Sendable {
    static let shared = ThreadCache()
    private init() {}

    func height(for key: String) -> CGFloat? { nil }
    func setHeight(_ height: CGFloat, for key: String) {}

    func markdown(for text: String) -> ParsedMarkdown? { nil }
    func setMarkdown(blocks: [MessageBlock], segments: [ContentSegment], for text: String) {}

    func image(for urlString: String) -> NSImage? { nil }
    func setImage(_ image: NSImage, for urlString: String) {}

    func clear() {}

    static func imageCacheKey(for urlString: String) -> NSString {
        urlString as NSString
    }
}

#endif
