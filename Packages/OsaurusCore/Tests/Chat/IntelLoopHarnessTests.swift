//
//  IntelLoopHarnessTests.swift
//  osaurusTests
//
//  W-agent-loop-tools (2026-10-10): Intel's engine drives upstream's
//  AgentTaskState. These cover the Intel wiring helpers; AgentTaskStateTests
//  (upstream) covers the state machine itself.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelLoopHarnessTests {
    @Test func identicalReadIsReplayedWithTheDedupeNotice() {
        let state = AgentTaskState()
        var notices: [String] = []
        let args = #"{"path":"a.txt"}"#
        let result = ToolEnvelope.success(tool: "file_read", text: "1|hello")
        #expect(ChatEngine.harnessResult(state, name: "file_read", arguments: args, notices: &notices) == nil)
        state.record(name: "file_read", argsJSON: args, result: result)

        let replay = ChatEngine.harnessResult(state, name: "file_read", arguments: args, notices: &notices)
        #expect(replay == result)
        #expect(notices.count == 1)
        #expect(notices[0].hasPrefix("[System Notice]"))
    }

    @Test func noticesFoldIntoTheTrailingToolResult() {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "go"],
            ["role": "tool", "tool_call_id": "c1", "content": "result"],
        ]
        let out = ChatEngine.appendingTransientNotices(["[System Notice] use it"], to: messages)
        #expect(out.count == 2)
        #expect(out[1]["tool_call_id"] as? String == "c1")
        #expect(out[1]["content"] as? String == "result\n\n[System Notice] use it")
        // Without a trailing tool result they ride as a user message.
        let plain = ChatEngine.appendingTransientNotices(["n"], to: [["role": "user", "content": "go"]])
        #expect(plain.last?["role"] as? String == "user")
        #expect(ChatEngine.appendingTransientNotices([], to: messages).count == 2)
    }

    @Test func biasRidesFirst() {
        var notices = [ChatEngine.dedupeNotice]
        ChatEngine.stageBiasNotice("look at the listing", into: &notices)
        #expect(notices.first == "[System Notice] look at the listing")
        #expect(notices.count == 2)
    }
}
