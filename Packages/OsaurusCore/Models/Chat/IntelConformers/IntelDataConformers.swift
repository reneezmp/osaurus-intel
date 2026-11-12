//
//  IntelDataConformers.swift
//  OsaurusCore
//
//  M10 Phase 4d: Intel-lite data type conformers for ChatView protocols.
//

#if OSAURUS_INTEL

import Combine
import Foundation
import SwiftUI
import os

// MARK: - ChatTurn

final class ChatTurn: ChatTurnProtocol, ObservableObject, Identifiable, @unchecked Sendable, Equatable {
    let id: UUID
    let role: MessageRole
    let createdAt: Date
    var completedAt: Date?

    // MARK: - Token-estimate revision (upstream #3112)

    /// Process-wide counter bumped whenever any turn mutates a field that
    /// feeds the context-budget token estimates (content, thinking, tool
    /// calls/results, attachments). `ChatSession` keys its cached transcript
    /// token totals on this value so the readout rendered from the chat view
    /// body doesn't re-walk every turn per render, while still picking up
    /// in-place turn edits that never reassign the session's `turns` array.
    private static let _tokenEstimateRevision = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    /// Current value of the process-wide token-estimate revision.
    static var tokenEstimateRevision: UInt64 {
        _tokenEstimateRevision.withLock { $0 }
    }

    private static func bumpTokenEstimateRevision() {
        _tokenEstimateRevision.withLock { $0 &+= 1 }
    }

    @Published var content: String {
        didSet {
            _contentLength = content.count
            _cachedVisibleContent = nil
            _cachedContentIsBlank = nil
            Self.bumpTokenEstimateRevision()
        }
    }
    var contentLength: Int { _contentLength }
    private var _contentLength: Int

    var contentIsEmpty: Bool { _contentLength == 0 }
    /// Memoized `contentIsBlank`. Trimming copies the whole message, and
    /// visible-block rebuilds read this for every assistant turn on every
    /// streaming sync (upstream #3267, APPLE-MACOS-3KF). Reset in `content`'s
    /// `didSet`, which every Intel mutation path goes through.
    private var _cachedContentIsBlank: Bool?
    var contentIsBlank: Bool {
        if _contentLength == 0 { return true }
        if let cached = _cachedContentIsBlank { return cached }
        let blank = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        _cachedContentIsBlank = blank
        return blank
    }

    @Published var thinking: String {
        didSet {
            _thinkingLength = thinking.count
            _cachedThinkingIsBlank = nil
            Self.bumpTokenEstimateRevision()
        }
    }
    var thinkingLength: Int { _thinkingLength }
    private var _thinkingLength: Int

    var thinkingIsEmpty: Bool { _thinkingLength == 0 }
    /// Memoized `thinkingIsBlank` (see `_cachedContentIsBlank`, upstream #3267).
    private var _cachedThinkingIsBlank: Bool?
    var thinkingIsBlank: Bool {
        if _thinkingLength == 0 { return true }
        if let cached = _cachedThinkingIsBlank { return cached }
        let blank = thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        _cachedThinkingIsBlank = blank
        return blank
    }

    var hasThinking: Bool { _thinkingLength > 0 }
    var hasRenderableThinking: Bool { hasThinking && !thinkingIsBlank }

    @Published var attachments: [Attachment] = [] {
        didSet { Self.bumpTokenEstimateRevision() }
    }
    @Published var toolCalls: [ToolCall]? = nil {
        didSet { Self.bumpTokenEstimateRevision() }
    }
    var toolCallId: String? = nil {
        didSet { Self.bumpTokenEstimateRevision() }  // upstream #3259
    }
    @Published var toolResults: [String: String] = [:] {
        didSet { Self.bumpTokenEstimateRevision() }
    }
    /// Artifact cards on this turn (upstream), e.g. a `/screenshot` capture.
    @Published var sharedArtifacts: [SharedArtifact] = []

    var pendingToolName: String? = nil {
        didSet {
            // First detection of a tool starts the clock; the imminent call
            // append consumes it in `markToolCallStarted` (upstream #1259).
            if pendingToolName != nil, pendingToolStartedAt == nil {
                pendingToolStartedAt = Date()
            }
        }
    }
    /// Wall-clock duration (seconds) each tool call took to finish, keyed by
    /// call id. Recorded by `setToolResult(_:for:)` and persisted so a
    /// reloaded chat still shows "· 1.2s" next to the tool title (upstream
    /// #1259).
    @Published var toolCallDurations: [String: TimeInterval] = [:]
    /// How long the model spent thinking (seconds) — from the first reasoning
    /// token to the first content/tool that follows. Drives "Thought for
    /// 30s"; persisted.
    @Published var thinkingDuration: TimeInterval?
    /// Anthropic `thinking` / `redacted_thinking` blocks with their
    /// signatures, kept whole so the next request can replay them (upstream
    /// #3203; persisted with the turn).
    var anthropicThinkingBlocks: [JSONValue] = []
    private var thinkingStartedAt: Date?
    private var accumulatedThinkingDuration: TimeInterval = 0
    private var pendingToolStartedAt: Date?
    private var toolCallStartedAt: [String: Date] = [:]
    var pendingToolArgPreview: String? = nil
    var pendingToolArgSize: Int = 0
    var pendingToolArgFragmentCount: Int = 0
    /// Full accumulated tool arguments during streaming, kept only for
    /// file-writing tools (see `FileDiff.diffProducingToolNames`) so the chat
    /// can render a live, growing code card while the model writes — the
    /// truncated `pendingToolArgPreview` can't back that. Capped so a runaway
    /// arg stream can't balloon memory (upstream #1683).
    var pendingToolArgFull: String? = nil
    private static let maxFullArgAccumulation = 262_144
    var preflightCapabilities: Any? = nil

    var timeToFirstToken: TimeInterval?
    var generationTokensPerSecond: Double?
    var generationTokenCount: Int?
    var unclosedReasoning: Bool = false
    /// Osaurus Router charge for this turn (upstream): stamped from the
    /// stream's billing hint, persisted with the chat.
    var routerBilling: RouterBillingSummary?
    /// Upstream: kept visible in the transcript but left out of model
    /// history (an ungrounded answer the model then corrected). Persisted.
    var modelContextExcluded: Bool = false
    /// Why the turn ended, when known (upstream #2388): `cancelled` for a
    /// user Stop. Persisted, and kept through the trailing-blank trim so a
    /// Stop before the first delta still leaves a record (#2392).
    var terminalStopReason: String?
    /// Frozen memory / time block this USER turn was first sent with,
    /// including its trailing separator (upstream #1798,
    /// `SystemPromptComposer.composeInjectedUserPrefix`). Recorded once at
    /// send time and replayed verbatim on every later request, so the turn's
    /// wire bytes never change and provider prompt caches stay valid. Never
    /// shown in the bubble; persisted.
    var injectedContextPrefix: String?
    /// Ledger rows written for this turn during the live run, finalized with
    /// the rendered outcome at run cleanup. Transient (upstream).
    var billingEntryIds: Set<String> = []

    var turnId: UUID? { id }
    var imageData: Data? { nil }
    var hasAttachments: Bool { !attachments.isEmpty }
    /// User-visible content (upstream): assistant turns hide a leaked
    /// Harmony channel label, Gemini round-trip metadata and tool-call JSON a
    /// model emitted as text. Cached because the cleaners are O(n·braces)
    /// and the block builder reads it on the main thread (upstream #2922);
    /// cleared whenever `content` changes.
    var visibleContent: String {
        guard role == .assistant else { return content }
        if let cached = _cachedVisibleContent { return cached }
        let cleaned = StringCleaning.stripLeakedActionJSON(
            StringCleaning.stripGeminiDisplayMetadata(
                StringCleaning.stripLeakedChannelLabel(content)
            )
        )
        _cachedVisibleContent = cleaned
        return cleaned
    }
    private var _cachedVisibleContent: String?

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

    /// Upstream's artifact-turn initializer (`/screenshot`).
    convenience init(role: MessageRole, content: String, sharedArtifacts: [SharedArtifact]) {
        self.init(role: role, content: content)
        self.sharedArtifacts = sharedArtifacts
    }

    convenience init(from turn: any ChatTurnProtocol) {
        self.init(role: turn.role, content: turn.content, attachments: turn.attachments, id: turn.id, createdAt: turn.createdAt)
        self.completedAt = turn.completedAt
        self.toolCalls = turn.toolCalls
        self.toolResults = turn.toolResults
        self.sharedArtifacts = turn.sharedArtifacts
        self.thinking = turn.thinking
        self.generationTokenCount = turn.generationTokenCount
        self.timeToFirstToken = turn.timeToFirstToken
        self.generationTokensPerSecond = turn.generationTokensPerSecond
        self.routerBilling = (turn as? ChatTurnData)?.routerBilling ?? (turn as? ChatTurn)?.routerBilling
        self.modelContextExcluded =
            (turn as? ChatTurnData)?.modelContextExcluded ?? (turn as? ChatTurn)?.modelContextExcluded ?? false
        self.terminalStopReason =
            (turn as? ChatTurnData)?.terminalStopReason ?? (turn as? ChatTurn)?.terminalStopReason
        self.injectedContextPrefix =
            (turn as? ChatTurnData)?.injectedContextPrefix ?? (turn as? ChatTurn)?.injectedContextPrefix
        self.toolCallDurations =
            (turn as? ChatTurnData)?.toolCallDurations ?? (turn as? ChatTurn)?.toolCallDurations ?? [:]
        self.thinkingDuration =
            (turn as? ChatTurnData)?.thinkingDuration ?? (turn as? ChatTurn)?.thinkingDuration
        self.anthropicThinkingBlocks =
            (turn as? ChatTurnData)?.anthropicThinkingBlocks ?? (turn as? ChatTurn)?.anthropicThinkingBlocks ?? []
    }

    func appendContent(_ s: String) {
        guard !s.isEmpty else { return }
        // First visible content marks the end of any thinking phase.
        finalizeThinkingDuration()
        content += s
    }

    /// Durations shorter than this aren't shown — they're indistinguishable
    /// from "instant" and usually mean the call + result arrived in the same
    /// tick without an observable execution window.
    private static let minDisplayableToolDuration: TimeInterval = 0.05

    /// Mark a tool call as started so its duration can be measured.
    /// Idempotent; uses the pending-detection start when present (so the
    /// timer spans the whole detect→result window), else now.
    func markToolCallStarted(_ callId: String) {
        // A tool following reasoning also ends the thinking phase.
        finalizeThinkingDuration()
        guard toolCallStartedAt[callId] == nil else { return }
        toolCallStartedAt[callId] = pendingToolStartedAt ?? Date()
        pendingToolStartedAt = nil
    }

    /// Record the thinking duration at the first content/tool that follows
    /// reasoning. No-op for turns without thinking or below the threshold.
    func finalizeThinkingDuration(at: Date = Date()) {
        guard let start = thinkingStartedAt else { return }
        accumulatedThinkingDuration += max(0, at.timeIntervalSince(start))
        thinkingStartedAt = nil
        if accumulatedThinkingDuration >= Self.minDisplayableToolDuration {
            thinkingDuration = accumulatedThinkingDuration
        }
    }

    /// Set a tool call's result and record how long it took (if we saw it
    /// start). Use this instead of assigning `toolResults` directly so
    /// durations persist.
    func setToolResult(_ result: String, for callId: String) {
        toolResults[callId] = result
        guard toolCallDurations[callId] == nil, let start = toolCallStartedAt[callId] else { return }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed >= Self.minDisplayableToolDuration {
            toolCallDurations[callId] = elapsed
        }
    }

    func appendContentAndNotify(_ s: String) {
        appendContent(s)
        objectWillChange.send()
    }

    func appendThinking(_ s: String, at: Date = Date()) {
        guard !s.isEmpty else { return }
        if thinkingStartedAt == nil { thinkingStartedAt = at }
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
        pendingToolArgFull = nil
    }

    func appendToolArgFragment(_ fragment: String) {
        pendingToolArgSize += fragment.utf8.count
        pendingToolArgFragmentCount += 1
        // Accumulate a bounded preview so the in-flight tool card can show the
        // query (args) building up live, not just the bare tool name.
        if (pendingToolArgPreview?.count ?? 0) < 600 {
            pendingToolArgPreview = (pendingToolArgPreview ?? "") + fragment
        }
        // Upstream: keep the full args for file-writing tools (and while the
        // name is still unknown) so the live diff card can grow with them.
        let wantsFull =
            pendingToolName == nil
            || pendingToolName == ToolDisplayName.pendingToolSentinel
            || FileDiff.diffProducingToolNames.contains(pendingToolName!)
        if wantsFull {
            let full = pendingToolArgFull ?? ""
            if full.count < Self.maxFullArgAccumulation {
                pendingToolArgFull = full + fragment
            }
        }
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
        var defaultThinkingOn: Bool = false
    }
    static func capability(forModelId modelId: String) -> Capability {
        Capability(isToggleableThinking: false)
    }
}

// MARK: - DeclaredReasoningEffort (Intel stub)
//
// Upstream's `Services/DeclaredReasoningEffort.swift` reads the effort set a
// local MLX bundle declares (`jang_config.json`, or the chat template's own
// closed-set guard). Intel has no local bundles, so nothing is ever declared;
// `ModelProfileRegistry` (upstream's) falls through to the live remote
// catalog and the static profiles.
enum DeclaredReasoningEffort {
    enum Control: Equatable, Sendable {
        case noEffortControl
    }
    static func control(forModelId modelId: String) -> Control? { nil }
    static func mode(forNativeEffort effort: String, control: Control?) -> String? { nil }
    static func capabilities(forModelId modelId: String) -> ModelReasoningCapabilities? { nil }
}

// Note: the Phase 8C-prep-2 `NSImage.pngData()` shim that used to live
// here has been removed in Phase 8C-main because FloatingInputCard.swift
// is now un-body-swapped and its own `extension NSImage` brings the
// helper into scope for the whole Intel module.

// NOTE: `AttachmentBlobStore` is now the REAL upstream type — un-excluded
// in M11 Phase 11.B.1 (it imports only CryptoKit/Foundation/os, no
// amputated deps). The throw-only Intel stub that used to live here was
// removed; the real `read(_:)` serves the same call sites.

// MARK: - ContentBlock

enum BlockPosition: Equatable {
    case only, first, middle, last
}

struct ToolCallItem: Equatable {
    let call: ToolCall
    let result: String?
    /// How long the call took to finish (seconds), shown as "· 1.2s". Nil
    /// until measured / for calls whose duration wasn't recorded (upstream
    /// #1259).
    var duration: TimeInterval? = nil
    static func == (lhs: ToolCallItem, rhs: ToolCallItem) -> Bool {
        lhs.call.id == rhs.call.id && lhs.result == rhs.result && lhs.duration == rhs.duration
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
    /// `duration` drives "Thought for 12s" (upstream #1259).
    case thinking(index: Int, text: String, isStreaming: Bool, duration: TimeInterval?)
    /// Upstream display-time roll-up of a run of consecutive `.thinking` /
    /// `.toolCallGroup` blocks (possibly across the assistant turns of an
    /// agent loop). Collapsed it is one summary row; expanded it renders its
    /// children, whose own ids keep per-item expansion working. Built only by
    /// `ContentBlock.rollupActivityBlocks`, never cached.
    case activityGroup(children: [ContentBlock])
    /// `responseTurnId` is the assistant turn that answered this message (the
    /// first assistant turn that follows it), used by the overflow menu's
    /// "Inspect response" to open that reply's request/response log. Nil when the
    /// message has no assistant reply yet (upstream #1939).
    /// `envelope` is set when the stored text is a machine-generated
    /// dispatch envelope (self-scheduled or watcher run): the cell renders
    /// its human-authored text under a badge row (upstream).
    case userMessage(
        text: String,
        attachments: [Attachment],
        timestamp: Date,
        responseTurnId: UUID?,
        envelope: DispatchEnvelope? = nil
    )
    case sharedArtifact(artifact: SharedArtifact)
    case pendingToolCall(toolName: String, argPreview: String?, argSize: Int)
    case preflightCapabilities(items: [PreflightCapabilityItem])
    /// `totalDuration` (upstream #2916, "Worked for"): wall clock from the
    /// user's message to the end of the reply, tool steps and approval
    /// prompts included. Only on the reply's last assistant turn.
    case generationStats(
        ttft: TimeInterval?, tokensPerSecond: Double?, tokenCount: Int?, unclosedReasoning: Bool,
        totalDuration: TimeInterval?)
    case typingIndicator
    case groupSpacer
    case chart(spec: ChartSpec)
    /// `timestamp` heads the overflow menu (upstream #1655).
    case assistantActions(turnId: UUID, timestamp: Date)
    /// GitHub-style diff card under a `file_write` / `file_edit` call
    /// (upstream #1683 + #2907 part A), or its live preview while the call
    /// streams.
    case fileDiff(diff: FileDiff)
    /// Upstream follow-up suggestions row, inserted at display time after
    /// the turn it belongs to (never cached by the memoizer).
    case followUpSuggestions(turnId: UUID, suggestions: [String])
    /// Upstream divider at the context-compaction boundary: everything above
    /// it is covered by the session's `ConversationSummary` in the outbound
    /// context (the visible turns are untouched). Expands to show the summary
    /// text. Inserted at display time, never cached by the memoizer.
    case compactionMarker(savedTokens: Int, modelName: String, summaryText: String)
    /// Upstream: the Osaurus Router billed a turn that produced no visible
    /// text, reasoning or tools. Shows the charge with a Retry.
    case emptyResponseNotice(turnId: UUID, outputTokens: Int, costMicro: String, status: String)

    static func == (lhs: ContentBlockKind, rhs: ContentBlockKind) -> Bool {
        switch (lhs, rhs) {
        case let (.header(lRole, lName, lFirst), .header(rRole, rName, rFirst)):
            return lRole == rRole && lName == rName && lFirst == rFirst
        case let (.paragraph(lIdx, lText, lStream, lRole), .paragraph(rIdx, rText, rStream, rRole)):
            return lIdx == rIdx && lText == rText && lStream == rStream && lRole == rRole
        case let (.toolCallGroup(lCalls), .toolCallGroup(rCalls)):
            return lCalls == rCalls
        case let (.thinking(lIdx, lText, lStream, lDur), .thinking(rIdx, rText, rStream, rDur)):
            return lIdx == rIdx && lText == rText && lStream == rStream && lDur == rDur
        case let (.activityGroup(lChildren), .activityGroup(rChildren)):
            return lChildren == rChildren
        case let (
            .userMessage(lText, lAttach, lTime, lResp, lEnv),
            .userMessage(rText, rAttach, rTime, rResp, rEnv)
        ):
            guard lTime == rTime && lResp == rResp else { return false }
            return lText == rText && lAttach.count == rAttach.count && lEnv == rEnv
        case let (.sharedArtifact(lArt), .sharedArtifact(rArt)):
            return lArt == rArt
        case let (.pendingToolCall(lName, _, lSize), .pendingToolCall(rName, _, rSize)):
            return lName == rName && lSize == rSize
        case let (.preflightCapabilities(lItems), .preflightCapabilities(rItems)):
            return lItems == rItems
        case let (
            .generationStats(lTtft, lTps, lCount, lUnclosed, lTotal),
            .generationStats(rTtft, rTps, rCount, rUnclosed, rTotal)
        ):
            return lTtft == rTtft && lTps == rTps && lCount == rCount && lUnclosed == rUnclosed
                && lTotal == rTotal
        case (.typingIndicator, .typingIndicator), (.groupSpacer, .groupSpacer): return true
        case let (.chart(lSpec), .chart(rSpec)): return lSpec == rSpec
        case let (.assistantActions(lId, lTime), .assistantActions(rId, rTime)):
            return lId == rId && lTime == rTime
        case let (.fileDiff(lDiff), .fileDiff(rDiff)): return lDiff == rDiff
        case let (.followUpSuggestions(lId, lSugg), .followUpSuggestions(rId, rSugg)):
            return lId == rId && lSugg == rSugg
        case let (.compactionMarker(lSaved, lModel, lText), .compactionMarker(rSaved, rModel, rText)):
            return lSaved == rSaved && lModel == rModel && lText == rText
        case let (
            .emptyResponseNotice(lId, lTokens, lCost, lStatus),
            .emptyResponseNotice(rId, rTokens, rCost, rStatus)
        ):
            return lId == rId && lTokens == rTokens && lCost == rCost && lStatus == rStatus
        default: return false
        }
    }
}

struct ContentBlock: Identifiable, Equatable, @unchecked Sendable {
    let id: String
    let turnId: UUID
    let kind: ContentBlockKind

    /// The text the find bar searches in this block, exactly as painted:
    /// user and assistant paragraphs and user messages (an enveloped one by
    /// its displayed text, so occurrence indices line up with the bubble).
    /// Nil for blocks the find bar doesn't search (upstream #1969).
    var searchableText: String? {
        switch kind {
        case let .paragraph(_, text, _, role) where role == .user || role == .assistant:
            return text
        case let .userMessage(text, _, _, _, envelope):
            return envelope?.displayText ?? text
        default:
            return nil
        }
    }
    var position: BlockPosition = .only

    var role: MessageRole {
        switch kind {
        case let .header(role, _, _): return role
        case let .paragraph(_, _, _, role): return role
        case .toolCallGroup, .thinking, .activityGroup, .sharedArtifact, .pendingToolCall, .preflightCapabilities,
             .generationStats, .typingIndicator, .groupSpacer, .chart, .assistantActions, .fileDiff,
             .followUpSuggestions, .compactionMarker, .emptyResponseNotice:
            return .assistant
        case .userMessage: return .user
        }
    }

    /// Whether toggling `toggleId` changes this row: the block itself, a tool
    /// call inside its group, or either nested in an activity roll-up
    /// (upstream). The table uses it to find the row to re-measure.
    func rendersToggleId(_ toggleId: String) -> Bool {
        if id == toggleId { return true }
        switch kind {
        case let .toolCallGroup(calls):
            return calls.contains { $0.call.id == toggleId }
        case let .activityGroup(children):
            return children.contains { $0.rendersToggleId(toggleId) }
        default:
            return false
        }
    }

    /// Intel's thinking block id (upstream's is `think-<turn>-<index>`).
    static func thinkingBlockId(turnId: UUID) -> String {
        "thinking-\(turnId.uuidString)"
    }

    // MARK: Activity roll-up (upstream)

    /// Stable roll-up id, from its first child so it survives streaming
    /// appends to the end of the run.
    static func activityGroupId(firstChildId: String) -> String {
        "activity-\(firstChildId)"
    }

    /// Wraps a non-empty run of consecutive thinking / tool-call blocks.
    static func activityGroup(children: [ContentBlock]) -> ContentBlock {
        ContentBlock(
            id: activityGroupId(firstChildId: children[0].id),
            turnId: children[0].turnId,
            kind: .activityGroup(children: children),
            position: children[0].position
        )
    }

    /// Thinking segments count one step each, tool calls one each.
    static func activityStepCount(of children: [ContentBlock]) -> Int {
        children.reduce(0) { acc, child in
            switch child.kind {
            case .thinking: return acc + 1
            case let .toolCallGroup(calls): return acc + calls.count
            default: return acc
            }
        }
    }

    /// Rolls every run of consecutive `.thinking` / `.toolCallGroup` blocks
    /// totalling ≥2 steps into one `.activityGroup` (upstream). Anything
    /// else (a paragraph, diff card, pending chip, the answer) breaks the
    /// run; a single step stays bare.
    static func rollupActivityBlocks(_ blocks: [ContentBlock]) -> [ContentBlock] {
        var result: [ContentBlock] = []
        result.reserveCapacity(blocks.count)
        var run: [ContentBlock] = []

        func flushRun() {
            if activityStepCount(of: run) >= 2 {
                result.append(.activityGroup(children: run))
            } else {
                result.append(contentsOf: run)
            }
            run = []
        }

        for block in blocks {
            switch block.kind {
            case .thinking, .toolCallGroup:
                run.append(block)
            default:
                flushRun()
                result.append(block)
            }
        }
        flushRun()
        return result
    }

    /// The roll-up holding `childId` in `blocks`, or nil when it renders bare.
    static func enclosingActivityGroupId(forChildId childId: String, in blocks: [ContentBlock]) -> String? {
        for block in blocks {
            if case let .activityGroup(children) = block.kind,
                children.contains(where: { $0.id == childId })
            {
                return block.id
            }
        }
        return nil
    }

    /// Settings › Conversation › Group Thinking & Tool Activity (upstream:
    /// on unless the user turned it off). Memoized because it's read on
    /// every rebuild while streaming; the toggle's notification and
    /// `UserDefaults.didChangeNotification` clear the memo.
    enum ActivityRollupSetting {
        static let defaultsKey = "chatActivityRollupEnabled"

        private static let lock = NSLock()
        nonisolated(unsafe) private static var memo: Bool?
        nonisolated(unsafe) private static var observersInstalled = false

        static var isEnabled: Bool {
            lock.lock()
            defer { lock.unlock() }
            installObserversLocked()
            if let memo { return memo }
            let value = UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
            memo = value
            return value
        }

        static func invalidate() {
            lock.lock()
            memo = nil
            lock.unlock()
        }

        private static func installObserversLocked() {
            guard !observersInstalled else { return }
            observersInstalled = true
            for name in [ContentBlock.activityRollupSettingChanged, UserDefaults.didChangeNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                    invalidate()
                }
            }
        }
    }

    /// Posted when the roll-up toggle flips, so open chats rebuild.
    static let activityRollupSettingChanged = Notification.Name("activityRollupSettingChanged")

    /// Compaction-boundary divider (upstream). Keyed on the summary id so a
    /// re-compaction moves and re-renders it; `turnId` is the last covered
    /// turn, anchoring the marker right below the covered span.
    static func compactionMarker(summary: ConversationSummary, afterTurnId: UUID) -> ContentBlock {
        ContentBlock(
            id: "compaction-\(summary.id.uuidString)",
            turnId: afterTurnId,
            kind: .compactionMarker(
                savedTokens: summary.savedTokensEstimate,
                modelName: summary.modelIdentifier,
                summaryText: summary.summaryText
            ),
            position: .only
        )
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
    var sharedArtifacts: [SharedArtifact] = []
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
    var routerBilling: RouterBillingSummary?
    var modelContextExcluded: Bool = false
    var terminalStopReason: String?
    var injectedContextPrefix: String?
    var toolCallDurations: [String: TimeInterval] = [:]
    var thinkingDuration: TimeInterval?
    var anthropicThinkingBlocks: [JSONValue] = []

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
        self.sharedArtifacts = turn.sharedArtifacts
        self.thinking = turn.thinking
        self.createdAt = turn.createdAt
        self.completedAt = turn.completedAt
        self.generationTokenCount = turn.generationTokenCount
        self.timeToFirstToken = turn.timeToFirstToken
        self.generationTokensPerSecond = turn.generationTokensPerSecond
        self.preflightCapabilities = turn.preflightCapabilities
        self.routerBilling = (turn as? ChatTurn)?.routerBilling ?? (turn as? ChatTurnData)?.routerBilling
        self.modelContextExcluded =
            (turn as? ChatTurn)?.modelContextExcluded ?? (turn as? ChatTurnData)?.modelContextExcluded ?? false
        self.terminalStopReason =
            (turn as? ChatTurn)?.terminalStopReason ?? (turn as? ChatTurnData)?.terminalStopReason
        self.injectedContextPrefix =
            (turn as? ChatTurn)?.injectedContextPrefix ?? (turn as? ChatTurnData)?.injectedContextPrefix
        self.toolCallDurations =
            (turn as? ChatTurn)?.toolCallDurations ?? (turn as? ChatTurnData)?.toolCallDurations ?? [:]
        self.thinkingDuration =
            (turn as? ChatTurn)?.thinkingDuration ?? (turn as? ChatTurnData)?.thinkingDuration
        self.anthropicThinkingBlocks =
            (turn as? ChatTurn)?.anthropicThinkingBlocks ?? (turn as? ChatTurnData)?.anthropicThinkingBlocks ?? []
    }

    static func == (lhs: ChatTurnData, rhs: ChatTurnData) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content
    }

    func consolidateContent() {}
    func clearPendingToolArgs() {}
    func appendToolArgFragment(_ arg: String) {}

    // M13 follow-up (Renée 2026-06-04): memberwise init so the Codable
    // initializer below (and any in-place construction) can build a turn
    // without going through `init(from: any ChatTurnProtocol)`.
    init(
        id: UUID,
        role: MessageRole,
        content: String,
        attachments: [Attachment] = [],
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil,
        toolResults: [String: String] = [:],
        sharedArtifacts: [SharedArtifact] = [],
        thinking: String = "",
        createdAt: Date,
        completedAt: Date? = nil,
        generationTokenCount: Int? = nil,
        timeToFirstToken: TimeInterval? = nil,
        generationTokensPerSecond: Double? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolResults = toolResults
        self.sharedArtifacts = sharedArtifacts
        self.thinking = thinking
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.generationTokenCount = generationTokenCount
        self.timeToFirstToken = timeToFirstToken
        self.generationTokensPerSecond = generationTokensPerSecond
    }
}

// MARK: - ChatTurnData Codable (M13 session persistence on Intel)
//
// Hand-rolled so the transient `preflightCapabilities: Any?` (live preflight
// state, not persistable) and the streaming-only `pending*` / `unclosedReasoning`
// scratch fields are skipped — they reconstruct to defaults on load. Everything
// that defines the conversation (role, content, attachments, tool calls/results,
// thinking, timing) round-trips.
extension ChatTurnData: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, role, content, attachments, toolCalls, toolCallId, toolResults
        case sharedArtifacts
        case thinking, createdAt, completedAt, generationTokenCount
        case timeToFirstToken, generationTokensPerSecond
        case routerBilling
        case modelContextExcluded
        case terminalStopReason
        case injectedContextPrefix
        case toolCallDurations, thinkingDuration
        case anthropicThinkingBlocks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            role: try c.decode(MessageRole.self, forKey: .role),
            content: try c.decodeIfPresent(String.self, forKey: .content) ?? "",
            attachments: try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? [],
            toolCalls: try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls),
            toolCallId: try c.decodeIfPresent(String.self, forKey: .toolCallId),
            toolResults: try c.decodeIfPresent([String: String].self, forKey: .toolResults) ?? [:],
            sharedArtifacts: try c.decodeIfPresent([SharedArtifact].self, forKey: .sharedArtifacts) ?? [],
            thinking: try c.decodeIfPresent(String.self, forKey: .thinking) ?? "",
            createdAt: try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            completedAt: try c.decodeIfPresent(Date.self, forKey: .completedAt),
            generationTokenCount: try c.decodeIfPresent(Int.self, forKey: .generationTokenCount),
            timeToFirstToken: try c.decodeIfPresent(TimeInterval.self, forKey: .timeToFirstToken),
            generationTokensPerSecond: try c.decodeIfPresent(
                Double.self, forKey: .generationTokensPerSecond)
        )
        self.routerBilling = try? c.decodeIfPresent(RouterBillingSummary.self, forKey: .routerBilling)
        self.modelContextExcluded = (try? c.decodeIfPresent(Bool.self, forKey: .modelContextExcluded)) ?? false
        self.terminalStopReason = try? c.decodeIfPresent(String.self, forKey: .terminalStopReason)
        self.injectedContextPrefix = try? c.decodeIfPresent(String.self, forKey: .injectedContextPrefix)
        self.toolCallDurations =
            (try? c.decodeIfPresent([String: TimeInterval].self, forKey: .toolCallDurations)) ?? [:]
        self.thinkingDuration = try? c.decodeIfPresent(TimeInterval.self, forKey: .thinkingDuration)
        self.anthropicThinkingBlocks =
            (try? c.decodeIfPresent([JSONValue].self, forKey: .anthropicThinkingBlocks)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        if !attachments.isEmpty { try c.encode(attachments, forKey: .attachments) }
        try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(toolCallId, forKey: .toolCallId)
        if !toolResults.isEmpty { try c.encode(toolResults, forKey: .toolResults) }
        if !sharedArtifacts.isEmpty { try c.encode(sharedArtifacts, forKey: .sharedArtifacts) }
        if !thinking.isEmpty { try c.encode(thinking, forKey: .thinking) }
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(generationTokenCount, forKey: .generationTokenCount)
        try c.encodeIfPresent(timeToFirstToken, forKey: .timeToFirstToken)
        try c.encodeIfPresent(generationTokensPerSecond, forKey: .generationTokensPerSecond)
        try c.encodeIfPresent(routerBilling, forKey: .routerBilling)
        if modelContextExcluded { try c.encode(true, forKey: .modelContextExcluded) }
        try c.encodeIfPresent(terminalStopReason, forKey: .terminalStopReason)
        try c.encodeIfPresent(injectedContextPrefix, forKey: .injectedContextPrefix)
        if !toolCallDurations.isEmpty { try c.encode(toolCallDurations, forKey: .toolCallDurations) }
        try c.encodeIfPresent(thinkingDuration, forKey: .thinkingDuration)
        if !anthropicThinkingBlocks.isEmpty { try c.encode(anthropicThinkingBlocks, forKey: .anthropicThinkingBlocks) }
    }
}

// MARK: - Type aliases

// Agent from Agent.swift is NOT excluded; add conformance to AgentInfoProtocol
extension Agent: AgentInfoProtocol {}

final class AppConfiguration: ObservableObject, @unchecked Sendable {
    static let shared = AppConfiguration()
    @Published var chatConfig = AppChatConfigStub()
    var foundationModelAvailable: Bool { false }
}
struct AppChatConfigStub: Sendable {
    var disableTools = false
    var maxToolAttempts = 5
    var topPOverride: Double? = nil
    /// Tracks the upstream `AppConfiguration.chatConfig.enableClipboardMonitoring`
    /// toggle. Intel reads it from `FloatingInputCard`'s paste-monitor wiring.
    /// Defaults true so clipboard paste works by default on Intel; users can
    /// opt-out via the same Settings → Chat row that exists on Apple Silicon.
    var enableClipboardMonitoring = true
}

/// Intel ChatConfigurationStore. Folds the passed instance into the shared
/// singleton AND persists it to `~/.osaurus/config/chat.json` via
/// `ChatConfiguration.persistToDisk()` — so Settings (core model, temperature,
/// max tokens, context length, …) now survive app restart. The singleton loads
/// the same file on first access (`ChatConfiguration.shared`). Keys match
/// upstream's format so a migrated/Apple-Silicon file round-trips.
final class ChatConfigurationStore: @unchecked Sendable {
    static func load() -> ChatConfiguration { ChatConfiguration.shared }

    /// Persists by folding the passed instance's fields into the
    /// shared singleton. On Intel `ChatConfiguration` is a class
    /// (not a value type like upstream), so the view-side pattern of
    /// `let cfg = ChatConfiguration(...); save(cfg)` produces a NEW
    /// instance — without this fold, mutations would be discarded.
    /// On-disk persistence on Intel is M11 follow-up; the singleton
    /// fold gives session-scoped persistence which is enough for
    /// the view's two-way bindings to round-trip.
    static func save(_ config: ChatConfiguration) {
        if config !== ChatConfiguration.shared {
            ChatConfiguration.shared.adopt(config)
        }
        // Persist to ~/.osaurus/config/chat.json so Settings survive restart.
        ChatConfiguration.shared.persistToDisk()
        // A new chat must not reuse a tool snapshot captured under the old
        // global capability settings (model/tool mode/tool assignments).
        AgentManager.shared.bumpCapabilityRevision()
    }
}



// M12 Gap 2/3: the real `FolderContextService` (Folder/FolderContextService.swift)
// is un-excluded — it drives the NSOpenPanel folder picker and registers the
// folder tool suite via FolderToolManager. The amputated directory-watcher /
// indexing pieces inside it are gated separately; the picker + tool wiring are
// pure AppKit/Foundation. The old no-op Intel stub that lived here is removed.

// `ImageFullScreenView` and `imageFullScreenSheetPresentation()` are
// upstream's, in Views/Chat/MarkdownImageView.swift (W-gated-sweep,
// 2026-10-10). The empty stub that lived here left image previews blank.

final class MemoryContextAssembler: @unchecked Sendable {
    static let shared = MemoryContextAssembler()

    /// Best-effort preview of what `MemorySearchService.recall(...)` (the
    /// real per-turn recall path, `IntelMemoryConformers.swift`, invoked
    /// from `composeChatContext` in this file) would inject. Feeds
    /// `ChatView.refreshMemoryTokens()`'s context-budget popover estimate —
    /// never used to build an actual outgoing prompt.
    ///
    /// Previously this hard-returned `nil` unconditionally, so the popover's
    /// memory row always read 0 tokens even while recall was genuinely
    /// injecting content via the real send path. That silent-zero bug is
    /// what this replaces.
    ///
    /// LIMITATION, read before treating a mismatch as a new bug: this call
    /// site has no query string — `refreshMemoryTokens` runs on session
    /// load / agent switch / config change, not per keystroke, and the
    /// signature here (fixed by other call sites: `ChatView.swift`,
    /// `Views/Memory/MemoryView.swift`, `Tests/Memory/MemoryTests.swift`)
    /// takes no query param to add one. Real recall requires a non-empty
    /// query and returns `nil` without one (see `MemorySearchService.recall`'s
    /// own guard) — so an exact estimate is not obtainable here by
    /// construction, not by omission. What this DOES estimate honestly:
    ///   - Layer 1 (Identity): query-independent in real recall too —
    ///     reproduced exactly (same overrides + content, same char caps).
    ///   - Layers 2-3 (pinned facts / episodes): approximated using the
    ///     same per-layer counts recall requests (topK 6 / 4), ordered by
    ///     salience / recency (`MemoryDatabase`'s natural ordering) instead
    ///     of a real semantic query match — a stand-in for "what's
    ///     typically available to recall," not "what the next turn's actual
    ///     query will surface." Can read higher or lower than the real
    ///     per-turn number.
    ///   - Layer 4 (raw transcript fallback) is NOT estimated: it is the
    ///     most query-sensitive layer and the shakiest to fake without one,
    ///     so it is left out rather than guessed at. The estimate therefore
    ///     tends to undercount on turns where transcript filler would
    ///     otherwise be injected — documented instead of hidden.
    ///
    /// `agentId` is accepted for call-site parity but intentionally NOT
    /// used to scope the read: the real send path calls
    /// `MemorySearchService.shared.recall(agentId: nil, ...)` on purpose
    /// (`docs/MEMORY_PLAN.md` §1: "Recall ignores agent scoping" is
    /// documented, deliberate behavior, not a bug for this file to paper
    /// over). Matching that means every agent's memory contributes to the
    /// estimate, same as it would to the real injected block.
    static func assembleContext(agentId: String = "", config: Any? = nil) async -> Any? {
        let cfg = (config as? MemoryConfiguration) ?? MemoryConfigurationStore.load()
        guard cfg.enabled else { return nil }

        let db = MemoryDatabase.shared
        guard db.isOpen else { return nil }

        var charBudget = max(200, cfg.memoryBudgetTokens) * MemoryConfiguration.charsPerToken
        var blocks: [String] = []

        // Layer 1: Identity — exact reproduction of recall()'s Layer 1.
        if let identity = try? db.loadIdentity() {
            var idLines: [String] = []
            for override in identity.overrides.prefix(12) {
                let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let line = "- \(trimmed)"
                guard line.count <= charBudget else { break }
                charBudget -= line.count
                idLines.append(line)
            }
            let content = identity.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                let snippet = String(content.prefix(min(charBudget, 600)))
                if !snippet.isEmpty, snippet.count <= charBudget {
                    charBudget -= snippet.count
                    idLines.append(snippet)
                }
            }
            if !idLines.isEmpty {
                blocks.append("### About you\n" + idLines.joined(separator: "\n"))
            }
        }

        // Layer 2: Pinned facts — approximated by salience ordering (no
        // query available here; see limitation note above).
        let pinned = (try? db.loadPinnedFacts(agentId: nil, limit: 6)) ?? []
        let pinnedLines = Self.budgetedLines(
            pinned.map { "- \($0.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))" },
            budget: &charBudget)
        if !pinnedLines.isEmpty {
            blocks.append("### Things to remember\n" + pinnedLines.joined(separator: "\n"))
        }

        // Layer 3: Episodes — approximated by recency ordering (same
        // reasoning as Layer 2).
        let days = cfg.episodeRetentionDays > 0 ? cfg.episodeRetentionDays : 3650
        let episodes = (try? db.loadEpisodes(agentId: nil, days: days, limit: 4)) ?? []
        let episodeLines = Self.budgetedLines(
            episodes.map {
                "- [\($0.conversationAt.prefix(10))] \($0.summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))"
            },
            budget: &charBudget)
        if !episodeLines.isEmpty {
            blocks.append("### Past sessions\n" + episodeLines.joined(separator: "\n"))
        }

        // Layer 4 (raw transcript fallback) intentionally omitted — see
        // limitation note above.

        guard !blocks.isEmpty else { return nil }
        return "## Relevant memory (estimate)\n" + blocks.joined(separator: "\n\n")
    }

    /// Take candidate lines in order until the shared character budget is
    /// spent. Mirrors `MemorySearchService.budgetedLines` exactly
    /// (duplicated rather than shared because that method is `private` on
    /// a type in a different, excluded-from-editing file).
    private static func budgetedLines(_ candidates: [String], budget: inout Int) -> [String] {
        var out: [String] = []
        for line in candidates where !line.isEmpty {
            guard line.count <= budget else { break }
            budget -= line.count
            out.append(line)
        }
        return out
    }
}
// `MemorySearchService` (real Intel implementation) lives in
// `IntelMemoryConformers.swift` — it embeds transcript turns and does cosine
// recall over the SQLCipher-backed transcript table.

// `ModelOptionsStore` and `ModelProfileRegistry` are now provided by
// upstream (un-excluded as part of Phase 8C-prep-2). The Intel stubs
// that used to live here have been removed.
final class ModelRuntime: @unchecked Sendable {
    static let shared = ModelRuntime()
    func unloadModelsNotIn(_ names: Set<String>) {}
    var runtimeSettings: Any? { nil }

    /// Background pre-encode hook the upstream FloatingInputCard calls so
    /// MLX can warm the audio encoder while the user is still recording.
    /// Intel has no resident MLX model, so we always return a `.skipped`
    /// result — the caller logs it and moves on. Signature mirrors
    /// upstream (non-optional return) so the chained `.status.rawValue`
    /// access at the call site type-checks unchanged.
    func preencodeLiveVoiceAudioIfResident(
        modelName: String,
        attachmentId: UUID,
        samples: [Float],
        sampleRate: Int
    ) async -> LiveVoicePreencodeResult {
        LiveVoicePreencodeResult(
            status: .skipped,
            sampleCount: samples.count,
            sampleRate: sampleRate,
            encodeMs: 0,
            message: "MLX preencode amputated on Intel"
        )
    }
}

/// Upstream's resolver (Services/Plugin/PluginInstructionsResolver.swift,
/// excluded on Intel because it reads upstream's `LoadedPlugin`): the
/// agent's override for the plugin first, then the plugin's manifest
/// `instructions`. Used by plugin `complete` / `complete_stream` and by the
/// chat send of a plugin-dispatched task (`W-plugin-reliability` stage 2d;
/// until then this always returned nil).
@MainActor
enum PluginInstructionsResolver {
    static func instructions(pluginId: String, agentId: UUID?) -> String? {
        if let agentId,
            let agent = AgentManager.shared.agent(for: agentId),
            let override = agent.pluginInstructions?[pluginId],
            !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return override
        }
        return PluginManager.shared.loadedPlugin(for: pluginId)?.plugin.manifest.instructions
    }
}

final class SandboxAgentProvisioner: @unchecked Sendable { static let shared = SandboxAgentProvisioner(); static func linuxName(for agentId: String) -> String { "agent" } }
final class SandboxToolRegistrar: @unchecked Sendable {
    static let shared = SandboxToolRegistrar()
    func registerTools(for agentId: UUID) async {}
    /// FloatingInputCard's sandbox chip calls this when the user
    /// clicks "Retry" after a provisioning failure. Intel has no
    /// failures to reset (no provisioning ever happens), so no-op.
    /// `for:` arg is optional to match both upstream call shapes
    /// (`resetStartupFailures()` and `resetStartupFailures(for:)`).
    func resetStartupFailures(for agentId: UUID? = nil) {}
}

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
struct SessionToolState: @unchecked Sendable {
    var initialPreflight: Any?
    var loadedToolNames: [String]
    /// Baseline tool names of the FIRST compose of this chat, echoed back on
    /// turn 2+ so the schema stays byte-stable (upstream #2171).
    var initialAlwaysLoadedNames: Set<String>?
    /// The exact tool specs of the first compose (upstream #2171): a name can
    /// stay while its schema changes, which would invalidate the prefix.
    var initialToolSpecs: [Tool]?
    var sessionFingerprint: String?
    /// The rendered enabled-capabilities block of the first compose (#2171).
    var frozenManifest: String?
    /// Frozen per-user-message memory/time prefixes for surfaces whose
    /// history the caller owns (HTTP `/agents/{id}/run`, plugin host),
    /// keyed by `SystemPromptComposer.frozenPrefixKeys` (upstream #2173).
    var frozenUserPrefixes: [String: String] = [:]

    init(
        initialPreflight: Any? = nil,
        loadedToolNames: [String] = [],
        initialAlwaysLoadedNames: Set<String>? = nil,
        initialToolSpecs: [Tool]? = nil,
        sessionFingerprint: String? = nil,
        frozenManifest: String? = nil,
        frozenUserPrefixes: [String: String] = [:]
    ) {
        self.initialPreflight = initialPreflight
        self.loadedToolNames = loadedToolNames
        self.initialAlwaysLoadedNames = initialAlwaysLoadedNames
        self.initialToolSpecs = initialToolSpecs
        self.sessionFingerprint = sessionFingerprint
        self.frozenManifest = frozenManifest
        self.frozenUserPrefixes = frozenUserPrefixes
    }

    /// Upstream's shape: execution mode (the folder ROOT is part of the
    /// identity, as a stable path hash and never the raw path), tool mode,
    /// and the AGENT. A grant or catalog edit is NOT part of it: that goes
    /// through `SessionToolStateStore.reconcileToolGrants`, which keeps the
    /// tools the chat already loaded. The agent is part of it because the
    /// baseline schema is per agent, so the first-turn snapshot is only valid
    /// for the agent that produced it. Arguments stay `Any?` so callers and
    /// tests can pass plain strings for the mode components.
    static func fingerprint(executionMode: Any?, toolMode: Any?, agentId: UUID? = nil) -> String {
        let mode: String
        if let executionMode = executionMode as? ExecutionMode {
            switch executionMode {
            case .hostFolder(let context): mode = "host@\(folderIdentity(context))"
            case .sandbox: mode = "sandbox"
            case .none: mode = "none"
            }
        } else {
            mode = String(describing: executionMode)
        }
        let tools = (toolMode as? ToolSelectionMode)?.rawValue ?? String(describing: toolMode)
        var fingerprint = "intel/\(mode)/\(tools)"
        if let agentId { fingerprint += "/agent:\(agentId.uuidString)" }
        return fingerprint
    }

    /// FNV-1a rather than `Hasher`, which is seeded per process; this
    /// identity must be stable across composes.
    private static func folderIdentity(_ context: FolderContext) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in context.rootPath.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

// `SkillsView` (un-body-swapped in M11 Phase 11.A.2) reads
// `skillManager.skills`, `skillManager.isRefreshing`,
// and mutates via the full CRUD
// surface — `create`, `update`, `delete`, `refresh`,
// `importSkill(from:)`, `importSkillFromMarkdown(_:)`,
// `importSkillsFromMarkdown(_:)`, `importSkillFromZip(_:)`,
// `exportSkillAsZip(_:)`. Extended in M11 Phase 11.A.2.0 to mirror
// the upstream public surface, with real on-disk persistence via
// `SkillStore` (NOT excluded on Intel — see
// `Models/Agent/SkillStore.swift`).
//
// Chat-side lookups (`skill(for:)`, `buildFullInstructions`) use the real
// `Skill` type too (docs/TOOL_DISCOVERY_INTEL.md). `@MainActor` matches
// upstream.
@MainActor
final class SkillManager: ObservableObject, @unchecked Sendable {
    static let shared = SkillManager()

    @Published private(set) var skills: [Skill] = []
    @Published private(set) var isRefreshing: Bool = false

    private init() {
        Task { @MainActor in await refresh() }
    }

    /// Refreshes run one after another: the launch refresh could otherwise
    /// finish after a later one (e.g. right after `create`) and put back a
    /// list read before the change. Each call returns once its own read —
    /// started after every earlier one — has been published.
    private var lastRefresh: Task<Void, Never>?

    func refresh() async {
        let previous = lastRefresh
        let task = Task { @MainActor in
            await previous?.value
            self.isRefreshing = true
            self.skills = await SkillStore.loadAll()
            self.isRefreshing = false
        }
        lastRefresh = task
        await task.value
    }

    @discardableResult
    func create(
        name: String,
        description: String = "",
        version: String = "1.0.0",
        author: String? = nil,
        category: String? = nil,
        keywords: [String] = [],
        instructions: String = ""
    ) async -> Skill {
        let skill = Skill(
            name: name,
            description: description,
            version: version,
            author: author,
            category: category,
            keywords: keywords,
            instructions: instructions
        )
        await SkillStore.save(skill)
        await refresh()
        return skill
    }

    func update(_ skill: Skill) async {
        var updated = skill
        updated.updatedAt = Date()
        await SkillStore.save(updated)
        await refresh()
    }

    @discardableResult
    func delete(id: UUID) async -> Bool {
        let result = await SkillStore.delete(id: id)
        if result { await refresh() }
        return result
    }

    // MARK: - Plugin Skills (upstream, `W-plugin-reliability` stage 2e)
    //
    // Upstream's bodies minus `SkillSearchService` indexing, which Intel
    // doesn't compile.

    /// Register a skill from a plugin. If a skill with the same pluginId and name already exists, update it.
    func registerPluginSkill(_ skill: Skill) async {
        // Upstream #2050: skills are a toggle-free library, so there is no
        // enabled state to preserve across a plugin update.
        await SkillStore.save(skill)
        await refresh()
    }

    /// Remove all skills associated with a plugin
    func unregisterPluginSkills(pluginId: String) async {
        let pluginSkillIds = skills.filter { $0.pluginId == pluginId }.map { $0.id }
        for id in pluginSkillIds {
            _ = await SkillStore.delete(id: id)
        }
        if !pluginSkillIds.isEmpty {
            await refresh()
        }
    }

    // Import / export paths.
    //
    // The JSON / markdown / zip importers can be implemented on Intel
    // because `SkillStore` + `Skill`'s Codable surface are both
    // present. Only the GitHub-installer path lives in
    // `Services/GitHubSkillService.swift` (excluded), so
    // `importSkillsFromMarkdown(_:)` — which takes pre-fetched skill
    // payloads from the GitHub sheet — is a no-op pass-through here
    // because the sheet is `AppleSiliconOnlyTab` on Intel.

    func importSkill(from data: Data) async throws -> Skill {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var skill = try decoder.decode(Skill.self, from: data)
        // New ID so an import doesn't collide with an existing skill.
        skill = Skill(
            id: UUID(),
            name: skill.name,
            description: skill.description,
            version: skill.version,
            author: skill.author,
            category: skill.category,
            keywords: skill.keywords,
            instructions: skill.instructions
        )
        await SkillStore.save(skill)
        await refresh()
        return skill
    }

    func importSkillFromMarkdown(_ content: String) async throws -> Skill {
        // Minimal Intel implementation — treats the whole markdown blob
        // as the instructions body and derives a default name from the
        // first H1 (or "Imported Skill" if absent). Upstream parses
        // YAML frontmatter for richer metadata; Intel is intentionally
        // simpler since the GitHub-importer (which produces the
        // richest markdown) is amputated.
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let h1 = lines.first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) }
        let skill = Skill(
            name: h1 ?? "Imported Skill",
            description: "",
            instructions: content
        )
        await SkillStore.save(skill)
        await refresh()
        return skill
    }

    func importSkillsFromMarkdown(_ skills: [Skill]) async -> [Skill] {
        // Used by `GitHubImportSheet.onImport` — on Intel the sheet
        // is `AppleSiliconOnlyTab`, so this path is unreachable from
        // the UI. Kept as a real implementation in case some other
        // code path feeds skills in directly.
        var imported: [Skill] = []
        for skill in skills {
            await SkillStore.save(skill)
            imported.append(skill)
        }
        await refresh()
        return imported
    }

    func importSkillFromZip(_ zipURL: URL) async throws -> Skill {
        // Zip import depends on excluded archiver utilities; surface
        // a clear runtime error rather than silently no-op so the
        // caller's toast shows useful text.
        throw NSError(
            domain: "SkillManager",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Skill .zip import is unavailable on Intel."]
        )
    }

    func exportSkillAsZip(_ skill: Skill) async throws -> URL {
        // Same constraint as import — zip path requires the excluded
        // archive utilities.
        throw NSError(
            domain: "SkillManager",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Skill .zip export is unavailable on Intel."]
        )
    }

    /// Export a skill as a SKILL.md document following the Agent Skills
    /// spec (https://agentskills.io/specification). Used by
    /// SkillsView's "Export" → "as SKILL.md" affordance. The format
    /// is a YAML frontmatter block followed by the instructions body.
    func exportSkillAsAgentSkills(_ skill: Skill) -> String {
        var lines: [String] = []
        lines.append("---")
        lines.append("name: \(skill.name)")
        if !skill.description.isEmpty {
            lines.append("description: \(skill.description)")
        }
        lines.append("version: \(skill.version)")
        if let author = skill.author, !author.isEmpty {
            lines.append("author: \(author)")
        }
        if let category = skill.category, !category.isEmpty {
            lines.append("category: \(category)")
        }
        if !skill.keywords.isEmpty {
            lines.append("keywords: [\(skill.keywords.joined(separator: ", "))]")
        }
        lines.append("---")
        lines.append("")
        lines.append(skill.instructions)
        return lines.joined(separator: "\n")
    }

    // Legacy chat-side overloads (unchanged surface for
    // FloatingInputCard's slash popup).
    /// Intel: real lookups (these returned nil, so a slash-selected skill and
    /// skill loading never reached the model). Reads the refreshed list.
    func skill(for id: UUID) -> Skill? { skills.first { $0.id == id } }

    /// Upstream #2050: case-insensitive name lookup with deterministic
    /// collision resolution. Order: exact-case match, user-authored, built-in,
    /// plugin-provided, then a stable id tiebreak — so `/name` and
    /// `capabilities_load skill/<name>` always resolve the same skill.
    func skill(named name: String) -> Skill? {
        let matches = skills(named: name)
        guard matches.count > 1 else { return matches.first }
        func tier(_ s: Skill) -> Int {
            if s.isFromPlugin { return 2 }
            return s.isBuiltIn ? 1 : 0
        }
        return matches.min { a, b in
            let aExact = a.name == name
            let bExact = b.name == name
            if aExact != bExact { return aExact }
            if tier(a) != tier(b) { return tier(a) < tier(b) }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// Upstream `skills(named:)` (#2089): case-insensitive display name
    /// first, then the Agent Skills slug (`code-reviewer`, what slash commands
    /// and on-disk folders show and what models copy into a load), matched
    /// against each skill's slug or its folder name. An exact name always wins.
    func skills(named name: String) -> [Skill] {
        let lowered = name.lowercased()
        let exact = skills.filter { $0.name.lowercased() == lowered }
        if !exact.isEmpty { return exact }

        let slug = Skill.agentSkillsSlug(for: name)
        guard !slug.isEmpty else { return [] }
        return skills.filter { candidate in
            if Skill.agentSkillsSlug(for: candidate.name) == slug { return true }
            return candidate.directoryName?.lowercased() == slug
        }
    }

    // Upstream `SkillManager.buildFullInstructions` / `loadReferenceContents`.
    func buildFullInstructions(
        for skill: Skill,
        referenceBudget: Int = .max
    ) async -> String {
        var sections: [String] = []

        // A skill body may refer to bundled files with paths such as
        // `scripts/main.py` or `references/schema.json`. The execution cwd is
        // the selected workspace, not the skill directory, so the model needs
        // this source-of-truth anchor to construct the correct absolute path.
        let directoryURL = SkillStore.skillDirectory(for: skill).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            sections.append(
                "Skill directory: `\(directoryURL.path)`. "
                    + "Resolve relative paths in this skill against that directory."
            )
        }

        sections.append(skill.instructions)

        if !skill.references.isEmpty {
            let refs = await loadReferenceContents(for: skill, budget: referenceBudget)
            if !refs.isEmpty {
                sections.append("\n## Reference Materials\n\n\(refs)")
            }
        }

        return sections.joined(separator: "\n")
    }

    private func loadReferenceContents(for skill: Skill, budget: Int = .max) async -> String {
        let textExtensions: Set<String> = [
            "md", "txt", "json", "yaml", "yml", "xml", "html", "css", "js", "ts",
            "swift", "py", "rb", "go", "rs", "java", "kt", "c", "cpp", "h", "hpp",
            "sql", "sh", "bash", "zsh", "toml", "ini", "cfg", "conf",
        ]

        var contents: [String] = []
        var usedBudget = 0
        var omittedNames: [String] = []
        for file in skill.references {
            let ext = (file.name as NSString).pathExtension.lowercased()
            guard textExtensions.contains(ext) || ext.isEmpty else { continue }
            guard file.size < 100_000 else {
                contents.append("### \(file.name)\n*File too large (>\(formatSize(file.size)))*\n")
                continue
            }
            // Once the budget is exhausted, keep scanning only to name what
            // was left out — a silent drop would let the model assume the
            // skill has no further reference material.
            guard usedBudget < budget else {
                omittedNames.append(file.name)
                continue
            }

            do {
                let data = try await SkillStore.readFile(from: skill, relativePath: file.relativePath)
                if let text = String(data: data, encoding: .utf8) {
                    if usedBudget + text.count > budget {
                        omittedNames.append(file.name)
                        continue
                    }
                    usedBudget += text.count
                    contents.append("### \(file.name)\n\n```\n\(text)\n```\n")
                }
            } catch {
                // Skip unreadable files
            }
        }
        if !omittedNames.isEmpty {
            contents.append(
                "### Omitted references\n*\(omittedNames.count) reference file(s) omitted to keep "
                    + "this load small: \(omittedNames.joined(separator: ", ")). Invoking the skill "
                    + "with its slash command includes them in full.*\n"
            )
        }
        return contents.joined(separator: "\n")
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

}

// `SlashCommandsView` (un-body-swapped in M11 Phase 11.A.1) and
// `ManagementBadgeStore` both read `customCommands` to drive the
// Commands sidebar tab + its badge. `SlashCommandStore` (NOT
// excluded on Intel — see `Models/SlashCommand/SlashCommandStore.swift`)
// already handles JSON-on-disk persistence inside the OsaurusPaths
// commands directory, so the Intel conformer can mirror the upstream
// CRUD surface byte-for-byte rather than running an in-memory shim.
//
// `@MainActor` matches the upstream class annotation. Required
// because `SlashCommandStore`'s static CRUD methods are themselves
// `@MainActor`-isolated; calling them from a non-isolated context
// would trigger Swift 6.3's actor-isolated-call diagnostic.
@MainActor
final class SlashCommandRegistry: ObservableObject, @unchecked Sendable {
    // Upstream's registry logic (`Managers/SlashCommandRegistry.swift`) in an
    // `ObservableObject`: upstream's class is `@Observable`, which needs
    // macOS 14. Upstream's file stays excluded; keep the two in step.
    static let shared = SlashCommandRegistry()

    /// User-defined custom commands loaded from disk.
    @Published private(set) var customCommands: [SlashCommand] = []

    /// True while the slash command popup is visible in any chat window.
    /// Used by the global key monitor in ChatView to suppress window-close on Escape.
    @Published var isPopupVisible: Bool = false

    private init() {
        // `SlashCommandStore.loadAll()` reads and JSON-decodes every custom
        // command file from disk. This type is `@MainActor`, so loading
        // synchronously in `init` runs that scan on the main thread — and the
        // first accessor is often `ManagementBadgeStore`'s periodic recompute
        // (counting commands) rather than a user opening the slash menu, which
        // tripped the app-hang watchdog. Load off the main actor and publish
        // back; `customCommands` stays empty for the few ms until it lands.
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                SlashCommandStore.loadAll()
            }.value
            self?.customCommands = loaded
        }
    }

    // MARK: - Refresh

    /// Reload from disk. Synchronous — callers are user-initiated CRUD on a
    /// small list, so the main-thread cost is negligible (unlike the cold
    /// first load, which `init` performs off the main actor).
    func refresh() {
        customCommands = SlashCommandStore.loadAll()
    }

    // MARK: - CRUD

    @discardableResult
    func create(
        name: String,
        description: String = "",
        icon: String = "text.bubble",
        template: String,
        pluginId: String? = nil
    ) -> SlashCommand {
        let cmd = SlashCommand(
            name: name,
            description: description,
            icon: icon,
            kind: .template,
            template: template,
            pluginId: pluginId
        )
        SlashCommandStore.save(cmd)
        refresh()
        return cmd
    }

    func update(_ command: SlashCommand) {
        guard !command.isBuiltIn else { return }
        var updated = command
        updated.updatedAt = Date()
        SlashCommandStore.save(updated)
        refresh()
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        let result = SlashCommandStore.delete(id: id)
        if result { refresh() }
        return result
    }

    /// Returns all persisted custom commands associated with a plugin.
    func commands(forPluginId pluginId: String) -> [SlashCommand] {
        customCommands.filter { $0.pluginId == pluginId }
    }

    /// Delete every persisted custom command that belongs to a plugin.
    /// Returns the number of commands deleted.
    @discardableResult
    func deleteByPluginId(_ pluginId: String) -> Int {
        let matches = commands(forPluginId: pluginId)
        guard !matches.isEmpty else { return 0 }
        var count = 0
        for cmd in matches where SlashCommandStore.delete(id: cmd.id) {
            count += 1
        }
        if count > 0 { refresh() }
        return count
    }

    // MARK: - Filtering

    /// Returns commands matching `query`, sorted by relevance then alphabetically.
    /// An empty query returns all commands in default order.
    func filtered(query: String) -> [SlashCommand] {
        let all = allCommands
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return
            all
            .compactMap { cmd -> (SlashCommand, Int)? in
                let score = matchScore(query: q, name: cmd.name.lowercased())
                return score > 0 ? (cmd, score) : nil
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
            }
            .map(\.0)
    }

    // MARK: - Private

    /// Full command list: built-ins → custom → skills (deduplicated by name).
    private var allCommands: [SlashCommand] {
        var seen = Set<String>()
        var result: [SlashCommand] = []

        func append(_ cmd: SlashCommand) {
            let key = cmd.name.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            result.append(cmd)
        }

        SlashCommand.builtIns.forEach(append)
        customCommands.forEach(append)

        // Surface every installed skill as a template command. Iterate in
        // the same precedence order as `SkillManager.skill(named:)` (user
        // skills, then built-ins, then plugin skills) so a slug collision
        // dedupes to the same skill the loader would resolve — otherwise
        // `/name` and `capabilities_load skill/<name>` could invoke two
        // different skills.
        let precedenceOrdered = SkillManager.shared.skills.sorted { a, b in
            func tier(_ s: Skill) -> Int {
                if s.isFromPlugin { return 2 }
                return s.isBuiltIn ? 1 : 0
            }
            if tier(a) != tier(b) { return tier(a) < tier(b) }
            return a.id.uuidString < b.id.uuidString
        }
        for skill in precedenceOrdered {
            let slug = skill.name
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            guard !slug.isEmpty else { continue }

            let desc =
                skill.description.isEmpty
                ? "Apply \(skill.name) skill"
                : skill.description

            append(
                SlashCommand(
                    id: skill.id,
                    name: slug,
                    description: desc,
                    icon: "wand.and.stars",
                    kind: .skill,
                    isBuiltIn: false
                )
            )
        }

        return result
    }

    /// Score: 3 = exact match, 2 = prefix match, 1 = substring match, 0 = no match.
    private func matchScore(query: String, name: String) -> Int {
        if name == query { return 3 }
        if name.hasPrefix(query) { return 2 }
        if name.contains(query) { return 1 }
        return 0
    }
}

// MARK: - Theme Sharing
//
// `ThemeShareOutcome` now comes from upstream's `ThemeShareService.swift`,
// which Intel compiles since the 2026-10-27 theme library port.

// `SlashCommand` is provided by upstream
// `Models/SlashCommand/SlashCommand.swift` (not excluded). The
// Intel duplicate that used to live here has been removed.

enum StreamingStatsHint: Sendable {
    private static let statsPrefix = "\u{FFFE}stats:"
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    static func encode(
        tokenCount: Int,
        tokensPerSecond: Double,
        unclosedReasoning: Bool = false,
        stopReason: String? = nil
    ) -> String {
        let tps = String(format: "%.4f", locale: posixLocale, tokensPerSecond)
        var flags: [String] = []
        if unclosedReasoning { flags.append("unclosed") }
        if let stopReason = stopReason?.trimmingCharacters(in: .whitespacesAndNewlines),
            !stopReason.isEmpty
        {
            flags.append("stop=\(stopReason)")
        }
        let suffix = flags.isEmpty ? "" : ";\(flags.joined(separator: ","))"
        return "\(statsPrefix)\(tokenCount);\(tps)\(suffix)"
    }

    static func decode(
        _ delta: String
    ) -> (
        tokenCount: Int,
        tokensPerSecond: Double,
        unclosedReasoning: Bool,
        stopReason: String?
    )? {
        guard delta.hasPrefix(statsPrefix) else { return nil }
        let parts = delta.dropFirst(statsPrefix.count).split(separator: ";", maxSplits: 2)
        guard parts.count >= 2, let count = Int(parts[0]), let tps = Double(parts[1]) else {
            return nil
        }
        let flags = parts.count == 3 ? parts[2].split(separator: ",") : []
        let stopReason = flags.compactMap { flag -> String? in
            guard flag.hasPrefix("stop=") else { return nil }
            let value = flag.dropFirst("stop=".count)
            return value.isEmpty ? nil : String(value)
        }.first
        return (count, tps, flags.contains("unclosed"), stopReason)
    }
}

// M13 Schedules restore: made `public` so the un-excluded DispatchRequest /
// ExecutionContext / BackgroundTaskModels (which expose `public let source:
// SessionSource`) compile — the real upstream enum is public too.
public enum SessionSource: String, Codable, CaseIterable, Sendable {
    case chat, plugin, http, schedule, watcher, selfSchedule = "self_schedule"
    /// Conversation imported from another assistant's export (ChatGPT,
    /// Claude, Gemini, Grok, Open WebUI, or generic JSON). Upstream
    /// 311f327c. Continues as a normal chat; the source tag keeps
    /// provenance visible in the sidebar.
    case imported

    var iconName: String {
        switch self {
        case .chat: return "bubble.left.fill"
        case .plugin: return "puzzlepiece.extension.fill"
        case .http: return "network"
        case .schedule: return "clock.fill"
        case .watcher: return "eye.fill"
        case .selfSchedule: return "alarm.fill"
        case .imported: return "square.and.arrow.down.fill"
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
        case .imported: return "Imported"
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
        case .imported: return "imported"
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
    /// Plugins/Tools search filters use this. Simple substring fuzzy
    /// match (case-insensitive contains) — good enough for the
    /// settings search boxes.
    static func fuzzyMatch(query: String, in target: String) -> Bool {
        guard !query.isEmpty else { return true }
        return target.localizedCaseInsensitiveContains(query)
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
    var agentDescription: String { "" }
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

// M12 Gap 3: the real `ToolEnvelope` (Tools/ToolEnvelope.swift) + the legacy
// `ToolErrorEnvelope` (Tools/ToolErrorEnvelope.swift) are un-excluded so the
// restored file/shell tools return their real structured result/error JSON.
// The hollow mirror that used to live here is therefore removed.

// M12 Gap 3: `shell_run` (FolderTools.swift) broadcasts its live output to the
// chat terminal viewer through a `LiveExecSink`. The real sink
// (Services/Sandbox/LiveExecSink.swift) implements `Containerization.Writer`
// and is therefore amputated on Intel. `LiveExecRegistry` itself is clean
// (Combine + Foundation, NOT excluded), so we keep the registration path live
// and only stub the sink: the command still runs and its output is collected
// for the model via `ShellRunOutputCollector` — only the optional live
// mid-run UI streaming is inert (the chat shows the final result instead).
final class LiveExecSink: @unchecked Sendable {
    enum TerminationReason: Sendable, Equatable { case none, user }
    init() {}
    var terminationReason: TerminationReason { .none }
    var outputPublisher: AnyPublisher<Data, Never> { Empty().eraseToAnyPublisher() }
    var statusPublisher: AnyPublisher<LiveExecRegistry.LiveExecStatus, Never> {
        Empty().eraseToAnyPublisher()
    }
    var currentStatus: LiveExecRegistry.LiveExecStatus { .running }
    func bufferedSnapshot() async -> Data { Data() }
    func write(_ data: Data) throws {}
    func markExited(code: Int32) {}
    func requestTerminate() {}
    func close() throws {}
}


final actor SessionToolStateStore {
    /// The process-wide store also drops every chat's frozen tool fields when
    /// the tool catalog changes (upstream `invalidateToolCatalog`, which
    /// upstream calls from its MCP manager; Intel listens to
    /// `.toolsListChanged`, which plugins and MCP servers both post).
    static let shared: SessionToolStateStore = {
        let store = SessionToolStateStore()
        NotificationCenter.default.addObserver(forName: .toolsListChanged, object: nil, queue: nil) { _ in
            Task { await store.invalidateToolCatalog() }
        }
        return store
    }()

    /// What a session's tool grants looked like when it last composed
    /// (upstream `ToolGrantSnapshot`). Intel's grants live in the agent
    /// record, so the process-wide capability revision plus the agent's
    /// allowlist stand in for upstream's per-tool schema hashes.
    struct ToolGrantSnapshot: Equatable, Sendable {
        let capabilityRevision: UInt64
        let allowedNames: Set<String>?
        /// Every other gate that decides the composed tools and sections
        /// (`IntelAgentConfigSnapshot.gateSignature`): toggling an ability
        /// resets the per-chat freeze so it applies on the next send.
        let gates: String

        init(capabilityRevision: UInt64, allowedNames: Set<String>?, gates: String = "") {
            self.capabilityRevision = capabilityRevision
            self.allowedNames = allowedNames
            self.gates = gates
        }

        @MainActor
        static func current(agentId: UUID) -> ToolGrantSnapshot {
            ToolGrantSnapshot(
                capabilityRevision: AgentManager.shared.currentCapabilityRevision(),
                allowedNames: AgentManager.shared.effectiveEnabledToolNames(for: agentId).map(Set.init),
                gates: IntelAgentConfigSnapshot.capture(agentId: agentId, projectId: nil).gateSignature)
        }
    }

    private var toolGrants: [String: ToolGrantSnapshot] = [:]

    /// Upstream `reconcileToolGrants`: explicit grant edits apply on the next
    /// request. The frozen catalog prefix is refreshed, but the tools the
    /// chat already loaded stay (the composer re-filters them against the
    /// live grant, so revoked ones drop out of the schema); unchanged grants
    /// are a no-op.
    func reconcileToolGrants(_ key: Any, current: ToolGrantSnapshot) {
        let key = stateKey(key)
        let previous = toolGrants.updateValue(current, forKey: key)
        guard previous != current, var entry = states[key] else { return }
        entry.initialPreflight = nil
        entry.initialAlwaysLoadedNames = nil
        entry.initialToolSpecs = nil
        entry.frozenManifest = nil
        states[key] = entry
        lastSendCacheHints.removeValue(forKey: key)
    }

    /// Upstream `invalidateToolCatalog`: the process-wide tool catalog changed
    /// (a plugin or MCP server added, removed or replaced a schema), so every
    /// chat re-resolves its frozen tool fields on the next send. Tools the
    /// model loaded and the frozen user prefixes survive.
    func invalidateToolCatalog() {
        for key in Array(states.keys) {
            guard var entry = states[key] else { continue }
            entry.initialAlwaysLoadedNames = nil
            entry.initialToolSpecs = nil
            entry.frozenManifest = nil
            states[key] = entry
        }
        lastSendCacheHints.removeAll()
    }

    // MARK: Frozen user-message prefixes (HTTP / plugin paths)

    /// The session's frozen per-user-message memory prefixes (empty when none
    /// recorded). Upstream `frozenUserPrefixes`.
    func frozenUserPrefixes(_ key: Any) -> [String: String] {
        states[stateKey(key)]?.frozenUserPrefixes ?? [:]
    }

    /// Record the prefix injected into a user message so later requests of
    /// the same session replay the exact bytes. Creates the entry if the
    /// session has not composed yet. Upstream `recordUserPrefix`.
    func recordUserPrefix(_ key: Any, key prefixKey: String, prefix: String) {
        let key = stateKey(key)
        var entry = states[key] ?? SessionToolState()
        entry.frozenUserPrefixes[prefixKey] = prefix
        states[key] = entry
    }

    private var states: [String: SessionToolState] = [:]
    private var lastSendCacheHints: [String: String] = [:]

    private func stateKey(_ key: Any) -> String {
        if let uuid = key as? UUID { return uuid.uuidString }
        return String(describing: key)
    }

    func invalidate(_ key: Any) {
        let key = stateKey(key)
        states.removeValue(forKey: key)
        toolGrants.removeValue(forKey: key)
        lastSendCacheHints.removeValue(forKey: key)
    }

    func invalidateAll() {
        states.removeAll(keepingCapacity: true)
        toolGrants.removeAll(keepingCapacity: true)
        lastSendCacheHints.removeAll(keepingCapacity: true)
    }

    func invalidateIfFingerprintChanged(_ key: Any, liveFingerprint: Any) {
        let key = stateKey(key)
        guard var state = states[key] else { return }
        let live = String(describing: liveFingerprint)
        guard let recorded = state.sessionFingerprint else {
            state.sessionFingerprint = live
            states[key] = state
            return
        }
        guard recorded != live else { return }
        states.removeValue(forKey: key)
        toolGrants.removeValue(forKey: key)
        lastSendCacheHints.removeValue(forKey: key)
    }

    func get(_ key: Any) -> SessionToolState? {
        states[stateKey(key)]
    }

    /// Upstream `setInitial`: a capabilities load or a frozen-prefix write can
    /// create the entry before the first compose reaches this point, so fill
    /// only the fields still missing instead of returning early, and keep
    /// whatever the entry already accumulated (#2171).
    func setInitial(
        _ key: Any,
        preflight: Any? = nil,
        alwaysLoadedNames: Set<String>?,
        toolSpecs: [Tool]? = nil,
        fingerprint: String,
        manifest: String? = nil
    ) {
        let key = stateKey(key)
        var entry = states[key] ?? SessionToolState()
        if entry.initialPreflight == nil { entry.initialPreflight = preflight }
        if entry.initialAlwaysLoadedNames == nil { entry.initialAlwaysLoadedNames = alwaysLoadedNames }
        if entry.initialToolSpecs == nil { entry.initialToolSpecs = toolSpecs }
        if entry.sessionFingerprint == nil { entry.sessionFingerprint = fingerprint }
        if entry.frozenManifest == nil { entry.frozenManifest = manifest }
        states[key] = entry
    }

    func recordSend(sessionId: Any, cacheHint: Any?, trace: Any?) {
        let key = stateKey(sessionId)
        lastSendCacheHints[key] = String(describing: cacheHint)
        _ = trace
    }

    /// `fallbackPreflight` defaults to nil: upstream dropped the parameter,
    /// so its call sites (and tests) omit it.
    func appendLoadedTools(
        _ key: Any,
        names: [String],
        fallbackPreflight: Any? = nil,
        fallbackAlwaysLoadedNames: Set<String>?
    ) {
        let key = stateKey(key)
        var state = states[key] ?? SessionToolState(
            initialPreflight: fallbackPreflight,
            initialAlwaysLoadedNames: fallbackAlwaysLoadedNames
        )
        for name in names where !state.loadedToolNames.contains(name) {
            state.loadedToolNames.append(name)
        }
        states[key] = state
    }

    func reset() {
        states.removeAll(keepingCapacity: true)
        toolGrants.removeAll(keepingCapacity: true)
        lastSendCacheHints.removeAll(keepingCapacity: true)
    }
}

struct MockChatData: Sendable {
    init() {}
    static var isEnabled: Bool { false }
    static let shared = MockChatData()
    static func mockTurnsForPerformanceTest(count: Int = 10) -> [ChatTurn] { [] }
}

/// Upstream's tool invocation (`ModelService.swift`, excluded). Intel's was
/// an empty stub until the subagent runner needed real values
/// (docs/SUBAGENTS_INTEL.md).
struct ServiceToolInvocation: Error, Sendable {
    let toolName: String
    let jsonArguments: String
    let toolCallId: String?
    let geminiThoughtSignature: String?

    init(toolName: String, jsonArguments: String, toolCallId: String? = nil, geminiThoughtSignature: String? = nil) {
        self.toolName = toolName
        self.jsonArguments = jsonArguments
        self.toolCallId = toolCallId
        self.geminiThoughtSignature = geminiThoughtSignature
    }
}

struct ServiceToolInvocations: Error, Sendable {
    let invocations: [ServiceToolInvocation]
}

final class BlockMemoizer: @unchecked Sendable {
    init() {}
    static let shared = BlockMemoizer()
    func blocks(from turns: [ChatTurn], streamingTurnId: UUID? = nil, agentName: String = "", version: Int = 0, thinkingEnabled: Bool = false, sessionSource: SessionSource = .chat) -> [ContentBlock] {
        let blocks = unrolledBlocks(
            from: turns, streamingTurnId: streamingTurnId, agentName: agentName, sessionSource: sessionSource)
        // Display-time roll-up, gated by the Conversation toggle (upstream
        // applies it at the same display chokepoint, `limited`).
        return ContentBlock.ActivityRollupSetting.isEnabled ? ContentBlock.rollupActivityBlocks(blocks) : blocks
    }

    /// Per-turn blocks before the activity roll-up (upstream
    /// `ContentBlock.generateBlocks`).
    func unrolledBlocks(
        from turns: [ChatTurn], streamingTurnId: UUID? = nil, agentName: String = "",
        sessionSource: SessionSource = .chat
    ) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        // Track which "side" (user vs assistant) the previous rendered turn
        // belonged to, so a header is emitted only when the side flips.
        // Consecutive assistant + tool turns (a tool round) share one header.
        var prevSideIsUser: Bool?
        // Start of the reply being built: the user message that asked for it.
        var replyStartedAt: Date?
        // Files seen in the conversation, for naming a streaming edit's card
        // before its `path` streams. Built once, only when a card needs it.
        var knownFilesCache: [(path: String, content: String)]?
        func knownFiles() -> [(path: String, content: String)] {
            if let knownFilesCache { return knownFilesCache }
            let built = Self.knownFileContents(in: turns)
            knownFilesCache = built
            return built
        }
        let visibleTurns = turns.filter { $0.role != .tool }
        for (visibleIndex, turn) in visibleTurns.enumerated() {
            // M12 Gap 3: `.tool`-role turns exist ONLY to carry the tool result
            // back to the API on the continuation request. Their content is the
            // raw result envelope and must NOT render as a chat bubble — it's
            // already shown inside the assistant turn's tool-call card (via
            // `toolResults`). The simplified Intel builder used to fall through
            // to the assistant-paragraph branch and dump that JSON into the
            // stream (Renée 2026-06-03). Skip them.
            if turn.role == .tool { continue }

            let isUser = turn.role == .user
            if isUser { replyStartedAt = turn.createdAt }

            // Header only when the conversation side flips (or at the very top).
            if prevSideIsUser != isUser {
                blocks.append(ContentBlock(
                    id: "header-\(turn.id.uuidString)",
                    turnId: turn.id,
                    kind: .header(role: turn.role, agentName: agentName, isFirstInGroup: blocks.isEmpty)
                ))
            }
            prevSideIsUser = isUser

            // Thinking
            if !turn.thinking.isEmpty {
                blocks.append(ContentBlock(
                    id: "thinking-\(turn.id.uuidString)",
                    turnId: turn.id,
                    kind: .thinking(
                        index: blocks.count, text: turn.thinking, isStreaming: turn.id == streamingTurnId,
                        duration: turn.thinkingDuration)
                ))
            }

            // User message
            if isUser && !turn.content.isEmpty {
                // The reply this message produced = the first assistant turn
                // that follows it. Nil until a reply exists. Powers the
                // overflow menu's "Inspect response" (upstream #1939).
                let next = visibleIndex + 1
                let responseTurnId: UUID? =
                    next < visibleTurns.count && visibleTurns[next].role == .assistant
                    ? visibleTurns[next].id : nil
                blocks.append(ContentBlock(
                    id: "user-\(turn.id.uuidString)",
                    turnId: turn.id,
                    // Self-scheduled and watcher runs render their
                    // instructions under a badge row, not the framing
                    // (upstream DispatchEnvelope); the stored turn is
                    // unchanged.
                    kind: .userMessage(
                        text: turn.content,
                        attachments: turn.attachments,
                        timestamp: turn.createdAt,
                        responseTurnId: responseTurnId,
                        envelope: DispatchEnvelope.parse(turn.content, sessionSource: sessionSource)
                    )
                ))
            }

            // Assistant message (paragraph) — the pre-tool framing ("Sure
            // thing! Let me peek…") streams before the tool call, so render it
            // BEFORE the card.
            if !isUser && !turn.content.isEmpty {
                blocks.append(ContentBlock(
                    id: "assistant-\(turn.id.uuidString)",
                    turnId: turn.id,
                    // Cleaned text once the reply has finished (upstream: the
                    // raw stream while it is still arriving).
                    kind: .paragraph(
                        index: blocks.count,
                        text: turn.id == streamingTurnId ? turn.content : turn.visibleContent,
                        isStreaming: turn.id == streamingTurnId,
                        role: .assistant
                    )
                ))
            }

            // Artifact cards (upstream), e.g. a `/screenshot` capture.
            if !isUser {
                for artifact in turn.sharedArtifacts {
                    blocks.append(ContentBlock(
                        id: "artifact-\(turn.id.uuidString)-\(artifact.id)",
                        turnId: turn.id,
                        kind: .sharedArtifact(artifact: artifact)
                    ))
                }
            }

            // In-flight tool call: render the card the MOMENT the model emits
            // the call (pendingToolName set by the engine's StreamingToolHint),
            // BEFORE/while the tool executes — so the user sees "calling X …"
            // with the query, and the result fills in on completion. Cleared by
            // ChatView on `decodeDone`, when the completed `toolCalls` block
            // below takes over (the two are mutually exclusive per call).
            if !isUser, let pendingName = turn.pendingToolName, !pendingName.isEmpty {
                blocks.append(ContentBlock(
                    id: "pendingtool-\(turn.id.uuidString)",
                    turnId: turn.id,
                    kind: .pendingToolCall(
                        toolName: pendingName,
                        argPreview: turn.pendingToolArgPreview,
                        argSize: turn.pendingToolArgSize
                    )
                ))
                // File-writing tools stream their whole file through the call
                // arguments: a live diff card grows with the code below the
                // chip (upstream), so the finished card doesn't land as one
                // jarring dump.
                if let partialArgs = turn.pendingToolArgFull,
                    let preview = FileDiff.streamingPreview(
                        toolName: pendingName,
                        partialArgs: partialArgs,
                        fallbackPath: FileDiff.inferredEditPath(
                            partialArgs: partialArgs, knownFiles: knownFiles())
                    )
                {
                    blocks.append(ContentBlock(
                        id: "filediff-pending-\(turn.id.uuidString)",
                        turnId: turn.id,
                        kind: .fileDiff(diff: preview)
                    ))
                }
            }

            // Tool-call cards (M12 Gap 3): rendered via NativeToolCallGroupView.
            // Each call pairs with its result from `turn.toolResults`, so the
            // result shows inside the (expandable) card — not as a chat bubble.
            let isStreaming = turn.id == streamingTurnId
            if !isUser, let toolCalls = turn.toolCalls, !toolCalls.isEmpty {
                // A file write keeps its tool row with the diff card right
                // below it (upstream #1683), so the calls split into groups
                // around each card. The first group keeps the turn's block
                // id, so its expanded rows survive the split.
                var regularItems: [ToolCallItem] = []
                var groupIndex = 0
                func flushRegularItems() {
                    guard !regularItems.isEmpty else { return }
                    let suffix = groupIndex == 0 ? "" : "-\(groupIndex)"
                    blocks.append(ContentBlock(
                        id: "toolgroup-\(turn.id.uuidString)\(suffix)",
                        turnId: turn.id,
                        kind: .toolCallGroup(calls: regularItems)
                    ))
                    regularItems = []
                    groupIndex += 1
                }
                for call in toolCalls {
                    let result = turn.toolResults[call.id]
                    regularItems.append(
                        ToolCallItem(call: call, result: result, duration: turn.toolCallDurations[call.id]))
                    guard let diff = Self.fileDiff(
                        for: call, result: result, isStreaming: isStreaming, knownFiles: knownFiles)
                    else { continue }
                    flushRegularItems()
                    blocks.append(ContentBlock(
                        id: "filediff-\(call.id)",
                        turnId: turn.id,
                        kind: .fileDiff(diff: diff)
                    ))
                }
                flushRegularItems()
            }

            let nextRole: MessageRole? =
                visibleIndex + 1 < visibleTurns.count ? visibleTurns[visibleIndex + 1].role : nil
            let isLastInGroup = nextRole != turn.role

            // The router billed this turn but it produced no visible text,
            // reasoning, artifacts or tools: surface the charge with a Retry
            // instead of an empty row (upstream). Only once the turn is done.
            if !isUser, !isStreaming, let billing = turn.routerBilling,
                turn.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !turn.hasRenderableThinking, turn.sharedArtifacts.isEmpty,
                (turn.toolCalls ?? []).isEmpty, turn.pendingToolName == nil
            {
                blocks.append(ContentBlock(
                    id: "empty-notice-\(turn.id.uuidString)",
                    turnId: turn.id,
                    kind: .emptyResponseNotice(
                        turnId: turn.id,
                        outputTokens: billing.outputTokens,
                        costMicro: billing.costMicro,
                        status: billing.status
                    )
                ))
            } else if !isUser, !isStreaming, turn.terminalStopReason == "cancelled",
                turn.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                turn.sharedArtifacts.isEmpty, (turn.toolCalls ?? []).isEmpty, turn.pendingToolName == nil
            {
                // Upstream #2516: a cancelled turn with no visible answer used
                // to render nothing (or only its thinking), reading as still
                // in flight or quietly complete. Show what the record says.
                blocks.append(ContentBlock(
                    id: "interrupted-\(turn.id.uuidString)",
                    turnId: turn.id,
                    kind: .paragraph(
                        index: blocks.count,
                        text: String(
                            localized: "Interrupted — stopped before a response was produced.",
                            bundle: .module),
                        isStreaming: false,
                        role: .assistant
                    )
                ))
            }

            let totalDuration = Self.workedFor(
                isUser: isUser, isLastInGroup: isLastInGroup, isStreaming: isStreaming,
                startedAt: replyStartedAt, completedAt: turn.completedAt)
            // Stats only on the reply's last turn (upstream): intermediate
            // tool-calling turns of a loop don't get their own row.
            if !isUser, !isStreaming, isLastInGroup,
                turn.timeToFirstToken != nil || turn.generationTokensPerSecond != nil
                    || turn.generationTokenCount != nil || turn.unclosedReasoning || totalDuration != nil
            {
                blocks.append(ContentBlock(
                    id: "stats-\(turn.id.uuidString)",
                    turnId: turn.id,
                    kind: .generationStats(
                        ttft: turn.timeToFirstToken,
                        tokensPerSecond: turn.generationTokensPerSecond,
                        tokenCount: turn.generationTokenCount,
                        unclosedReasoning: turn.unclosedReasoning,
                        totalDuration: totalDuration
                    )
                ))
            }

            let hasFooterableContent =
                !turn.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || turn.hasRenderableThinking || !(turn.toolCalls ?? []).isEmpty
                || !turn.sharedArtifacts.isEmpty
            if !isUser, !isStreaming, isLastInGroup, hasFooterableContent {
                blocks.append(ContentBlock(
                    id: "actions-\(turn.id.uuidString)",
                    turnId: turn.id,
                    kind: .assistantActions(turnId: turn.id, timestamp: turn.createdAt)
                ))
            }
        }
        return blocks
    }
    /// The diff card for one call (upstream `ContentBlock.generateBlocks`):
    /// the applied diff from a completed write; for a FAILED write, the
    /// streamed content as a "preview" card so what the user watched stream
    /// doesn't vanish with the error; for a write still EXECUTING, the
    /// preview until the result lands under the same block id.
    static func fileDiff(
        for call: ToolCall,
        result: String?,
        isStreaming: Bool,
        knownFiles: () -> [(path: String, content: String)]
    ) -> FileDiff? {
        let name = call.function.name
        guard FileDiff.diffProducingToolNames.contains(name) else { return nil }
        if let result {
            if let diff = FileDiff.from(toolResult: result) { return diff }
            guard ToolEnvelope.successPayload(result) == nil else { return nil }
            return FileDiff.streamingPreview(
                toolName: name,
                partialArgs: call.function.arguments,
                isStreaming: false,
                fallbackPath: FileDiff.inferredEditPath(
                    partialArgs: call.function.arguments, knownFiles: knownFiles())
            )
        }
        guard isStreaming else { return nil }
        return FileDiff.streamingPreview(
            toolName: name,
            partialArgs: call.function.arguments,
            fallbackPath: FileDiff.inferredEditPath(
                partialArgs: call.function.arguments, knownFiles: knownFiles())
        )
    }

    /// Contents of every file the conversation has seen, keyed by path —
    /// `file_read` result text (line-number display prefixes stripped) and
    /// `file_write` argument content, latest version per path. Feeds
    /// `FileDiff.inferredEditPath`. Upstream `ContentBlock.knownFileContents`.
    static func knownFileContents(in turns: [ChatTurn]) -> [(path: String, content: String)] {
        var latest: [String: String] = [:]
        for turn in turns {
            guard let calls = turn.toolCalls else { continue }
            for call in calls {
                switch call.function.name {
                case "file_read", "sandbox_read_file":
                    guard let result = turn.toolResults[call.id],
                        let payload = ToolEnvelope.successPayload(result) as? [String: Any],
                        (payload["kind"] as? String) != "directory",
                        (payload["kind"] as? String) != "image",
                        (payload["kind"] as? String) != "workbook",
                        (payload["source"] as? String) != "ocr_text",
                        let path = payload["path"] as? String, !path.isEmpty,
                        let text = payload["text"] as? String
                    else { continue }
                    let content =
                        payload["line_format"] == nil
                        ? text
                        : text.components(separatedBy: "\n")
                            .map { line -> Substring in
                                guard let bar = line.firstIndex(of: "|") else { return line[...] }
                                return line[line.index(after: bar)...]
                            }
                            .joined(separator: "\n")
                    latest[path] = content
                case "file_write", "sandbox_write_file":
                    guard let data = call.function.arguments.data(using: .utf8),
                        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                        let path = (obj["path"] as? String), !path.isEmpty,
                        let content = obj["content"] as? String
                    else { continue }
                    latest[path] =
                        (obj["mode"] as? String) == "append"
                        ? (latest[path] ?? "") + content
                        : content
                default:
                    continue
                }
            }
        }
        // Rebuilt on the streaming tick and matched with `contains`: cap each
        // entry so a huge read can't turn the tick into a main-thread scan.
        return latest.map { (path: $0.key, content: String($0.value.prefix(262_144))) }
    }

    /// "Worked for" (upstream #2916): the finished reply's last assistant
    /// turn, measured from the user message. Nil while streaming, for user
    /// turns, mid-reply turns, or implausible clocks.
    static func workedFor(
        isUser: Bool, isLastInGroup: Bool, isStreaming: Bool, startedAt: Date?, completedAt: Date?
    ) -> TimeInterval? {
        guard !isUser, isLastInGroup, !isStreaming, let startedAt, let completedAt else { return nil }
        let seconds = completedAt.timeIntervalSince(startedAt)
        return seconds > 0 ? seconds : nil
    }

    var groupHeaderMap: [UUID: UUID] { [:] }
    func memoized<T>(forKey key: String, build: () -> T) -> T { build() }
    func clear() {}
}

// M12 Gap 3: real sentinel protocol between `CloudChatEngine` (which runs the
// DeepSeek tool loop) and `ChatView`'s stream-delta decoder. The engine yields
// these tagged strings interleaved with normal content; ChatView routes them
// (decodeDone → tool-call card + result turn; decode → pending tool name).
// Prefixes use an ESC control char + bracket tag so they can't collide with
// model-authored content. The hollow stub these replace meant tool calls were
// never decoded even if the engine had emitted them.
struct StreamingToolHint: Sendable {
    private static let donePrefix = "\u{1B}[[OSX_TOOL_DONE]]"
    private static let namePrefix = "\u{1B}[[OSX_TOOL_NAME]]"
    private static let argsPrefix = "\u{1B}[[OSX_TOOL_ARGS]]"
    /// Intel: tool calls a `stopAtToolCalls` round proposed (not run).
    private static let proposedPrefix = "\u{1B}[[OSX_TOOL_PROPOSED]]"

    struct ProposedCall: Sendable, Equatable, Codable {
        let callId: String
        let name: String
        let arguments: String
    }

    static func encodeProposed(_ calls: [ProposedCall]) -> String {
        let data = (try? JSONEncoder().encode(calls)) ?? Data("[]".utf8)
        return proposedPrefix + (String(data: data, encoding: .utf8) ?? "[]")
    }

    static func decodeProposed(_ delta: String) -> [ProposedCall]? {
        guard delta.hasPrefix(proposedPrefix) else { return nil }
        return try? JSONDecoder().decode(
            [ProposedCall].self, from: Data(delta.dropFirst(proposedPrefix.count).utf8))
    }

    /// Intel (`W-server-api` stage 4c): a tool the engine is about to run,
    /// sent only for requests that ask for it
    /// (`ChatCompletionRequest.reportsToolStarts`), so `/agents/{id}/run`
    /// streams upstream's "started" tool trace with the call id its
    /// "completed" trace (`encodeDone`) carries.
    private static let startedPrefix = "\u{1B}[[OSX_TOOL_STARTED]]"

    static func encodeStarted(callId: String, name: String, arguments: String) -> String {
        let data = (try? JSONEncoder().encode(ProposedCall(callId: callId, name: name, arguments: arguments))) ?? Data()
        return startedPrefix + (String(data: data, encoding: .utf8) ?? "")
    }

    static func decodeStarted(_ delta: String) -> ProposedCall? {
        guard delta.hasPrefix(startedPrefix) else { return nil }
        return try? JSONDecoder().decode(ProposedCall.self, from: Data(delta.dropFirst(startedPrefix.count).utf8))
    }

    static func encode(_ toolName: String) -> String { namePrefix + toolName }
    static func encodeArgs(_ fragment: String) -> String { argsPrefix + fragment }
    static func encodeDone(callId: String, name: String, arguments: String, result: String) -> String {
        let dict: [String: String] = [
            "callId": callId, "name": name, "arguments": arguments, "result": result,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        return donePrefix + (String(data: data, encoding: .utf8) ?? "")
    }
    static func decodeDone(_ delta: String) -> ToolCallDone? {
        guard delta.hasPrefix(donePrefix) else { return nil }
        let json = String(delta.dropFirst(donePrefix.count))
        guard let data = json.data(using: .utf8),
            let d = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return ToolCallDone(
            callId: d["callId"] ?? "",
            name: d["name"] ?? "",
            arguments: d["arguments"] ?? "",
            result: d["result"] ?? ""
        )
    }
    /// Any in-band hint, not just the tool ones: upstream's rule is "starts
    /// with `\u{FFFE}`" (reasoning, stats, billing), so generic filters such
    /// as `completeChat`'s one-shot text never pick up a hint as content.
    static func isSentinel(_ delta: String) -> Bool {
        delta.first == "\u{FFFE}"
            || delta.hasPrefix(donePrefix) || delta.hasPrefix(namePrefix) || delta.hasPrefix(argsPrefix)
            || delta.hasPrefix(proposedPrefix) || delta.hasPrefix(startedPrefix)
    }
    static func decode(_ delta: String) -> String? {
        delta.hasPrefix(namePrefix) ? String(delta.dropFirst(namePrefix.count)) : nil
    }
    static func decodeArgs(_ delta: String) -> String? {
        delta.hasPrefix(argsPrefix) ? String(delta.dropFirst(argsPrefix.count)) : nil
    }
}

struct ToolCallDone: Sendable, Equatable {
    let callId: String
    let name: String
    let arguments: String
    let result: String
}

// `StreamingDeltaProcessor` is upstream's (Utils/StreamingDeltaProcessor.swift,
// smooth streaming); the Intel pass-through that lived here is gone.

/// Intel mirror of the upstream `StreamingReasoningHint` (lives in the
/// excluded `Services/Inference/ModelService.swift` alongside MLX). The
/// previous Intel stub returned `nil` from `decode(_:)`, which meant
/// `CloudChatEngine`'s reasoning-content chunks (DeepSeek V4 Pro's
/// `Max` mode emits a separate `reasoning_content` SSE field) couldn't
/// be routed to `ChatTurn.thinking` and silently disappeared — so users
/// got the answer but no Think panel.
///
/// Same `\u{FFFE}reasoning:` sentinel prefix as upstream so the
/// `ChatView` decode site (`StreamingReasoningHint.decode(delta)` at
/// L1721) works without an architecture-specific branch.
/// In-band signaling for an Osaurus Router billing event (cost, token counts,
/// status). Shares the `\u{FFFE}` sentinel so the generic filters in HTTP
/// handlers and `ChatEngine` drop it from visible output and skip it for token
/// counting; `ChatView` decodes it to keep + surface the billed turn and to
/// write the on-device billing ledger row. Payload is JSON so fields can be
/// added later without changing the sentinel prefix. (Upstream; upstream
/// keeps it in `ModelService.swift`, which Intel doesn't compile.)
enum StreamingBillingHint: Sendable {
    private static let billingPrefix = "\u{FFFE}billing:"

    static func encode(_ summary: RouterBillingSummary) -> String {
        guard let data = try? JSONEncoder().encode(summary),
            let json = String(data: data, encoding: .utf8)
        else { return billingPrefix + "{}" }
        return billingPrefix + json
    }

    static func decode(_ delta: String) -> RouterBillingSummary? {
        guard delta.hasPrefix(billingPrefix) else { return nil }
        let json = String(delta.dropFirst(billingPrefix.count))
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RouterBillingSummary.self, from: data)
    }
}

enum StreamingReasoningHint: Sendable {
    private static let reasoningPrefix = "\u{FFFE}reasoning:"
    static func encode(_ text: String) -> String { reasoningPrefix + text }
    static func decode(_ delta: String) -> String? {
        guard delta.hasPrefix(reasoningPrefix) else { return nil }
        return String(delta.dropFirst(reasoningPrefix.count))
    }
}

final class SystemPromptComposer: @unchecked Sendable {
    static let shared = SystemPromptComposer()

    static func filteringWebSearchTools(_ specs: [Tool], enabled: Bool) -> [Tool] {
        specs.filter {
            enabled || !["web_search", "search_and_extract"].contains($0.function.name)
        }
    }
    /// Upstream `resolveEffectiveQuery`: the explicit `query`, else the most
    /// recent user message. Feeds memory recall only.
    static func resolveEffectiveQuery(query: String, messages: [ChatMessage]) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        for message in messages.reversed() where message.role == "user" {
            if let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                !content.isEmpty
            {
                return content
            }
        }
        return ""
    }

    /// Upstream `canonicalToolOrder` (#3266 lineage): loop tools pinned first
    /// in fixed order, then the `capabilities` gateway, then everything else
    /// alphabetical, so the tools block is byte-stable across turns and
    /// across the HTTP merge (provider prompt-cache prefix). Intel has no
    /// built-in sandbox bucket.
    static func canonicalToolOrder(_ tools: [Tool]) -> [Tool] {
        let loopIndex = Dictionary(
            uniqueKeysWithValues: ["todo", "complete", "clarify", "share_artifact"]
                .enumerated().map { ($1, $0) })
        let capabilityIndex = Dictionary(
            uniqueKeysWithValues: ["capabilities", "capabilities_discover", "capabilities_load"]
                .enumerated().map { ($1, $0) })
        func sortKey(_ tool: Tool) -> (Int, Int, String) {
            let name = tool.function.name
            if let order = loopIndex[name] { return (0, order, name) }
            if let order = capabilityIndex[name] { return (2, order, name) }
            return (3, .max, name)
        }
        return tools.sorted { sortKey($0) < sortKey($1) }
    }

    static func folderToolIsVisible(
        _ name: String,
        folder: FolderContext?,
        registeredFolderToolNames: Set<String>
    ) -> Bool {
        guard registeredFolderToolNames.contains(name) else { return true }
        guard let folder else { return false }
        let gitToolNames: Set<String> = ["git_status", "git_diff", "git_commit"]
        return folder.isGitRepo || !gitToolNames.contains(name)
    }
    // M12 Gap 1 follow-up: the real `SystemPromptComposer` is excluded on
    // Intel; this is Intel's own composer. Stage 5b slices 4-5 split it the
    // way upstream does: a synchronous, main-actor `buildStaticContext`
    // (everything but memory recall) fed by one `IntelAgentConfigSnapshot`,
    // shared by the send path (`composeChatContext`) and the preview path
    // (`composePreviewContext`, upstream #2306/#2323), plus the per-chat
    // freeze (upstream #2171).
    static func composeChatContext(agentId: Any? = nil, executionMode: Any? = nil, model: String? = nil, query: String? = nil, messages: [Any] = [], toolsDisabled: Bool = false, cachedPreflight: Any? = nil, additionalToolNames: [String] = [], frozenAlwaysLoadedNames: Set<String>? = nil, frozenToolSpecs: [Tool]? = nil, frozenManifest: String? = nil, trace: Any? = nil, projectId: UUID? = nil, folderContext: FolderContext? = nil, offerFolderPrompt: Bool = false) async -> ComposedContext {
        let id = (agentId as? UUID) ?? Agent.defaultId
        await KnowledgeManager.shared.ensureLoaded()
        // One main-actor read for every gate (upstream `AgentConfigSnapshot`),
        // so a settings edit mid-compose cannot mix two states.
        let snapshot = await MainActor.run {
            IntelAgentConfigSnapshot.capture(agentId: id, projectId: projectId)
        }
        let built = await MainActor.run {
            buildStaticContext(
                snapshot: snapshot, model: model, toolsDisabled: toolsDisabled,
                additionalToolNames: additionalToolNames,
                frozenAlwaysLoadedNames: frozenAlwaysLoadedNames, frozenToolSpecs: frozenToolSpecs,
                frozenManifest: frozenManifest, folderContext: folderContext,
                offerFolderPrompt: offerFolderPrompt, allowDatabaseOpen: true)
        }

        // Recall: assemble the layered memory block (identity → pinned →
        // episodes → transcript fallback) that `injectMemoryPrefix` will splice
        // in just before the user's message.
        var memorySection: String? = nil
        let memCfg = MemoryConfigurationStore.load()
        if memCfg.enabled,
            !snapshot.memoryDisabled,
            case let q = resolveEffectiveQuery(
                query: query ?? "", messages: messages.compactMap { $0 as? ChatMessage }),
            !q.isEmpty
        {
            // `projectId` additionally opens the project's own namespace as a
            // second lane, mirroring upstream: a chat inside a project recalls
            // what the whole project has learned, floored at a share of the
            // budget and deduped against what the agent lane already surfaced.
            // It is additive — passing nil keeps the previous behaviour exactly.
            let days = memCfg.episodeRetentionDays > 0 ? memCfg.episodeRetentionDays : 3650
            memorySection = await MemorySearchService.shared.recall(
                query: q, agentId: id.uuidString, projectId: projectId, days: days,
                budgetTokens: memCfg.memoryBudgetTokens)
        }

        if let databaseSchemaSection = built.databaseSchemaSection, !databaseSchemaSection.isEmpty {
            memorySection = [databaseSchemaSection, memorySection].compactMap { $0 }
                .joined(separator: "\n\n")
        }

        return ComposedContext(
            prompt: built.prompt, toolTokens: built.toolTokens, tools: built.tools,
            alwaysLoadedNames: built.alwaysLoadedNames,
            memorySection: memorySection, promptSections: built.sections,
            initialToolSpecs: built.initialToolSpecs, enabledManifest: built.enabledManifest)
    }

    /// Upstream `composePreviewContext` (#2306/#2323): the same sections and
    /// tools the next send would compose, without memory and without opening
    /// the agent database (`allowOpen: false`). Drives the Context Budget
    /// popover and the Abilities context readout.
    @MainActor
    static func composePreviewContext(
        agentId: Any? = nil, executionMode: Any? = nil, model: String? = nil,
        toolsDisabled: Bool = false, projectId: UUID? = nil, folderContext: FolderContext? = nil,
        offerFolderPrompt: Bool = false
    ) -> ComposedContext {
        let id = (agentId as? UUID) ?? Agent.defaultId
        return composePreviewContext(
            snapshot: IntelAgentConfigSnapshot.capture(agentId: id, projectId: projectId), model: model,
            toolsDisabled: toolsDisabled, folderContext: folderContext, offerFolderPrompt: offerFolderPrompt)
    }

    /// Snapshot-taking variant, so the Abilities editor can price a DRAFT
    /// state (toggles not yet saved) through the exact same gates.
    @MainActor
    static func composePreviewContext(
        snapshot: IntelAgentConfigSnapshot, model: String? = nil, toolsDisabled: Bool = false,
        folderContext: FolderContext? = nil, offerFolderPrompt: Bool = false
    ) -> ComposedContext {
        let built = buildStaticContext(
            snapshot: snapshot, model: model, toolsDisabled: toolsDisabled, additionalToolNames: [],
            frozenAlwaysLoadedNames: nil, frozenToolSpecs: nil, frozenManifest: nil,
            folderContext: folderContext, offerFolderPrompt: offerFolderPrompt, allowDatabaseOpen: false)
        return ComposedContext(
            prompt: built.prompt, toolTokens: built.toolTokens, tools: built.tools,
            alwaysLoadedNames: built.alwaysLoadedNames,
            // The agent database state is Intel's per-turn prefix, so it
            // prices as the memory rail (read only from an already-open DB).
            memorySection: built.databaseSchemaSection, promptSections: built.sections,
            initialToolSpecs: built.initialToolSpecs, enabledManifest: built.enabledManifest)
    }

    /// Everything the system prompt and tool schema need except memory.
    /// Synchronous and main-actor so the preview path can share it.
    @MainActor
    static func buildStaticContext(
        snapshot s: IntelAgentConfigSnapshot,
        model: String?,
        toolsDisabled: Bool,
        additionalToolNames: [String],
        frozenAlwaysLoadedNames: Set<String>?,
        frozenToolSpecs: [Tool]?,
        frozenManifest: String?,
        folderContext: FolderContext?,
        offerFolderPrompt: Bool,
        allowDatabaseOpen: Bool
    ) -> IntelStaticCompose {
        let id = s.agentId
        let basePrompt = IntelOrchestratorPrompt.compose(
            agentID: id,
            editablePrompt: s.editablePrompt,
            delegationTargets: s.delegationTargets
        )
        let folder = folderContext
        let enabledToolNames = s.enabledToolNames
        let agentToolsDisabled = s.agentToolsDisabled
        let selfSchedulingEnabled = s.selfSchedulingEnabled
        let webSearchEnabled = s.webSearchEnabled
        let databaseEnabled = s.databaseEnabled
        let speakEnabled = s.speakEnabled
        let imageEnabled = s.imageEnabled
        let videoEnabled = s.videoEnabled
        let appleScriptEnabled = s.appleScriptEnabled
        let browserUseEnabled = s.browserUseEnabled
        let renderChartEnabled = s.renderChartEnabled
        let searchMemoryEnabled = s.searchMemoryEnabled
        let disabledOptionalTools = s.disabledOptionalTools
        let appleAppToolNames = s.appleAppToolNames
        let folderToolNames = s.folderToolNames
        let knowledgeGrants = s.knowledgeGrants
        let knowledgeAllowed = !knowledgeGrants.isEmpty

        // M12 Gap 3: when a working folder is mounted, append the real
        // "## Working directory" framing (SystemPromptTemplates.folderContext —
        // NOT excluded). Without it the model just had bare tool specs and no
        // context, so DeepSeek hallucinated tool output as plain text instead
        // of emitting a real call (Renée 2026-06-03). The section carries the
        // path, project type, root contents, git status, the path rule, and
        // the per-tool dispatch guide that primes actual tool calls.
        let folderToolsAvailable = !toolsDisabled && !agentToolsDisabled
        let folderSection = SystemPromptTemplates.folderContext(
            from: folder,
            toolsAvailable: folderToolsAvailable
        )
        // M12 Gap 3: DeepSeek V4 Flash is an inconsistent tool-caller — with
        // only the (descriptive) folder guide it sometimes role-plays tool use
        // in prose and fabricates listings/contents/`ls` output instead of
        // emitting real calls (Renée 2026-06-03). The base system-instruction
        // tool directives that anchor this on Apple Silicon live in excluded
        // files, so we add a firm, recency-positioned directive here.
        let toolDirective: String
        if folder != nil && folderToolsAvailable {
            toolDirective = """

                ## Tool Use (MANDATORY)
                You have REAL tools that execute on the user's actual filesystem. \
                To list, read, search, write, or edit files — or run shell commands — \
                you MUST emit the matching tool call (`file_tree`, `file_read`, \
                `file_search`, `file_write`, `file_edit`, `shell_run`) and use its \
                returned result. The "Root contents" above is only a partial hint; \
                for any real answer, CALL the tool. NEVER fabricate, guess, or \
                simulate file names, file contents, or command output — if you have \
                not called the tool this turn, you do not know the answer. Do not \
                describe running a command in prose; actually call the tool. \
                Documents are built in: `file_read` and `file_search` handle PDF, Word, \
                PowerPoint, Excel and images (OCR); `file_write` produces .docx and \
                .pdf from Markdown, .pptx slides from Markdown and .xlsx from CSV or \
                JSON rows; and `file_edit` changes an existing .docx/.xlsx/.pptx/.pdf \
                in place with `operations` (read it with `file_read` mode "structure" \
                first) so its formatting is kept — prefer that over regenerating it. \
                Never shell out to pandoc, pdftotext or Python for these.
                """
        } else {
            toolDirective = ""
        }
        // Upstream `appendBasePrompt`: the platform line is always first, and
        // a blank custom-agent persona falls back to `defaultPersona`. The
        // built-in agent's prompt is the Orchestrator role, never blank.
        let persona = id == Agent.defaultId ? basePrompt : SystemPromptTemplates.effectivePersona(basePrompt)
        let platform = SystemPromptTemplates.platformIdentity
        var prompt = platform + "\n\n" + persona + folderSection + toolDirective
        if !folderToolsAvailable {
            prompt += """


                ## Tool availability for this turn
                No tools are offered in this request. Do not print XML, DSML, JSON, or other simulated tool-call markup as a substitute for a real call. If the user asks for an action requiring a tool, explain that it is unavailable and ask them to enable it.
                """
        }
        // Track each slice of the prompt so the budget popover can show them as
        // distinct rails (Persona / Working Directory / Grounding / …).
        var sections: [PromptSection] = []
        sections.append(PromptSection(id: "platform", label: L("Platform"), text: platform, tint: .gray))
        if !persona.isEmpty {
            sections.append(PromptSection(id: "persona", label: "Persona", text: persona, tint: .purple))
        }
        if !folderSection.isEmpty {
            // Upstream's id and label for this section ("folderContext",
            // "Working Directory"); "grounding" is the Grounding discipline
            // section (3c-2).
            sections.append(
                PromptSection(id: "folderContext", label: "Working Directory", text: folderSection, tint: .teal))
        }
        if !toolDirective.isEmpty {
            sections.append(PromptSection(id: "folderToolUse", label: "Folder Tool Use", text: toolDirective, tint: .indigo))
        }
        // Private agent database (docs/AGENT_DATABASE_INTEL_PLAN.md). The
        // onboarding framing is session-constant, so it joins the stable,
        // cached prompt; the schema snapshot changes as the agent works and
        // rides the per-turn prefix below (upstream's DYNAMIC section).
        let databaseActive = databaseEnabled && folderToolsAvailable
        if databaseActive {
            let block = "\n\n" + OnboardingPrompt.block
            prompt += block
            sections.append(PromptSection(id: "agentDB", label: "Agent DB", text: block, tint: .orange))
        }
        // Surface the registered tools, honoring the agent's capability picker
        // (M12 follow-up): in Manual mode, restrict to the agent's enabled
        // allowlist; in Auto mode (or un-seeded), send everything registered.
        var tools: [Tool]
        if toolsDisabled || agentToolsDisabled {
            tools = []
        } else {
            let chainedSpecs = filteringWebSearchTools(
                ToolRegistry.shared.openAISpecs(for: id),
                enabled: webSearchEnabled
            )
                .filter {
                    knowledgeAllowed || !ToolRegistry.knowledgeToolNames.contains($0.function.name)
                }
                .filter {
                    databaseActive || !ToolRegistry.databaseToolNames.contains($0.function.name)
                }
                .filter {
                    // `prompt_working_folder`: only when the attended chat
                    // offers it (no folder yet; upstream #2918).
                    $0.function.name != PromptWorkingFolderTool.toolName
                        || (offerFolderPrompt && folder == nil && id != Agent.defaultId)
                }
                .filter {
                    // Apple app tools: only the apps this agent switched on.
                    !AppleApp.allToolNames.contains($0.function.name)
                        || appleAppToolNames.contains($0.function.name)
                }
                .filter { spec in
                    folderToolIsVisible(
                        spec.function.name,
                        folder: folder,
                        registeredFolderToolNames: folderToolNames
                    )
                }
                .filter { spec in
                    selfSchedulingEnabled || !["schedule_next_run", "cancel_next_run", "notify"].contains(spec.function.name)
                }
                .filter { spec in
                    speakEnabled || spec.function.name != ToolRegistry.speakToolName
                }
                .filter { spec in
                    (renderChartEnabled || spec.function.name != "render_chart")
                        && (searchMemoryEnabled || spec.function.name != "search_memory")
                }
            // Per-agent switches: image / video / AppleScript (kept out of the
            // chain above, which is at the type checker's limit).
            let allSpecs = chainedSpecs.filter { (spec: Tool) -> Bool in
                let name = spec.function.name
                if name == ToolRegistry.imageToolName { return imageEnabled }
                if name == ToolRegistry.videoToolName { return videoEnabled }
                if ToolRegistry.appleScriptToolNames.contains(name) { return appleScriptEnabled }
                if name == ToolRegistry.browserUseToolName { return browserUseEnabled }
                if disabledOptionalTools.contains(name) { return false }
                return true
            }
            if let enabled = enabledToolNames {
                // Folder/runtime tools (file_read, file_write, file_edit,
                // file_search, file_tree, shell_run, git_*) are auto-mounted with
                // the working directory and must BYPASS the manual capability
                // allowlist — mirrors upstream, where runtime-managed tools form the
                // always-loaded baseline and the manual picker only ADDS discretionary
                // tools on top. Without this, selecting a folder gave a Manual-mode
                // agent the "## Working directory" prompt but none of the actual
                // file/shell tool specs, so it couldn't call them (Renée, native
                // Ventura, 2026-06-12).
                var allowed = Set(enabled).union(folderToolNames)
                // Knowledge assignment is its own explicit capability grant,
                // independent of the discretionary Tools-tab allowlist. A
                // seeded agent therefore receives the Knowledge schemas when
                // (and only when) that live grant/project scope is non-empty.
                if knowledgeAllowed {
                    allowed.formUnion(ToolRegistry.knowledgeToolNames)
                }
                // Same for the Database ability: the toggle is the grant.
                if databaseActive {
                    allowed.formUnion(ToolRegistry.databaseToolNames)
                }
                // And for Apple apps: the per-app toggle is the grant.
                allowed.formUnion(appleAppToolNames)
                // The folder ask is a chat-surface affordance, not a capability.
                allowed.insert(PromptWorkingFolderTool.toolName)
                // So are the agent-loop tools (todo/complete/clarify/time).
                allowed.formUnion(ToolRegistry.agentLoopToolNames)
                // Self-scheduling: the agent's switch is the grant.
                if selfSchedulingEnabled {
                    allowed.formUnion(ToolRegistry.selfSchedulingToolNames)
                }
                // Speak Tool: the agent's switch is the grant.
                if speakEnabled {
                    allowed.insert(ToolRegistry.speakToolName)
                }
                // Image / Video: the agent's switches are the grants.
                if imageEnabled { allowed.insert(ToolRegistry.imageToolName) }
                if videoEnabled { allowed.insert(ToolRegistry.videoToolName) }
                if appleScriptEnabled { allowed.formUnion(ToolRegistry.appleScriptToolNames) }
                if browserUseEnabled { allowed.insert(ToolRegistry.browserUseToolName) }
                // Upstream: `share_artifact` is baseline; Charts and Memory
                // Recall switches are their own grants.
                allowed.insert("share_artifact")
                if renderChartEnabled { allowed.insert("render_chart") }
                if searchMemoryEnabled { allowed.insert("search_memory") }
                if id == Agent.defaultId {
                    allowed.formUnion(ToolRegistry.orchestratorOnlyToolNames)
                }
                tools = allSpecs.filter { allowed.contains($0.function.name) }
            } else {
                // Legacy, never-opened agents have no seeded allowlist yet and
                // retain the historical registry-wide fallback. Once the
                // capability picker seeds a list, every item the user removes
                // is excluded on the very next turn in both Auto and Manual
                // modes. Auto controls discovery strategy, not authorization.
                tools = allSpecs
            }
        }
        // Per-chat freeze (upstream #2171). `alwaysLoaded` is the baseline
        // (non-discoverable) tool names of this compose. On turn 2+ the
        // session's snapshot filters it, so a built-in that registers
        // mid-session cannot change the schema and break the provider's
        // prompt-cache prefix; plugin/MCP tools only enter through the
        // explicit `capabilities` load (`additionalToolNames`) or, in Manual
        // mode, the user's own picks. Folder tools are carved out because the
        // folder gate has already decided them.
        let toolsOff = toolsDisabled || agentToolsDisabled
        tools.removeAll { $0.function.name == CapabilitiesTool.toolName }
        let isDynamicTool: (String) -> Bool = { ToolRegistry.shared.isLoadableDynamicTool($0) }
        let loadedByModel = Set(additionalToolNames)
        var alwaysLoaded: Set<String>? = nil
        if !toolsOff {
            if let frozen = frozenAlwaysLoadedNames {
                tools.removeAll {
                    let name = $0.function.name
                    return !isDynamicTool(name) && !frozen.contains(name)
                        && !folderToolNames.contains(name) && !loadedByModel.contains(name)
                }
                alwaysLoaded = frozen
            } else {
                alwaysLoaded = Set(tools.map(\.function.name).filter { !isDynamicTool($0) })
            }
        }
        // Automatic tool discovery (upstream "Design C",
        // docs/TOOL_DISCOVERY_INTEL.md). In Auto mode a custom agent's
        // plugin/MCP tools stay out of the schema until `capabilities` loads
        // them (this session's loads arrive as `additionalToolNames`); the
        // prompt lists what can be loaded. Manual mode sends the enabled set.
        var manifestBlock: String? = nil
        if !tools.isEmpty, id != Agent.defaultId {
            if s.toolMode == .auto {
                let catalog = CapabilityCatalog.build(agentId: id)
                let loadable = Set(catalog.tools.map(\.name))
                let loaded = Set(additionalToolNames).intersection(loadable)
                let dynamicNames = Set(tools.map(\.function.name).filter { isDynamicTool($0) })
                tools.removeAll { dynamicNames.contains($0.function.name) && !loaded.contains($0.function.name) }
                let present = Set(tools.map(\.function.name))
                tools += CapabilityLoadBuffer.validSpecs(
                    ToolRegistry.shared.openAISpecs(named: loaded.sorted().filter { !present.contains($0) }))
                // Upstream: `capabilities` is in a custom agent's schema whenever
                // something is loadable; the manifest itself renders only when
                // at least one assigned dynamic tool exists (skills alone
                // reach the model through `capabilities` search).
                if !catalog.isEmpty {
                    tools += ToolRegistry.shared.openAISpecs(named: [CapabilitiesTool.toolName])
                }
                // A frozen manifest is reused verbatim (upstream #2171); nil
                // means render fresh.
                if let frozenManifest {
                    manifestBlock = frozenManifest
                } else if let manifest = CapabilityManifest.render(catalog) {
                    manifestBlock = "\n\n" + CapabilityManifest.discoveryGuidance + "\n\n" + manifest
                }
            }
        }
        // Upstream's static discipline sections (#1317, #1430), gated on the
        // final schema and placed before the manifest as upstream does
        // (`IntelPromptDiscipline`).
        for section in IntelPromptDiscipline.sections(
            modelId: model,
            toolNames: Set(tools.map(\.function.name)),
            toolsOff: toolsDisabled || agentToolsDisabled
        ) {
            let block = "\n\n" + section.text
            prompt += block
            sections.append(PromptSection(id: section.id, label: section.label, text: block, tint: .indigo))
        }
        if let manifestBlock {
            prompt += manifestBlock
            sections.append(
                PromptSection(
                    id: "enabledManifest", label: "Enabled Capabilities", text: manifestBlock, tint: .blue))
        }
        // Append plugin-declared `instructions` for any plugin whose tools are
        // active this turn, so a plugin can shape how the model wields it.
        if !tools.isEmpty {
            let activeNames = Set(tools.map { $0.function.name })
            let pluginInstructions = PluginManager.shared.instructions(
                forActiveToolNames: activeNames, agentId: id)
            if !pluginInstructions.isEmpty {
                let block = "\n\n## Plugin Instructions\n" + pluginInstructions.joined(separator: "\n\n")
                prompt += block
                sections.append(
                    PromptSection(
                        id: "pluginInstructions", label: "Plugin Instructions", text: block, tint: .cyan)
                )
            }
        }
        // Subagent capability guidance (upstream's registry-driven loop): each
        // capability's guidance renders only when its PRIMARY tool resolved
        // into the schema (computer use, browser use, image, video,
        // AppleScript). Intel adaptations: the `image` tool only generates
        // (no edit model on Intel), so the generation-only guidance is used;
        // AppleScript uses Intel's helper wording.
        let resolvedNames = Set(tools.map { $0.function.name })
        for capability in SubagentCapabilityRegistry.all {
            guard let sectionId = capability.guidanceSectionId,
                let labelKey = capability.guidanceLabelKey,
                resolvedNames.contains(capability.primaryToolName)
            else { continue }
            var guidance = capability.guidance
            if capability.id == SubagentCapabilityRegistry.image.id {
                guidance = SystemPromptTemplates.imageGenerationOnlyGuidance
            } else if capability.id == SubagentCapabilityRegistry.appleScript.id {
                guidance = SystemPromptTemplates.intelAppleScriptGuidance
            }
            guard let guidance else { continue }
            let block = "\n\n" + guidance
            prompt += block
            sections.append(
                PromptSection(
                    id: sectionId,
                    label: String(localized: String.LocalizationValue(labelKey), bundle: .module),
                    text: block, tint: .green))
        }
        // Knowledge grant manifest (upstream): names + summaries of the
        // granted collections, when a retrieval tool is in the schema.
        if !resolvedNames.isDisjoint(with: ToolRegistry.knowledgeToolNames), !knowledgeGrants.isEmpty {
            let block = "\n\n" + SystemPromptTemplates.knowledgeGuidance(collections: knowledgeGrants)
            prompt += block
            sections.append(PromptSection(id: "knowledge", label: L("Knowledge"), text: block, tint: .teal))
        }
        // Built-in Apple apps (docs/APPLE_APPS_INTEL_PLAN.md): guidance for the
        // apps that resolved into this turn's schema; they resolve dates
        // against the `[Current Time]` block every turn carries (#2173).
        let activeAppleApps = IntelAppleAppsGuidance.activeApps(in: resolvedNames)
        if !activeAppleApps.isEmpty {
            let block = "\n\n" + IntelAppleAppsGuidance.guidance(apps: activeAppleApps)
            prompt += block
            sections.append(PromptSection(id: "appleApps", label: "Apple Apps", text: block, tint: .green))
        }
        // Project instructions (upstream, ChatView): constant per session, so
        // they ride the system prompt rather than the per-turn `[Memory]`
        // prefix.
        if let project = s.project {
            let instructions = project.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if !instructions.isEmpty {
                let block = "\n\n## Project: \(project.name)\n\n\(instructions)"
                prompt += block
                sections.append(
                    PromptSection(id: "projectInstructions", label: L("Project"), text: block, tint: .cyan))
            }
        }

        // Frozen payloads (upstream #2171): a tool name can stay while its
        // schema changes (an MCP server re-registering), which rewrites the
        // cached prefix. Reuse the first compose's spec for every baseline
        // tool still visible; tools the model loaded this session stay live
        // so `capabilities` can upgrade them.
        if let frozenToolSpecs {
            let frozenByName = Dictionary(
                frozenToolSpecs.map { ($0.function.name, $0) }, uniquingKeysWith: { first, _ in first })
            tools = tools.map { spec in
                loadedByModel.contains(spec.function.name) ? spec : (frozenByName[spec.function.name] ?? spec)
            }
        }
        // Upstream canonical order, applied once the schema is final.
        tools = canonicalToolOrder(tools)
        // Estimate the tool-schema token cost so the budget popover shows a real
        // "Tools" rail instead of 0.
        let toolTokens = ContextBudgetManager.estimateToolTokens(tools)

        // The agent database state is Intel's per-turn prefix (upstream keeps
        // it as a dynamic system section). `allowDatabaseOpen: false` (the
        // preview) reads only an already-open connection.
        let databaseSchemaSection: String? =
            databaseActive ? Self.renderSchemaSnapshot(agentId: id, allowOpen: allowDatabaseOpen) : nil

        return IntelStaticCompose(
            prompt: prompt, sections: sections, tools: tools, toolTokens: toolTokens,
            enabledManifest: toolsOff ? nil : manifestBlock,
            alwaysLoadedNames: alwaysLoaded,
            // Nothing to freeze while tools are off; leave the session's
            // snapshot unset so the next compose records the real one.
            initialToolSpecs: toolsOff ? nil : tools.filter { !loadedByModel.contains($0.function.name) },
            databaseSchemaSection: databaseSchemaSection)
    }


    /// Upstream `SystemPromptComposer.renderSchemaSnapshot`: opens the agent
    /// database (creating it on first use) and falls back to the "no tables
    /// yet" block when it cannot be read.
    /// `allowOpen: false` (the preview path, which runs during SwiftUI body
    /// evaluation) reads only an already-open connection: a first open does
    /// file I/O plus SQLCipher key derivation (upstream hung the main thread
    /// for seconds on it).
    static func renderSchemaSnapshot(agentId: UUID, allowOpen: Bool = true) -> String {
        guard allowOpen else {
            return LocalAgentBridge.shared.schemaSnapshotIfOpen(agentId: agentId)
                ?? SchemaSnapshot.emptyStateBlock
        }
        do {
            return try LocalAgentBridge.shared.schemaSnapshot(agentId: agentId)
        } catch {
            NSLog(
                "[Context:agentDB] schema snapshot unavailable for %@: %@",
                agentId.uuidString, error.localizedDescription)
            return SchemaSnapshot.emptyStateBlock
        }
    }

    /// Upstream: prepend the per-turn block (memory, the clock, the agent
    /// database state, project instructions) to the latest user message as
    /// `[Memory]…[/Memory]`, so the long system prefix stays byte-identical
    /// across turns and the block sits next to the query.
    ///
    /// Intel used to insert it as a separate `system` message just before the
    /// last user turn. Rosy (2026-11-01) showed that breaks models whose chat
    /// template expects one system message at the start: Venice Uncensored
    /// repeated its previous answer on every turn. Intel difference: a user
    /// message with image or audio parts gets the block as a leading text
    /// part (upstream leaves such a message without it).
    ///
    /// `timeContext` (upstream #2173, `SystemPromptTemplates.timeContext`)
    /// rides last, right against the user's text, as in upstream's
    /// `composeInjectedUserPrefix`.
    static func injectMemoryPrefix(
        _ section: String?, timeContext: String? = nil, into messages: inout [ChatMessage]
    ) {
        guard let prefix = composeInjectedUserPrefix(memorySection: section, timeContext: timeContext),
            let idx = messages.lastIndex(where: { $0.role == "user" })
        else { return }
        let existing = messages[idx]
        messages[idx] = ChatMessage(
            role: existing.role,
            content: prefix + (existing.content ?? ""),
            tool_calls: existing.tool_calls,
            tool_call_id: existing.tool_call_id,
            reasoning_content: existing.reasoning_content,
            contentParts: existing.contentParts.map { [.text(prefix)] + $0 }
        )
    }

    /// Upstream `applyFrozenMemoryPrefixes` (#2171 lineage): session-stable
    /// memory/time injection for surfaces whose history the CALLER owns (HTTP
    /// `/agents/{id}/run`, the plugin host). The client resends clean history
    /// every request, so a prefix injected into the latest user message on
    /// request N would vanish from request N+1 and the provider's prompt
    /// cache would diverge at that message. This makes the injected bytes
    /// sticky: it (1) replays recorded prefixes onto matching history user
    /// messages (keyed by content hash plus occurrence of the ORIGINAL
    /// message), and (2) injects this request's block into the latest user
    /// message unless that message already has a recorded prefix (an
    /// identical retry, where byte stability beats fresher memory). Returns
    /// the (key, prefix) newly recorded for the latest message so the caller
    /// can persist it in the session ledger; nil when nothing new was
    /// injected. Intel difference: a message with image or audio parts gets
    /// the block as a leading text part (as `injectMemoryPrefix` does);
    /// upstream skips such messages.
    static func applyFrozenMemoryPrefixes(
        memorySection: String?,
        frozen: [String: String],
        timeContext: String? = nil,
        into messages: inout [ChatMessage]
    ) -> (key: String, prefix: String)? {
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == "user" }) else { return nil }
        let keys = frozenPrefixKeys(for: messages)

        func prepend(_ prefix: String, at idx: Int) {
            let existing = messages[idx]
            messages[idx] = ChatMessage(
                role: existing.role,
                content: prefix + (existing.content ?? ""),
                tool_calls: existing.tool_calls,
                tool_call_id: existing.tool_call_id,
                reasoning_content: existing.reasoning_content,
                contentParts: existing.contentParts.map { [.text(prefix)] + $0 }
            )
        }

        // History user messages replay the exact bytes they were sent with.
        for (idx, key) in keys where idx != lastUserIdx {
            if let prefix = frozen[key] { prepend(prefix, at: idx) }
        }

        guard let lastKey = keys[lastUserIdx] else { return nil }
        if let recorded = frozen[lastKey] {
            prepend(recorded, at: lastUserIdx)
            return nil
        }
        guard let prefix = composeInjectedUserPrefix(memorySection: memorySection, timeContext: timeContext)
        else { return nil }
        prepend(prefix, at: lastUserIdx)
        return (key: lastKey, prefix: prefix)
    }

    /// Stable ledger keys for every user message: an FNV-1a hash of the
    /// ORIGINAL content plus an occurrence ordinal, so duplicate texts ("yes",
    /// "continue") map to distinct entries while staying deterministic for a
    /// client that resends identical history.
    static func frozenPrefixKeys(for messages: [ChatMessage]) -> [Int: String] {
        var occurrence: [String: Int] = [:]
        var keys: [Int: String] = [:]
        for (idx, msg) in messages.enumerated() where msg.role == "user" {
            let hash = fnv1aHex(msg.content ?? "")
            let ordinal = occurrence[hash, default: 0]
            occurrence[hash] = ordinal + 1
            keys[idx] = "\(hash)#\(ordinal)"
        }
        return keys
    }

    private static func fnv1aHex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Upstream `composeInjectedUserPrefix` (#1798, #2173): the memory block,
    /// then the time block right against the user's text, each with its
    /// trailing separator; nil when both are empty. Intel has no screen or
    /// automation context.
    static func composeInjectedUserPrefix(
        memorySection: String?, automationContext: String? = nil, timeContext: String? = nil
    ) -> String? {
        var prefix = ""
        if let trimmed = memorySection?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            prefix = "[Memory]\n\(trimmed)\n[/Memory]\n\n"
        }
        // Upstream: the automation context leads the memory block.
        if let trimmed = automationContext?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            prefix = "\(trimmed)\n\n" + prefix
        }
        if let trimmed = timeContext?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            prefix += "\(trimmed)\n\n"
        }
        return prefix.isEmpty ? nil : prefix
    }

    /// Upstream `appleScriptWorkingAppContext`: the app the user was working
    /// in before this message, so "the file" / "the document" routes to
    /// AppleScript. Callers include it only when `applescript` is in the
    /// schema.
    static func appleScriptWorkingAppContext(appName: String?) -> String? {
        guard let appName else { return nil }
        let app =
            appName
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty else { return nil }
        return """
            [Mac Automation Context]
            Working app before this message: \(app)
            If the request says `the file` or `the document`, it means that app's front open document. Use `applescript`; do not ask for a path or create a separate artifact.
            [/Mac Automation Context]
            """
    }

    /// Upstream: merge content into the first system message (prepending or
    /// appending), or insert one at index 0.
    static func mergeSystemContent(
        _ content: String,
        into messages: inout [ChatMessage],
        prepend: Bool
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = messages.firstIndex(where: { $0.role == "system" }),
            let existing = messages[idx].content, !existing.isEmpty
        {
            let combined = prepend ? trimmed + "\n\n" + existing : existing + "\n\n" + trimmed
            messages[idx] = ChatMessage(role: "system", content: combined)
        } else {
            messages.insert(ChatMessage(role: "system", content: trimmed), at: 0)
        }
    }

    /// Upstream: the HTTP agent path lands the composed prompt ahead of any
    /// caller-supplied system message.
    static func injectSystemContent(_ content: String, into messages: inout [ChatMessage]) {
        mergeSystemContent(content, into: &messages, prepend: true)
    }
}

/// What `buildStaticContext` produces: everything but memory.
struct IntelStaticCompose: @unchecked Sendable {
    var prompt: String
    var sections: [PromptSection]
    var tools: [Tool]
    var toolTokens: Int
    var enabledManifest: String?
    var alwaysLoadedNames: Set<String>?
    var initialToolSpecs: [Tool]?
    var databaseSchemaSection: String?
}

/// Intel's counterpart of upstream `AgentConfigSnapshot`: every per-agent
/// gate the composer reads, captured in ONE main-actor read so the send path
/// and the preview path (and the Abilities readout's draft overlay) run the
/// same gates and a settings edit mid-compose cannot mix two states
/// (stage 5b slices 4-5).
struct IntelAgentConfigSnapshot: @unchecked Sendable {
    struct ProjectInstructions: Sendable, Equatable {
        var name: String
        var instructions: String
    }

    var agentId: UUID
    var editablePrompt: String
    var delegationTargets: [IntelOrchestratorPrompt.DelegationTarget]
    var enabledToolNames: [String]?
    var agentToolsDisabled: Bool
    var toolMode: ToolSelectionMode
    var memoryDisabled: Bool
    var selfSchedulingEnabled: Bool
    var webSearchEnabled: Bool
    var databaseEnabled: Bool
    var speakEnabled: Bool
    var imageEnabled: Bool
    var videoEnabled: Bool
    var appleScriptEnabled: Bool
    var browserUseEnabled: Bool
    var renderChartEnabled: Bool
    var searchMemoryEnabled: Bool
    var disabledOptionalTools: Set<String>
    var appleAppToolNames: Set<String>
    var folderToolNames: Set<String>
    var knowledgeGrants: [KnowledgeGrantDescriptor]
    var project: ProjectInstructions?

    @MainActor
    static func capture(agentId id: UUID, projectId: UUID?) -> IntelAgentConfigSnapshot {
        let manager = AgentManager.shared
        let settings = manager.agent(for: id)?.settings
        var delegationTargets: [IntelOrchestratorPrompt.DelegationTarget] = []
        if id == Agent.defaultId {
            let delegation = DefaultAgentConfigurationStore.load().delegation
            delegationTargets = IntelOrchestratorAdmission.evaluate(
                configuration: delegation,
                agents: manager.agents,
                effectiveModel: { manager.effectiveModel(for: $0) }
            ).targets
        }
        var disabledOptional: Set<String> = []
        if id != Agent.defaultId, let settings {
            disabledOptional = ToolRegistry.disabledOptionalToolNames(settings)
        }
        // The agent's own knowledge grants plus the project's, deduplicated,
        // so the `## Knowledge` section and the tool gate cannot disagree.
        var collections = manager.effectiveKnowledgeCollections(for: id)
        let known = Set(collections.map(\.id))
        var project: ProjectInstructions? = nil
        if let projectId, let found = ProjectManager.shared.project(for: projectId) {
            collections += KnowledgeManager.shared.enabledCollections(
                withIds: found.knowledgeCollectionIds
            ).filter { !known.contains($0.id) }
            project = ProjectInstructions(name: found.name, instructions: found.instructions)
        }
        return IntelAgentConfigSnapshot(
            agentId: id,
            editablePrompt: manager.effectiveSystemPrompt(for: id),
            delegationTargets: delegationTargets,
            enabledToolNames: manager.effectiveEnabledToolNames(for: id),
            agentToolsDisabled: manager.effectiveToolsDisabled(for: id),
            toolMode: manager.effectiveToolSelectionMode(for: id),
            memoryDisabled: manager.effectiveMemoryDisabled(for: id),
            selfSchedulingEnabled: manager.effectiveSelfSchedulingEnabled(for: id),
            webSearchEnabled: settings?.webSearchEnabled ?? false,
            databaseEnabled: manager.effectiveDBEnabled(for: id),
            speakEnabled: manager.effectiveSpeakEnabled(for: id),
            imageEnabled: manager.effectiveImageEnabled(for: id),
            videoEnabled: manager.effectiveVideoEnabled(for: id),
            appleScriptEnabled: manager.effectiveAppleScriptEnabled(for: id),
            browserUseEnabled: manager.effectiveBrowserUseEnabled(for: id),
            renderChartEnabled: settings?.renderChartEnabled ?? false,
            searchMemoryEnabled: settings?.searchMemoryEnabled ?? false,
            disabledOptionalTools: disabledOptional,
            appleAppToolNames: AppleApp.toolNames(for: manager.effectiveAppleApps(for: id)),
            folderToolNames: Set(FolderToolManager.shared.folderToolNames),
            knowledgeGrants: collections.map(\.grantDescriptor),
            project: project
        )
    }

    /// A stable fingerprint of every gate that decides which tools and
    /// sections a compose yields. A change resets the chat's frozen
    /// snapshot (`SessionToolStateStore.reconcileToolGrants`), so toggling an
    /// ability applies on the next send instead of being held back by the
    /// freeze.
    var gateSignature: String {
        let flags: [Bool] = [
            agentToolsDisabled, selfSchedulingEnabled, webSearchEnabled, databaseEnabled, speakEnabled,
            imageEnabled, videoEnabled, appleScriptEnabled, browserUseEnabled, renderChartEnabled,
            searchMemoryEnabled,
        ]
        return [
            flags.map { $0 ? "1" : "0" }.joined(),
            toolMode.rawValue,
            disabledOptionalTools.sorted().joined(separator: ","),
            appleAppToolNames.sorted().joined(separator: ","),
            knowledgeGrants.map(\.name).sorted().joined(separator: ","),
        ].joined(separator: "|")
    }
}

struct PromptManifest: Sendable { init() {} }

// M12 Gap 3: OpenAI-compatible tool spec carried in `ChatCompletionRequest.tools`.
// `OsaurusTool.asOpenAITool()` builds
// `Tool(type:, function: ToolFunction(name:description:parameters:))`, so the
// function MUST carry a JSON-Schema `parameters` object — that's what the model
// reads to call the tool with the right argument shape. The earlier mirror
// dropped `parameters` (and split into two incompatible `ToolFunction` types),
// which would have shipped schema-less tools the model couldn't invoke.
struct ToolFunction: Codable, Sendable {
    let name: String
    let description: String?
    let parameters: JSONValue?
    init(name: String, description: String? = nil, parameters: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

struct IntelTool: Codable, Sendable {
    let type: String
    let function: ToolFunction
    init(type: String = "function", function: ToolFunction) {
        self.type = type
        self.function = function
    }
}

typealias Tool = IntelTool

// `ToolChoiceOption` is upstream's, in Models/API/IntelOpenAIWire.swift.

/// A named, individually-measurable slice of the Intel system prompt, so the
/// context-budget popover can show Persona / Grounding / Agent Loop / Plugin
/// Instructions as distinct rails — matching the granularity of upstream's
/// PromptManifest sections (minus the local-model-only ones the fork amputates).
struct PromptSection: Sendable {
    let id: String
    let label: String
    let text: String
    let tint: ContextBreakdown.Tint
}

struct ComposedContext: @unchecked Sendable {
    let prompt: String
    let manifest: PromptManifest
    let toolTokens: Int
    var tools: [IntelTool]
    var preflight: Any?
    /// The baseline (non-discoverable) tool names of this compose, stored on
    /// the session and echoed back on turn 2+ (upstream #2171). nil while
    /// tools are off.
    var alwaysLoadedNames: Set<String>?
    /// The exact tool specs of the first compose, frozen per chat (#2171).
    var initialToolSpecs: [Tool]?
    /// The rendered enabled-capabilities block of the first compose, frozen
    /// per chat (#2171).
    var enabledManifest: String?
    var preflightItems: [Any]
    var memorySection: String?
    var cacheHint: Any?
    /// Named slices of `prompt`, in order, for the budget breakdown. Empty for
    /// the lightweight restored-session preview (which falls back to a single
    /// "System Prompt" rail).
    var promptSections: [PromptSection]
    init(prompt: String = "", manifest: PromptManifest = PromptManifest(), toolTokens: Int = 0, tools: [IntelTool] = [], preflight: Any? = nil, alwaysLoadedNames: Set<String>? = nil, preflightItems: [Any] = [], memorySection: String? = nil, cacheHint: Any? = nil, promptSections: [PromptSection] = [], initialToolSpecs: [Tool]? = nil, enabledManifest: String? = nil) {
        self.prompt = prompt
        self.manifest = manifest
        self.toolTokens = toolTokens
        self.tools = tools
        self.preflight = preflight
        self.alwaysLoadedNames = alwaysLoadedNames
        self.initialToolSpecs = initialToolSpecs
        self.enabledManifest = enabledManifest
        self.preflightItems = preflightItems
        self.memorySection = memorySection
        self.cacheHint = cacheHint
        self.promptSections = promptSections
    }
}
/// Auto-disable hints flowed from the context budget composer to the
/// FloatingInputCard's context-popover. On Intel none of this fires
/// (the composer's local-model budgeting paths are amputated) but
/// the upstream popover code reads the props unconditionally — Bool
/// defaults make the relevant rows collapse correctly.
struct ContextDisableInfo: Sendable {
    var modelId: String? = nil
    var contextLength: Int? = nil
    var disabledMemory: Bool = false
    var disabledTools: Bool = false

    init(
        modelId: String? = nil,
        contextLength: Int? = nil,
        disabledMemory: Bool = false,
        disabledTools: Bool = false
    ) {
        self.modelId = modelId
        self.contextLength = contextLength
        self.disabledMemory = disabledMemory
        self.disabledTools = disabledTools
    }
}

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

    /// Upsert helper used by `FloatingInputCard.displayContextBreakdown` so
    /// the typing-tokens entry can be written back into the breakdown
    /// without dropping the existing context / message rows.
    mutating func setTokens(
        for id: String,
        in keyPath: WritableKeyPath<ContextBreakdown, [Entry]>,
        tokens: Int,
        label: String,
        tint: Tint
    ) {
        if let idx = self[keyPath: keyPath].firstIndex(where: { $0.id == id }) {
            self[keyPath: keyPath][idx].tokens = tokens
        } else {
            self[keyPath: keyPath].append(
                Entry(id: id, label: label, tokens: tokens, tint: tint)
            )
        }
    }

    static func from(
        context composed: ComposedContext,
        conversationTokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        fallbackMemoryTokens: Int = 0
    ) -> ContextBreakdown {
        // The Intel `ComposedContext` DOES carry the real system prompt and a
        // tool-token estimate (see `SystemPromptComposer.composeChatContext`),
        // so surface them as proper rails. `context` = the static prefix
        // (System Prompt + Tools); `messages` = the dynamic part (Conversation
        // + Input + Output), rendered below a divider — matching upstream's
        // popover layout. Empty rails are skipped to keep it compact.
        var bd = ContextBreakdown()

        // Per-section prompt rails (Persona / Grounding / Agent Loop / Plugin
        // Instructions) when the composer provided them; otherwise fall back to
        // a single "System Prompt" rail (e.g. the restored-session preview,
        // which only has the agent persona).
        if !composed.promptSections.isEmpty {
            for section in composed.promptSections {
                let t = ContextBudgetManager.estimateTokens(for: section.text)
                if t > 0 {
                    bd.context.append(Entry(id: section.id, label: section.label, tokens: t, tint: section.tint))
                }
            }
        } else {
            let promptTokens =
                composed.prompt.isEmpty ? 0 : ContextBudgetManager.estimateTokens(for: composed.prompt)
            if promptTokens > 0 {
                bd.context.append(Entry(id: "persona", label: "System Prompt", tokens: promptTokens, tint: .purple))
            }
        }
        // Prefer the precomputed count; fall back to estimating from the tool
        // specs so the restored-session preview (which doesn't precompute) still
        // shows a real Tools rail.
        let toolTokens =
            composed.toolTokens > 0
            ? composed.toolTokens : ContextBudgetManager.estimateToolTokens(composed.tools)
        if toolTokens > 0 {
            bd.context.append(Entry(id: "tools", label: "Tools", tokens: toolTokens, tint: .orange))
        }

        // Recalled memory is spliced in as its own system message just before
        // the last user turn (`injectMemoryPrefix`), so it costs real context
        // and belongs on the rail. This mirror previously omitted it
        // entirely — the excluded upstream builder derives it the same way,
        // from `composed.memorySection`.
        let memoryTokens = composed.memorySection.map {
            $0.isEmpty ? 0 : ContextBudgetManager.estimateTokens(for: $0)
        } ?? fallbackMemoryTokens
        if memoryTokens > 0 {
            bd.context.append(Entry(id: "memory", label: "Memory", tokens: memoryTokens, tint: .teal))
        }

        if conversationTokens > 0 {
            bd.messages.append(Entry(id: "conversation", label: "Conversation", tokens: conversationTokens, tint: .blue))
        }
        if inputTokens > 0 {
            bd.messages.append(Entry(id: "input", label: "Input", tokens: inputTokens, tint: .cyan))
        }
        if outputTokens > 0 {
            bd.messages.append(Entry(id: "output", label: "Output", tokens: outputTokens, tint: .green))
        }
        return bd
    }

    /// Welcome-screen / restored-session preview path.
    ///
    /// The Intel `PromptManifest` is an empty stub, so nothing can be read
    /// from it — but every other argument is a real, already-computed count.
    /// This used to return `ContextBreakdown()` and silently discard all of
    /// them, which is why the preview popover showed no memory row no matter
    /// what the estimator produced.
    static func from(
        manifest: PromptManifest,
        toolTokens: Int = 0,
        memoryTokens: Int = 0,
        conversationTokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0
    ) -> ContextBreakdown {
        var bd = ContextBreakdown()
        if toolTokens > 0 {
            bd.context.append(Entry(id: "tools", label: "Tools", tokens: toolTokens, tint: .orange))
        }
        if memoryTokens > 0 {
            bd.context.append(Entry(id: "memory", label: "Memory", tokens: memoryTokens, tint: .teal))
        }
        if conversationTokens > 0 {
            bd.messages.append(
                Entry(id: "conversation", label: "Conversation", tokens: conversationTokens, tint: .blue))
        }
        if inputTokens > 0 {
            bd.messages.append(Entry(id: "input", label: "Input", tokens: inputTokens, tint: .cyan))
        }
        if outputTokens > 0 {
            bd.messages.append(Entry(id: "output", label: "Output", tokens: outputTokens, tint: .green))
        }
        return bd
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
    /// FloatingInputCard's live-voice preencode session calls this when
    /// either the session ends or the user discards the recording. Intel
    /// has no live-voice path (the whole MLX-backed preencode pipeline is
    /// amputated), so the bookkeeping is a no-op.
    func remove(for id: UUID) {}
    /// FloatingInputCard's send path tags the wav attachment with the
    /// matching live snapshot. Stored snapshots are read back later by
    /// the (Intel-absent) preencode pipeline. No-op on Intel.
    func store(snapshot: LiveVoiceAudioSnapshot, for id: UUID) {}
}

// NOTE (Intel memory port): the minimal `MemoryDatabase` stub that used to live
// here was removed — the real `Storage/MemoryDatabase.swift` is now compiled on
// Intel (it's pure OsaurusSQLCipher, no MLX/VecturaKit) and is a superset of the
// stub's API, so compiled callers (ChatView, MemoryView, AgentsView) bind to it
// directly.

// `IdentityView` (un-body-swapped in M11 Phase 11.A.1) reads
// `@EnvironmentObject private var server: ServerController`, which
// requires `ObservableObject` conformance. The upstream class at
// `Networking/ServerController.swift` (excluded on Intel) is an
// `ObservableObject` with `@Published` properties; we mirror just
// the protocol conformance here so SwiftUI's environment-object
// plumbing type-checks. The HTTP server itself is wired through
// `OsaurusServer` directly in `AppDelegate`, not through this
// controller surface — `restartServer()` below bridges to it.
//
// Settings-tab revival (2026-09-04, Renée): `configuration` used to be
// a hardcoded `Any? { nil }` with `port` pinned to a literal 1338 —
// there was no way for the Server → Settings tab to change or persist
// the listening port at all. It now holds the real, persisted
// `ServerConfiguration` (same file `AppDelegate` reads at launch), so
// `ServerSettingsTabContent` can edit port / CORS / proxy / body-size
// caps and have `restartServer()` actually apply them.
@MainActor
final class ServerController: ObservableObject, @unchecked Sendable {
    static let shared = ServerController()

    static func signalGenerationStart() {}
    static func signalGenerationEnd() {}

    @Published var configuration: ServerConfiguration = ServerConfigurationStore.load() ?? .default

    var port: Int { configuration.port }
    var isRunning: Bool { true }

    /// ServerView (un-body-swapped in M11 Phase 11.B.1) reads these for
    /// the connection URL + status badge. The Intel HTTP server
    /// (`OsaurusServer`) is always up while the app runs, so health is
    /// `.running`. The address is this Mac's LAN address while "Expose to
    /// Network" is on (upstream's `LocalNetworkAddress`), else loopback.
    var localNetworkAddress: String {
        configuration.exposeToNetwork ? LocalNetworkAddress.primaryIPv4() : "127.0.0.1"
    }
    var serverHealth: ServerHealth { .running }

    /// ServerView's start button. The Intel `OsaurusServer` is started
    /// from `AppDelegate` at launch and stays up, so this is a no-op
    /// (the button only shows when health is `.stopped`, which never
    /// happens on Intel).
    func startServer() async {}

    /// Upstream: start the server if it isn't running. Intel's
    /// `OsaurusServer` runs from launch, so there is nothing to start.
    static func ensureRunning() async {}

    /// Upstream: why the server can't take requests, or nil. Intel's server
    /// is always up while the app runs.
    static func notRunningReason() -> String? { nil }

    /// Persists `configuration` and asks `AppDelegate` to stop + restart
    /// the live `OsaurusServer` in place with the new port / CORS /
    /// body-size caps. Also the same path `IdentityView` calls after an
    /// agent's address rotates/revokes — access-key validation reads the
    /// live `APIKeyManager` on each request, so the restart there is
    /// only to be safe, not because keys are cached.
    func restartServer() async {
        await AppDelegate.shared?.applyServerConfiguration(configuration)
    }
}

extension ChatMessage {
    /// Upstream: text plus images as `data:` URL parts. (Until 2026-10-10
    /// this Intel initializer dropped the images.)
    init(role: String, text: String, imageData: [Data]) {
        self.init(role: role, text: text, imageData: imageData, audios: [], videos: [])
    }

    /// Upstream's multimodal initializer: text, image, audio and video parts.
    /// Local audio samples are an MLX-only shortcut and are ignored on Intel.
    init(
        role: String,
        text: String,
        imageData: [Data],
        audios: [(data: Data, format: String)],
        localAudioSamples: [LocalAudioSamples?] = [],
        videos: [(data: Data, mimeSubtype: String)]
    ) {
        var parts: [MessageContentPart] = []
        if !text.isEmpty { parts.append(.text(text)) }
        for data in imageData {
            parts.append(.imageUrl(url: MessageContentPart.imageDataURL(data), detail: nil))
        }
        for audio in audios {
            parts.append(.audioInput(data: audio.data.base64EncodedString(), format: audio.format))
        }
        for video in videos {
            parts.append(.videoUrl(url: "data:video/\(video.mimeSubtype);base64,\(video.data.base64EncodedString())"))
        }
        self.init(
            role: role,
            content: text.isEmpty ? nil : text,
            contentParts: parts.contains(where: \.isMedia) ? parts : nil
        )
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
    /// Posted by the `/agent` slash command to pop open the toolbar's agent
    /// picker for the window identified in `userInfo["windowId"]`.
    static let chatToolbarOpenAgentPicker = NSNotification.Name("chatToolbarOpenAgentPicker")
    /// Posted by a tab's folder glyph to reopen the current chat's project
    /// page in the window identified by `userInfo["windowId"]`.
    static let chatToolbarBackToProject = NSNotification.Name("chatToolbarBackToProject")
    static let toolsListChanged = NSNotification.Name("toolsListChanged")
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
