//
//  IntelTranscriptSyncTests.swift
//  osaurusTests
//
//  `W-cov-reaudit` stage 3b-2 (docs/COV_REAUDIT.md): the transcript pieces
//  Intel's own copies were missing.
//  - #1259: thinking and tool-call durations, measured on the turn, saved
//    with the chat, and carried by the blocks the views render.
//  - #1969: the find bar searches what blocks paint (`searchableText`) and
//    an enveloped user turn by its displayed text.
//  (Per-occurrence matching itself is upstream's `ChatFindMatcherTests`;
//  the renderer's occurrence guards are upstream's
//  `SearchOccurrenceIndexTests`.)
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct IntelTurnDurationTests {
    @Test func thinkingDurationRunsFromFirstReasoningToFirstContent() {
        let turn = ChatTurn(role: .assistant, content: "")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        turn.appendThinking("let me think", at: start)
        turn.finalizeThinkingDuration(at: start.addingTimeInterval(2.5))
        #expect(turn.thinkingDuration == 2.5)
    }

    @Test func aTurnWithoutThinkingHasNoDuration() {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.appendContent("hello")
        #expect(turn.thinkingDuration == nil)
    }

    @Test func toolDurationSpansStartToResult() async throws {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.markToolCallStarted("call_1")
        try await Task.sleep(for: .milliseconds(80))
        turn.setToolResult("ok", for: "call_1")
        #expect(turn.toolResults["call_1"] == "ok")
        #expect((turn.toolCallDurations["call_1"] ?? 0) >= 0.05)
    }

    @Test func anInstantResultRecordsNoDuration() {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.markToolCallStarted("call_1")
        turn.setToolResult("ok", for: "call_1")
        #expect(turn.toolCallDurations["call_1"] == nil)
    }

    @Test func durationsAreSaved() throws {
        let turn = ChatTurn(role: .assistant, content: "done")
        turn.thinkingDuration = 4.2
        turn.toolCallDurations = ["call_1": 1.5]
        let data = try JSONEncoder().encode(ChatTurnData(from: turn))
        let decoded = try JSONDecoder().decode(ChatTurnData.self, from: data)
        #expect(decoded.thinkingDuration == 4.2)
        #expect(decoded.toolCallDurations == ["call_1": 1.5])
        let restored = ChatTurn(from: decoded)
        #expect(restored.thinkingDuration == 4.2)
        #expect(restored.toolCallDurations == ["call_1": 1.5])
    }

    @Test func blocksCarryTheDurations() {
        let turn = ChatTurn(role: .assistant, content: "answer")
        turn.thinking = "reasoning"
        turn.thinkingDuration = 3
        turn.toolCalls = [
            ToolCall(id: "call_1", type: "function", function: ToolCallFunction(name: "file_read", arguments: "{}"))
        ]
        turn.toolResults = ["call_1": "contents"]
        turn.toolCallDurations = ["call_1": 0.8]
        let blocks = BlockMemoizer().unrolledBlocks(
            from: [ChatTurn(role: .user, content: "hi"), turn], agentName: "A")
        let thinking = blocks.compactMap { block -> TimeInterval?? in
            if case let .thinking(_, _, _, duration) = block.kind { return duration }
            return nil
        }
        #expect(thinking == [3])
        let tools = blocks.flatMap { block -> [ToolCallItem] in
            if case let .toolCallGroup(calls) = block.kind { return calls }
            return []
        }
        #expect(tools.first?.duration == 0.8)
    }
}

@Suite
struct IntelFindSearchableTextTests {
    @Test func paragraphsAndUserMessagesAreSearchable() {
        let turnId = UUID()
        let paragraph = ContentBlock(
            id: "p", turnId: turnId,
            kind: .paragraph(index: 0, text: "find me", isStreaming: false, role: .assistant))
        let user = ContentBlock(
            id: "u", turnId: turnId,
            kind: .userMessage(text: "and me", attachments: [], timestamp: Date(), responseTurnId: nil))
        let header = ContentBlock(
            id: "h", turnId: turnId, kind: .header(role: .assistant, agentName: "A", isFirstInGroup: true))
        #expect(paragraph.searchableText == "find me")
        #expect(user.searchableText == "and me")
        #expect(header.searchableText == nil)
    }

    @Test @MainActor func aUserTurnIsSearchedAsDisplayed() {
        let turn = ChatTurn(role: .user, content: "plain question")
        let snapshot = ChatFindTurnSnapshot(turn: turn, sessionSource: .chat)
        #expect(snapshot.content == "plain question")
    }
}
