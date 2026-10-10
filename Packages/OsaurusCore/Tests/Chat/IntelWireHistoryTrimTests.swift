//
//  IntelWireHistoryTrimTests.swift
//  osaurusTests
//
//  W-agent-loop-tools (2026-10-10): upstream's sticky history trim applied
//  to the cloud engine's wire messages. The adapter must render exactly what
//  upstream's `ChatMessage` trim renders, while keeping provider fields on
//  the messages it keeps.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelWireHistoryTrimTests {
    private static let bulk = String(repeating: "lorem ipsum dolor sit amet ", count: 120)

    /// system, task, then `rounds` assistant tool-call + tool-result pairs.
    private static func conversation(rounds: Int) -> [[String: Any]] {
        var wire: [[String: Any]] = [
            ["role": "system", "content": "You are helpful."],
            ["role": "user", "content": "Summarize the repo."],
        ]
        for i in 0 ..< rounds {
            wire.append([
                "role": "assistant", "content": "",
                "tool_calls": [[
                    "id": "c\(i)", "type": "function",
                    "function": ["name": "file_read", "arguments": #"{"path":"f\#(i).txt"}"#],
                    IntelGeminiAdapter.thoughtSignatureKey: "sig-\(i)",
                ]],
            ])
            wire.append(["role": "tool", "tool_call_id": "c\(i)", "content": "Exit code: 0\n" + bulk])
        }
        return wire
    }

    private static func manager(window: Int) -> ContextBudgetManager {
        IntelWireHistoryTrim.makeBudgetManager(
            contextWindow: window, systemPromptChars: 16, toolTokens: 0, maxResponseTokens: 256)
    }

    @Test func withinBudgetIsUntouched() {
        let wire = Self.conversation(rounds: 2)
        let out = IntelWireHistoryTrim.trim(wire, manager: Self.manager(window: 200_000), watermark: CompactionWatermark())
        #expect(out.count == wire.count)
        #expect(out.map { $0["content"] as? String } == wire.map { $0["content"] as? String })
    }

    @Test func rendersWhatUpstreamRenders() {
        for window in [4_000, 6_000, 9_000] {
            let wire = Self.conversation(rounds: 8)
            let manager = Self.manager(window: window)
            let upstream = manager.trimMessagesReportingOverflow(
                Array(wire.dropFirst()).map(IntelWireHistoryTrim.chatMessage), watermark: CompactionWatermark()
            ).messages
            let ours = IntelWireHistoryTrim.trim(wire, manager: manager, watermark: CompactionWatermark())
            #expect(ours.first?["role"] as? String == "system")  // the prefix is never trimmed
            let mapped = ours.dropFirst().map(IntelWireHistoryTrim.chatMessage)
            #expect(mapped.map(\.role) == upstream.map(\.role), "window \(window)")
            #expect(mapped.map(\.content) == upstream.map(\.content), "window \(window)")
            #expect(mapped.map(\.tool_call_id) == upstream.map(\.tool_call_id), "window \(window)")
        }
    }

    @Test func overBudgetSummarizesOrDropsButKeepsProviderFields() throws {
        let wire = Self.conversation(rounds: 8)
        let out = IntelWireHistoryTrim.trim(wire, manager: Self.manager(window: 6_000), watermark: CompactionWatermark())
        #expect(out.count <= wire.count + 1)
        let contents = out.compactMap { $0["content"] as? String }
        #expect(contents.contains { $0.hasPrefix("[Compressed:") || $0 == ContextBudgetManager.trimmedHistoryNote })
        // Kept assistant calls still carry their Gemini signature.
        let kept = try #require(out.last { $0["role"] as? String == "assistant" })
        let call = try #require((kept["tool_calls"] as? [[String: Any]])?.first)
        #expect((call[IntelGeminiAdapter.thoughtSignatureKey] as? String)?.hasPrefix("sig-") == true)
        // Every tool result still follows its assistant call (no orphans).
        var openCalls: Set<String> = []
        for message in out {
            if let calls = message["tool_calls"] as? [[String: Any]] {
                openCalls.formUnion(calls.compactMap { $0["id"] as? String })
            }
            if message["role"] as? String == "tool" {
                #expect(openCalls.contains(message["tool_call_id"] as? String ?? ""))
            }
        }
    }

    @Test func decisionsAreStickyAcrossRounds() {
        let watermark = CompactionWatermark()
        let manager = Self.manager(window: 9_000)
        var wire = Self.conversation(rounds: 6)
        let first = IntelWireHistoryTrim.trim(wire, manager: manager, watermark: watermark)
        wire.append(["role": "assistant", "content": "Looking further."])
        wire.append(["role": "user", "content": "Go on."])
        let second = IntelWireHistoryTrim.trim(wire, manager: manager, watermark: watermark)
        // Whatever survived both rounds is byte-identical (KV / cache stable).
        let firstContents = first.compactMap { $0["content"] as? String }
        let secondContents = second.compactMap { $0["content"] as? String }
        for content in secondContents where content.hasPrefix("[Compressed:") {
            #expect(firstContents.contains(content))
        }
    }

    @Test func nearLimitNoticeIsUpstreams() {
        #expect(ChatEngine.contextNearLimitNotice.hasPrefix("[System Notice] Context is nearly full"))
    }
}
