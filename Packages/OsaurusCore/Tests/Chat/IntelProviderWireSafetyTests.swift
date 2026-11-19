//
//  IntelProviderWireSafetyTests.swift
//  OsaurusCoreTests
//
//  Stage 5d slice 2 (docs/COV_REAUDIT_STAGE5D_PROVIDER.md rows 6, 7, 8, 15,
//  33, 34; upstream Classic #3266 and the stream framer). In-process scripted
//  URLProtocol only: never the network, a real provider, the real Router, the
//  keychain or the Router identity.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel provider wire safety (5d slice 2)", .serialized)
struct IntelProviderWireSafetyTests {
    // MARK: Row 6: top-level schema narrowing

    private static let anyOfSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["a": .object(["anyOf": .array([.object(["type": .string("string")])])])]),
        "anyOf": .array([.object(["required": .array([.string("a")])])]),
        "enum": .array([.string("x")]),
        "oneOf": .array([]), "allOf": .array([]), "const": .string("c"), "not": .object([:]),
    ])

    private static func tool(_ schema: JSONValue) -> Tool {
        Tool(type: "function", function: ToolFunction(name: "t", description: "d", parameters: schema))
    }

    @Test("Strict targets get the schema without top-level anyOf/oneOf/allOf/enum/const/not; nested keys stay")
    func strictTargetsLoseTopLevelKeywords() throws {
        let wire = try #require(ChatEngine.encodeTools([Self.tool(Self.anyOfSchema)], stripRestrictedTopLevelKeys: true))
        let params = try #require((wire[0]["function"] as? [String: Any])?["parameters"] as? [String: Any])
        #expect(Set(params.keys) == ["type", "properties"])
        let nested = (params["properties"] as? [String: Any])?["a"] as? [String: Any]
        #expect(nested?["anyOf"] != nil)
    }

    @Test("Other targets, and the request's own tools, keep the full schema")
    func otherTargetsKeepFullSchema() throws {
        let tool = Self.tool(Self.anyOfSchema)
        let wire = try #require(ChatEngine.encodeTools([tool]))
        let params = try #require((wire[0]["function"] as? [String: Any])?["parameters"] as? [String: Any])
        #expect(params["anyOf"] != nil && params["enum"] != nil)
        // Local validation reads the tool itself, which narrowing never touches.
        guard case .object(let local)? = tool.function.parameters else {
            Issue.record("no schema")
            return
        }
        #expect(local["anyOf"] != nil)
    }

    @Test("Which provider types and hosts are strict (upstream table)")
    func strictnessTable() {
        let strict = ChatEngine.enforcesTopLevelParameterSchemaRestrictions
        #expect(strict(.osaurusRouter, "router.example"))
        #expect(strict(.anthropic, "api.anthropic.com"))
        #expect(strict(.azureOpenAI, "x.openai.azure.com"))
        #expect(strict(.openAICodex, "chatgpt.com"))
        #expect(strict(.openResponses, "api.openai.com"))
        #expect(strict(.openaiLegacy, "API.OpenAI.com"))
        #expect(!strict(.openaiLegacy, "localhost"))
        #expect(!strict(.gemini, "generativelanguage.googleapis.com"))
    }

    @Test("The engine narrows tools on the wire for a strict host, not for a local one")
    func engineNarrowsOnlyForStrictHosts() async throws {
        let tools = [Self.tool(Self.anyOfSchema)]
        for (host, expectStripped) in [("api.openai.com", true), ("local-llm.invalid", false)] {
            let fixture = WireFixture(host: host, steps: [Self.textStream("ok")])
            _ = try await fixture.run(type: .openaiLegacy) { $0.tools = tools }
            let body = try #require(fixture.requestJSON(0))
            let sent =
                ((body["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])?["parameters"]
                as? [String: Any]
            #expect((sent?["anyOf"] == nil) == expectStripped)
        }
    }

    // MARK: Row 7: framing

    private static func events(
        _ text: String, options: OpenAICompatibleStreamFramer.Options = .strict
    ) async throws -> [String] {
        let bytes = Array(text.utf8)
        let stream = AsyncStream<UInt8> { continuation in
            for byte in bytes { continuation.yield(byte) }
            continuation.finish()
        }
        var out: [String] = []
        for try await event in IntelSSEEventSequence(base: stream, options: options) { out.append(event) }
        return out
    }

    @Test("`data:` without the space, LF, CR and CRLF line ends all parse")
    func lineEndsAndSpacing() async throws {
        #expect(try await Self.events("data:{\"a\":1}\n\ndata: {\"a\":2}\n\n") == ["{\"a\":1}", "{\"a\":2}"])
        #expect(try await Self.events("data: {\"a\":1}\r\n\r\ndata: [DONE]\r\n\r\n") == ["{\"a\":1}", "[DONE]"])
        #expect(try await Self.events("data: {\"a\":1}\r\rdata: {\"a\":2}\r\r") == ["{\"a\":1}", "{\"a\":2}"])
        // An unterminated last event is still delivered.
        #expect(try await Self.events("data: [DONE]") == ["[DONE]"])
        // Comments and other fields are ignored.
        #expect(try await Self.events(": ping\n\nevent: x\ndata: {\"a\":1}\n\n") == ["{\"a\":1}"])
    }

    @Test("Router mode takes raw JSON lines and one payload split across data: lines")
    func routerCompatible() async throws {
        let router = OpenAICompatibleStreamFramer.Options.routerCompatible
        #expect(try await Self.events("{\"a\":1}\n", options: router) == ["{\"a\":1}"])
        let split = try await Self.events("data: {\"a\":\ndata: 1}\n\n", options: router)
        #expect(split.count == 1)
        let repaired = OpenAICompatibleStreamFramer.repairedSplitDataJSONPayload(Data(split[0].utf8), options: router)
        let parsed = try JSONSerialization.jsonObject(with: try #require(repaired)) as? [String: Int]
        #expect(parsed == ["a": 1])
        // Strict mode does not accept a bare JSON line.
        #expect(try await Self.events("{\"a\":1}\n").isEmpty)
    }

    @Test("The engine streams a server that writes `data:` with no space and CRLF")
    func engineAcceptsSpacelessCRLF() async throws {
        let sse =
            "data:{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hi\"},\"finish_reason\":null}]}\r\n\r\n"
            + "data:{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\r\n\r\ndata:[DONE]\r\n\r\n"
        let fixture = WireFixture(host: "compat.invalid", steps: [sse])
        let deltas = try await fixture.run(type: .openaiLegacy) { _ in }
        #expect(deltas.joined() == "Hi")
        #expect(fixture.requestCount == 1)
    }

    // MARK: Row 8: slot resolution and name once

    @Test("Slot resolver: explicit index, id, last slot and new slots (upstream table)")
    func slotResolver() {
        var r = IntelToolCallSlotResolver()
        #expect(r.resolve(explicitIndex: nil, callId: "a", accumulatedSlots: []) == 0)
        #expect(r.resolve(explicitIndex: nil, callId: nil, accumulatedSlots: [0]) == 0)  // continuation
        #expect(r.resolve(explicitIndex: nil, callId: "b", accumulatedSlots: [0]) == 1)  // new call
        #expect(r.resolve(explicitIndex: nil, callId: "a", accumulatedSlots: [0, 1]) == 0)  // known id
        #expect(r.resolve(explicitIndex: 5, callId: "c", accumulatedSlots: [0, 1]) == 5)
        #expect(r.resolve(explicitIndex: nil, callId: "d", accumulatedSlots: [0, 1, 5]) == 6)
    }

    @Test("Two parallel calls without `index` get two slots; a repeated name is not doubled")
    func engineNoIndexAndRepeatedName() async throws {
        let sse = """
            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"id":"c1","type":"function","function":{"name":"get_current_time","arguments":"{"}}]}}]}

            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"function":{"name":"get_current_time","arguments":"}"}}]}}]}

            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"id":"c2","type":"function","function":{"name":"get_current_time","arguments":"{}"}}]}}]}

            data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """
        let fixture = WireFixture(host: "compat.invalid", steps: [sse, Self.textStream("done")])
        let deltas = try await fixture.run(type: .openaiLegacy) {
            $0.reportsToolStarts = true
            $0.tools = ToolRegistry.shared.openAISpecs().filter { $0.function.name == "get_current_time" }
        }
        let done = deltas.compactMap(StreamingToolHint.decodeDone)
        #expect(done.count == 2)
        let second = try #require(fixture.requestJSON(1))
        let calls =
            (second["messages"] as? [[String: Any]])?.compactMap { $0["tool_calls"] as? [[String: Any]] }.flatMap { $0 }
            ?? []
        let names = calls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        let args = calls.compactMap { ($0["function"] as? [String: Any])?["arguments"] as? String }
        #expect(names == ["get_current_time", "get_current_time"])
        #expect(args == ["{}", "{}"])
    }

    // MARK: Row 33: headers

    @Test("A custom header with CR/LF or control characters is not sent; a clean one is")
    func unsafeHeadersAreDropped() async throws {
        let fixture = WireFixture(
            host: "compat.invalid", steps: [Self.textStream("ok")],
            headers: ["X-Good": "fine", "X-Bad": "a\r\nInjected: 1", "X-Ctl": "a\u{01}b"])
        _ = try await fixture.run(type: .openaiLegacy) { _ in }
        let sent = fixture.requestHeaders(0)
        #expect(sent["X-Good"] == "fine")
        #expect(sent["X-Bad"] == nil && sent["X-Ctl"] == nil && sent["Injected"] == nil)
    }

    // MARK: Row 34: error text

    @Test("`detail` is read, and a long raw body is capped at 200 characters")
    func errorText() {
        #expect(extractAPIErrorMessage(#"{"detail":"Not authenticated"}"#) == "Not authenticated")
        #expect(extractAPIErrorMessage(#"{"error":{"message":"bad key"}}"#) == "bad key")
        let page = "<html>" + String(repeating: "x", count: 5000) + "</html>"
        let capped = extractAPIErrorMessage(page)
        #expect(capped.count == 203 && capped.hasSuffix("..."))
        #expect(extractAPIErrorMessage("plain gateway text") == "plain gateway text")
    }

    // MARK: Row 15: malformed Responses arguments

    @Test("A Responses tool call with invalid JSON arguments is never run")
    func malformedResponsesArgumentsAreQuarantined() async throws {
        let item =
            #"{"id":"fc1","type":"function_call","call_id":"c1","name":"get_current_time","arguments":"{\"tz\":","status":"completed"}"#
        let added =
            #"{"id":"fc1","type":"function_call","call_id":"c1","name":"get_current_time","arguments":"","status":"in_progress"}"#
        let sse = """
            data: {"type":"response.output_item.added","output_index":0,"item":\(added)}

            data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\\"tz\\":"}

            data: {"type":"response.output_item.done","output_index":0,"item":\(item)}

            data: {"type":"response.completed","response":{"id":"r1","status":"completed","output":[\(item)]}}

            """
        let fixture = WireFixture(host: "responses.invalid", steps: [sse, sse, sse])
        var failed = false
        do {
            let deltas = try await fixture.run(type: .openResponses, interactive: true) {
                $0.reportsToolStarts = true
                $0.tools = ToolRegistry.shared.openAISpecs().filter { $0.function.name == "get_current_time" }
            }
            #expect(deltas.compactMap(StreamingToolHint.decodeDone).isEmpty)
        } catch { failed = true }
        #expect(failed)
        #expect(fixture.requestCount <= 3)
    }

    private static func textStream(_ text: String) -> String {
        """
        data: {"choices":[{"index":0,"delta":{"content":"\(text)"},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
    }
}

// MARK: - Fixture

private final class WireFixture: @unchecked Sendable {
    let host: String
    let headers: [String: String]
    init(host: String, steps: [String], headers: [String: String] = [:]) {
        self.host = host
        self.headers = headers
        WireFixtureProtocol.configure(host: host, steps: steps)
    }

    var requestCount: Int { WireFixtureProtocol.bodiesSnapshot().count }
    func requestJSON(_ i: Int) -> [String: Any]? {
        let bodies = WireFixtureProtocol.bodiesSnapshot()
        guard bodies.indices.contains(i) else { return nil }
        return try? JSONSerialization.jsonObject(with: bodies[i]) as? [String: Any]
    }
    func requestHeaders(_ i: Int) -> [String: String] {
        let log = WireFixtureProtocol.headersSnapshot()
        return log.indices.contains(i) ? log[i] : [:]
    }

    func run(
        type: RemoteProviderType, interactive: Bool = false, configure: (inout ChatCompletionRequest) -> Void
    ) async throws -> [String] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WireFixtureProtocol.self]
        let provider = RemoteProvider(
            name: "Fixture", host: host, providerProtocol: .https,
            port: nil, basePath: "/v1", customHeaders: headers, authType: .none,
            providerType: type, enabled: true, autoConnect: false, timeout: 5)
        let engine = ChatEngine(provider: provider, session: URLSession(configuration: configuration))
        var request = ChatCompletionRequest(
            model: "fixture-model", messages: [ChatMessage(role: "user", content: "What time is it?")])
        configure(&request)
        let stream = try await ChatExecutionContext.$interactiveChatRun.withValue(interactive) {
            try await engine.streamChat(request: request)
        }
        var deltas: [String] = []
        for try await delta in stream { deltas.append(delta) }
        return deltas
    }
}

private final class WireFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var host = ""
    nonisolated(unsafe) private static var queue: [String] = []
    nonisolated(unsafe) private static var bodies: [Data] = []
    nonisolated(unsafe) private static var headerLog: [[String: String]] = []
    static func configure(host: String, steps: [String]) {
        lock.lock(); defer { lock.unlock() }
        self.host = host
        queue = steps
        bodies = []
        headerLog = []
    }
    static func bodiesSnapshot() -> [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
    static func headersSnapshot() -> [[String: String]] { lock.lock(); defer { lock.unlock() }; return headerLog }
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
        Self.headerLog.append(request.allHTTPHeaderFields ?? [:])
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
