//
//  IntelLocalEndpointsTests.swift
//  OsaurusCoreTests
//
//  Stage 5d slice 7 (docs/COV_REAUDIT_STAGE5D_PROVIDER.md rows 23, 24, 26 and 35;
//  upstream Classic `DeltaContent`, `RemoteReasoningPolicy`,
//  `RemoteToolDetection`): local and compatible endpoints. Fixtures only: a
//  URLProtocol answers on `*.invalid` hosts, no network, no keychain, no real
//  provider.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel local and compatible endpoints (5d slice 7)", .serialized)
struct IntelLocalEndpointsTests {
    // MARK: Row 23: Mistral array content

    @Test("Mistral's content array splits into thinking and answer; other shapes are not arrays")
    func structuredContentSplits() throws {
        let value: [[String: Any]] = [
            ["type": "thinking", "thinking": [["type": "text", "text": "let me "], ["type": "text", "text": "think"]]],
            ["type": "text", "text": "Answer"],
            ["type": "text", "text": "!"],
        ]
        let split = try #require(IntelReasoningWire.structuredContent(value))
        #expect(split.thinking == "let me think")
        #expect(split.visible == "Answer!")
        #expect(IntelReasoningWire.structuredContent("plain") == nil)
        #expect(IntelReasoningWire.structuredContent(nil) == nil)
    }

    @Test("A streamed Mistral array reaches the Think panel and the answer")
    func engineSplitsMistralArray() async throws {
        let result = try await Self.run(
            host: "api.mistral.ai.fixture.invalid",
            frames: [
                #"{"choices":[{"index":0,"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"hmm"}]}]}}]}"#,
                #"{"choices":[{"index":0,"delta":{"content":[{"type":"text","text":"Hello"}]},"finish_reason":"stop"}]}"#,
            ])
        #expect(result.reasoning == "hmm")
        #expect(result.text == "Hello")
    }

    // MARK: Row 24: MiniMax

    @Test("MiniMax resolves by host or model id; DeepSeek echoes; everyone else strips")
    func policyResolution() {
        let wire = IntelReasoningWire.resolve
        #expect(wire(.openaiLegacy, "api.minimax.io", "MiniMax-M3").inbound == .inlineThink)
        #expect(wire(.openaiLegacy, "api.minimax.io", "MiniMax-M3").outbound == .embedAsThink)
        #expect(wire(.openaiLegacy, "api.atlascloud.ai", "minimaxai/minimax-m2.7").inbound == .inlineThink)
        #expect(wire(.openaiLegacy, "api.deepseek.com", "deepseek-v4-pro").outbound == .echoField)
        #expect(wire(nil, "api.deepseek.com", "deepseek-v4-pro").outbound == .echoField)
        #expect(wire(.openaiLegacy, "localhost", "deepseek-r1").outbound == .echoField)
        #expect(wire(.openaiLegacy, "localhost", "qwen3").outbound == .strip)
        #expect(wire(.osaurusRouter, "router", "deepseek-v4").outbound == .strip)
        #expect(wire(.anthropic, "api.anthropic.com", "minimax").outbound == .strip)
        #expect(wire(.openaiLegacy, "localhost", "qwen3").inbound == .separateField)
    }

    @Test("Inline <think> tags split to reasoning even across deltas, and an unclosed block is drained")
    func engineSplitsInlineThink() async throws {
        let result = try await Self.run(
            host: "fixture.invalid", model: "MiniMax-M2",
            frames: [
                #"{"choices":[{"index":0,"delta":{"content":"<thi"}}]}"#,
                #"{"choices":[{"index":0,"delta":{"content":"nk>plan it</th"}}]}"#,
                #"{"choices":[{"index":0,"delta":{"content":"ink>The answer"}}]}"#,
                #"{"choices":[{"index":0,"delta":{"content":" <think>unfinished"},"finish_reason":"stop"}]}"#,
            ])
        #expect(result.reasoning == "plan itunfinished")
        #expect(result.text == "The answer ")
        #expect(!result.text.contains("<think"))
    }

    @Test("A model that is not MiniMax keeps <think> text as it arrived")
    func otherModelsKeepTags() async throws {
        let result = try await Self.run(
            host: "fixture.invalid", model: "qwen3",
            frames: [#"{"choices":[{"index":0,"delta":{"content":"<think>x</think>y"},"finish_reason":"stop"}]}"#])
        #expect(result.text == "<think>x</think>y")
        #expect(result.reasoning.isEmpty)
    }

    @Test("MiniMax history carries prior reasoning inside <think>, never as reasoning_content")
    func miniMaxEmbedsHistory() async throws {
        let history = [
            ChatMessage(role: "user", content: "q1"),
            ChatMessage(role: "assistant", content: "a1", reasoning_content: "because"),
            ChatMessage(role: "user", content: "q2"),
        ]
        let sent = try await Self.sentMessages(host: "fixture.invalid", model: "MiniMax-M2", history: history)
        let assistant = try #require(sent.first { ($0["role"] as? String) == "assistant" })
        #expect(assistant["content"] as? String == "<think>\nbecause\n</think>\na1")
        #expect(assistant["reasoning_content"] == nil)
    }

    // MARK: Row 26: DeepSeek echo

    @Test("DeepSeek history echoes reasoning_content; a default provider drops it")
    func deepSeekEchoesHistory() async throws {
        let history = [
            ChatMessage(role: "user", content: "q1"),
            ChatMessage(role: "assistant", content: "a1", reasoning_content: "because"),
            ChatMessage(role: "user", content: "q2"),
        ]
        let deepSeek = try await Self.sentMessages(host: "fixture.invalid", model: "deepseek-v4-pro", history: history)
        let echoed = try #require(deepSeek.first { ($0["role"] as? String) == "assistant" })
        #expect(echoed["reasoning_content"] as? String == "because")
        #expect(echoed["content"] as? String == "a1")

        let other = try await Self.sentMessages(host: "fixture.invalid", model: "qwen3", history: history)
        let dropped = try #require(other.first { ($0["role"] as? String) == "assistant" })
        #expect(dropped["reasoning_content"] == nil)
        #expect(dropped["content"] as? String == "a1")
    }

    @Test("The tool-round echo carries the round's reasoning per the outbound policy")
    func outboundTransforms() {
        let message: [String: Any] = ["role": "assistant", "content": "calling", "tool_calls": [["id": "c1"]]]
        let echo = IntelReasoningWire.resolve(providerType: .openaiLegacy, host: "h", model: "deepseek-v4")
        #expect(echo.applyingOutbound(reasoning: "why", to: message)["reasoning_content"] as? String == "why")
        #expect(echo.applyingOutbound(reasoning: nil, to: message)["reasoning_content"] == nil)
        let embed = IntelReasoningWire.resolve(providerType: .openaiLegacy, host: "h", model: "minimax-m2")
        let folded = embed.applyingOutbound(reasoning: "why", to: message)
        #expect(folded["content"] as? String == "<think>\nwhy\n</think>\ncalling")
        #expect(folded["reasoning_content"] == nil)
        #expect(folded["tool_calls"] != nil)
        // Blank reasoning folds to nothing; an empty answer is not invented.
        #expect(embed.applyingOutbound(reasoning: "  ", to: ["role": "assistant", "content": ""])["content"] == nil)
        let strip = IntelReasoningWire.resolve(providerType: .openaiLegacy, host: "h", model: "qwen")
        #expect(strip.applyingOutbound(reasoning: "why", to: message)["reasoning_content"] == nil)
        // Only assistant messages are touched.
        #expect(echo.applyingOutbound(reasoning: "why", to: ["role": "user", "content": "x"])["reasoning_content"] == nil)
    }

    // MARK: Row 35: effort and the reasoning object

    private func effortBody(host: String, model: String, options: [String: ModelOptionValue]) async throws
        -> [String: Any]
    {
        var request = ChatCompletionRequest(model: model, messages: [ChatMessage(role: "user", content: "hi")])
        request.modelOptions = options
        let result = try await Self.run(
            host: host, model: model,
            frames: [#"{"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"#], request: request)
        return try #require(result.lastBody)
    }

    @Test("A compatible host gets reasoning_effort and the reasoning object")
    func compatibleHostGetsObject() async throws {
        let body = try await effortBody(
            host: "fixture.invalid", model: "qwen3", options: ["reasoningEffort": .string("high")])
        #expect(body["reasoning_effort"] as? String == "high")
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "high")
    }

    @Test("Mistral and openai.com get reasoning_effort only")
    func strictHostsGetNoObject() async throws {
        for host in ["api.mistral.ai.fixture.invalid", "openai.com.fixture.invalid"] {
            let body = try await effortBody(
                host: host, model: "some-model", options: ["reasoningEffort": .string("high")])
            #expect(body["reasoning_effort"] as? String == "high")
            #expect(body["reasoning"] == nil)
        }
    }

    @Test("Mistral takes none as a real effort; other hosts treat it as off")
    func noneOnMistral() async throws {
        let mistral = try await effortBody(
            host: "api.mistral.ai.fixture.invalid", model: "magistral", options: ["reasoningEffort": .string("none")])
        #expect(mistral["reasoning_effort"] as? String == "none")
        #expect(mistral["reasoning"] == nil)
        #expect(mistral["chat_template_kwargs"] == nil)

        let local = try await effortBody(
            host: "fixture.invalid", model: "qwen3", options: ["reasoningEffort": .string("none")])
        #expect(local["reasoning_effort"] == nil)
        #expect(local["reasoning"] == nil)
        #expect((local["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false)
    }

    @Test("openai.com takes none only for models whose table has it")
    func noneOnOpenAI() async throws {
        let accepting = "gpt-6-luna"
        try #require(ModelPickerItem.officialOpenAIAcceptsNoneEffort(modelId: accepting))
        let yes = try await effortBody(
            host: "openai.com.fixture.invalid", model: accepting, options: ["reasoningEffort": .string("none")])
        #expect(yes["reasoning_effort"] as? String == "none")
        #expect(yes["reasoning"] == nil)
        let no = try await effortBody(
            host: "openai.com.fixture.invalid", model: "gpt-4o", options: ["reasoningEffort": .string("none")])
        #expect(no["reasoning_effort"] == nil)
    }

    @Test("DeepSeek forwards only its own effort set; the 'instruct' alias is never a wire value")
    func deepSeekEffortSet() async throws {
        let high = try await effortBody(
            host: "api.deepseek.com.fixture.invalid", model: "deepseek-v4-pro",
            options: ["reasoningEffort": .string("high")])
        #expect(high["reasoning_effort"] as? String == "high")
        let odd = try await effortBody(
            host: "api.deepseek.com.fixture.invalid", model: "deepseek-v4-pro",
            options: ["reasoningEffort": .string("minimal")])
        #expect(odd["reasoning_effort"] == nil)
        let instruct = try await effortBody(
            host: "api.deepseek.com.fixture.invalid", model: "deepseek-v4-pro",
            options: ["reasoningEffort": .string("instruct")])
        #expect(instruct["reasoning_effort"] == nil)
        #expect((instruct["thinking"] as? [String: Any])?["type"] as? String == "disabled")
    }

    // MARK: Harness

    struct Outcome {
        var text = ""
        var reasoning = ""
        var proposed: [StreamingToolHint.ProposedCall] = []
        var lastBody: [String: Any]?
    }

    static func run(
        host: String, model: String = "fixture-model", frames: [String], request: ChatCompletionRequest? = nil
    ) async throws -> Outcome {
        LocalEndpointProtocol.configure(frames: frames)
        let provider = RemoteProvider(
            name: "Fixture", host: host, providerProtocol: .https,
            port: nil, basePath: "/v1", customHeaders: [:], authType: .none,
            providerType: .openaiLegacy, enabled: true, autoConnect: false, timeout: 60)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalEndpointProtocol.self]
        let engine = ChatEngine(provider: provider, session: URLSession(configuration: configuration))
        let turn =
            request
            ?? ChatCompletionRequest(model: model, messages: [ChatMessage(role: "user", content: "hi")])
        var outcome = Outcome()
        for try await delta in try await engine.streamChat(request: turn) {
            if let reasoning = StreamingReasoningHint.decode(delta) {
                outcome.reasoning += reasoning
            } else if let calls = StreamingToolHint.decodeProposed(delta) {
                outcome.proposed += calls
            } else if !StreamingToolHint.isSentinel(delta) && StreamingStatsHint.decode(delta) == nil
                && StreamingUsageHint.decode(delta) == nil
            {
                outcome.text += delta
            }
        }
        outcome.lastBody = LocalEndpointProtocol.lastBody()
        return outcome
    }

    private static func sentMessages(host: String, model: String, history: [ChatMessage]) async throws
        -> [[String: Any]]
    {
        let request = ChatCompletionRequest(model: model, messages: history)
        let result = try await run(
            host: host, model: model,
            frames: [#"{"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"#],
            request: request)
        return try #require(result.lastBody?["messages"] as? [[String: Any]])
    }
}

/// Records the request body and answers with the configured SSE frames.
final class LocalEndpointProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var frames: [String] = []
    nonisolated(unsafe) private static var bodies: [[String: Any]] = []
    static func configure(frames: [String]) {
        lock.lock()
        self.frames = frames
        bodies = []
        lock.unlock()
    }
    static func lastBody() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return bodies.last }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix("invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            stream.close()
            data = collected
        }
        Self.lock.lock()
        if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            Self.bodies.append(object)
        }
        let frames = Self.frames
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let lines = frames.map { "data: \($0)" } + ["data: [DONE]"]
        client?.urlProtocol(self, didLoad: Data((lines.joined(separator: "\n\n") + "\n\n").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
