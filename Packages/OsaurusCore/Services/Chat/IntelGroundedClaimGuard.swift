//
//  IntelGroundedClaimGuard.swift
//  osaurus
//
//  W-agent-loop-tools (2026-10-10): upstream `AgentToolLoop`'s grounded-claim
//  bookkeeping, carried per run by Intel's cloud engine. The checks themselves
//  are upstream's files (`GroundedConfigClaimCheck`,
//  `GroundedFileSideEffectCheck`, `GroundedKnowledgeClaimCheck`); this only
//  holds the run state and the bounds upstream's driver keeps in locals.
//

import Foundation

struct IntelGroundedClaimGuard {
    /// Upstream `AgentToolLoop.maxGroundedClaimRetries`.
    static let maxGroundedClaimRetries = 2
    /// Upstream `AgentToolLoop.maxUngroundedFileClaimNotices`.
    static let maxUngroundedFileClaimNotices = 2

    private(set) var hasGroundedConfigApply = false
    private(set) var hasGroundedFileWrite = false
    private(set) var hasGroundedKnowledgeRead = false
    private(set) var lastFailedKnowledgeRead: (tool: String, result: String)?
    private(set) var groundedClaimRetries = 0
    private(set) var ungroundedFileClaimNotices = 0

    /// Upstream's batch-completion bookkeeping, one outcome at a time.
    mutating func record(toolName: String, argumentsJSON: String, result: String) {
        if !hasGroundedConfigApply,
            GroundedConfigClaimCheck.isGroundedApplyOutcome(
                toolName: toolName, argumentsJSON: argumentsJSON, result: result)
        {
            hasGroundedConfigApply = true
        }
        if !hasGroundedFileWrite,
            GroundedFileSideEffectCheck.isGroundedFileWriteOutcome(toolName: toolName, result: result)
        {
            hasGroundedFileWrite = true
        }
        if GroundedKnowledgeClaimCheck.isGroundedKnowledgeOutcome(toolName: toolName, result: result) {
            hasGroundedKnowledgeRead = true
        } else if GroundedKnowledgeClaimCheck.isFailedKnowledgeOutcome(toolName: toolName, result: result) {
            lastFailedKnowledgeRead = (toolName, result)
        }
    }

    /// Advisory for a tool-calling message whose narration claims a file
    /// write nothing grounded (upstream stages it and keeps going; bounded).
    /// Call after the round's outcomes are recorded.
    mutating func toolTurnNotice(narration: String) -> String? {
        guard !hasGroundedFileWrite,
            ungroundedFileClaimNotices < Self.maxUngroundedFileClaimNotices,
            GroundedFileSideEffectCheck.containsFileSideEffectClaim(narration)
        else { return nil }
        ungroundedFileClaimNotices += 1
        NSLog(
            "[CloudChatEngine] Ungrounded file side-effect claim in a tool-calling turn "
                + "(notice \(ungroundedFileClaimNotices)/\(Self.maxUngroundedFileClaimNotices))")
        return GroundedFileSideEffectCheck.ungroundedFileClaimNotice
    }

    /// Upstream's final-answer checks, in upstream's order. A non-nil notice
    /// means: keep the answer visible, leave it out of the next request, and
    /// regenerate once with the notice. `configToolOffered` scopes the config
    /// check to runs that offer `osaurus_config`, as upstream's chat does.
    mutating func finalAnswerNotice(visibleText: String, configToolOffered: Bool) -> String? {
        guard groundedClaimRetries < Self.maxGroundedClaimRetries else { return nil }
        var notice: String?
        if configToolOffered {
            notice = GroundedConfigClaimCheck.notice(
                finalText: visibleText, hasGroundedApply: hasGroundedConfigApply)
        }
        if notice == nil, !hasGroundedFileWrite,
            GroundedFileSideEffectCheck.containsFileSideEffectClaim(visibleText)
        {
            notice = GroundedFileSideEffectCheck.ungroundedFileClaimNotice
        }
        if notice == nil, !hasGroundedKnowledgeRead, let failed = lastFailedKnowledgeRead,
            GroundedKnowledgeClaimCheck.containsCollectionContentClaim(visibleText)
        {
            notice = GroundedKnowledgeClaimCheck.ungroundedKnowledgeClaimNotice(
                tool: failed.tool,
                grantedNames: GroundedKnowledgeClaimCheck.grantedCollectionNames(inFailure: failed.result))
        }
        guard let notice else { return nil }
        groundedClaimRetries += 1
        NSLog(
            "[CloudChatEngine] Grounded-claim guard tripped "
                + "(retry \(groundedClaimRetries)/\(Self.maxGroundedClaimRetries))")
        return notice
    }
}

/// In-band hint from the engine to `ChatView`: the answer streamed so far was
/// ungrounded and a corrected one follows. The chat keeps it visible, marks
/// it `modelContextExcluded`, and opens a fresh assistant turn (upstream's
/// `prepareGroundedClaimRetry` hook). Same `\u{FFFE}` sentinel family as the
/// other hints, so text-only consumers drop it.
enum StreamingGroundedRetryHint {
    static let sentinel = "\u{FFFE}grounded-retry"

    static func isRetry(_ delta: String) -> Bool { delta == sentinel }
}
