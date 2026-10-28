//
//  IntelAgentLoopBudget.swift
//  osaurus
//
//  The pieces of upstream's `AgentLoopBudget` (AgentToolLoop.swift) that the
//  desktop subagent loops use (docs/SUBAGENTS_INTEL.md, layer 2): the context
//  window, the budget manager, and the per-iteration message assembly (trim,
//  then transient notices). Upstream's `AgentToolLoop.swift` is the chat tool
//  loop, which Intel's `CloudChatEngine` replaces; its trim already runs on
//  Intel's `ContextBudgetManager` (`IntelWireHistoryTrim`), so the logic here
//  is upstream's on the same manager.
//

import Foundation

/// Upstream: one iteration's messages plus the advisory over-budget flag.
struct AgentLoopIterationInput {
    var messages: [ChatMessage]
    var overBudget: Bool = false
}

enum AgentLoopBudget {
    static let fallbackContextWindow = IntelWireHistoryTrim.fallbackContextWindow

    /// The model catalog, else Settings' Context Length, else 128k (the
    /// order of `IntelContextBudget.resolveWindow`). Read without hopping to
    /// the main actor: both sources are thread-safe, and a desktop loop must
    /// not wait behind main-actor work (a full test run showed a 272 s stall).
    static func resolveContextWindow(modelId: String) async -> Int {
        if let ctx = ModelInfo.load(modelId: modelId)?.model.contextLength, ctx > 0 { return ctx }
        if let setting = ChatConfiguration.shared.contextLength, setting > 0 { return setting }
        return fallbackContextWindow
    }

    static func makeBudgetManager(
        contextWindow: Int,
        systemPromptChars: Int,
        toolTokens: Int,
        maxResponseTokens: Int?
    ) -> ContextBudgetManager {
        IntelWireHistoryTrim.makeBudgetManager(
            contextWindow: contextWindow, systemPromptChars: systemPromptChars,
            toolTokens: toolTokens, maxResponseTokens: maxResponseTokens)
    }

    /// Upstream: trim first (system prefix kept byte-stable, sticky with a
    /// watermark), then append the staged `[System Notice]` lines as
    /// transient messages.
    static func composeIterationMessages(
        _ messages: [ChatMessage],
        notices: [String],
        manager: ContextBudgetManager?,
        watermark: CompactionWatermark? = nil
    ) -> AgentLoopIterationInput {
        var msgs = messages
        var overBudget = false
        if let manager {
            let result = trimPreservingSystemPrefixReportingOverflow(msgs, with: manager, watermark: watermark)
            msgs = result.messages
            overBudget = result.overBudget
        }
        msgs = appendingTransientNotices(notices, to: msgs)
        return AgentLoopIterationInput(messages: msgs, overBudget: overBudget)
    }

    static func trimPreservingSystemPrefixReportingOverflow(
        _ messages: [ChatMessage],
        with manager: ContextBudgetManager,
        watermark: CompactionWatermark? = nil
    ) -> (messages: [ChatMessage], overBudget: Bool) {
        func trim(_ msgs: [ChatMessage]) -> (messages: [ChatMessage], overBudget: Bool) {
            if let watermark {
                return manager.trimMessagesReportingOverflow(msgs, watermark: watermark)
            }
            let trimmed = manager.trimMessages(msgs)
            return (trimmed, ContextBudgetManager.estimateTokens(for: trimmed) > manager.historyBudget)
        }
        guard let first = messages.first, first.role == "system" else { return trim(messages) }
        let result = trim(Array(messages.dropFirst()))
        return ([first] + result.messages, result.overBudget)
    }

    /// Upstream: notices after a trailing tool result ride as tool-role
    /// feedback with that result's call id (keeps the cached prefix stable);
    /// otherwise a trailing user turn. (Upstream's native-image exception is
    /// MLX-only and left out.)
    static func appendingTransientNotices(_ notices: [String], to messages: [ChatMessage]) -> [ChatMessage] {
        guard !notices.isEmpty else { return messages }
        var msgs = messages
        let trailingTool = (msgs.last?.role == "tool") ? msgs.last : nil
        for notice in notices {
            if let trailingTool {
                msgs.append(
                    ChatMessage(role: "tool", content: notice, tool_calls: nil, tool_call_id: trailingTool.tool_call_id))
            } else {
                msgs.append(ChatMessage(role: "user", content: notice))
            }
        }
        return msgs
    }
}
