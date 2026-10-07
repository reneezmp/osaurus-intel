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

// MARK: - Activity roll-up and expand-thinking (W-chat-ux part 2)

@MainActor
@Suite("Intel activity roll-up", .serialized)
struct IntelActivityRollupTests {
    private func call(_ id: String, _ name: String = "file_read") -> ToolCall {
        ToolCall(id: id, type: "function", function: ToolCallFunction(name: name, arguments: "{}"))
    }

    /// user → (thinking + call) → tool result → (thinking + call) → answer.
    private func loopTurns() -> [ChatTurn] {
        let user = ChatTurn(role: .user, content: "Look into it")
        let step1 = ChatTurn(role: .assistant, content: "")
        step1.thinking = "Plan the first read."
        step1.toolCalls = [call("c1")]
        step1.toolResults = ["c1": #"{"ok":true}"#]
        step1.timeToFirstToken = 0.5
        let tool1 = ChatTurn(role: .tool, content: "result 1")
        let step2 = ChatTurn(role: .assistant, content: "")
        step2.thinking = "Now the second."
        step2.toolCalls = [call("c2", "shell_run")]
        step2.toolResults = ["c2": #"{"ok":true}"#]
        step2.timeToFirstToken = 0.4
        let tool2 = ChatTurn(role: .tool, content: "result 2")
        let answer = ChatTurn(role: .assistant, content: "Here is what I found.")
        answer.timeToFirstToken = 0.3
        return [user, step1, tool1, step2, tool2, answer]
    }

    private func withRollup<T>(_ enabled: Bool, _ body: () throws -> T) rethrows -> T {
        let key = ContentBlock.ActivityRollupSetting.defaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(enabled, forKey: key)
        ContentBlock.ActivityRollupSetting.invalidate()
        defer {
            UserDefaults.standard.set(previous, forKey: key)
            ContentBlock.ActivityRollupSetting.invalidate()
        }
        return try body()
    }

    @Test("Runs of two or more steps roll up; a paragraph breaks the run; one step stays bare")
    func rollupRules() {
        let turn = UUID()
        let think = ContentBlock(id: "t1", turnId: turn, kind: .thinking(index: 0, text: "x", isStreaming: false))
        let tools = ContentBlock(id: "g1", turnId: turn, kind: .toolCallGroup(calls: [ToolCallItem(call: call("a"), result: nil)]))
        let para = ContentBlock(
            id: "p1", turnId: turn, kind: .paragraph(index: 0, text: "hi", isStreaming: false, role: .assistant))
        let rolled = ContentBlock.rollupActivityBlocks([think, tools, para, think])
        #expect(rolled.map(\.id) == ["activity-t1", "p1", "t1"])
        #expect(ContentBlock.activityStepCount(of: [think, tools]) == 2)
        #expect(ContentBlock.enclosingActivityGroupId(forChildId: "g1", in: rolled) == "activity-t1")
        #expect(rolled[0].rendersToggleId("a"))  // a tool call nested in the roll-up
        #expect(!rolled[1].rendersToggleId("a"))
    }

    @Test("An agent loop becomes one Worked row with stats only under the answer")
    func memoizerRollsUpLoops() {
        withRollup(true) {
            let blocks = BlockMemoizer().blocks(from: loopTurns(), agentName: "A")
            let groups = blocks.filter { if case .activityGroup = $0.kind { return true } else { return false } }
            #expect(groups.count == 1)
            if case let .activityGroup(children) = groups.first?.kind {
                #expect(ContentBlock.activityStepCount(of: children) == 4)
            }
            let stats = blocks.filter { if case .generationStats = $0.kind { return true } else { return false } }
            #expect(stats.count == 1)
        }
    }

    @Test("Turning the switch off shows every step bare")
    func rollupSwitchOff() {
        withRollup(false) {
            let blocks = BlockMemoizer().blocks(from: loopTurns(), agentName: "A")
            #expect(!blocks.contains { if case .activityGroup = $0.kind { return true } else { return false } })
            #expect(blocks.contains { $0.id.hasPrefix("toolgroup-") })
        }
    }

    @Test("The switch is on by default (upstream)")
    func rollupDefault() {
        let key = ContentBlock.ActivityRollupSetting.defaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        ContentBlock.ActivityRollupSetting.invalidate()
        #expect(ContentBlock.ActivityRollupSetting.isEnabled)
        UserDefaults.standard.set(previous, forKey: key)
        ContentBlock.ActivityRollupSetting.invalidate()
    }

    @Test("Expand Thinking While Streaming opens the live thinking block and folds it when the answer starts")
    func expandThinkingWhileStreaming() async throws {
        try await ChatHistoryTestStorage.run {
            let key = ChatSession.expandThinkingWhileStreamingKey
            let previous = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            defer { UserDefaults.standard.set(previous, forKey: key) }

            let session = ChatSession()
            let user = ChatTurn(role: .user, content: "Think hard")
            let reply = ChatTurn(role: .assistant, content: "")
            reply.thinking = "Reasoning…"
            session.turns = [user, reply]
            session.isStreaming = true
            session.rebuildVisibleBlocks()
            let thinkingId = ContentBlock.thinkingBlockId(turnId: reply.id)
            #expect(session.expandedBlocksStore.isExpanded(thinkingId))

            reply.content = "The answer"
            session.rebuildVisibleBlocks()
            #expect(!session.expandedBlocksStore.isExpanded(thinkingId))
            session.isStreaming = false
        }
    }

    @Test("A finished reasoning-only reply opens its thinking once")
    func reasoningOnlySeed() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let reply = ChatTurn(role: .assistant, content: "")
            reply.thinking = "Only reasoning came back."
            session.turns = [ChatTurn(role: .user, content: "q"), reply]
            session.rebuildVisibleBlocks()
            let id = ContentBlock.thinkingBlockId(turnId: reply.id)
            #expect(session.expandedBlocksStore.isExpanded(id))
            session.expandedBlocksStore.collapse(id)
            session.rebuildVisibleBlocks()
            #expect(!session.expandedBlocksStore.isExpanded(id))  // a collapse sticks
        }
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
