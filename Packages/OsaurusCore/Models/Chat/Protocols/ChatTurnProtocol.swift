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
    var role: ChatTurnRole { get set }
    var content: String { get set }
    var toolCalls: [ToolCall]? { get set }
    var toolResults: [String: String] { get set }
    var toolCallId: String? { get set }
    var thinking: String? { get }
    var unclosedReasoning: Bool { get set }
    var hasRenderableThinking: Bool { get }
    var contentIsBlank: Bool { get }
    var thinkingIsBlank: Bool { get }
    var contentIsEmpty: Bool { get }
    var contentLength: Int { get }
    var attachments: [any AttachmentProtocol] { get set }
    var imageData: Data? { get }
    var generationTokenCount: Int? { get set }
    var generationTokensPerSecond: Double? { get set }
    var timeToFirstToken: TimeInterval? { get set }
    var completedAt: Date? { get set }
    var pendingToolName: String? { get set }
    var pendingToolArgFragmentCount: Int { get }
    var preflightCapabilities: Any? { get set }

    mutating func consolidateContent()
    mutating func clearPendingToolArgs()
    mutating func appendToolArgFragment(_ arg: String)
}

enum ChatTurnRole: String, Sendable {
    case user, assistant, system, tool
}
