//
//  ChatTurnProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on ChatTurn.
//

import Foundation

protocol ChatTurnProtocol: Identifiable, Sendable {
    var id: UUID { get }
    var turnId: UUID? { get }
    var role: MessageRole { get }
    var content: String { get set }
    var toolCalls: [ToolCall]? { get set }
    var toolResults: [String: String] { get set }
    var toolCallId: String? { get set }
    var thinking: String { get }
    var unclosedReasoning: Bool { get set }
    var hasRenderableThinking: Bool { get }
    var hasThinking: Bool { get }
    var contentIsBlank: Bool { get }
    var thinkingIsBlank: Bool { get }
    var contentIsEmpty: Bool { get }
    var contentLength: Int { get }
    var attachments: [Attachment] { get }
    /// Files shown as artifact cards on the turn (upstream; on Intel only
    /// `/screenshot` creates them so far).
    var sharedArtifacts: [SharedArtifact] { get }
    var imageData: Data? { get }
    var generationTokenCount: Int? { get set }
    var generationTokensPerSecond: Double? { get set }
    var timeToFirstToken: TimeInterval? { get set }
    var completedAt: Date? { get set }
    var pendingToolName: String? { get set }
    var pendingToolArgFragmentCount: Int { get }
    var preflightCapabilities: Any? { get set }
    var createdAt: Date { get }
    var visibleContent: String { get }

    func consolidateContent()
    func clearPendingToolArgs()
    func appendToolArgFragment(_ arg: String)
}
