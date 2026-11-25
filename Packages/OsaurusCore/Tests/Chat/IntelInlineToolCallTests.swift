//
//  IntelInlineToolCallTests.swift
//  OsaurusCoreTests
//
//  Stage 5d slice 7, row 25 (docs/COV_REAUDIT_STAGE5D_PROVIDER.md; upstream
//  Classic `RemoteToolDetection`, `dispatchFinal`): a tool call printed as JSON
//  in the reply is detected when tools were offered and none was streamed.
//  Fixtures only: no network, no real provider; calls are proposed
//  (`stopAtToolCalls`), never run.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel inline tool calls (5d slice 7, row 25)", .serialized)
struct IntelInlineToolCallTests {
    private static let weather = Tool(
        type: "function",
        function: ToolFunction(
            name: "get_weather", description: "Weather.",
            parameters: .object(["type": .string("object"), "properties": .object(["city": .object([:])])])))

    private static func proposed(frames: [String], tools: [Tool]?) async throws -> [StreamingToolHint.ProposedCall] {
        var request = ChatCompletionRequest(
            model: "fixture-model", messages: [ChatMessage(role: "user", content: "weather?")], tools: tools)
        request.stopAtToolCalls = true
        let result = try await IntelLocalEndpointsTests.run(host: "fixture.invalid", frames: frames, request: request)
        return result.proposed
    }

    @Test("Text JSON naming an offered tool becomes a tool call; the text stays visible")
    func inlineToolCallDetected() async throws {
        let frames = [
            #"{"choices":[{"index":0,"delta":{"content":"Sure. {\"name\":\"get_weather\",\"arguments\":{\"city\":\"SF\"}}"},"finish_reason":"stop"}]}"#
        ]
        let calls = try await Self.proposed(frames: frames, tools: [Self.weather])
        #expect(calls.count == 1)
        #expect(calls.first?.name == "get_weather")
        #expect(calls.first?.arguments.contains("\"city\":\"SF\"") == true)
        #expect(calls.first?.callId.hasPrefix("call_") == true)
    }

    @Test("Qwen-style <tool_call> wrappers are detected too")
    func inlineQwenWrapper() async throws {
        let frames = [
            #"{"choices":[{"index":0,"delta":{"content":"<tool_call>{\"name\":\"get_weather\",\"arguments\":{\"city\":\"NYC\"}}</tool_call>"},"finish_reason":"stop"}]}"#
        ]
        let calls = try await Self.proposed(frames: frames, tools: [Self.weather])
        #expect(calls.first?.name == "get_weather")
    }

    @Test("No tools offered, or a name that was not offered: nothing is run")
    func inlineToolCallNotInvented() async throws {
        let frames = [
            #"{"choices":[{"index":0,"delta":{"content":"{\"name\":\"get_weather\",\"arguments\":{}}"},"finish_reason":"stop"}]}"#
        ]
        #expect(try await Self.proposed(frames: frames, tools: nil).isEmpty)
        let other = Tool(
            type: "function",
            function: ToolFunction(name: "other_tool", description: "x", parameters: .object(["type": .string("object")])))
        #expect(try await Self.proposed(frames: frames, tools: [other]).isEmpty)
    }

    @Test("A structured tool call wins; the text is not scanned")
    func structuredCallWins() async throws {
        let frames = [
            #"{"choices":[{"index":0,"delta":{"content":"{\"name\":\"get_weather\",\"arguments\":{\"city\":\"A\"}}","tool_calls":[{"index":0,"id":"call_9","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"B\"}"}}]},"finish_reason":"tool_calls"}]}"#
        ]
        let calls = try await Self.proposed(frames: frames, tools: [Self.weather])
        #expect(calls.count == 1)
        #expect(calls.first?.callId == "call_9")
    }
}
