//
//  IntelProviderMoneyUsageTests.swift
//  OsaurusCoreTests
//
//  Stage 5d slice 1 (docs/COV_REAUDIT_STAGE5D_PROVIDER.md rows 1-5), against
//  an in-process scripted URLProtocol: never the network, a real provider,
//  the real Router, the keychain or the Router identity (the signer and the
//  account hooks are replaced for the run).
//    1. Router / Osaurus / Codex one-shots stream (upstream
//       `oneShotRequiresStreaming`), with the Router summary, a stable
//       idempotency key and the connect retry.
//    2. The Responses wire reports `response.usage`.
//    3. `clamp_to_balance: false` on Router requests only.
//    4. An in-stream error frame fails the turn, once.
//    5. Anthropic `stop_reason: "refusal"` fails the turn with its message.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel provider money and usage (5d slice 1)", .serialized)
struct IntelProviderMoneyUsageTests {
    fileprivate enum Step {
        case sse(String)
        case json(String)
        case fail(URLError.Code)
    }

    private static let routerModel = "osaurus/anthropic/claude-opus"

    private func makeEngine(_ type: RemoteProviderType, steps: [Step]) -> ChatEngine {
        MoneyFixtureProtocol.configure(steps: Self.encode(steps))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MoneyFixtureProtocol.self]
        let provider = RemoteProvider(
            name: "Fixture", host: "money-fixture.invalid", providerProtocol: .https,
            port: nil, basePath: type == .osaurusRouter ? "" : "/v1", customHeaders: [:],
            authType: .none, providerType: type, enabled: true, autoConnect: false, timeout: 5)
        return ChatEngine(provider: provider, session: URLSession(configuration: configuration))
    }

    private func request(model: String = "fixture-model") -> ChatCompletionRequest {
        ChatCompletionRequest(model: model, messages: [ChatMessage(role: "user", content: "Hello")])
    }

    /// Runs `body` with the Router signer and account hooks replaced, so the
    /// identity, the keychain and the shared account service are never touched.
    private func withRouterFixtures(
        summaries: Box<[OsaurusRouterSummaryEvent.Summary]> = Box([]),
        reconciles: Box<Int> = Box(0),
        _ body: () async throws -> Void
    ) async rethrows {
        let previousSigner = ChatEngine.routerSignerOverride
        let previousHooks = ChatEngine.routerAccountHooks
        ChatEngine.routerSignerOverride = { _, _ in }
        ChatEngine.routerAccountHooks = .init(
            noteSummary: { summary in summaries.mutate { $0.append(summary) } },
            reconcileWithoutSummary: { reconciles.mutate { $0 += 1 } })
        defer {
            ChatEngine.routerSignerOverride = previousSigner
            ChatEngine.routerAccountHooks = previousHooks
        }
        try await body()
    }

    private static func routerStream(text: String, costMicro: String = "1500") -> String {
        """
        data: {"choices":[{"index":0,"delta":{"content":"\(text)"},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"osaurus":{"request_id":"req-1","cost_micro":"\(costMicro)","status":"ok","token_source":"provider","input_tokens":10,"output_tokens":2}}

        data: [DONE]

        """
    }

    private func bodyJSON(_ index: Int) throws -> [String: Any] {
        let data = try #require(MoneyFixtureProtocol.requestBodies[safe: index])
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Row 1: one-shots stream

    @Test("Only the Router, Osaurus and Codex providers force streaming one-shots (upstream table)")
    func oneShotStreamingTable() {
        #expect(ChatEngine.oneShotRequiresStreaming(providerType: .osaurusRouter, authType: .none))
        #expect(ChatEngine.oneShotRequiresStreaming(providerType: .osaurus, authType: .none))
        #expect(ChatEngine.oneShotRequiresStreaming(providerType: .openAICodex, authType: .none))
        #expect(ChatEngine.oneShotRequiresStreaming(providerType: .openaiLegacy, authType: .openAICodexOAuth))
        #expect(!ChatEngine.oneShotRequiresStreaming(providerType: .openaiLegacy, authType: .none))
        #expect(!ChatEngine.oneShotRequiresStreaming(providerType: .anthropic, authType: .none))
    }

    @Test("A Router one-shot streams, carries one idempotency key and reports the summary")
    func routerOneShotStreamsWithSummary() async throws {
        let summaries = Box<[OsaurusRouterSummaryEvent.Summary]>([])
        try await withRouterFixtures(summaries: summaries) {
            let engine = makeEngine(.osaurusRouter, steps: [.sse(Self.routerStream(text: "A title"))])
            let response = try await engine.completeChat(request: request(model: Self.routerModel))
            // The text is clean: the billing hint never leaks into a one-shot.
            #expect(response.choices.first?.message?.content == "A title")
            #expect(MoneyFixtureProtocol.requestCount == 1)
            let body = try bodyJSON(0)
            #expect(body["stream"] as? Bool == true)
            #expect(body["clamp_to_balance"] as? Bool == false)
            let key = try #require(body["idempotency_key"] as? String)
            #expect(key.hasPrefix("auto-"))
            #expect(summaries.value.map(\.costMicro) == ["1500"])
        }
    }

    @Test("A connect retry of a Router one-shot re-sends the same signed body and key")
    func routerOneShotConnectRetryReusesTheKey() async throws {
        try await withRouterFixtures {
            let engine = makeEngine(
                .osaurusRouter,
                steps: [.fail(.networkConnectionLost), .sse(Self.routerStream(text: "ok"))])
            let response = try await engine.completeChat(request: request(model: Self.routerModel))
            #expect(response.choices.first?.message?.content == "ok")
            #expect(MoneyFixtureProtocol.requestCount == 2)
            let first = try #require(MoneyFixtureProtocol.requestBodies[safe: 0])
            let second = try #require(MoneyFixtureProtocol.requestBodies[safe: 1])
            #expect(first == second)
            let firstKey = try #require(try bodyJSON(0)["idempotency_key"] as? String)
            #expect(firstKey == (try bodyJSON(1)["idempotency_key"] as? String))
        }
    }

    @Test("Two logical one-shots never share a Router key")
    func separateOneShotsGetSeparateKeys() async throws {
        try await withRouterFixtures {
            let engine = makeEngine(.osaurusRouter, steps: [.sse(Self.routerStream(text: "a"))])
            _ = try await engine.completeChat(request: request(model: Self.routerModel))
            let first = try #require(try bodyJSON(0)["idempotency_key"] as? String)
            MoneyFixtureProtocol.configure(steps: Self.encode([.sse(Self.routerStream(text: "a"))]))
            _ = try await engine.completeChat(request: request(model: Self.routerModel))
            let second = try #require(try bodyJSON(0)["idempotency_key"] as? String)
            #expect(first != second)
        }
    }

    @Test("A non-Router one-shot keeps its non-streaming body, with no Router fields")
    func nonRouterOneShotIsUnchanged() async throws {
        let json = """
            {"id":"c1","object":"chat.completion","created":1,"model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"plain"},"finish_reason":"stop"}]}
            """
        let engine = makeEngine(.openaiLegacy, steps: [.json(json)])
        let response = try await engine.completeChat(request: request())
        #expect(response.choices.first?.message?.content == "plain")
        let body = try bodyJSON(0)
        #expect(body["stream"] as? Bool == false)
        #expect(body["clamp_to_balance"] == nil)
        #expect(body["idempotency_key"] == nil)
    }

    // MARK: Row 3: clamp_to_balance

    @Test("clamp_to_balance goes to the Router body only")
    func clampPolicyIsRouterOnly() throws {
        var router: [String: Any] = ["model": "m"]
        ChatEngine.applyRouterClampPolicy(to: &router, isOsaurusRouter: true)
        #expect(router["clamp_to_balance"] as? Bool == false)
        var other: [String: Any] = ["model": "m"]
        ChatEngine.applyRouterClampPolicy(to: &other, isOsaurusRouter: false)
        #expect(other["clamp_to_balance"] == nil)
    }

    @Test("A non-Router stream request carries neither clamp_to_balance nor an idempotency key")
    func nonRouterStreamBodyHasNoRouterFields() async throws {
        let engine = makeEngine(
            .openaiLegacy,
            steps: [.sse("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: [DONE]\n\n")])
        for try await _ in try await engine.streamChat(request: request()) {}
        let body = try bodyJSON(0)
        #expect(body["clamp_to_balance"] == nil)
        #expect(body["idempotency_key"] == nil)
    }

    // MARK: Row 4: in-stream error frame

    @Test("An in-stream error frame fails the turn with its message and is not retried")
    func errorFrameFailsTheTurnOnce() async throws {
        let engine = makeEngine(
            .openaiLegacy,
            steps: [
                .sse("data: {\"error\":{\"message\":\"Upstream exploded\",\"type\":\"server_error\"}}\n\ndata: [DONE]\n\n"),
                .sse("data: {\"choices\":[{\"delta\":{\"content\":\"second\"}}]}\n\ndata: [DONE]\n\n"),
            ])
        var failure: Error?
        do {
            for try await _ in try await engine.streamChat(request: request()) {}
        } catch { failure = error }
        let message = try #require(failure).localizedDescription
        #expect(message.contains("Upstream exploded"))
        #expect(MoneyFixtureProtocol.requestCount == 1)
    }

    @Test("A Router out-of-credits frame reaches the out-of-credits notice")
    func routerOutOfCreditsFrame() async throws {
        let reconciles = Box(0)
        try await withRouterFixtures(reconciles: reconciles) {
            let engine = makeEngine(
                .osaurusRouter,
                steps: [
                    .sse(
                        "data: {\"error\":{\"code\":\"INSUFFICIENT_FUNDS\",\"message\":\"balance below estimated max cost\"}}\n\n"
                    )
                ])
            var failure: Error?
            do {
                for try await _ in try await engine.streamChat(request: request(model: Self.routerModel)) {}
            } catch { failure = error }
            let error = try #require(failure)
            #expect(OsaurusRouter.isInsufficientFundsError(error.localizedDescription))
            #expect(
                ChatErrorMessages.assistantMessage(for: error)
                    == "Error: You're out of credits. Add credits to continue.")
            #expect(MoneyFixtureProtocol.requestCount == 1)
        }
    }

    @Test("Ordinary chunks and billing frames are not mistaken for errors")
    func normalFramesAreNotErrors() {
        let chunk: [String: Any] = ["choices": [["delta": ["content": "hi"]]]]
        #expect(ChatEngine.tryDecodeStreamError(chunk, isOsaurusRouter: false) == nil)
        let summary: [String: Any] = ["osaurus": ["cost_micro": "1"]]
        #expect(ChatEngine.tryDecodeStreamError(summary, isOsaurusRouter: true) == nil)
        let nullError: [String: Any] = ["error": NSNull()]
        #expect(ChatEngine.tryDecodeStreamError(nullError, isOsaurusRouter: false) == nil)
        let rate: [String: Any] = ["error": ["message": "Rate limited", "type": "rate_limit_error"]]
        #expect(ChatEngine.tryDecodeStreamError(rate, isOsaurusRouter: false) == "Rate limited")
        let routerFrame: [String: Any] = ["error": ["code": "INSUFFICIENT_FUNDS", "message": "low"]]
        #expect(ChatEngine.tryDecodeStreamError(routerFrame, isOsaurusRouter: true) == "INSUFFICIENT_FUNDS: low")
    }

    // MARK: Row 5: Anthropic refusal

    @Test("An Anthropic refusal fails the turn with its explanation and is not retried")
    func anthropicRefusalFails() async throws {
        let refusal = """
            event: message_start
            data: {"type":"message_start","message":{"usage":{"input_tokens":12,"output_tokens":1}}}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_sequence":null,"stop_details":{"type":"refusal","category":"cyber","explanation":"Blocked under the usage policy."}},"usage":{"output_tokens":4}}

            event: message_stop
            data: {"type":"message_stop"}

            """
        let engine = makeEngine(.anthropic, steps: [.sse(refusal), .sse(refusal), .sse(refusal)])
        var failure: Error?
        do {
            for try await _ in try await engine.streamChat(request: request()) {}
        } catch { failure = error }
        let message = try #require(failure).localizedDescription
        #expect(message.contains("refus"))
        #expect(message.contains("Blocked under the usage policy."))
        #expect(MoneyFixtureProtocol.requestCount == 1)
    }

    @Test("A normal Anthropic stop does not fail")
    func anthropicNormalStopStillWorks() async throws {
        let ok = """
            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"fine"}}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}

            event: message_stop
            data: {"type":"message_stop"}

            """
        let engine = makeEngine(.anthropic, steps: [.sse(ok)])
        var text = ""
        for try await delta in try await engine.streamChat(request: request()) { text += delta }
        #expect(text == "fine")
    }

    // MARK: Row 2: Responses usage

    private static func responsesStream(usage: String) -> String {
        """
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"Hello"}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"r1","status":"completed","output":[{"id":"m1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello"}]}]\(usage)}}

        """
    }

    @Test("The Responses wire reports provider usage to API callers that ask for it")
    func responsesUsageReachesTheCaller() async throws {
        let usage = ",\"usage\":{\"input_tokens\":120,\"output_tokens\":7,\"total_tokens\":127,\"input_tokens_details\":{\"cached_tokens\":64}}"
        let engine = makeEngine(.openResponses, steps: [.sse(Self.responsesStream(usage: usage))])
        var asked = request()
        asked.reportsUsage = true
        var deltas: [String] = []
        for try await delta in try await engine.streamChat(request: asked) { deltas.append(delta) }
        let reported = try #require(deltas.compactMap(StreamingUsageHint.decode).last)
        #expect(reported.promptTokens == 120)
        #expect(reported.completionTokens == 7)
    }

    @Test("A Responses round without usage reports none")
    func responsesWithoutUsageReportsNothing() async throws {
        let engine = makeEngine(.openResponses, steps: [.sse(Self.responsesStream(usage: ""))])
        var asked = request()
        asked.reportsUsage = true
        var deltas: [String] = []
        for try await delta in try await engine.streamChat(request: asked) { deltas.append(delta) }
        #expect(deltas.compactMap(StreamingUsageHint.decode).isEmpty)
    }

    @Test("response.usage needs both counts; cached tokens are clamped to the input")
    func responsesUsageParsing() throws {
        let full = IntelCodexResponsesUsage(response: [
            "usage": ["input_tokens": 10, "output_tokens": 2, "input_tokens_details": ["cached_tokens": 99]]
        ])
        #expect(full?.inputTokens == 10)
        #expect(full?.outputTokens == 2)
        #expect(full?.cachedInputTokens == 10)
        #expect(IntelCodexResponsesUsage(response: ["usage": ["input_tokens": 10]]) == nil)
        #expect(IntelCodexResponsesUsage(response: [:]) == nil)
    }
}

// MARK: - Fixtures

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private final class MoneyFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var steps: [Any] = []
    nonisolated(unsafe) private static var bodies: [Data] = []
    nonisolated(unsafe) private static var count = 0
    static var requestBodies: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    fileprivate static func configure(steps: [Any]) {
        lock.lock(); defer { lock.unlock() }
        self.steps = steps; bodies = []; count = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "money-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var sent = request.httpBody ?? Data()
        if sent.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&bytes, maxLength: bytes.count)
                if n <= 0 { break }
                sent.append(contentsOf: bytes.prefix(n))
            }
        }
        Self.lock.lock()
        Self.count += 1
        Self.bodies.append(sent)
        // The last step repeats, so an unexpected extra request is counted, not a crash.
        let step = Self.steps.isEmpty ? nil : (Self.steps.count > 1 ? Self.steps.removeFirst() : Self.steps[0])
        Self.lock.unlock()

        let url = request.url!
        func respond(_ text: String, type: String) {
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        switch step {
        case let text as String where text.hasPrefix("SSE:"):
            respond(String(text.dropFirst(4)), type: "text/event-stream")
        case let text as String where text.hasPrefix("JSON:"):
            respond(String(text.dropFirst(5)), type: "application/json")
        case let code as Int:
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        }
    }
    override func stopLoading() {}
}

extension IntelProviderMoneyUsageTests {
    fileprivate static func encode(_ steps: [Step]) -> [Any] {
        steps.map {
            switch $0 {
            case .sse(let text): return "SSE:" + text
            case .json(let text): return "JSON:" + text
            case .fail(let code): return code.rawValue
            }
        }
    }
}
