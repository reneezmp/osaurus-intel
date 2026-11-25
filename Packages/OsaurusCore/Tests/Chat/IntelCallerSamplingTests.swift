//
//  IntelCallerSamplingTests.swift
//  OsaurusCoreTests
//
//  Stage 5d slice 6, row 21 (docs/COV_REAUDIT_STAGE5D_PROVIDER.md; upstream
//  Classic `buildChatRequest`, `applyStopSequences`): an API or plugin
//  caller's temperature, top_p, penalties, stop and seed reach the provider,
//  and `stop` truncates client-side. Fixtures only: a URLProtocol answers on
//  `fixture.invalid`, no network, no keychain, no real provider.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel caller sampling (5d slice 6, row 21)", .serialized)
struct IntelCallerSamplingTests {
    private func caller(
        temperature: Double? = nil, topP: Double? = nil, frequency: Double? = nil,
        presence: Double? = nil, seed: Int? = nil, stop: [String]? = nil
    ) -> ChatExplicitSampling {
        ChatExplicitSampling(
            temperature: temperature, topP: topP, frequencyPenalty: frequency,
            presencePenalty: presence, seed: seed, stop: stop)
    }

    // MARK: merge

    @Test("An OpenAI-compatible wire carries every caller field")
    func chatCompletionsKeepsAll() {
        let sampling = caller(temperature: 0, topP: 0.5, frequency: 0.1, presence: 0.2, seed: 7, stop: ["END"])
        let merged = IntelSamplingWire.effectiveSampling(
            explicit: nil, caller: sampling, wire: .chatCompletions(acceptsExtensions: true))
        #expect(merged == sampling)
    }

    @Test("Wires that cannot carry a caller field drop it quietly, as upstream")
    func unrepresentableFieldsDrop() throws {
        let sampling = caller(temperature: 0.2, topP: 0.9, frequency: 0.1, presence: 0.2, seed: 7, stop: ["END"])
        let anthropic = IntelSamplingWire.effectiveSampling(explicit: nil, caller: sampling, wire: .anthropic)
        #expect(anthropic == caller(temperature: 0.2, topP: 0.9, stop: ["END"]))
        let gemini = IntelSamplingWire.effectiveSampling(explicit: nil, caller: sampling, wire: .gemini)
        #expect(gemini == caller(temperature: 0.2, topP: 0.9, seed: 7, stop: ["END"]))
        let responses = IntelSamplingWire.effectiveSampling(explicit: nil, caller: sampling, wire: .responses)
        #expect(responses == caller(temperature: 0.2, topP: 0.9))
        // Nothing the caller sent may turn into a hard error.
        var body: [String: Any] = [:]
        for wire in [IntelSamplingWire.Wire.anthropic, .gemini, .responses] {
            try IntelSamplingWire.apply(
                IntelSamplingWire.effectiveSampling(explicit: nil, caller: sampling, wire: wire),
                wire: wire, rejectsSamplers: false, providerLabel: "Fixture", into: &body)
        }
    }

    @Test("The agent's explicit sampling wins field by field; the caller fills the rest")
    func explicitWins() {
        let explicit = ChatExplicitSampling(temperature: 0.3, topK: 40, stop: ["AGENT"])
        let merged = IntelSamplingWire.effectiveSampling(
            explicit: explicit, caller: caller(temperature: 0, topP: 0.5, seed: 1, stop: ["API"]),
            wire: .chatCompletions(acceptsExtensions: true))
        #expect(merged?.temperature == 0.3)
        #expect(merged?.topP == 0.5)
        #expect(merged?.topK == 40)
        #expect(merged?.seed == 1)
        #expect(merged?.stop == ["AGENT"])
    }

    @Test("No caller sampling leaves the explicit sampling exactly as it was")
    func noCallerIsIdentity() {
        let explicit = ChatExplicitSampling(temperature: 0.3)
        #expect(
            IntelSamplingWire.effectiveSampling(explicit: explicit, caller: nil, wire: .anthropic) == explicit)
        #expect(IntelSamplingWire.effectiveSampling(explicit: nil, caller: nil, wire: .gemini) == nil)
    }

    // MARK: request fields

    @Test("seed decodes from the request body and is the caller's, not the chat's")
    func decodesSeed() throws {
        let json = """
            {"model":"m","messages":[{"role":"user","content":"hi"}],
             "temperature":0,"top_p":0.5,"seed":-5,"stop":["END"],"frequency_penalty":0.5}
            """
        var request = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(request.seed == -5)
        #expect(request.callerSampling == nil)
        request.adoptCallerSampling()
        #expect(request.callerSampling?.temperature == 0)
        #expect(request.callerSampling?.topP == 0.5)
        #expect(request.callerSampling?.seed == -5)
        #expect(request.callerSampling?.stop == ["END"])
        #expect(request.callerSampling?.frequencyPenalty == 0.5)
        #expect(request.explicitSampling == nil)
    }

    @Test("A request with none of the fields has no caller sampling")
    func emptyFields() {
        var request = ChatCompletionRequest(model: "m", messages: [ChatMessage(role: "user", content: "hi")])
        request.adoptCallerSampling()
        #expect(request.callerSampling == nil)
    }

    @Test("The API entry point marks the sampling as the caller's; the chat's request is untouched")
    func entryPoints() {
        let request = ChatCompletionRequest(
            model: "m", messages: [ChatMessage(role: "user", content: "hi")], temperature: 0.4)
        #expect(request.callerSampling == nil)
        #expect(IntelHTTPInference.engineRequest(request).callerSampling?.temperature == 0.4)
    }

    // MARK: truncation

    @Test("Stop truncation cuts at the first sequence and drops what follows")
    func truncation() {
        var stops = IntelStopSequences(["END", "", "END", "STOP"])
        #expect(stops.apply("hello") == "hello")
        #expect(!stops.hit)
        #expect(stops.apply("one END two") == "one ")
        #expect(stops.hit)
        #expect(stops.apply("later") == "")
        var none = IntelStopSequences([])
        #expect(none.isEmpty)
        #expect(none.apply("END") == "END")
    }

    @Test("The engine's stop set is the request's stop plus the agent's, without duplicates")
    func stopSet() {
        var request = ChatCompletionRequest(
            model: "m", messages: [ChatMessage(role: "user", content: "hi")], stop: ["A", "B"])
        request.explicitSampling = ChatExplicitSampling(stop: ["B", "C"])
        var stops = IntelStopSequences(request: request)
        #expect(stops.apply("xCy") == "x")
    }

    // MARK: engine, offline

    @Test("A cloud turn sends the caller's sampling and ends the reply at its stop sequence")
    func engineSendsAndTruncates() async throws {
        CallerSamplingProtocol.reset()
        var request = ChatCompletionRequest(
            model: "fixture-model", messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0, top_p: 0.5, frequency_penalty: 0.25, stop: ["END"])
        request.seed = 7
        request = IntelHTTPInference.engineRequest(request)
        let text = try await Self.run(request)
        #expect(text == "hello ")
        let body = try #require(CallerSamplingProtocol.lastBody())
        #expect(body["temperature"] as? Double == 0)
        #expect(body["top_p"] as? Double == 0.5)
        #expect(body["frequency_penalty"] as? Double == 0.25)
        #expect(body["seed"] as? Int == 7)
        #expect(body["stop"] as? [String] == ["END"])
    }

    @Test("The app's chat sends no sampling and is not truncated")
    func chatUnchanged() async throws {
        CallerSamplingProtocol.reset()
        // Same fields on the request, but not adopted: the chat's own request.
        let request = ChatCompletionRequest(
            model: "fixture-model", messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0, top_p: 0.5)
        let text = try await Self.run(request)
        #expect(text == "hello END world more")
        let body = try #require(CallerSamplingProtocol.lastBody())
        #expect(body["temperature"] == nil)
        #expect(body["top_p"] == nil)
        #expect(body["seed"] == nil)
        #expect(body["stop"] == nil)
    }

    private static func run(_ request: ChatCompletionRequest) async throws -> String {
        let provider = IntelChatTransportTests.provider()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CallerSamplingProtocol.self]
        let engine = ChatEngine(provider: provider, session: URLSession(configuration: configuration))
        var text = ""
        for try await delta in try await engine.streamChat(request: request)
        where !StreamingToolHint.isSentinel(delta) && StreamingReasoningHint.decode(delta) == nil
            && StreamingStatsHint.decode(delta) == nil && StreamingUsageHint.decode(delta) == nil
        {
            text += delta
        }
        return text
    }
}

/// Records the request body and answers with a fixed two-delta stream.
private final class CallerSamplingProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [[String: Any]] = []
    static func reset() { lock.lock(); bodies = []; lock.unlock() }
    static func lastBody() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return bodies.last }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
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
        if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            Self.lock.lock()
            Self.bodies.append(object)
            Self.lock.unlock()
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let frames = [
            #"data: {"choices":[{"index":0,"delta":{"content":"hello END world"}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"content":" more"},"finish_reason":"stop"}]}"#,
            "data: [DONE]",
        ]
        client?.urlProtocol(self, didLoad: Data((frames.joined(separator: "\n\n") + "\n\n").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
