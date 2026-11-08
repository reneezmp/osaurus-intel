//
//  IntelMidRunSteer.swift
//  osaurus
//
//  Upstream's mid-run steering (#1433, with #2653's ordering fixes) for
//  Intel's chat. Upstream's chat loop injects a queued text-only send at each
//  iteration boundary (`injectQueuedSteerIfEligible` in its `buildMessages`
//  hook). On Intel `CloudChatEngine` runs the tool rounds itself, so the
//  engine asks the chat for the steer at each round boundary
//  (`ChatExecutionContext.midRunSteer`), adds it to the wire history, and
//  yields this sentinel in stream order so the chat records the user turn
//  after the round's tool results, never before them.
//

import Foundation

enum StreamingSteerHint {
    private static let prefix = "\u{FFFE}steer:"

    static func encode(_ text: String) -> String { prefix + text }

    static func decode(_ delta: String) -> String? {
        guard delta.hasPrefix(prefix) else { return nil }
        return String(delta.dropFirst(prefix.count))
    }
}

extension AgentToolLoop {
    private static let budgetWarningNoticeMarker = "[System Notice] Tool call budget: "

    /// Upstream: notices staged for the previous user message (repeated
    /// calls, invalid arguments, planning nudges) no longer describe the
    /// message a steer starts. Only the run-scoped tool-budget warning
    /// belongs to the run rather than to the message; keep that one.
    static func noticesSurvivingNewUserMessage(_ notices: [String]) -> [String] {
        notices.filter { $0.hasPrefix(budgetWarningNoticeMarker) }
    }
}
