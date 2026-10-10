//
//  IntelWireHistoryTrim.swift
//  osaurus
//
//  W-agent-loop-tools (2026-10-10): upstream's per-iteration history trim
//  (`AgentLoopBudget.trimPreservingSystemPrefixReportingOverflow` with a
//  `CompactionWatermark`, run by chat on every loop iteration) applied to
//  Intel's cloud engine, whose running conversation is OpenAI wire
//  dictionaries rather than `ChatMessage`s.
//
//  Upstream's trim decides on `ChatMessage`s; every decision lands in the
//  watermark (summarized / dropped / sent verbatim). This adapter hands the
//  trim a `ChatMessage` view of the wire messages, then rebuilds the wire
//  array from the watermark exactly as upstream's `render()` does, so
//  provider-specific fields (image parts, Gemini signatures, reasoning echo)
//  survive on the messages that are kept.
//

import Foundation

enum IntelWireHistoryTrim {
    /// Upstream `AgentLoopBudget.fallbackContextWindow`: the window when
    /// neither the model catalog nor the Context Length setting knows it.
    static let fallbackContextWindow = 128_000

    /// Upstream `AgentLoopBudget.makeBudgetManager`.
    static func makeBudgetManager(
        contextWindow: Int, systemPromptChars: Int, toolTokens: Int, maxResponseTokens: Int?
    ) -> ContextBudgetManager {
        var manager = ContextBudgetManager(contextLength: contextWindow)
        manager.reserveByCharCount(.systemPrompt, characters: systemPromptChars)
        manager.reserve(.tools, tokens: toolTokens)
        manager.reserve(
            .response,
            tokens: IntelContextBudget.cappedResponseReservation(
                maxResponseTokens, effectiveBudget: manager.effectiveBudget))
        return manager
    }

    /// The leading system message is never trimmed (its tokens are reserved
    /// separately); the rest is trimmed against the history budget.
    static func trim(
        _ wire: [[String: Any]], manager: ContextBudgetManager, watermark: CompactionWatermark
    ) -> [[String: Any]] {
        let hasSystem = wire.first?["role"] as? String == "system"
        let prefix = hasSystem ? [wire[0]] : []
        let tail = hasSystem ? Array(wire.dropFirst()) : wire
        guard !tail.isEmpty else { return wire }
        _ = manager.trimMessagesReportingOverflow(tail.map(chatMessage), watermark: watermark)

        var rendered: [[String: Any]] = []
        rendered.reserveCapacity(tail.count + 1)
        for (index, message) in tail.enumerated() {
            switch watermark.decision(at: index) {
            case .dropped:
                continue
            case .summarized(let summary):
                var summarized = message
                summarized["content"] = summary
                rendered.append(summarized)
            case .verbatim, .none:
                rendered.append(message)
            }
        }
        if watermark.droppedCount > 0, !rendered.isEmpty {
            rendered.insert(
                ["role": "user", "content": ContextBudgetManager.trimmedHistoryNote],
                at: min(1, rendered.count))
        }
        return prefix + rendered
    }

    /// Estimated history tokens (system prefix excluded), for upstream's
    /// near-limit notice.
    static func historyTokens(_ wire: [[String: Any]]) -> Int {
        ContextBudgetManager.estimateTokens(
            for: wire.filter { $0["role"] as? String != "system" }.map(chatMessage))
    }

    /// The `ChatMessage` the trim and the estimators see. Text parts are
    /// joined; images are not counted (upstream's estimator reads text too).
    static func chatMessage(_ wire: [String: Any]) -> ChatMessage {
        let content: String?
        if let text = wire["content"] as? String {
            content = text
        } else if let parts = wire["content"] as? [[String: Any]] {
            content = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            content = nil
        }
        let calls = (wire["tool_calls"] as? [[String: Any]])?.map { call -> ToolCall in
            let function = call["function"] as? [String: Any]
            return ToolCall(
                id: call["id"] as? String ?? "",
                type: "function",
                function: ToolCallFunction(
                    name: function?["name"] as? String ?? "",
                    arguments: function?["arguments"] as? String ?? ""))
        }
        return ChatMessage(
            role: wire["role"] as? String ?? "user",
            content: content,
            tool_calls: calls,
            tool_call_id: wire["tool_call_id"] as? String)
    }
}
