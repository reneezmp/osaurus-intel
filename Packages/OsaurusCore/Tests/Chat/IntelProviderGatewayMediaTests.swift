//
//  IntelProviderGatewayMediaTests.swift
//  OsaurusCoreTests
//
//  Stage 5d slices 8 and 9 (docs/COV_REAUDIT_STAGE5D_PROVIDER.md rows 27, 29,
//  30, 31, 32; upstream Classic `handleGeminiEvent`, `geminiImageGenerateContent`,
//  `opencodeSessionHeaders`, `routerWireCompatibleMessages`,
//  `RemoteImagePayloadPolicy`). In-process scripted URLProtocol only: never the
//  network, a real provider, the real Router, the keychain or the Router
//  identity. Images stay in memory.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel gateway and media wire (5d slices 8-9)", .serialized)
struct IntelProviderGatewayMediaTests {
    // MARK: Row 27: Gemini MAX_TOKENS

    @Test("Gemini MAX_TOKENS becomes finish_reason length; STOP adds nothing")
    func maxTokensIsLength() throws {
        var translator = IntelGeminiSSETranslator()
        let lines = try translator.translate(
            #"data: {"candidates":[{"content":{"parts":[{"text":"cut"}]},"finishReason":"MAX_TOKENS"}]}"#)
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"content\":\"cut\""))
        #expect(lines[1].contains("\"finish_reason\":\"length\""))
        var stop = IntelGeminiSSETranslator()
        let done = try stop.translate(
            #"data: {"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}"#)
        #expect(done.count == 1)
    }

    @Test("The engine streams a Gemini MAX_TOKENS cut on the streaming URL")
    func engineSeesLength() async throws {
        let body =
            #"data: {"candidates":[{"content":{"parts":[{"text":"partial"}]},"finishReason":"MAX_TOKENS"}]}"# + "\n\n"
        let fixture = MediaFixture(host: "gemini.invalid", steps: [body])
        let deltas = try await fixture.run(type: .gemini, model: "gemini-2.5-flash")
        #expect(deltas.joined().contains("partial"))
        #expect(fixture.urls.first?.contains(":streamGenerateContent") == true)
    }

    // MARK: Row 29: Gemini image models

    @Test("Image models are recognised; text models are not")
    func imageModelDetection() {
        #expect(IntelGeminiAdapter.isImageCapableModel("gemini-3.1-flash-image-preview"))
        #expect(IntelGeminiAdapter.isImageCapableModel("gemini-2.5-flash-image"))
        #expect(!IntelGeminiAdapter.isImageCapableModel("gemini-2.5-flash"))
        #expect(
            IntelGeminiAdapter.generateURL(
                modelsEndpoint: "https://x.invalid/v1beta/models", model: "models/gemini-2.5-flash-image")
                == "https://x.invalid/v1beta/models/gemini-2.5-flash-image:generateContent")
    }

    @Test("Image request asks for modalities and image config from the model options")
    func imageRequestShape() throws {
        let body: [String: Any] = [
            "model": "gemini-2.5-flash-image", "messages": [["role": "user", "content": "a cat"]],
        ]
        let both = try IntelGeminiAdapter.makeRequest(
            chatCompletions: body,
            modelOptions: ["aspectRatio": .string("16:9"), "imageSize": .string("auto")])
        let generation = try #require(both["generationConfig"] as? [String: Any])
        #expect(generation["responseModalities"] as? [String] == ["TEXT", "IMAGE"])
        #expect((generation["imageConfig"] as? [String: Any])?["aspectRatio"] as? String == "16:9")
        #expect((generation["imageConfig"] as? [String: Any])?["imageSize"] == nil)
        let only = try IntelGeminiAdapter.makeRequest(
            chatCompletions: body, modelOptions: ["outputType": .string("imageOnly")])
        #expect((only["generationConfig"] as? [String: Any])?["responseModalities"] as? [String] == ["IMAGE"])
        let text = try IntelGeminiAdapter.makeRequest(
            chatCompletions: ["model": "gemini-2.5-flash", "messages": [["role": "user", "content": "hi"]]],
            modelOptions: ["outputType": .string("imageOnly")])
        #expect(text["generationConfig"] == nil)
    }

    @Test("An inline image part streams as markdown and comes back as inlineData with its signature")
    func inlineImageRoundTrip() throws {
        var translator = IntelGeminiSSETranslator(wholeBody: true)
        // Pretty-printed, as the non-streaming endpoint answers.
        let pretty = """
            {
              "candidates": [
                {
                  "content": { "parts": [
                    { "text": "here" },
                    { "inlineData": { "mimeType": "image/png", "data": "QUJD" }, "thoughtSignature": "sigX" }
                  ] },
                  "finishReason": "STOP"
                }
              ]
            }
            """
        var out: [String] = []
        for line in pretty.split(separator: "\n") { out += try translator.translate(String(line)) }
        #expect(out.count == 2)
        let content = out.compactMap { line -> String? in
            guard let data = line.dropFirst("data: ".count).data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let delta = ((json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])
            else { return nil }
            return delta["content"] as? String
        }
        #expect(content[0] == "here")
        #expect(content[1] == "\n\n![image|ts:sigX](data:image/png;base64,QUJD)\n\n")
        let back = try IntelGeminiAdapter.makeRequest(chatCompletions: [
            "model": "gemini-2.5-flash-image",
            "messages": [
                ["role": "user", "content": "draw"],
                ["role": "assistant", "content": "here" + content[1]],
                ["role": "user", "content": "bluer"],
            ],
        ])
        let contents = try #require(back["contents"] as? [[String: Any]])
        let parts = try #require(contents[1]["parts"] as? [[String: Any]])
        #expect(parts.count == 2)
        #expect((parts[0]["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "here")
        #expect((parts[1]["inlineData"] as? [String: Any])?["data"] as? String == "QUJD")
        #expect(parts[1]["thoughtSignature"] as? String == "sigX")
    }

    @Test("The engine posts generateContent for an image model and shows the image")
    func engineImageModel() async throws {
        let json =
            #"{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"QUJD"}}]},"finishReason":"STOP"}]}"#
        let fixture = MediaFixture(host: "gemini-image.invalid", steps: [json], contentType: "application/json")
        let deltas = try await fixture.run(type: .gemini, model: "gemini-2.5-flash-image")
        #expect(fixture.urls.first?.contains(":generateContent") == true)
        #expect(fixture.urls.first?.contains("streamGenerateContent") == false)
        #expect(deltas.joined().contains("data:image/png;base64,QUJD"))
        let generation = fixture.requestJSON(0)?["generationConfig"] as? [String: Any]
        #expect(generation?["responseModalities"] as? [String] == ["TEXT", "IMAGE"])
    }

    // MARK: Row 30: OpenCode session header

    @Test("OpenCode hosts are recognised, subdomains included")
    func openCodeHosts() {
        #expect(ChatEngine.isOpenCodeHost("opencode.ai"))
        #expect(ChatEngine.isOpenCodeHost("API.OpenCode.ai"))
        #expect(!ChatEngine.isOpenCodeHost("notopencode.ai"))
        #expect(!ChatEngine.isOpenCodeHost("example.com"))
    }

    @Test("An OpenCode host gets one stable x-opencode-session per conversation; a user header wins")
    func openCodeHeader() async throws {
        let ok = #"data: {"choices":[{"index":0,"delta":{"content":"hi"}}]}"# + "\n\ndata: [DONE]\n\n"
        let fixture = MediaFixture(host: "zen.opencode.ai", steps: [ok, ok])
        // One engine, two turns of the same conversation.
        _ = try await fixture.run(type: .openaiLegacy, sessionId: "conv-1", times: 2)
        let first = fixture.requestHeaders(0)["x-opencode-session"]
        #expect(first?.isEmpty == false)
        #expect(first != nil && first == fixture.requestHeaders(1)["x-opencode-session"])
        let plain = MediaFixture(host: "compat.invalid", steps: [ok])
        _ = try await plain.run(type: .openaiLegacy, sessionId: "conv-1")
        #expect(plain.requestHeaders(0)["x-opencode-session"] == nil)
        let custom = MediaFixture(host: "go.opencode.ai", steps: [ok], headers: ["X-OpenCode-Session": "mine"])
        _ = try await custom.run(type: .openaiLegacy, sessionId: "conv-1")
        let sent = custom.requestHeaders(0)
        #expect(sent.first { $0.key.lowercased() == "x-opencode-session" }?.value == "mine")
        #expect(sent.keys.filter { $0.lowercased() == "x-opencode-session" }.count == 1)
    }
}

// MARK: - Fixture

private final class MediaFixture: @unchecked Sendable {
    let host: String
    let headers: [String: String]
    init(host: String, steps: [String], headers: [String: String] = [:], contentType: String = "text/event-stream") {
        self.host = host
        self.headers = headers
        MediaFixtureProtocol.configure(host: host, steps: steps, contentType: contentType)
    }

    var urls: [String] { MediaFixtureProtocol.snapshot().urls }
    func requestJSON(_ i: Int) -> [String: Any]? {
        let bodies = MediaFixtureProtocol.snapshot().bodies
        guard bodies.indices.contains(i) else { return nil }
        return try? JSONSerialization.jsonObject(with: bodies[i]) as? [String: Any]
    }
    func requestHeaders(_ i: Int) -> [String: String] {
        let log = MediaFixtureProtocol.snapshot().headers
        return log.indices.contains(i) ? log[i] : [:]
    }

    func run(
        type: RemoteProviderType, model: String = "fixture-model", sessionId: String? = nil, times: Int = 1,
        messages: [ChatMessage] = [ChatMessage(role: "user", content: "hello")],
        configure: (inout ChatCompletionRequest) -> Void = { _ in }
    ) async throws -> [String] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaFixtureProtocol.self]
        let provider = RemoteProvider(
            name: "Fixture", host: host, providerProtocol: .https,
            port: nil, basePath: "/v1", customHeaders: headers, authType: .none,
            providerType: type, enabled: true, autoConnect: false, timeout: 5)
        let engine = ChatEngine(provider: provider, session: URLSession(configuration: configuration))
        var request = ChatCompletionRequest(model: model, messages: messages)
        request.session_id = sessionId
        configure(&request)
        var deltas: [String] = []
        for _ in 0 ..< times {
            deltas = []
            let stream = try await engine.streamChat(request: request)
            for try await delta in stream { deltas.append(delta) }
        }
        return deltas
    }
}

private final class MediaFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var host = ""
    nonisolated(unsafe) private static var contentType = "text/event-stream"
    nonisolated(unsafe) private static var queue: [String] = []
    nonisolated(unsafe) private static var bodies: [Data] = []
    nonisolated(unsafe) private static var headerLog: [[String: String]] = []
    nonisolated(unsafe) private static var urlLog: [String] = []
    static func configure(host: String, steps: [String], contentType: String) {
        lock.lock(); defer { lock.unlock() }
        self.host = host
        self.contentType = contentType
        queue = steps
        bodies = []
        headerLog = []
        urlLog = []
    }
    static func snapshot() -> (bodies: [Data], headers: [[String: String]], urls: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (bodies, headerLog, urlLog)
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
        Self.headerLog.append(request.allHTTPHeaderFields ?? [:])
        Self.urlLog.append(request.url?.absoluteString ?? "")
        let text = Self.queue.isEmpty ? "data: [DONE]\n\n" : Self.queue.removeFirst()
        let type = Self.contentType
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
