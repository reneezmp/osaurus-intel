//
//  IntelRouterBillingTests.swift
//  osaurusTests
//
//  `W-router-billing`: the Router's per-turn summary frame reaches the chat
//  as a billing hint, is stamped on the turn, saved with the chat, and a
//  billed turn with no visible reply shows the "charged" notice
//  (upstream `RemoteProviderService` / `ChatView` / `ContentBlock`).
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelRouterBillingTests {
    private static let frame = """
        {"osaurus":{"request_id":"req-1","cost_micro":"1234","status":"completed","token_source":"provider",
         "input_tokens":10000,"output_tokens":300,"cached_input_tokens":8000,"cache_write_tokens":1500}}
        """

    private func object(_ text: String) throws -> [String: Any] {
        try #require((try JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])
    }

    @Test func summaryFrameDecodesAndRoundTripsAsAHint() throws {
        let summary = try #require(
            ChatEngine.routerSummary(fromFrame: try object(Self.frame), data: Data(Self.frame.utf8)))
        #expect(summary.costMicro == "1234")
        #expect(summary.outputTokens == 300)

        let hint = StreamingBillingHint.encode(RouterBillingSummary(summary))
        #expect(StreamingToolHint.isSentinel(hint))
        let decoded = try #require(StreamingBillingHint.decode(hint))
        #expect(decoded.requestId == "req-1")
        #expect(decoded.cachedInputTokens == 8000)
    }

    @Test func ordinaryFramesAreNotSummaries() throws {
        let usage = #"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#
        #expect(ChatEngine.routerSummary(fromFrame: try object(usage), data: Data(usage.utf8)) == nil)
        let content = #"{"choices":[{"index":0,"delta":{"content":"Hi"}}]}"#
        #expect(ChatEngine.routerSummary(fromFrame: try object(content), data: Data(content.utf8)) == nil)
    }

    private func billing(outputTokens: Int = 0) -> RouterBillingSummary {
        RouterBillingSummary(
            requestId: "req-2", costMicro: "500", status: "completed",
            tokenSource: "provider", inputTokens: 40, outputTokens: outputTokens)
    }

    @Test func routerBillingIsSavedWithTheChatTurn() throws {
        let turn = ChatTurn(role: .assistant, content: "Hello")
        turn.routerBilling = billing(outputTokens: 2)
        let data = try JSONEncoder().encode(ChatTurnData(from: turn))
        let back = try JSONDecoder().decode(ChatTurnData.self, from: data)
        #expect(back.routerBilling == billing(outputTokens: 2))
        #expect(ChatTurn(from: back).routerBilling == billing(outputTokens: 2))

        // Chats saved before this field still load.
        let legacy = try JSONDecoder().decode(
            ChatTurnData.self,
            from: Data(#"{"id":"\#(UUID().uuidString)","role":"assistant","content":"x","createdAt":0}"#.utf8))
        #expect(legacy.routerBilling == nil)
    }

    @Test func billedTurnWithNoReplyShowsTheChargeNotice() {
        let user = ChatTurn(role: .user, content: "Hi")
        let empty = ChatTurn(role: .assistant, content: "")
        empty.routerBilling = billing()
        let blocks = BlockMemoizer().unrolledBlocks(from: [user, empty], streamingTurnId: nil, agentName: "Assistant")
        let notice = blocks.compactMap { block -> String? in
            guard case let .emptyResponseNotice(_, _, cost, _) = block.kind else { return nil }
            return cost
        }
        #expect(notice == ["500"])

        // A billed turn that did answer shows no notice; nor does one still streaming.
        let answered = ChatTurn(role: .assistant, content: "Done.")
        answered.routerBilling = billing(outputTokens: 2)
        let answeredBlocks = BlockMemoizer().unrolledBlocks(
            from: [user, answered], streamingTurnId: nil, agentName: "Assistant")
        #expect(!answeredBlocks.contains { if case .emptyResponseNotice = $0.kind { return true } else { return false } })
        let streamingBlocks = BlockMemoizer().unrolledBlocks(
            from: [user, empty], streamingTurnId: empty.id, agentName: "Assistant")
        #expect(!streamingBlocks.contains { if case .emptyResponseNotice = $0.kind { return true } else { return false } })
    }
}
