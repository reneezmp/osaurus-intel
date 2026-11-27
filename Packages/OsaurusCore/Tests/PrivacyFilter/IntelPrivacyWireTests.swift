//
//  IntelPrivacyWireTests.swift
//  OsaurusCoreTests
//
//  `W-privacy-filter` stage 3 (docs/W_PRIVACY_FILTER_PLAN.md): the Privacy
//  Filter wired into Intel's cloud engine. The engine runs against an in-process
//  HTTP fixture, never a provider; every value is synthetic.
//
//  Covers: master switch off leaves the send path untouched; on, the wire body
//  carries placeholders and the reply is restored; a send the filter cannot make
//  safe throws the typed error before any request; tool results and Responses
//  replay items are scrubbed per round; tool arguments are restored before a
//  tool runs; the Computer Use screen context block is scrubbed like the rest of
//  the user turn; HTTP status and error codes for non-interactive review.
//

import Foundation
import NIOHTTP1
import Testing

@testable import OsaurusCore

@Suite("Intel privacy wire", .serialized)
struct IntelPrivacyWireTests {
    private static let email = "alice.example@example.com"

    private static func provider() -> RemoteProvider {
        RemoteProvider(
            name: "PrivacyFixture", host: "privacy-fixture.invalid", providerProtocol: .https,
            port: nil, basePath: "/v1", customHeaders: [:], authType: .none,
            providerType: .openaiLegacy, enabled: true, autoConnect: false, timeout: 5)
    }

    private static func engine(mode: PrivacyReviewMode = .interactive) -> ChatEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivacyFixtureProtocol.self]
        return ChatEngine(
            source: .chatUI, provider: provider(), session: URLSession(configuration: configuration),
            privacyReviewMode: mode)
    }

    private static func request(_ text: String) -> ChatCompletionRequest {
        var request = ChatCompletionRequest(
            model: "fixture-model", messages: [ChatMessage(role: "user", content: text)])
        request.session_id = UUID().uuidString
        return request
    }

    private static func enabledConfig(alwaysApprove: Bool = true) -> PrivacyFilterConfiguration {
        var config = PrivacyFilterConfiguration()
        config.enabled = true
        config.alwaysApproveByDefault = alwaysApprove
        return config
    }

    private static func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await delta in stream where !StreamingToolHint.isSentinel(delta) { text += delta }
        return text
    }

    /// Reply that repeats the first placeholder found in the request body.
    private static let echoPlaceholder: @Sendable (String) -> String = { body in
        let token =
            body.range(of: #"\[[A-Z_]+_\d+\]"#, options: .regularExpression).map { String(body[$0]) } ?? "none"
        return PrivacyFixtureProtocol.sse(text: "Writing to \(token) now.")
    }

    // MARK: Master switch off

    @Test("Switch off: the body carries the real text and the reply is returned untouched")
    func offLeavesSendUnchanged() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyWire-off")
        defer { guard_.release() }
        PrivacyFilterStore.save(PrivacyFilterConfiguration())  // upstream default: master switch off
        #expect(!IntelPrivacyWire.isActive(providerId: Self.provider().id))

        // The reply contains placeholder-shaped text: with the filter off it must not be touched.
        PrivacyFixtureProtocol.configure { _ in PrivacyFixtureProtocol.sse(text: "Keep [EMAIL_1] as typed.") }
        let text = "Mail \(Self.email) please"
        let reply = try await Self.collect(try await Self.engine().streamChat(request: Self.request(text)))
        let body = PrivacyFixtureProtocol.bodies.first ?? ""
        #expect(body.contains(Self.email))
        #expect(body.range(of: #"\[[A-Z_]+_\d+\]"#, options: .regularExpression) == nil)
        #expect(reply == "Keep [EMAIL_1] as typed.")
        #expect(PrivacyFixtureProtocol.bodies.count == 1)
    }

    @Test("Switch off: the one-shot path sends and returns the same text")
    func offLeavesOneShotUnchanged() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyWire-off-oneshot")
        defer { guard_.release() }
        PrivacyFilterStore.save(PrivacyFilterConfiguration())
        PrivacyFixtureProtocol.configure { _ in PrivacyFixtureProtocol.json(text: "Reply [EMAIL_1]") }
        let response = try await Self.engine().completeChat(request: Self.request("Mail \(Self.email)"))
        #expect(PrivacyFixtureProtocol.bodies.first?.contains(Self.email) == true)
        #expect(response.choices.first?.message?.content == "Reply [EMAIL_1]")
    }

    // MARK: On

    @Test("Switch on: the wire carries a placeholder and the streamed reply gets the real value back")
    func onScrubsAndRestores() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyWire-on")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.enabledConfig())
        PrivacyFixtureProtocol.configure(Self.echoPlaceholder)
        let reply = try await Self.collect(
            try await Self.engine().streamChat(request: Self.request("Mail \(Self.email) please")))
        let body = PrivacyFixtureProtocol.bodies.first ?? ""
        #expect(!body.contains(Self.email))
        #expect(body.range(of: #"\[[A-Z_]+_\d+\]"#, options: .regularExpression) != nil)
        #expect(reply == "Writing to \(Self.email) now.")
    }

    @Test("Switch on: the one-shot path is scrubbed and its reply restored")
    func onScrubsOneShot() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyWire-on-oneshot")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.enabledConfig())
        PrivacyFixtureProtocol.configure { body in
            let token =
                body.range(of: #"\[[A-Z_]+_\d+\]"#, options: .regularExpression).map { String(body[$0]) } ?? "none"
            return PrivacyFixtureProtocol.json(text: "Title for \(token)")
        }
        let response = try await Self.engine().completeChat(request: Self.request("Mail \(Self.email)"))
        #expect(PrivacyFixtureProtocol.bodies.first?.contains(Self.email) == false)
        #expect(response.choices.first?.message?.content == "Title for \(Self.email)")
    }

    @Test("A provider the owner turned off is not scrubbed even with the master switch on")
    func providerOverrideOff() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyWire-override")
        defer { guard_.release() }
        var config = Self.enabledConfig()
        let provider = Self.provider()
        config.setProviderEnabled(provider.id, enabled: false)
        PrivacyFilterStore.save(config)
        #expect(!IntelPrivacyWire.isActive(providerId: provider.id))
        #expect(IntelPrivacyWire.isActive(providerId: UUID()))
    }

    // MARK: Blocked send

    @Test("No reviewer and a detection: the typed error is thrown and nothing is sent")
    func blockedSendThrowsBeforeAnyRequest() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyWire-blocked")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.enabledConfig(alwaysApprove: false))
        PrivacyFixtureProtocol.configure { _ in PrivacyFixtureProtocol.sse(text: "should not happen") }
        do {
            _ = try await Self.engine().streamChat(request: Self.request("Mail \(Self.email) please"))
            Issue.record("expected the send to be blocked")
        } catch let error as PrivacyFilterPipelineError {
            #expect(error == .reviewRequiresInteractive(detectionCount: 1))
        }
        #expect(PrivacyFixtureProtocol.bodies.isEmpty)
    }

    @Test("A delegated loop step (auto-scrub) goes through without a reviewer")
    func autoScrubModeSends() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyWire-autoscrub")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.enabledConfig(alwaysApprove: false))
        PrivacyFixtureProtocol.configure(Self.echoPlaceholder)
        let reply = try await Self.collect(
            try await Self.engine(mode: .autoScrub).streamChat(request: Self.request("Mail \(Self.email) please")))
        #expect(PrivacyFixtureProtocol.bodies.first?.contains(Self.email) == false)
        #expect(reply == "Writing to \(Self.email) now.")
    }

    @Test("Blocked sends map to 422 and a stable error code")
    func httpStatusAndCodes() {
        let blocked = PrivacyFilterPipelineError.reviewRequiresInteractive(detectionCount: 2)
        let mapped = HTTPHandler.inferenceHTTPStatus(for: blocked)
        #expect(mapped.status.code == 422)
        #expect(mapped.type == "privacy_filter")
        #expect(blocked.httpErrorCode == "privacy_filter_review_required")
        let leaked = HTTPHandler.inferenceHTTPStatus(for: PrivacyFilterPipelineError.scrubLeaked(categoryCounts: [.email: 1]))
        #expect(leaked.status.code == 422)
        // Everything else keeps its old mapping.
        #expect(HTTPHandler.inferenceHTTPStatus(for: CancellationError()).status.code == 499)
    }

    // MARK: Per-round scrub

    @Test("A tool result with fresh data is scrubbed on the next round, with the session's map")
    func toolResultScrubbedPerRound() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyWire-round")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.enabledConfig())
        let context = IntelPrivacyWire.Context(
            providerId: Self.provider().id, sessionId: UUID().uuidString, requestSource: .chatUI,
            reviewMode: .interactive)
        var wire: [[String: Any]] = [
            ["role": "user", "content": "Read the file"],
            [
                "role": "assistant", "content": "",
                "tool_calls": [
                    ["id": "call_1", "type": "function", "function": ["name": "file_read", "arguments": "{\"path\":\"a.txt\"}"]]
                ],
            ],
            ["role": "tool", "tool_call_id": "call_1", "content": "Contact: \(Self.email)"],
        ]
        var items: [[String: Any]] = []
        let map = try await IntelPrivacyWire.scrubRound(wire: &wire, items: &items, context: context)
        let tool = wire[2]["content"] as? String ?? ""
        #expect(!tool.contains(Self.email))
        #expect(tool.hasPrefix("Contact: ["))
        // Ids and roles are untouched.
        #expect(wire[2]["tool_call_id"] as? String == "call_1")
        #expect(wire[2]["role"] as? String == "tool")
        // The model's tool call comes back with the real value before the tool runs.
        let token = tool.dropFirst("Contact: ".count)
        let restored = await IntelPrivacyWire.unscrubArguments("{\"to\":\"\(token)\"}", map: map)
        #expect(restored == "{\"to\":\"\(Self.email)\"}")
    }

    @Test("Echoed tool-call arguments holding a real value are scrubbed on the next round")
    func echoedArgumentsScrubbed() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyWire-args")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.enabledConfig())
        let context = IntelPrivacyWire.Context(
            providerId: Self.provider().id, sessionId: UUID().uuidString, requestSource: .chatUI,
            reviewMode: .interactive)
        var wire: [[String: Any]] = [
            ["role": "user", "content": "Send a note to \(Self.email)"],
            [
                "role": "assistant", "content": "",
                "tool_calls": [
                    ["id": "c1", "type": "function", "function": ["name": "send", "arguments": "{\"to\":\"\(Self.email)\"}"]]
                ],
            ],
        ]
        var items: [[String: Any]] = []
        try await IntelPrivacyWire.scrubRound(wire: &wire, items: &items, context: context)
        let calls = wire[1]["tool_calls"] as? [[String: Any]]
        let arguments = (calls?.first?["function"] as? [String: Any])?["arguments"] as? String ?? ""
        #expect(!arguments.contains(Self.email))
        #expect(!(wire[0]["content"] as? String ?? "").contains(Self.email))
    }

    @Test("Responses replay items (tool output, function call, message) are scrubbed")
    func responsesItemsScrubbed() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyWire-items")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.enabledConfig())
        let context = IntelPrivacyWire.Context(
            providerId: Self.provider().id, sessionId: UUID().uuidString, requestSource: .chatUI,
            reviewMode: .interactive)
        var wire: [[String: Any]] = [["role": "user", "content": "Look it up"]]
        var items: [[String: Any]] = [
            ["type": "function_call", "call_id": "c1", "name": "lookup", "arguments": "{\"q\":\"x\"}"],
            ["type": "function_call_output", "call_id": "c1", "output": "Found \(Self.email)"],
            ["type": "reasoning", "encrypted_content": "opaque"],
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Also \(Self.email)"]]],
        ]
        try await IntelPrivacyWire.scrubRound(wire: &wire, items: &items, context: context)
        #expect(!(items[1]["output"] as? String ?? "").contains(Self.email))
        let parts = items[3]["content"] as? [[String: Any]]
        let partText = (parts?.first?["text"] as? String) ?? ""
        #expect(partText.hasPrefix("Also ["))
        #expect(!partText.contains(Self.email))
        // Opaque items and ids stay as they were.
        #expect(items[2]["encrypted_content"] as? String == "opaque")
        #expect(items[1]["call_id"] as? String == "c1")
    }

    // MARK: Computer Use screen context

    @Test("The screen-context block on the user turn is scrubbed with the rest of the turn")
    func screenContextScrubbed() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyWire-screen")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.enabledConfig())
        let text =
            "[Screen Context]\nDoing: reading mail from \(Self.email)\n[/Screen Context]\nSummarize my screen"
        PrivacyFixtureProtocol.configure(Self.echoPlaceholder)
        _ = try await Self.collect(try await Self.engine().streamChat(request: Self.request(text)))
        let body = PrivacyFixtureProtocol.bodies.first ?? ""
        #expect(!body.contains(Self.email))
        #expect(body.contains("Summarize my screen"))
    }

    // MARK: Insights

    @Test("The Insights probe is told the filter ran")
    func probeRecordsOutcome() {
        let probe = WireTransportProbe()
        probe.recordPrivacyFilter(applied: true, redactedCount: 2)
        #expect(probe.privacyOutcome == .init(applied: true, redactedCount: 2))
    }
}

private final class PrivacyFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [String] = []
    nonisolated(unsafe) private static var responder: @Sendable (String) -> String = { _ in "data: [DONE]\n\n" }

    static var bodies: [String] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    static func configure(_ responder: @escaping @Sendable (String) -> String) {
        lock.lock()
        defer { lock.unlock() }
        captured = []
        self.responder = responder
    }

    static func sse(text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        return """
            data: {"choices":[{"index":0,"delta":{"content":"\(escaped)"},"finish_reason":null}]}

            data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

            data: [DONE]

            """
    }

    static func json(text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        return """
            {"id":"x","object":"chat.completion","created":1,"model":"fixture-model","choices":[{"index":0,"message":{"role":"assistant","content":"\(escaped)"},"finish_reason":"stop"}]}
            """
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "privacy-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            stream.close()
            data = collected
        }
        let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
        Self.lock.lock()
        Self.captured.append(body)
        let reply = Self.responder(body)
        Self.lock.unlock()
        let isJSON = reply.hasPrefix("{")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": isJSON ? "application/json" : "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
