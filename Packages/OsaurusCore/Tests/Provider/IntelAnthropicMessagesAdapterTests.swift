//
//  IntelAnthropicMessagesAdapterTests.swift
//  osaurusTests
//
//  W-provider-wire-formats (2026-10-10): the Anthropic Messages translation
//  in front of Intel's cloud engine.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelAnthropicMessagesAdapterTests {
    private func request(_ body: [String: Any]) throws -> [String: Any] {
        try IntelAnthropicMessagesAdapter.makeRequest(chatCompletions: body)
    }

    @Test func historyBecomesMessagesWithToolBlocks() throws {
        let out = try request([
            "model": "claude-sonnet-5",
            "stream": true,
            "stream_options": ["include_usage": true],
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": "be brief"],
                ["role": "user", "content": "weather in Paris and Rome?"],
                [
                    "role": "assistant", "content": "",
                    "tool_calls": [
                        ["id": "call_1", "type": "function", "function": ["name": "weather", "arguments": #"{"city":"Paris"}"#]],
                        ["id": "call_2", "type": "function", "function": ["name": "weather", "arguments": #"{"city":"Rome"}"#]],
                    ],
                ],
                ["role": "tool", "tool_call_id": "call_1", "content": "sunny"],
                ["role": "tool", "tool_call_id": "call_2", "content": ""],
            ],
            "tools": [["type": "function", "function": ["name": "weather", "description": "w", "parameters": ["type": "object"]]]],
            "tool_choice": "auto",
        ])
        #expect(out["system"] as? String == "be brief")
        #expect(out["max_tokens"] as? Int == 4096)
        #expect(out["stream"] as? Bool == true)
        #expect(out["stream_options"] == nil)
        // claude-sonnet-5 rejects sampler knobs (upstream list).
        #expect(out["temperature"] == nil)
        let messages = try #require(out["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        #expect(messages[0]["content"] as? String == "weather in Paris and Rome?")
        let toolUses = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(toolUses.map { $0["type"] as? String } == ["tool_use", "tool_use"])
        #expect((toolUses[0]["input"] as? [String: Any])?["city"] as? String == "Paris")
        // Both results ride in ONE user message; an empty result gets the marker.
        let results = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(messages[2]["role"] as? String == "user")
        #expect(results.map { $0["tool_use_id"] as? String } == ["call_1", "call_2"])
        #expect(results[1]["content"] as? String == IntelAnthropicMessagesAdapter.emptyToolResultMarker)
        let tools = try #require(out["tools"] as? [[String: Any]])
        #expect((tools[0]["input_schema"] as? [String: Any])?["properties"] != nil)
        #expect(tools[0]["eager_input_streaming"] as? Bool == true)
        #expect((out["tool_choice"] as? [String: Any])?["type"] as? String == "auto")
        // Last message is a tool result → 5-minute cache (no ttl).
        #expect((out["cache_control"] as? [String: Any])?["ttl"] == nil)
    }

    @Test func imagesBecomeImageBlocksAndHumanTurnsCacheForAnHour() throws {
        let out = try request([
            "model": "claude-haiku-4-5",
            "temperature": 0.2,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "what is this?"],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,AAAA"]],
                ],
            ]],
        ])
        #expect(out["temperature"] as? Double == 0.2)
        let messages = try #require(out["messages"] as? [[String: Any]])
        let blocks = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(blocks[0]["type"] as? String == "image")
        let source = try #require(blocks[0]["source"] as? [String: Any])
        #expect(source["media_type"] as? String == "image/jpeg")
        #expect(source["data"] as? String == "AAAA")
        #expect(blocks[1]["text"] as? String == "what is this?")
        #expect((out["cache_control"] as? [String: Any])?["ttl"] as? String == "1h")
    }

    @Test func streamEventsBecomeOpenAIChunks() throws {
        var translator = IntelAnthropicSSETranslator()
        let events = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":90,"output_tokens":1}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Let me check."}}"#,
            #"data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"weather","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"city\":"}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"Paris\"}"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        var lines: [String] = []
        for event in events { lines += try translator.translate(event) }
        let frames: [[String: Any]] = lines.compactMap { line in
            guard line.hasPrefix("data: "), line != "data: [DONE]" else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any]
        }
        func delta(_ frame: [String: Any]) -> [String: Any]? {
            ((frame["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any]
        }
        #expect(delta(frames[0])?["reasoning_content"] as? String == "hmm")
        #expect(delta(frames[1])?["content"] as? String == "Let me check.")
        let start = try #require((delta(frames[2])?["tool_calls"] as? [[String: Any]])?.first)
        #expect(start["index"] as? Int == 0)
        #expect(start["id"] as? String == "toolu_1")
        #expect((start["function"] as? [String: Any])?["name"] as? String == "weather")
        let args = frames[3...4].compactMap {
            ((delta($0)?["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any])?["arguments"] as? String
        }
        #expect(args.joined() == #"{"city":"Paris"}"#)
        let usage = try #require(frames[5]["usage"] as? [String: Any])
        #expect(usage["prompt_tokens"] as? Int == 100)
        #expect(usage["completion_tokens"] as? Int == 42)
        #expect(lines.last == "data: [DONE]")
    }

    @Test func streamErrorsThrow() {
        var translator = IntelAnthropicSSETranslator()
        #expect(throws: IntelAnthropicMessagesAdapter.Failure.self) {
            _ = try translator.translate(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
    }

    // MARK: - Reasoning from the Models API contract (upstream #3229)

    private func adaptive(disabled: Bool = true) -> AnthropicModelCapabilities {
        AnthropicModelCapabilities(
            thinking: .init(
                supported: true,
                types: .init(
                    adaptive: .init(supported: true), enabled: .init(supported: false),
                    disabled: .init(supported: disabled))),
            effort: .init(
                supported: true, low: .init(supported: true), medium: .init(supported: true),
                high: .init(supported: true)))
    }

    private var manualOnly: AnthropicModelCapabilities {
        AnthropicModelCapabilities(
            thinking: .init(
                supported: true,
                types: .init(
                    adaptive: .init(supported: false), enabled: .init(supported: true),
                    disabled: .init(supported: true))),
            effort: nil)
    }

    private let base: [String: Any] = [
        "model": "claude-opus-5-5", "stream": true, "temperature": 0.4,
        "messages": [["role": "user", "content": "hi"]],
    ]

    @Test func adaptiveModelsGetSummarizedThinkingAndThePickedEffort() throws {
        let out = try IntelAnthropicMessagesAdapter.makeRequest(
            chatCompletions: base, capabilities: adaptive(), effort: "high")
        let thinking = try #require(out["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["display"] as? String == "summarized")
        #expect((out["output_config"] as? [String: Any])?["effort"] as? String == "high")
        #expect(out["temperature"] == nil)
        let off = try IntelAnthropicMessagesAdapter.makeRequest(
            chatCompletions: base, capabilities: adaptive(), effort: "none")
        #expect((off["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect(off["output_config"] == nil)
    }

    @Test func uncataloguedModelsSendNoThinking() throws {
        let out = try IntelAnthropicMessagesAdapter.makeRequest(chatCompletions: base, effort: "high")
        #expect(out["thinking"] == nil)
        #expect(out["output_config"] == nil)
    }

    @Test func manualThinkingSendsABudgetAndDowngradesForcedToolChoice() throws {
        var body = base
        body["model"] = "claude-sonnet-4-5"
        body["tool_choice"] = "required"
        body["tools"] = [["type": "function", "function": ["name": "t", "parameters": ["type": "object"]]]]
        body["max_tokens"] = 20_000
        let out = try IntelAnthropicMessagesAdapter.makeRequest(
            chatCompletions: body, capabilities: manualOnly, effort: "medium")
        let thinking = try #require(out["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "enabled")
        #expect(thinking["budget_tokens"] as? Int == 8192)
        #expect((out["tool_choice"] as? [String: Any])?["type"] as? String == "auto")
        #expect(out["temperature"] == nil, "thinking drops the sampler knobs")
        // Thinking off on a model that accepts the knobs keeps them.
        let offOut = try IntelAnthropicMessagesAdapter.makeRequest(
            chatCompletions: base, capabilities: manualOnly, effort: "none")
        #expect(offOut["thinking"] == nil)
        #expect(offOut["temperature"] as? Double == 0.4)
    }
}
