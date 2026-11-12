//
//  IntelAnthropicThinkingReplayTests.swift
//  osaurusTests
//
//  W-anthropic-thinking-replay: signed Anthropic thinking blocks are captured
//  from the stream, kept on the turn, and replayed ahead of the assistant's
//  text and tool calls. Ports upstream's #3203 coverage (stream capture,
//  history persistence, the rebuild that keeps the field).
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelAnthropicThinkingReplayTests {
    private func blocks(from lines: [String]) -> [[String: Any]] {
        lines.compactMap { line -> [String: Any]? in
            guard line.hasPrefix("data: "), line != "data: [DONE]",
                let frame = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
                let delta = (frame["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]
            else { return nil }
            return delta["anthropic_thinking_block"] as? [String: Any]
        }
    }

    private func translate(_ events: [String]) throws -> [String] {
        var translator = IntelAnthropicSSETranslator()
        var lines: [String] = []
        for event in events { lines += try translator.translate(event) }
        return lines
    }

    private let signed: JSONValue = .object([
        "type": .string("thinking"), "thinking": .string("native thought"),
        "signature": .string("opaque-signature"),
    ])

    @Test func streamKeepsSignedAndRedactedBlocksWhole() throws {
        let lines = try translate([
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":1}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","future":"retained"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Actual "}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"thinking."}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"opaque-"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signature"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"opaque-redacted"}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"message_stop"}"#,
        ])
        let captured = blocks(from: lines)
        #expect(captured.count == 2)
        #expect(captured[0]["type"] as? String == "thinking")
        #expect(captured[0]["thinking"] as? String == "Actual thinking.")
        #expect(captured[0]["signature"] as? String == "opaque-signature")
        #expect(captured[0]["future"] as? String == "retained")
        #expect(captured[1]["type"] as? String == "redacted_thinking")
        #expect(captured[1]["data"] as? String == "opaque-redacted")
        // Thinking text still shows as reasoning.
        #expect(lines.contains { $0.contains("reasoning_content") })
    }

    @Test func blockWithoutStopEventIsFlushedAtMessageStopOnce() throws {
        let captured = blocks(from: try translate([
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"x"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"s"}}"#,
            #"data: {"type":"message_stop"}"#,
        ]))
        #expect(captured.count == 1)
        #expect(captured[0]["signature"] as? String == "s")
    }

    @Test func requestReplaysBlocksBeforeTextAndToolUse() throws {
        let wire = IntelAnthropicMessagesAdapter.wireThinkingBlocks([
            signed, .object(["type": .string("redacted_thinking"), "data": .string("opaque-redacted")]),
        ])
        let out = try IntelAnthropicMessagesAdapter.makeRequest(chatCompletions: [
            "model": "claude-sonnet-5",
            "messages": [
                ["role": "user", "content": "weather?"],
                [
                    "role": "assistant", "content": "Checking.",
                    "anthropic_thinking_blocks": wire,
                    "tool_calls": [
                        ["id": "toolu_1", "type": "function", "function": ["name": "weather", "arguments": "{}"]]
                    ],
                ],
                ["role": "tool", "tool_call_id": "toolu_1", "content": "sunny"],
            ],
        ])
        let messages = try #require(out["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        let content = try #require(assistant["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["thinking", "redacted_thinking", "text", "tool_use"])
        #expect(content[0]["signature"] as? String == "opaque-signature")
        #expect(content[0]["thinking"] as? String == "native thought")
        #expect(content[1]["data"] as? String == "opaque-redacted")
    }

    @Test func unsignedAndUnknownBlocksAreNotReplayed() {
        let kept = IntelAnthropicMessagesAdapter.replayableThinkingBlocks(of: [
            ["type": "thinking", "thinking": "no signature"],
            ["type": "thinking", "thinking": "empty", "signature": ""],
            ["type": "text", "text": "not thinking"],
            ["type": "redacted_thinking"],
            ["type": "thinking", "thinking": "ok", "signature": "sig"],
        ] as [[String: Any]])
        #expect(kept.count == 1)
        #expect(kept[0]["signature"] as? String == "sig")
    }

    @Test func chatMessageRoundTripsAndSurvivesRebuild() throws {
        let message = ChatMessage(
            role: "assistant", content: "Answer", reasoning_content: "thought",
            anthropic_thinking_blocks: [signed])
        let reloaded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        #expect(reloaded.anthropic_thinking_blocks == [signed])
        // The image-policy / media-bridge rebuild keeps the field.
        let rebuilt = message.replacingContentParts([.text("Answer")])
        #expect(rebuilt.anthropic_thinking_blocks == [signed])
        // A message without blocks encodes without the key.
        let plain = try JSONEncoder().encode(ChatMessage(role: "assistant", content: "hi"))
        #expect(!String(decoding: plain, as: UTF8.self).contains("anthropic_thinking_blocks"))
    }

    @Test func nonAnthropicWiresDropTheField() {
        let messages: [[String: Any]] = [
            ["role": "assistant", "content": "x", "anthropic_thinking_blocks": [["type": "thinking"]]],
            ["role": "user", "content": "y"],
        ]
        let stripped = IntelAnthropicMessagesAdapter.strippingThinkingBlocks(messages)
        #expect(stripped.allSatisfy { $0["anthropic_thinking_blocks"] == nil })
        #expect(stripped.count == 2)
    }

    @Test func hintRoundTripsAndIsASentinel() {
        let encoded = StreamingAnthropicThinkingHint.encode(signed)
        #expect(StreamingToolHint.isSentinel(encoded))
        #expect(StreamingAnthropicThinkingHint.decode(encoded) == signed)
        #expect(StreamingReasoningHint.decode(encoded) == nil)
        #expect(StreamingAnthropicThinkingHint.decode("plain text") == nil)
    }

    @Test @MainActor func signedBlocksSurviveSessionPersistence() throws {
        let turn = ChatTurn(role: .assistant, content: "Answer")
        turn.anthropicThinkingBlocks = [signed]
        let data = try JSONEncoder().encode(ChatTurnData(from: turn))
        let reloaded = ChatTurn(from: try JSONDecoder().decode(ChatTurnData.self, from: data))
        #expect(reloaded.anthropicThinkingBlocks == [signed])
        // An older saved turn (no field) loads with none.
        let legacy = try JSONDecoder().decode(
            ChatTurnData.self,
            from: Data(#"{"id":"\#(UUID().uuidString)","role":"assistant","content":"hi","createdAt":0}"#.utf8))
        #expect(legacy.anthropicThinkingBlocks.isEmpty)
    }

    @Test @MainActor func phoneContinuationReplaysBlocks() throws {
        var turn = ChatTurnData(id: UUID(), role: .assistant, content: "", createdAt: Date())
        turn.anthropicThinkingBlocks = [signed]
        let message = try #require(RemoteSessionContinuation.message(from: turn))
        #expect(message.anthropic_thinking_blocks == [signed])
    }
}
