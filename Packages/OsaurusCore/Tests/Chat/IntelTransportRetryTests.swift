//
//  IntelTransportRetryTests.swift
//  OsaurusCoreTests
//
//  `W-cov-reaudit` stage 5c slice 6 (rows 11 and 12): upstream Classic's
//  connect-phase retry, 429 / 503 + Retry-After text, and the quarantine and
//  uncharged retry of a tool call cut off mid-stream. The engine talks to an
//  in-process URLProtocol fixture, never a provider.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Classification

struct IntelTransportClassificationTests {
    private func response(_ status: Int, retryAfter: String? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.invalid/v1")!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: retryAfter.map { ["Retry-After": $0] } ?? [:])!
    }

    @Test func retryAfterParsesSecondsAndDates() {
        #expect(IntelTransportRetry.parseRetryAfterSeconds("30") == 30)
        #expect(IntelTransportRetry.parseRetryAfterSeconds(" 5 ") == 5)
        #expect(IntelTransportRetry.parseRetryAfterSeconds("0") == nil)
        #expect(IntelTransportRetry.parseRetryAfterSeconds("soon") == nil)
        #expect(IntelTransportRetry.parseRetryAfterSeconds(nil) == nil)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let later = now.addingTimeInterval(90)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let parsed = IntelTransportRetry.parseRetryAfterSeconds(formatter.string(from: later), now: now)
        #expect(parsed == 90)
        #expect(IntelTransportRetry.parseRetryAfterSeconds(formatter.string(from: now.addingTimeInterval(-5)), now: now) == nil)
    }

    @Test func a429IsAlwaysARateLimitButA503NeedsTheHint() {
        guard case .rateLimited(let retryAfter, let status)? = IntelTransportRetry.rateLimited(from: response(429))
        else {
            Issue.record("429 should be a rate limit")
            return
        }
        #expect(retryAfter == nil && status == 429)
        #expect(IntelTransportRetry.rateLimited(from: response(503)) == nil)
        guard case .rateLimited(let hint, let code)? = IntelTransportRetry.rateLimited(from: response(503, retryAfter: "12"))
        else {
            Issue.record("503 with Retry-After should be a rate limit")
            return
        }
        #expect(hint == 12 && code == 503)
        #expect(IntelTransportRetry.rateLimited(from: response(500, retryAfter: "12")) == nil)
        #expect(IntelTransportRetry.rateLimited(from: response(400)) == nil)
    }

    @Test func theRateLimitTextIsUpstreams() {
        let withHint = CloudChatError.rateLimited(retryAfter: 29.2, statusCode: 429).localizedDescription
        #expect(withHint == "The provider rate-limited this request (HTTP 429). Retry in about 30s.")
        let without = CloudChatError.rateLimited(retryAfter: nil, statusCode: 429).localizedDescription
        #expect(without == "The provider rate-limited this request (HTTP 429). Retry shortly.")
        let unavailable = CloudChatError.rateLimited(retryAfter: 4, statusCode: 503).localizedDescription
        #expect(unavailable == "The provider is temporarily unavailable (HTTP 503). Retry in about 4s.")
        #expect(
            ChatErrorMessages.assistantMessage(for: CloudChatError.rateLimited(retryAfter: 4, statusCode: 429))
                == "Error: The provider rate-limited this request (HTTP 429). Retry in about 4s.")
    }

    @Test func onlyTransientConnectErrorsAreRetried() {
        for code in [
            URLError.Code.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
            .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed,
            .serverCertificateUntrusted, .resourceUnavailable,
        ] {
            #expect(IntelTransportRetry.isRetryableConnectError(URLError(code)))
        }
        #expect(!IntelTransportRetry.isRetryableConnectError(URLError(.cancelled)))
        #expect(!IntelTransportRetry.isRetryableConnectError(URLError(.userAuthenticationRequired)))
        #expect(!IntelTransportRetry.isRetryableConnectError(CancellationError()))
    }

    @Test func malformedArgumentsAreOnlyInvalidJson() {
        #expect(!IntelTransportRetry.argumentsAreMalformed(""))
        #expect(!IntelTransportRetry.argumentsAreMalformed("  "))
        #expect(!IntelTransportRetry.argumentsAreMalformed("{}"))
        #expect(!IntelTransportRetry.argumentsAreMalformed("{\"a\": [1, 2]}"))
        #expect(IntelTransportRetry.argumentsAreMalformed("{\"a\": \"Par"))
        #expect(IntelTransportRetry.argumentsAreMalformed("{\"a\": [1,"))
    }

    @Test func truncatedCallTextIsUpstreams() {
        let text = CloudChatError.truncatedToolCall(toolName: "file_write", finishMarker: "tool_calls")
            .localizedDescription
        #expect(text.hasPrefix("Streaming error: Stream ended before tool call 'file_write' arguments were complete"))
        #expect(text.contains("(finish marker: tool_calls)"))
    }
}

// MARK: - Engine

@Suite("Intel transport retry engine", .serialized)
struct IntelTransportRetryEngineTests {
    private static func frame(_ delta: String, finish: String? = nil) -> String {
        let reason = finish.map { "\"\($0)\"" } ?? "null"
        return "data: {\"choices\":[{\"index\":0,\"delta\":{\(delta)},\"finish_reason\":\(reason)}]}\n\n"
    }

    static func answer(_ text: String) -> String {
        frame("\"content\":\"\(text)\"") + frame("", finish: "stop") + "data: [DONE]\n\n"
    }

    /// A tool call whose argument string is `args` (already JSON-escaped).
    static func toolCall(args: String, narration: String? = nil) -> String {
        (narration.map { frame("\"content\":\"\($0)\"") } ?? "")
            + frame(
                "\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"get_current_time\",\"arguments\":\"\(args)\"}}]"
            ) + frame("", finish: "tool_calls") + "data: [DONE]\n\n"
    }

    static let cutArguments = "{\\\"zone\\\": \\\"Par"

    static let offeredTool = Tool(
        function: ToolFunction(
            name: "get_current_time", description: "Current time",
            parameters: .object(["type": .string("object"), "properties": .object([:])])))

    private func run(
        _ steps: [TransportFixtureProtocol.Step],
        interactive: Bool = true
    ) async throws -> (deltas: [String], bodies: [String]) {
        TransportFixtureProtocol.configure(steps: steps)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportFixtureProtocol.self]
        let provider = RemoteProvider(
            name: "Fixture", host: TransportFixtureProtocol.host, providerProtocol: .https,
            port: nil, basePath: "/v1", customHeaders: [:], authType: .none,
            providerType: .openaiLegacy, enabled: true, autoConnect: false, timeout: 5)
        let engine = ChatEngine(provider: provider, session: URLSession(configuration: configuration))
        let request = ChatCompletionRequest(
            model: "fixture-model", messages: [ChatMessage(role: "user", content: "What time is it?")],
            tools: [Self.offeredTool])
        var deltas: [String] = []
        do {
            let stream = try await ChatExecutionContext.$interactiveChatRun.withValue(interactive) {
                try await engine.streamChat(request: request)
            }
            for try await delta in stream { deltas.append(delta) }
        } catch {
            throw FixtureFailure(error: error, deltas: deltas, bodies: TransportFixtureProtocol.bodies)
        }
        return (deltas, TransportFixtureProtocol.bodies)
    }

    struct FixtureFailure: Error {
        let error: Error
        let deltas: [String]
        let bodies: [String]
    }

    private func failure(_ steps: [TransportFixtureProtocol.Step], interactive: Bool = true) async -> FixtureFailure? {
        do {
            _ = try await run(steps, interactive: interactive)
            return nil
        } catch let failure as FixtureFailure {
            return failure
        } catch {
            return nil
        }
    }

    @Test("A transient connect failure is retried with the same request")
    func connectFailureIsRetried() async throws {
        let (deltas, bodies) = try await run([
            .fail(.networkConnectionLost), .fail(.cannotConnectToHost), .sse(Self.answer("It is noon.")),
        ])
        #expect(deltas.last == "It is noon.")
        #expect(bodies.count == 3)
        #expect(Set(bodies).count == 1)  // a Router key rides in the body: identical, so deduped
    }

    @Test("The connect retry gives up after three attempts and reports the error")
    func connectRetryIsBounded() async {
        let failed = await failure([.fail(.timedOut), .fail(.timedOut), .fail(.timedOut), .sse(Self.answer("late"))])
        #expect((failed?.error as? URLError)?.code == .timedOut)
        #expect(failed?.bodies.count == 3)
    }

    @Test("A request that cannot succeed is not retried")
    func nonTransientConnectErrorIsNotRetried() async {
        let failed = await failure([.fail(.userAuthenticationRequired), .sse(Self.answer("x"))])
        #expect(failed?.bodies.count == 1)
    }

    @Test("429 with Retry-After reads as a rate limit and is not re-sent")
    func rateLimitIsClassified() async {
        let failed = await failure([.status(429, retryAfter: "7", body: "{\"error\":{\"message\":\"slow down\"}}")])
        #expect(failed?.bodies.count == 1)
        guard case .rateLimited(let retryAfter, let status)? = failed?.error as? CloudChatError else {
            Issue.record("Expected a rate limit, got \(String(describing: failed?.error))")
            return
        }
        #expect(retryAfter == 7 && status == 429)
        #expect(failed?.error.localizedDescription.contains("Retry in about 7s.") == true)
    }

    @Test("A plain 503 stays an ordinary HTTP error")
    func plain503IsAnHttpError() async {
        let failed = await failure([.status(503, retryAfter: nil, body: "{\"error\":{\"message\":\"down\"}}")])
        guard case .httpError(_, let status, _)? = failed?.error as? CloudChatError else {
            Issue.record("Expected an HTTP error, got \(String(describing: failed?.error))")
            return
        }
        #expect(status == 503)
    }

    @Test("A cut tool call is quarantined and the round re-asked, uncharged")
    func cutToolCallIsRetried() async throws {
        let (deltas, bodies) = try await run([
            .sse(Self.toolCall(args: Self.cutArguments)), .sse(Self.toolCall(args: Self.cutArguments)),
            .sse(Self.answer("It is noon.")),
        ])
        #expect(bodies.count == 3)
        #expect(Set(bodies).count == 1)  // same body, so same Router key
        #expect(deltas.last == "It is noon.")
        // The cut call never ran: no result card.
        #expect(!deltas.contains { StreamingToolHint.decodeDone($0) != nil })
    }

    @Test("After two retries the cut call is reported, not run")
    func cutToolCallIsReportedAfterTwoRetries() async {
        let cut = Self.toolCall(args: Self.cutArguments)
        let failed = await failure([.sse(cut), .sse(cut), .sse(cut), .sse(Self.answer("late"))])
        #expect(failed?.bodies.count == 3)
        guard case .truncatedToolCall(let name, let marker)? = failed?.error as? CloudChatError else {
            Issue.record("Expected a truncated-call error, got \(String(describing: failed?.error))")
            return
        }
        #expect(name == "get_current_time" && marker == "tool_calls")
    }

    @Test("Text already shown means no retry")
    func visibleTextBlocksTheRetry() async {
        let failed = await failure([
            .sse(Self.toolCall(args: Self.cutArguments, narration: "Checking the clock.")),
            .sse(Self.answer("late")),
        ])
        #expect(failed?.bodies.count == 1)
        #expect(failed?.error is CloudChatError)
    }

    @Test("API runs keep upstream's behaviour: no chat retry")
    func headlessRunsDoNotRetry() async {
        let failed = await failure(
            [.sse(Self.toolCall(args: Self.cutArguments)), .sse(Self.answer("late"))], interactive: false)
        #expect(failed?.bodies.count == 1)
    }

    @Test("A stream that drops before anything is shown is re-asked")
    func earlyDropIsRetried() async throws {
        let (deltas, bodies) = try await run([.dropAfterHead(.networkConnectionLost), .sse(Self.answer("Back."))])
        #expect(bodies.count == 2)
        #expect(deltas.last == "Back.")
    }

    @Test("A drop after text was shown surfaces the error instead")
    func dropAfterTextIsNotRetried() async {
        let failed = await failure([
            .dropAfterText("Half an ans", .networkConnectionLost), .sse(Self.answer("late")),
        ])
        #expect(failed?.bodies.count == 1)
        #expect((failed?.error as? URLError)?.code == .networkConnectionLost)
        #expect(failed?.deltas == ["Half an ans"])
    }

    @Test("Early drops are retried twice, then reported")
    func earlyDropIsBounded() async {
        let failed = await failure([
            .dropAfterHead(.networkConnectionLost), .dropAfterHead(.networkConnectionLost),
            .dropAfterHead(.networkConnectionLost), .sse(Self.answer("late")),
        ])
        #expect(failed?.bodies.count == 3)
        #expect((failed?.error as? URLError)?.code == .networkConnectionLost)
    }
}

final class TransportFixtureProtocol: URLProtocol, @unchecked Sendable {
    enum Step {
        case sse(String)
        case fail(URLError.Code)
        case status(Int, retryAfter: String?, body: String)
        case dropAfterHead(URLError.Code)
        case dropAfterText(String, URLError.Code)
    }

    static let host = "transport-fixture.invalid"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [Step] = []
    nonisolated(unsafe) private static var captured: [String] = []
    static var bodies: [String] { lock.lock(); defer { lock.unlock() }; return captured }
    static func configure(steps: [Step]) {
        lock.lock(); defer { lock.unlock() }
        queue = steps; captured = []
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.captured.append(String(decoding: body, as: UTF8.self))
        let step = Self.queue.isEmpty ? Step.sse("data: [DONE]\n\n") : Self.queue.removeFirst()
        Self.lock.unlock()
        func head(_ status: Int, _ fields: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
        }
        let sseHead = ["Content-Type": "text/event-stream"]
        switch step {
        case .sse(let text):
            client?.urlProtocol(self, didReceive: head(200, sseHead), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .status(let status, let retryAfter, let text):
            var fields = ["Content-Type": "application/json"]
            if let retryAfter { fields["Retry-After"] = retryAfter }
            client?.urlProtocol(self, didReceive: head(status, fields), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .dropAfterHead(let code):
            client?.urlProtocol(self, didReceive: head(200, sseHead), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .dropAfterText(let text, let code):
            client?.urlProtocol(self, didReceive: head(200, sseHead), cacheStoragePolicy: .notAllowed)
            let frame =
                "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\(text)\"},\"finish_reason\":null}]}\n\n"
            client?.urlProtocol(self, didLoad: Data(frame.utf8))
            // Let the engine read the text before the link drops (the failure
            // can otherwise overtake the buffered bytes).
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didFailWithError: URLError(code))
            }
        }
    }
    override func stopLoading() {}
}
