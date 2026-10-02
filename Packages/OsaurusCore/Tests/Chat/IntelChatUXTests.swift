//
//  IntelChatUXTests.swift
//  OsaurusCoreTests
//
//  Intel checks for the `W-chat-ux` ports (docs/CHAT_UX_INTEL.md): the "@"
//  file menu's resolver and lister (upstream ships no test for them) and the
//  composer wiring that Intel's own views add.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel chat UX")
struct IntelChatUXTests {

    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("atmenu-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("b".utf8).write(to: root.appendingPathComponent("src/main.swift"))
        try Data("c".utf8).write(to: root.appendingPathComponent(".hidden"))
        return root
    }

    @Test("@ lists the work folder: folders first, dotfiles hidden until typed")
    func atMenuListsWorkFolder() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let all = AtFileMenu.list(query: "", rootPath: root)
        #expect(all.status == .ok)
        #expect(all.items.map(\.name) == ["docs", "src", "README.md"])
        #expect(all.items.first?.isDirectory == true)

        let filtered = AtFileMenu.list(query: "sr", rootPath: root)
        #expect(filtered.items.map(\.name) == ["src"])

        let nested = AtFileMenu.list(query: "src/", rootPath: root)
        #expect(nested.items.map(\.name) == ["main.swift"])
        // Temp paths may resolve through /private; compare the tail.
        #expect(nested.items.first?.path.hasSuffix("/src/main.swift") == true)

        let dot = AtFileMenu.list(query: ".h", rootPath: root)
        #expect(dot.items.map(\.name) == [".hidden"])

        let missing = AtFileMenu.list(query: "nope/", rootPath: root)
        #expect(missing.status == .notFound)
    }

    @Test("@ resolves absolute and tilde queries directly")
    func atMenuResolve() {
        let abs = AtFileMenu.resolve(query: "/etc/ho", rootPath: nil)
        #expect(abs.dir.path == "/etc")
        #expect(abs.filter == "ho")
        let tilde = AtFileMenu.resolve(query: "~/", rootPath: URL(fileURLWithPath: "/tmp"))
        #expect(tilde.dir.path == NSHomeDirectory())
        #expect(tilde.filter.isEmpty)
    }

    // MARK: - Follow-up suggestions

    @Test("Follow-up parsing keeps up to four clean questions")
    func followUpParse() {
        let json = #"Sure: ["What next?", "what next?", "How about {json}?", "Why?", "Where?", "When?"]"#
        #expect(FollowUpSuggestionService.parse(json) == ["What next?", "Why?", "Where?", "When?"])
        let list = "1. First one?\n- Second one?\n"
        #expect(FollowUpSuggestionService.parse(list) == ["First one?", "Second one?"])
        #expect(FollowUpSuggestionService.parse("").isEmpty)
    }

    @Test("Follow-ups are on by default and survive a chat.json round trip")
    @MainActor
    func followUpSettingDefault() {
        #expect(ChatConfiguration(hotkey: nil, systemPrompt: "").generateFollowUpSuggestions)
        let off = ChatConfiguration(hotkey: nil, systemPrompt: "", generateFollowUpSuggestions: false)
        let copy = ChatConfiguration(hotkey: nil, systemPrompt: "")
        copy.adopt(off)
        #expect(copy.generateFollowUpSuggestions == false)
    }

    @Test("Follow-ups go through the chat engine as an /internal one-shot")
    func followUpGeneration() async throws {
        FollowUpFixtureProtocol.body = #"""
            {"id":"f1","object":"chat.completion","created":1,"model":"m",
             "choices":[{"index":0,"message":{"role":"assistant","content":"[\"Can you expand?\", \"Any examples?\"]"},"finish_reason":"stop"}]}
            """#
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FollowUpFixtureProtocol.self]
        let provider = RemoteProvider(
            name: "FU", host: "followup-fixture.invalid", providerProtocol: .https,
            port: nil, basePath: "/v1", customHeaders: [:], authType: .none,
            providerType: .openaiLegacy, enabled: true, autoConnect: false, timeout: 5)
        let previous = FollowUpSuggestionService.engineFactory
        FollowUpSuggestionService.engineFactory = {
            ChatEngine(source: .chatUI, provider: provider, session: URLSession(configuration: configuration))
        }
        defer { FollowUpSuggestionService.engineFactory = previous }
        let model = "fu-probe-\(UUID().uuidString.prefix(6))"
        let result = await FollowUpSuggestionService.shared.generateSuggestions(
            userMessage: "Tell me about tides", assistantResponse: "Tides are caused by the moon.",
            fallbackModel: model, modelOverride: model)
        #expect(result == ["Can you expand?", "Any examples?"])
        var row: RequestLog?
        for _ in 0 ..< 100 where row == nil {
            row = await MainActor.run { InsightsService.shared.logs.first { $0.model == model } }
            if row == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        #expect(row?.path == "/internal/follow_up_suggestions")
        #expect(row?.source == .system)
    }

    @Test("No answer, no suggestions (and no request)")
    func followUpNeedsAnswer() async {
        let result = await FollowUpSuggestionService.shared.generateSuggestions(
            userMessage: "hi", assistantResponse: "   ", fallbackModel: nil)
        #expect(result.isEmpty)
    }
}

private final class FollowUpFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = ""
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "followup-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
