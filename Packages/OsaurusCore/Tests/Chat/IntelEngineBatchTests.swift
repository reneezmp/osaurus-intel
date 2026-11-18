//
//  IntelEngineBatchTests.swift
//  OsaurusCoreTests
//
//  Stage 5c rows 18 and 21 (upstream Classic `runBatchInParallel` and
//  `uniquelyIdentifiedInvocations`): once a call in a batch is refused, the
//  rest of the batch does not run and each gets a paired `rejected` envelope;
//  a batch whose calls share one `tool_call_id` (or have none) gets unique
//  ids. The engine talks to an in-process HTTP fixture, never a provider.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel engine tool batches", .serialized)
struct IntelEngineBatchTests {
    // MARK: - Row 21: unique ids

    @Test("The first occurrence of a call id is kept; duplicates and blanks are minted")
    func duplicateIdsAreMinted() {
        let ids = ChatEngine.uniquelyIdentifiedCallIds(["call_0", "call_0", "", "call_1", "call_0"])
        #expect(ids.count == 5)
        #expect(ids[0] == "call_0")
        #expect(ids[3] == "call_1")
        #expect(Set(ids).count == 5)
        for index in [1, 2, 4] { #expect(ids[index].hasPrefix("call_") && ids[index].count == 29) }
    }

    @Test("sanitizeToolSequence keeps duplicate ids as they are (so the engine must not emit them)")
    func sanitizeDoesNotRepairDuplicates() {
        let repaired = ChatEngine.sanitizeToolSequence([
            ["role": "user", "content": "go"],
            [
                "role": "assistant", "content": "",
                "tool_calls": [
                    ["id": "call_0", "type": "function", "function": ["name": "a", "arguments": "{}"]],
                    ["id": "call_0", "type": "function", "function": ["name": "b", "arguments": "{}"]],
                ],
            ],
            ["role": "tool", "tool_call_id": "call_0", "content": "A"],
            ["role": "tool", "tool_call_id": "call_0", "content": "B"],
        ])
        let calls = (repaired[1]["tool_calls"] as? [[String: Any]]) ?? []
        #expect(calls.compactMap { $0["id"] as? String } == ["call_0", "call_0"])
    }

    @Test("Two calls that share one id reach the app, and the next request, with different ids")
    func engineMintsDistinctIdsForASharedId() async throws {
        let deltas = try await Self.run(
            [Self.twoCallStream(first: "call_0", second: "call_0"), Self.textStream()]
        ) { $0.reportsToolStarts = true }
        let ids = deltas.compactMap { StreamingToolHint.decodeDone($0)?.callId }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        #expect(ids.first == "call_0")

        let body = try #require(FixtureProtocol.requestBodies.last)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let echoed = messages.compactMap { $0["tool_calls"] as? [[String: Any]] }.flatMap { $0 }.compactMap { $0["id"] as? String }
        let answered = messages.filter { $0["role"] as? String == "tool" }.compactMap { $0["tool_call_id"] as? String }
        #expect(Set(echoed).count == 2)
        #expect(echoed == answered)
    }

    // MARK: - Row 18: skip the rest after a refusal

    @Test("After a refused call the rest of the batch is skipped with a rejected envelope")
    func restOfBatchIsSkippedAfterARefusal() async throws {
        ToolRegistry.shared.setPolicy(.deny, for: "get_current_time")
        defer { ToolRegistry.shared.clearPolicy(for: "get_current_time") }
        let deltas = try await Self.run(
            [Self.twoCallStream(first: "call_a", second: "call_b"), Self.textStream()]
        ) { $0.reportsToolStarts = true }

        let done = deltas.compactMap(StreamingToolHint.decodeDone)
        #expect(done.count == 2)
        #expect(done[0].result.contains("was not run"))
        #expect(done[1].result.contains("\"kind\":\"rejected\"") || done[1].result.contains("\"kind\" : \"rejected\""))
        #expect(done[1].result.contains("Skipped: an earlier tool call in this batch was rejected"))
        // Only the refused call announced itself; the skipped one never started.
        #expect(deltas.compactMap(StreamingToolHint.decodeStarted).map(\.callId) == ["call_a"])
    }

    @Test("Without a refusal every call in the batch runs")
    func batchRunsWhenNothingIsRefused() async throws {
        let deltas = try await Self.run(
            [Self.twoCallStream(first: "call_a", second: "call_b"), Self.textStream()]
        ) { $0.reportsToolStarts = true }
        let done = deltas.compactMap(StreamingToolHint.decodeDone)
        #expect(done.count == 2)
        #expect(!done.contains { $0.result.contains("Skipped:") || $0.result.contains("was not run") })
    }

    @Test("The skip envelope is a rejected failure naming the tool")
    func skipEnvelopeShape() {
        let envelope = ChatEngine.skippedAfterRejectionResult(toolName: "file_write")
        #expect(ToolEnvelope.isError(envelope))
        #expect(envelope.contains("rejected"))
        #expect(envelope.contains("file_write"))
    }

    // MARK: - Fixture

    private static func twoCallStream(first: String, second: String) -> String {
        """
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"\(first)","type":"function","function":{"name":"get_current_time","arguments":"{}"}},{"index":1,"id":"\(second)","type":"function","function":{"name":"get_current_time","arguments":"{}"}}]},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """
    }

    private static func textStream() -> String {
        """
        data: {"choices":[{"index":0,"delta":{"content":"All done."},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
    }

    private static func run(
        _ responses: [String],
        configure: (inout ChatCompletionRequest) -> Void
    ) async throws -> [String] {
        FixtureProtocol.configure(responses: responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let provider = RemoteProvider(
            name: "Fixture", host: "batch-fixture.invalid", providerProtocol: .https,
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
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [String] = []
    nonisolated(unsafe) private static var bodies: [Data] = []
    static var requestBodies: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
    static func configure(responses: [String]) {
        lock.lock(); defer { lock.unlock() }
        queue = responses; bodies = []
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "batch-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        var sent = request.httpBody ?? Data()
        if sent.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                sent.append(buffer, count: n)
            }
            stream.close()
        }
        Self.bodies.append(sent)
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
