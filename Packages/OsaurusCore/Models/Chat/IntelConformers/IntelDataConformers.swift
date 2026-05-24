//
//  IntelDataConformers.swift
//  OsaurusCore
//
//  M10 Phase 4d: Intel-lite data type conformers for ChatView protocols.
//

#if OSAURUS_INTEL

import Foundation

// MARK: - ChatTurn

struct IntelChatTurn: ChatTurnProtocol, Identifiable, @unchecked Sendable {
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

struct IntelContentBlock: ContentBlockProtocol, Identifiable, Sendable {
    let id: UUID
    init() { self.id = UUID() }
}

// MARK: - ModelOptionValue

struct IntelModelOptionValue: ModelOptionValueProtocol, Sendable {
    let boolValue: Bool?
    init(boolValue: Bool?) { self.boolValue = boolValue }
}

// MARK: - ChatTurnData

struct IntelChatTurnData: ChatTurnDataProtocol, Sendable {
    init(from turn: any ChatTurnProtocol) {}
}

#endif
