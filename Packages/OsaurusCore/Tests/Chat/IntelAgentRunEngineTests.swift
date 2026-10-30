//
//  IntelAgentRunEngineTests.swift
//  OsaurusCoreTests
//
//  `W-server-api` stage 4c (docs/SERVER_API_INTEL.md): what `/agents/{id}/run`
//  asks of Intel's engine. A run gets a "started" marker before each tool it
//  runs (with the call id the "completed" marker carries), its own tool-round
//  limit, and usage summed over every model round. The engine talks to an
//  in-process HTTP fixture, never a real provider.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel agent-run engine", .serialized)
struct IntelAgentRunEngineTests {
    private static func toolCallStream(callId: String, usage: (Int, Int)?) -> String {
        """
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"\(callId)","type":"function","function":{"name":"get_current_time","arguments":"{}"}}]},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        \(usageLine(usage))data: [DONE]

        """
    }

    private static func textStream(usage: (Int, Int)?) -> String {
        """
        data: {"choices":[{"index":0,"delta":{"content":"All done."},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        \(usageLine(usage))data: [DONE]

        """
    }

    private static func usageLine(_ usage: (Int, Int)?) -> String {
        guard let usage else { return "" }
        return "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":\(usage.0),\"completion_tokens\":\(usage.1)}}\n\n"
    }

    private func run(
        _ responses: [String],
        configure: (inout ChatCompletionRequest) -> Void
    ) async throws -> [String] {
        RunFixtureProtocol.configure(responses: responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RunFixtureProtocol.self]
        let provider = RemoteProvider(
            name: "Fixture", host: "run-fixture.invalid", providerProtocol: .https,
            port: nil, basePath: "/v1", customHeaders: [:], authType: .none,
            providerType: .openaiLegacy, enabled: true, autoConnect: false, timeout: 5)
        let engine = ChatEngine(provider: provider, session: URLSession(configuration: configuration))
        var request = ChatCompletionRequest(
            model: "fixture-model",
            messages: [ChatMessage(role: "user", content: "What time is it?")])
        request.tools = ToolRegistry.shared.openAISpecs().filter { $0.function.name == "get_current_time" }
        configure(&request)
        var deltas: [String] = []
        for try await delta in try await engine.streamChat(request: request) { deltas.append(delta) }
        return deltas
    }

    @Test("A run hears each tool start, with the call id its result carries")
    func startedMarkerPrecedesTheResult() async throws {
        let deltas = try await run([Self.toolCallStream(callId: "call_7", usage: nil), Self.textStream(usage: nil)]) {
            $0.reportsToolStarts = true
        }
        let startedIndex = try #require(deltas.firstIndex { StreamingToolHint.decodeStarted($0) != nil })
        let doneIndex = try #require(deltas.firstIndex { StreamingToolHint.decodeDone($0) != nil })
        #expect(startedIndex < doneIndex)
        let started = try #require(StreamingToolHint.decodeStarted(deltas[startedIndex]))
        #expect(started.callId == "call_7")
        #expect(started.name == "get_current_time")
        #expect(StreamingToolHint.decodeDone(deltas[doneIndex])?.callId == "call_7")
    }

    @Test("Chats never get the started marker")
    func noStartedMarkerUnlessAsked() async throws {
        let deltas = try await run([Self.toolCallStream(callId: "call_1", usage: nil), Self.textStream(usage: nil)]) { _ in }
        #expect(!deltas.contains { StreamingToolHint.decodeStarted($0) != nil })
        #expect(deltas.contains { StreamingToolHint.decodeDone($0) != nil })
    }

    @Test("A run's own tool-round limit ends it with ToolRoundLimitReached")
    func runToolRoundLimit() async throws {
        await #expect(throws: ChatEngine.ToolRoundLimitReached.self) {
            _ = try await run([Self.toolCallStream(callId: "call_1", usage: nil)]) { $0.maxToolRounds = 1 }
        }
        #expect(RunFixtureProtocol.requestCount == 1)
    }

    @Test("Usage is summed over every model round")
    func usageSumsRounds() async throws {
        let deltas = try await run([
            Self.toolCallStream(callId: "call_1", usage: (10, 2)), Self.textStream(usage: (20, 3)),
        ]) { $0.reportsUsage = true }
        let usage = try #require(deltas.compactMap(StreamingUsageHint.decode).last)
        #expect(usage.promptTokens == 30)
        #expect(usage.completionTokens == 5)
    }

    @Test("A round with no measured usage leaves the run's usage unreported")
    func incompleteUsageIsNotReported() async throws {
        let deltas = try await run([
            Self.toolCallStream(callId: "call_1", usage: (10, 2)), Self.textStream(usage: nil),
        ]) { $0.reportsUsage = true }
        #expect(deltas.compactMap(StreamingUsageHint.decode).isEmpty)
    }

    @Test("The started marker is an in-band hint, never text")
    func startedMarkerIsASentinel() {
        let encoded = StreamingToolHint.encodeStarted(callId: "c", name: "n", arguments: "{\"a\":1}")
        #expect(StreamingToolHint.isSentinel(encoded))
        #expect(IntelHTTPInference.classify(encoded) == nil)
        #expect(StreamingToolHint.decodeStarted(encoded) == .init(callId: "c", name: "n", arguments: "{\"a\":1}"))
    }
}

private final class RunFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [String] = []
    nonisolated(unsafe) private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func configure(responses: [String]) {
        lock.lock(); defer { lock.unlock() }
        queue = responses; count = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "run-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let text = Self.queue.isEmpty ? "data: [DONE]\n\n" : Self.queue.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
