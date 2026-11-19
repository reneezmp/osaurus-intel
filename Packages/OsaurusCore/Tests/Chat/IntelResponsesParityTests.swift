//
//  IntelResponsesParityTests.swift
//  OsaurusCoreTests
//
//  Stage 5d slice 3 (docs/COV_REAUDIT_STAGE5D_PROVIDER.md rows 9-14): the
//  Responses wire of the OpenAI preset and Codex, and the capability fallback
//  to Chat Completions. In-process scripted URLProtocol only: never the
//  network, a real provider, the real Router, the keychain or the Router
//  identity.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel Responses parity (5d slice 3)", .serialized)
struct IntelResponsesParityTests {
    private static let strictSchema: JSONValue = .object([
        "type": .string("object"), "additionalProperties": .bool(false),
        "required": .array([.string("a")]),
        "properties": .object(["a": .object(["type": .string("string")])]),
    ])

    private static var okStream: String {
        "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"ok\"}\n\n"
            + "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]}}\n\n"
    }

    private static var chatOK: String {
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}\n\n"
            + "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
    }

    private static func tool(_ name: String, _ schema: JSONValue) -> Tool {
        Tool(type: "function", function: ToolFunction(name: name, description: "d", parameters: schema))
    }

    // MARK: Rows 9, 12, 13: the OpenAI preset's Responses body

    @Test("OpenAI preset sends max_output_tokens, sampling, strict tools and the session cache key")
    func openAIPresetBody() async throws {
        let fixture = ResponsesFixture(host: "api.openai.com", steps: [.init(body: Self.okStream)])
        _ = try await fixture.run(type: .openResponses, model: "gpt-4.1") {
            $0.max_tokens = 321
            $0.session_id = "chat-1"
            $0.explicitSampling = ChatExplicitSampling(temperature: 0.4, topP: 0.8)
            $0.tools = [Self.tool("strict_tool", Self.strictSchema)]
        }
        let body = try #require(fixture.requestJSON(0))
        #expect(body["max_output_tokens"] as? Int == 321)
        #expect(body["temperature"] as? Double == 0.4)
        #expect(body["top_p"] as? Double == 0.8)
        #expect(body["prompt_cache_key"] as? String == "osaurus-session-chat-1")
        #expect(body["parallel_tool_calls"] as? Bool == true)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.first?["strict"] as? Bool == true)
        #expect(body["client_metadata"] == nil)
        #expect(fixture.requestPath(0) == "/v1/responses")
    }

    @Test("A reasoning model drops temperature and top_p; a non-strict tool is sent strict false")
    func reasoningModelDropsSamplers() async throws {
        let fixture = ResponsesFixture(host: "api.openai.com", steps: [.init(body: Self.okStream)])
        _ = try await fixture.run(type: .openResponses, model: "gpt-5") {
            $0.explicitSampling = ChatExplicitSampling(temperature: 0.4, topP: 0.8)
            $0.tools = [Self.tool("loose", .object(["type": .string("object")]))]
        }
        let body = try #require(fixture.requestJSON(0))
        #expect(body["temperature"] == nil && body["top_p"] == nil)
        #expect((body["tools"] as? [[String: Any]])?.first?["strict"] as? Bool == false)
        // No chat id: no cache key, as upstream.
        #expect(body["prompt_cache_key"] == nil)
        #expect(body["max_output_tokens"] == nil)
    }

    @Test("A custom host gets no prompt_cache_key; Codex gets no limits or sampling but a session key")
    func customHostAndCodex() async throws {
        let custom = ResponsesFixture(host: "gateway.invalid", steps: [.init(body: Self.okStream)])
        _ = try await custom.run(type: .openResponses, model: "gpt-4.1") { $0.session_id = "chat-2" }
        #expect(try #require(custom.requestJSON(0))["prompt_cache_key"] == nil)

        let codex = ResponsesFixture(host: "chatgpt.invalid", steps: [.init(body: Self.okStream)])
        _ = try await codex.run(type: .openAICodex, model: "gpt-5.5") {
            $0.max_tokens = 50
            $0.session_id = "chat-3"
            $0.explicitSampling = ChatExplicitSampling(temperature: 0.4)
        }
        let body = try #require(codex.requestJSON(0))
        #expect(body["max_output_tokens"] == nil && body["temperature"] == nil)
        let key = try #require(body["prompt_cache_key"] as? String)
        #expect(!key.isEmpty)
        let metadata = try #require((body["client_metadata"] as? [String: Any])?["x-codex-turn-metadata"] as? String)
        #expect(metadata.contains(key))
    }

    // MARK: Row 10: refusals

    @Test("A refusal surfaces as an error, not an empty turn")
    func refusalFailsTheTurn() async throws {
        let stream =
            "data: {\"type\":\"response.refusal.delta\",\"delta\":\"No.\"}\n\n"
            + "data: {\"type\":\"response.refusal.done\",\"refusal\":\"No.\"}\n\n"
        let fixture = ResponsesFixture(host: "api.openai.com", steps: [.init(body: stream)])
        do {
            _ = try await fixture.run(type: .openResponses, model: "gpt-4.1") { _ in }
            Issue.record("expected a refusal error")
        } catch {
            #expect(error.localizedDescription.contains("OpenAI refused this request: No."))
        }
        #expect(fixture.requestCount == 1)
    }

    @Test("An unknown event does not kill the turn")
    func unknownEventIgnored() async throws {
        let stream = "data: {\"type\":\"response.web_search_call.in_progress\",\"output_index\":0}\n\n" + Self.okStream
        let fixture = ResponsesFixture(host: "api.openai.com", steps: [.init(body: stream)])
        let out = try await fixture.run(type: .openResponses, model: "gpt-4.1") { _ in }
        #expect(out.joined() == "ok")
    }

    // MARK: Row 11: capability fallback

    @Test("A host with no /responses endpoint is retried once on Chat Completions")
    func fallsBackToChatCompletions() async throws {
        let fixture = ResponsesFixture(
            host: "compat.invalid",
            steps: [
                .init(status: 404, body: "{\"error\":{\"message\":\"Cannot POST /v1/responses\"}}"),
                .init(body: Self.chatOK),
            ])
        let out = try await fixture.run(type: .openResponses, model: "local-model") { $0.session_id = "chat-4" }
        #expect(out.joined() == "hi")
        #expect(fixture.requestCount == 2)
        #expect(fixture.requestPath(0) == "/v1/responses")
        #expect(fixture.requestPath(1) == "/v1/chat/completions")
        let second = try #require(fixture.requestJSON(1))
        #expect(second["messages"] is [[String: Any]])
        #expect(second["input"] == nil)
        #expect((second["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
    }

    @Test("Auth, model and rate failures and a wrong path never trigger the fallback")
    func noFallbackForOtherErrors() async throws {
        for (status, body) in [
            (401, "{\"error\":{\"message\":\"bad key\",\"code\":\"invalid_api_key\"}}"),
            (404, "{\"error\":{\"message\":\"model not found\",\"code\":\"model_not_found\",\"param\":\"model\"}}"),
            (404, "{\"error\":{\"message\":\"nope\"}}"),
            (429, "{\"error\":{\"message\":\"slow down\"}}"),
        ] {
            let fixture = ResponsesFixture(host: "compat.invalid", steps: [.init(status: status, body: body)])
            await #expect(throws: (any Error).self) {
                _ = try await fixture.run(type: .openResponses, model: "m") { _ in }
            }
            #expect(fixture.requestCount == 1)
        }
    }

    @Test("Codex never falls back, and the fallback runs at most once")
    func codexAndSecondFailure() async throws {
        let codex = ResponsesFixture(
            host: "chatgpt.invalid",
            steps: [.init(status: 404, body: "{\"error\":{\"code\":\"unsupported_endpoint\"}}")])
        await #expect(throws: (any Error).self) {
            _ = try await codex.run(type: .openAICodex, model: "gpt-5.5") { _ in }
        }
        #expect(codex.requestCount == 1)

        let twice = ResponsesFixture(
            host: "compat.invalid",
            steps: [
                .init(status: 404, body: "{\"error\":{\"code\":\"unsupported_endpoint\"}}"),
                .init(status: 404, body: "{\"error\":{\"code\":\"unsupported_endpoint\"}}"),
            ])
        await #expect(throws: (any Error).self) {
            _ = try await twice.run(type: .openResponses, model: "m") { _ in }
        }
        #expect(twice.requestCount == 2)
    }

    @Test("isUnsupportedEndpoint follows upstream")
    func unsupportedEndpointTable() throws {
        func check(_ status: Int, _ body: String, _ path: String = "/v1/responses") -> Bool {
            IntelResponsesCapabilityFallback.isUnsupportedEndpoint(
                status: status, body: Data(body.utf8), endpoint: URL(string: "https://h.invalid\(path)"))
        }
        #expect(check(404, "{\"error\":{\"code\":\"route_not_found\"}}"))
        #expect(check(405, "Cannot POST /v1/responses"))
        #expect(check(501, "responses endpoint is not supported"))
        #expect(!check(404, "Cannot POST /v1/responses", "/v1/chat/completions"))
        #expect(!check(500, "Cannot POST /v1/responses"))
        #expect(!check(404, "model_not_found: Cannot POST /responses"))
        #expect(!check(400, "{\"error\":{\"param\":\"model\",\"code\":\"unsupported_endpoint\"}}"))
        #expect(!check(404, "plain not found"))
    }
}

// MARK: - Fixture

private struct ResponsesStep {
    var status: Int = 200
    var body: String
}

private final class ResponsesFixture: @unchecked Sendable {
    let host: String
    init(host: String, steps: [ResponsesStep]) {
        self.host = host
        ResponsesFixtureProtocol.configure(host: host, steps: steps)
    }

    func reset(steps: [ResponsesStep]) { ResponsesFixtureProtocol.configure(host: host, steps: steps) }
    var requestCount: Int { ResponsesFixtureProtocol.snapshot().bodies.count }
    func requestJSON(_ i: Int) -> [String: Any]? {
        let bodies = ResponsesFixtureProtocol.snapshot().bodies
        guard bodies.indices.contains(i) else { return nil }
        return try? JSONSerialization.jsonObject(with: bodies[i]) as? [String: Any]
    }
    func requestPath(_ i: Int) -> String? {
        let paths = ResponsesFixtureProtocol.snapshot().paths
        return paths.indices.contains(i) ? paths[i] : nil
    }

    func run(
        type: RemoteProviderType, model: String, configure: (inout ChatCompletionRequest) -> Void
    ) async throws -> [String] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesFixtureProtocol.self]
        let provider = RemoteProvider(
            name: "Fixture", host: host, providerProtocol: .https, port: nil, basePath: "/v1",
            customHeaders: [:], authType: type == .openAICodex ? .openAICodexOAuth : .none, providerType: type,
            enabled: true, autoConnect: false, timeout: 5)
        // Codex gets in-memory fixture credentials: never the keychain.
        let credentials = IntelCodexCredentials(
            load: { _ in
                RemoteProviderOAuthTokens(
                    accessToken: "fixture-access", refreshToken: "fixture-refresh",
                    expiresAt: Date().addingTimeInterval(3600), accountId: "fixture-account")
            },
            refresh: { $0 },
            save: { _, _ in true })
        let engine = ChatEngine(
            provider: provider, session: URLSession(configuration: configuration), credentials: credentials)
        var request = ChatCompletionRequest(model: model, messages: [ChatMessage(role: "user", content: "hello")])
        configure(&request)
        let stream = try await engine.streamChat(request: request)
        var deltas: [String] = []
        for try await delta in stream { deltas.append(delta) }
        return deltas
    }
}

private final class ResponsesFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var host = ""
    nonisolated(unsafe) private static var queue: [ResponsesStep] = []
    nonisolated(unsafe) private static var bodies: [Data] = []
    nonisolated(unsafe) private static var paths: [String] = []
    static func configure(host: String, steps: [ResponsesStep]) {
        lock.lock(); defer { lock.unlock() }
        self.host = host
        queue = steps
        bodies = []
        paths = []
    }
    static func snapshot() -> (bodies: [Data], paths: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (bodies, paths)
    }
    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return request.url?.host == host
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
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
        Self.lock.lock()
        Self.bodies.append(sent)
        Self.paths.append(request.url?.path ?? "")
        let step = Self.queue.isEmpty ? ResponsesStep(body: "data: [DONE]\n\n") : Self.queue.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: step.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": step.status == 200 ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(step.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
