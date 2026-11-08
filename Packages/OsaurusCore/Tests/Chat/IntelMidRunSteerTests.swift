//
//  IntelMidRunSteerTests.swift
//  osaurusTests
//
//  `W-cov-reaudit` stage 3c-3 (docs/COV_REAUDIT.md): upstream's mid-run
//  steering (#1433) with #2653's ordering fixes, on Intel's engine-run tool
//  rounds. Upstream's own cases are in its `ChatSessionQueuedSendTests` and
//  `AgentLoopBudgetTests` (not compiled on Intel). Also upstream's tool
//  scope gate (#2018, #2145, #2309; `IntelToolScopeGate`). The engine runs
//  against an in-process HTTP fixture, never a provider.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel mid-run steer")
@MainActor
struct IntelMidRunSteerSessionTests {
    @Test("A steer lands before the trailing assistant placeholder (#2653)")
    func steerLandsBeforeThePlaceholder() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let user = ChatTurn(role: .user, content: "Check what's configured.")
            let call = ChatTurn(role: .assistant, content: "")
            call.toolCalls = [
                ToolCall(
                    id: "call_1", type: "function",
                    function: ToolCallFunction(name: "osaurus_inspect", arguments: #"{"action":"status"}"#))
            ]
            let result = ChatTurn(role: .tool, content: #"{"ok":true}"#)
            result.toolCallId = "call_1"
            let placeholder = ChatTurn(role: .assistant, content: "")
            session.turns = [user, call, result, placeholder]

            session.enqueueSend("Use describe instead", attachments: [])
            let steer = try #require(session.takeQueuedSteerIfEligible())
            session.appendMidRunUserTurn(ChatTurn(role: .user, content: steer))

            #expect(session.queuedSend == nil)
            #expect(session.turns.map(\.role) == [.user, .assistant, .tool, .user, .assistant])
            #expect(session.turns[3].content == "Use describe instead")
            #expect(session.turns.last === placeholder)
        }
    }

    @Test("A trailing reply with content is not a placeholder")
    func steerAppendsAfterAReplyWithContent() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.turns = [ChatTurn(role: .user, content: "hi"), ChatTurn(role: .assistant, content: "partial")]
            session.appendMidRunUserTurn(ChatTurn(role: .user, content: "and also this"))
            #expect(session.turns.map(\.role) == [.user, .assistant, .user])
            #expect(session.turns.last?.content == "and also this")
        }
    }

    @Test("Attachments and one-off skills stay queued for the run's end")
    func onlyTextOnlySendsSteer() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.queuedSend = QueuedSend(
                text: "with a file", attachments: [Attachment.document(filename: "a.txt", content: "x", fileSize: 1)],
                oneOffSkillId: nil)
            #expect(session.takeQueuedSteerIfEligible() == nil)
            #expect(session.queuedSend != nil)
            session.queuedSend = QueuedSend(text: "with a skill", attachments: [], oneOffSkillId: UUID())
            #expect(session.takeQueuedSteerIfEligible() == nil)
            #expect(session.queuedSend != nil)
        }
    }

    @Test("Only the run's budget warning survives a steer (#2653)")
    func noticesAcrossTheSteer() {
        let budget = "[System Notice] Tool call budget: 3 of 15 remaining. Wrap up your current work and provide a summary."
        let stale = "[System Notice] You have now made the exact same `osaurus_inspect` call with identical arguments 3+ times."
        let todo = "[System Notice] Update the todo list before continuing."
        #expect(AgentToolLoop.noticesSurvivingNewUserMessage([budget, stale, todo]) == [budget])
        #expect(AgentToolLoop.noticesSurvivingNewUserMessage([stale]).isEmpty)
        #expect(AgentToolLoop.noticesSurvivingNewUserMessage([]).isEmpty)
    }
}

@Suite("Intel mid-run steer engine", .serialized)
struct IntelMidRunSteerEngineTests {
    private static func frame(_ delta: String, finish: String? = nil) -> String {
        let reason = finish.map { "\"\($0)\"" } ?? "null"
        return "data: {\"choices\":[{\"index\":0,\"delta\":{\(delta)},\"finish_reason\":\(reason)}]}\n\n"
    }

    private static let toolCall =
        frame(
            #""tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"steer_fixture_tool","arguments":"{}"}}]"#
        ) + frame("", finish: "tool_calls") + "data: [DONE]\n\n"

    fileprivate static func answer(_ text: String) -> String {
        frame("\"content\":\"\(text)\"") + frame("", finish: "stop") + "data: [DONE]\n\n"
    }

    private static let tool = Tool(
        function: ToolFunction(
            name: "steer_fixture_tool", description: "Fixture",
            parameters: .object(["type": .string("object"), "properties": .object([:])])))

    fileprivate static func call(_ name: String) -> String {
        frame(
            #""tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":""#
                + name + #"","arguments":"{}"}}]"#
        ) + frame("", finish: "tool_calls") + "data: [DONE]\n\n"
    }

    fileprivate func run(
        steers: [String], responses: [String]? = nil
    ) async throws -> (deltas: [String], bodies: [String]) {
        SteerFixtureProtocol.configure(responses: responses ?? [Self.toolCall, Self.answer("Done.")])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SteerFixtureProtocol.self]
        let provider = RemoteProvider(
            name: "Fixture", host: SteerFixtureProtocol.host, providerProtocol: .https,
            port: nil, basePath: "/v1", customHeaders: [:], authType: .none,
            providerType: .openaiLegacy, enabled: true, autoConnect: false, timeout: 5)
        let engine = ChatEngine(provider: provider, session: URLSession(configuration: configuration))
        let request = ChatCompletionRequest(
            model: "fixture-model", messages: [ChatMessage(role: "user", content: "Run the tool.")],
            tools: [Self.tool])
        let box = SteerBox(steers)
        let stream = try await ChatExecutionContext.$midRunSteer.withValue({ await box.next() }) {
            try await engine.streamChat(request: request)
        }
        var deltas: [String] = []
        for try await delta in stream { deltas.append(delta) }
        return (deltas, SteerFixtureProtocol.bodies)
    }

    @Test("A queued steer joins the next round after the tool result")
    func steerJoinsTheNextRound() async throws {
        let (deltas, bodies) = try await run(steers: ["Also list the files."])
        #expect(bodies.count == 2)
        #expect(!bodies[0].contains("Also list the files."))
        let second = try #require(bodies[1].data(using: .utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: second) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let roles = messages.map { $0["role"] as? String ?? "" }
        #expect(Array(roles.suffix(3)) == ["assistant", "tool", "user"])
        #expect(messages.last?["content"] as? String == "Also list the files.")
        // The chat records the turn in stream order: after the tool's result.
        let done = try #require(deltas.firstIndex { StreamingToolHint.decodeDone($0) != nil })
        let steer = try #require(deltas.firstIndex { StreamingSteerHint.decode($0) == "Also list the files." })
        #expect(done < steer)
    }

    @Test("No queued steer leaves the rounds unchanged")
    func noSteerNoChange() async throws {
        let (deltas, bodies) = try await run(steers: [])
        #expect(bodies.count == 2)
        #expect(!deltas.contains { StreamingSteerHint.decode($0) != nil })
    }

    @Test("A call to a tool that was not offered gets an envelope and the run goes on")
    func unofferedCallContinues() async throws {
        let (deltas, bodies) = try await run(
            steers: [], responses: [Self.call("file_write"), Self.answer("I need a folder first.")])
        #expect(bodies.count == 2)
        #expect(bodies[1].contains("needs a working folder attached to THIS chat"))
        let done = try #require(deltas.compactMap(StreamingToolHint.decodeDone).first)
        #expect(done.name == "file_write")
        #expect(ToolEnvelope.isError(done.result))
        #expect(deltas.last == "I need a folder first.")
    }
}

@Suite("Intel tool scope gate")
struct IntelToolScopeGateTests {
    private static let catalog = CapabilityCatalog(
        tools: [
            .init(name: "weather_forecast", description: "Forecast", groupId: "weather-kit"),
            .init(name: "stock_quote", description: "Quote", groupId: nil),
        ],
        skills: [],
        groups: [
            .init(
                id: "weather-kit", display: "Weather Kit",
                tools: [.init(name: "weather_forecast", description: "Forecast", groupId: "weather-kit")])
        ])

    private func gate(_ name: String, offered: Set<String> = ["capabilities"], agent: UUID? = UUID()) -> String {
        IntelToolScopeGate.envelope(
            forUnofferedCall: name, offeredNames: offered, agentId: agent, catalog: Self.catalog)
    }

    private func object(_ envelope: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
    }

    @Test("Folder tools say to attach a folder")
    func folderTools() throws {
        for name in ["file_read", "file_search", "file_write", "file_edit", "shell_run"] {
            let envelope = gate(name)
            #expect(envelope.contains("needs a working folder attached to THIS chat"))
            #expect(envelope.contains("prompt_working_folder"))
            #expect(!envelope.contains("Autonomous execution"))
            #expect(try object(envelope)["retryable"] as? Bool == false)
        }
    }

    @Test("Apple app tools name the agent's switch")
    func appleAppTools() throws {
        let app = try #require(AppleApp.allCases.first { !$0.toolNames.isEmpty })
        let tool = try #require(app.toolNames.sorted().first)
        #expect(gate(tool).contains("Abilities → Apple Apps"))
        #expect(gate(tool, agent: Agent.defaultId).contains("The Default agent never uses Apple app tools"))
        #expect(try object(gate(tool))["kind"] as? String == "rejected")
    }

    @Test("An enabled capability one load away gets the load hint (#2145)")
    func loadableHint() throws {
        let envelope = gate("stock_quote")
        #expect(envelope.contains(#"Call capabilities with ids: [\"tool/stock_quote\"]"#))
        #expect(try object(envelope)["retryable"] as? Bool == true)
        // Without the gateway in the request, the refusal stays opaque.
        #expect(gate("stock_quote", offered: []).contains("is not available in this conversation"))
    }

    @Test("A plugin group id called as a function is redirected (#2309)")
    func groupRescue() throws {
        for guessed in ["plugin/weather-kit", "weather-kit", "Weather Kit"] {
            let envelope = gate(guessed)
            #expect(envelope.contains("is a capability id for a plugin group"))
            #expect(envelope.contains(#"{\"ids\":[\"plugin/weather-kit\"]}"#))
            #expect(try object(envelope)["retryable"] as? Bool == true)
        }
        #expect(gate("plugin/unknown-group").contains("is not available in this conversation"))
        #expect(gate("tool/weather-kit").contains("is not available in this conversation"))
        #expect(gate("weather-kit", offered: []).contains("is not available in this conversation"))
    }

    @Test("Anything else keeps the opaque refusal")
    func opaque() throws {
        let envelope = gate("made_up_tool")
        #expect(envelope.contains("made_up_tool is not available in this conversation."))
        #expect(try object(envelope)["retryable"] as? Bool == false)
    }
}

private actor SteerBox {
    private var steers: [String]
    init(_ steers: [String]) { self.steers = steers }
    func next() -> String? { steers.isEmpty ? nil : steers.removeFirst() }
}

private final class SteerFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let host = "steer-fixture.invalid"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [String] = []
    nonisolated(unsafe) private static var captured: [String] = []
    static var bodies: [String] { lock.lock(); defer { lock.unlock() }; return captured }
    static func configure(responses: [String]) {
        lock.lock(); defer { lock.unlock() }
        queue = responses; captured = []
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
