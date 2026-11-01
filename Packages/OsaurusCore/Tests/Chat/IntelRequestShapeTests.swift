//
//  IntelRequestShapeTests.swift
//  OsaurusCoreTests
//
//  What Intel's engine puts on the wire, after the 1.0.61 (62) Rosy pass
//  (2026-11-01, docs/UPSTREAM_SYNC.md "Rosy candidate 1.0.61 fixes"):
//  the output cap the Router needs, Venice's own settings, and the per-turn
//  memory block on the user message instead of a mid-conversation system
//  message. Requests go to an in-process fixture, never a provider.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelRequestShapeTests {

    // MARK: - Output cap (upstream remoteChatMaxTokens)

    @Test func routerAndAnthropicAlwaysGetACap() {
        #expect(ChatEngine.streamMaxTokens(requested: nil, isOsaurusRouter: true, providerType: .osaurusRouter) == 16_384)
        #expect(ChatEngine.streamMaxTokens(requested: 2_000, isOsaurusRouter: true, providerType: .osaurusRouter) == 2_000)
        #expect(ChatEngine.streamMaxTokens(requested: nil, isOsaurusRouter: false, providerType: .anthropic) == 16_384)
    }

    @Test func otherProvidersGetOnlyTheCallersCap() {
        #expect(ChatEngine.streamMaxTokens(requested: nil, isOsaurusRouter: false, providerType: .openaiLegacy) == nil)
        #expect(ChatEngine.streamMaxTokens(requested: 512, isOsaurusRouter: false, providerType: .openaiLegacy) == 512)
        #expect(ChatEngine.streamMaxTokens(requested: nil, isOsaurusRouter: false, providerType: nil) == nil)
    }

    // A Router stream can't be captured here: its request is signed with the
    // Osaurus identity, which tests don't have. The Anthropic case in
    // `IntelCodexEngineTests` covers the same call site end to end.

    @Test func otherStreamCarriesNoCapUnlessAsked() async throws {
        let body = try await sentBody(providerType: .openaiLegacy, host: "shape-fixture.invalid")
        #expect(body["max_tokens"] == nil)
        let asked = try await sentBody(providerType: .openaiLegacy, host: "shape-fixture.invalid", maxTokens: 300)
        #expect(asked["max_tokens"] as? Int == 300)
    }

    // MARK: - Venice settings (upstream buildVeniceParameters)

    @Test func veniceSettingsReachVeniceOnly() throws {
        let options: [String: ModelOptionValue] = [
            "enableWebSearch": .string("auto"), "disableThinking": .bool(true),
            "includeVeniceSystemPrompt": .bool(false),
        ]
        let parameters = try #require(ChatEngine.veniceParameters(options, host: "api.venice.ai"))
        #expect(parameters["enable_web_search"] as? String == "auto")
        #expect(parameters["disable_thinking"] as? Bool == true)
        #expect(parameters["include_venice_system_prompt"] as? Bool == false)
        #expect(ChatEngine.veniceParameters(options, host: "api.openai.com") == nil)
    }

    @Test func veniceDefaultsSendNothing() {
        let defaults: [String: ModelOptionValue] = [
            "enableWebSearch": .string("off"), "includeVeniceSystemPrompt": .bool(true),
        ]
        #expect(ChatEngine.veniceParameters(defaults, host: "api.venice.ai") == nil)
        #expect(ChatEngine.veniceParameters(nil, host: "api.venice.ai") == nil)
    }

    @Test func veniceStreamCarriesTheSettings() async throws {
        let body = try await sentBody(
            providerType: .openaiLegacy, host: "api.venice.ai",
            options: ["includeVeniceSystemPrompt": .bool(false)])
        let parameters = try #require(body["venice_parameters"] as? [String: Any])
        #expect(parameters["include_venice_system_prompt"] as? Bool == false)
    }

    // MARK: - Memory block on the user message

    @Test func memoryBlockJoinsTheLatestUserMessage() {
        var messages = [
            ChatMessage(role: "system", content: "persona"),
            ChatMessage(role: "user", content: "hi"),
            ChatMessage(role: "assistant", content: "hello"),
            ChatMessage(role: "user", content: "season ground beef?"),
        ]
        SystemPromptComposer.injectMemoryPrefix("## Current local time\nnow", into: &messages)
        #expect(messages.count == 4)
        #expect(messages.filter { $0.role == "system" }.count == 1)
        #expect(messages[3].content == "[Memory]\n## Current local time\nnow\n[/Memory]\n\nseason ground beef?")
    }

    @Test func memoryBlockLeadsAnImageMessage() throws {
        var messages = [
            ChatMessage(
                role: "user", content: "what is this?",
                contentParts: [.text("what is this?"), .imageUrl(url: "data:image/png;base64,AA==", detail: nil)])
        ]
        SystemPromptComposer.injectMemoryPrefix("memory", into: &messages)
        let parts = try #require(messages[0].contentParts)
        #expect(parts.count == 3)
        guard case .text(let first) = parts[0] else {
            Issue.record("expected a leading text part")
            return
        }
        #expect(first == "[Memory]\nmemory\n[/Memory]\n\n")
        #expect(messages[0].imageUrls == ["data:image/png;base64,AA=="])
    }

    // MARK: - Fixture

    private func sentBody(
        providerType: RemoteProviderType, host: String, maxTokens: Int? = nil,
        options: [String: ModelOptionValue]? = nil
    ) async throws -> [String: Any] {
        ShapeFixtureProtocol.reset(host: host)
        let provider = RemoteProvider(
            name: "Fixture", host: host, providerProtocol: .https, port: nil, basePath: "/v1",
            customHeaders: [:], authType: .none, providerType: providerType, enabled: true,
            autoConnect: false, timeout: 5)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShapeFixtureProtocol.self]
        let engine = ChatEngine(
            source: .chatUI, model: "fixture-model", provider: provider,
            session: URLSession(configuration: configuration))
        var request = ChatCompletionRequest(
            model: "fixture-model", messages: [ChatMessage(role: "user", content: "hi")])
        request.max_tokens = maxTokens
        request.modelOptions = options
        for try await _ in try await engine.streamChat(request: request) {}
        let data = try #require(ShapeFixtureProtocol.lastBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class ShapeFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var host = ""
    nonisolated(unsafe) private static var body: Data?
    static var lastBody: Data? { lock.lock(); defer { lock.unlock() }; return body }
    static func reset(host: String) { lock.lock(); self.host = host; body = nil; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return request.url?.host == host
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
        Self.lock.lock(); Self.body = data; Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(
                "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
                    .utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
