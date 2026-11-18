//
//  IntelAnnounceAndStopTests.swift
//  OsaurusCoreTests
//
//  `W-cov-reaudit` stage 5c slice 3 (rows 5 to 9): upstream Classic's
//  announce-only and continuation-request nudges (#2480), the tool-free status
//  steps after exhausted announcements or a repeated retrieval failure, and
//  ending the chat run on a denied or `rejected` tool call
//  (`shouldStopAfterToolOutcome`). The engine talks to an in-process HTTP
//  fixture, never a provider.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Recovery decisions

struct IntelAnnounceRecoveryTests {
    private let announce = AgentLoopModelStep.announcedToolCall
    private let continuation = AgentLoopModelStep.continuationRequest

    @Test func anAnnouncementIsNudgedTwiceThenWrappedUp() {
        var recovery = IntelTerminalRecovery()
        let nudge = AgentToolLoop.announcedToolCallNotice(recovery: nil)
        #expect(recovery.action(for: announce, completedToolWork: false) == .retryKeepingText(notice: nudge))
        #expect(recovery.action(for: announce, completedToolWork: false) == .retryKeepingText(notice: nudge))
        #expect(
            recovery.action(for: announce, completedToolWork: false)
                == .wrapUp(notice: AgentToolLoop.announceExhaustedWrapUpNotice(announcements: 3)))
    }

    @Test func aToolRoundResetsTheAnnounceAndContinuationBudgets() {
        var recovery = IntelTerminalRecovery()
        _ = recovery.action(for: announce, completedToolWork: false)
        _ = recovery.action(for: announce, completedToolWork: false)
        _ = recovery.action(for: continuation, completedToolWork: false, pendingTodo: 2)
        recovery.noteToolRound()
        #expect(recovery.consecutiveAnnouncedToolCalls == 0)
        #expect(recovery.consecutiveContinuationRequests == 0)
        let nudge = AgentToolLoop.announcedToolCallNotice(recovery: nil)
        #expect(recovery.action(for: announce, completedToolWork: true) == .retryKeepingText(notice: nudge))
    }

    @Test func aContinuationRequestIsAStallOnlyWithATodoPending() {
        var recovery = IntelTerminalRecovery()
        #expect(recovery.action(for: continuation, completedToolWork: true, pendingTodo: 0) == .finish)
        let notice = AgentToolLoop.continuationRequestNotice(pending: 3)
        #expect(recovery.action(for: continuation, completedToolWork: true, pendingTodo: 3) == .retryKeepingText(notice: notice))
        #expect(recovery.action(for: continuation, completedToolWork: true, pendingTodo: 3) == .retryKeepingText(notice: notice))
        // Two nudges spent: the question stands (no wrap-up for a question).
        #expect(recovery.action(for: continuation, completedToolWork: true, pendingTodo: 3) == .finish)
    }

    @Test func theNoticesAreUpstreamsText() {
        #expect(AgentToolLoop.continuationRequestNotice(pending: 1).contains("1 item remains"))
        #expect(AgentToolLoop.continuationRequestNotice(pending: 4).contains("4 items remain"))
        #expect(AgentToolLoop.announcedToolCallNotice(recovery: nil).hasPrefix("[System Notice] Your previous turn described a tool call"))
        #expect(AgentToolLoop.announceExhaustedWrapUpNotice(announcements: 3).contains("described the next action 3 times"))
        #expect(AgentToolLoop.repeatedRetrievalWrapUpNotice(tool: "search_and_extract", failures: 3).contains("failed 3 times"))
    }

    @Test func theAnnounceNoticeNamesWhatIsCallableLoadableAndBlocked() {
        let recovery = AgentToolLoop.AnnouncedToolCallRecovery(
            exposed: ["capabilities", "share_artifact"], loadable: ["web_search"], loaderName: "capabilities",
            workspaceBlocked: ["file_write", "file_read"])
        let text = AgentToolLoop.announcedToolCallNotice(recovery: recovery)
        #expect(text.contains("right now in this chat are: capabilities, share_artifact."))
        #expect(text.contains("call capabilities with ids [\"tool/<name>\"] first, then emit the call: web_search."))
        #expect(text.contains("file_read, file_write need a workspace attached"))
        #expect(text.contains("Folder chip"))
        #expect(text.contains("(share_artifact can carry it)."))
        let picker = AgentToolLoop.AnnouncedToolCallRecovery(
            exposed: [PromptWorkingFolderTool.toolName], workspaceBlocked: ["file_write"])
        #expect(AgentToolLoop.announcedToolCallNotice(recovery: picker).contains("Call prompt_working_folder now"))
    }

    @Test func theRecoveryBucketsFollowTheScopeGate() {
        let catalog = CapabilityCatalog(
            tools: [
                .init(name: "web_search", description: "", groupId: nil),
                .init(name: "file_write", description: "", groupId: nil),
                .init(name: "get_current_time", description: "", groupId: nil),
            ], skills: [], groups: [])
        let withLoader = IntelAnnouncedRecovery.make(
            exposed: ["capabilities", "get_current_time"], catalog: catalog)
        #expect(withLoader.loadable == ["web_search"])
        #expect(withLoader.workspaceBlocked == IntelToolScopeGate.coreWorkspaceToolNames)
        // No loader in the request: nothing is promised as loadable.
        let noLoader = IntelAnnouncedRecovery.make(exposed: ["get_current_time"], catalog: catalog)
        #expect(noLoader.loadable.isEmpty)
        // A folder attached: its tools are exposed, not blocked.
        let folder = IntelAnnouncedRecovery.make(
            exposed: ["capabilities", "file_read", "file_write", "file_edit", "file_search", "shell_run"],
            catalog: catalog)
        #expect(folder.workspaceBlocked.isEmpty)
    }
}

// MARK: - Stop policy (row 9)

struct IntelToolStopPolicyTests {
    private func outcome(
        _ result: String, tool: String = "file_write", deduped: Bool = false, error: Bool? = nil
    ) -> IntelToolOutcome {
        IntelToolOutcome(
            toolName: tool, argumentsJSON: "{}", result: result, wasDeduped: deduped,
            wasError: error ?? ToolEnvelope.isError(result))
    }

    private func envelope(_ kind: ToolEnvelope.Kind) -> String {
        ToolEnvelope.failure(kind: kind, message: "No.", tool: "file_write")
    }

    @Test func aDeniedOrRejectedCallStopsTheRun() {
        #expect(AgentToolLoop.shouldStopAfterToolOutcome(outcome(envelope(.userDenied))))
        #expect(AgentToolLoop.shouldStopAfterToolOutcome(outcome(envelope(.rejected))))
        // The engine's own denial text is untyped.
        #expect(
            AgentToolLoop.shouldStopAfterToolOutcome(
                outcome("⛔️ “file_write” was not run — you declined to run it this time.")))
    }

    @Test func correctableFailuresGoBackToTheModel() {
        #expect(!AgentToolLoop.shouldStopAfterToolOutcome(outcome(envelope(.invalidArgs))))
        #expect(!AgentToolLoop.shouldStopAfterToolOutcome(outcome(envelope(.executionError))))
        #expect(!AgentToolLoop.shouldStopAfterToolOutcome(outcome(envelope(.toolNotFound))))
        #expect(!AgentToolLoop.shouldStopAfterToolOutcome(outcome(envelope(.timeout))))
        #expect(!AgentToolLoop.shouldStopAfterToolOutcome(outcome(ToolEnvelope.success(tool: "file_read", text: "ok"))))
    }

    @Test func aReplayedFailureStopsButARetrievalReplayGetsOneChance() {
        let failed = envelope(.executionError)
        #expect(AgentToolLoop.shouldStopAfterToolOutcome(outcome(failed, deduped: true)))
        #expect(!AgentToolLoop.shouldStopAfterToolOutcome(outcome(failed, tool: "search_and_extract", deduped: true), heldErrorReplays: 1))
        #expect(AgentToolLoop.shouldStopAfterToolOutcome(outcome(failed, tool: "search_and_extract", deduped: true), heldErrorReplays: 2))
        // A replayed success is not a failure.
        #expect(!AgentToolLoop.shouldStopAfterToolOutcome(outcome(ToolEnvelope.success(tool: "file_read", text: "ok"), deduped: true)))
    }

    @Test func todoContractRejectionsAreRecoverable() {
        let stale = ToolEnvelope.failure(
            kind: .rejected, message: "stale", tool: "complete", metadata: ["reason": CompleteTool.staleSessionTodoReason])
        #expect(AgentToolLoop.isRecoverableTodoContractResult(stale))
        #expect(!AgentToolLoop.shouldStopAfterToolOutcome(outcome(stale, tool: "complete")))
    }

    @Test func aRepeatedRetrievalReplayBecomesAStatusStep() {
        let failed = envelope(.executionError)
        let replay = outcome(failed, tool: "search_and_extract", deduped: true)
        let notice = AgentToolLoop.repeatedRetrievalWrapUpNotice(for: replay, replays: 2)
        #expect(notice == AgentToolLoop.repeatedRetrievalWrapUpNotice(tool: "search_and_extract", failures: 3))
        #expect(AgentToolLoop.repeatedRetrievalWrapUpNotice(for: outcome(failed, tool: "file_write", deduped: true), replays: 2) == nil)
        #expect(AgentToolLoop.repeatedRetrievalWrapUpNotice(for: outcome(failed, tool: "search_and_extract"), replays: 2) == nil)
    }

    @Test func theClosingTextCarriesTheCanonicalMessage() {
        let typed = AgentToolLoop.toolRejectionText(for: envelope(.userDenied))
        #expect(typed == "The requested action was not completed. No.")
        let engineDenial = AgentToolLoop.toolRejectionText(
            for: "⛔️ “file_write” was not run — you declined to run it this time.")
        #expect(engineDenial.hasPrefix("The requested action was not completed. “file_write” was not run"))
        #expect(!engineDenial.contains("⛔️"))
    }

    @Test func theRunEndHintsRoundTripAndAreSentinels() {
        let rejected = StreamingRunEndHint.encodeToolRejected(text: "The requested action was not completed.")
        #expect(StreamingRunEndHint.decodeToolRejected(rejected) == "The requested action was not completed.")
        #expect(StreamingRunEndHint.decodeWrapUp(rejected) == nil)
        let wrap = StreamingRunEndHint.encodeWrapUp(notice: "[System Notice] x")
        #expect(StreamingRunEndHint.decodeWrapUp(wrap) == "[System Notice] x")
        #expect(StreamingRunEndHint.decodeToolRejected(wrap) == nil)
        #expect(StreamingToolHint.isSentinel(rejected))
        #expect(StreamingToolHint.isSentinel(wrap))
    }
}

// MARK: - Engine

@Suite("Intel announce and stop engine", .serialized)
struct IntelAnnounceAndStopEngineTests {
    private static func frame(_ delta: String, finish: String? = nil) -> String {
        let reason = finish.map { "\"\($0)\"" } ?? "null"
        return "data: {\"choices\":[{\"index\":0,\"delta\":{\(delta)},\"finish_reason\":\(reason)}]}\n\n"
    }

    static func answer(_ text: String) -> String {
        frame("\"content\":\"\(text)\"") + frame("", finish: "stop") + "data: [DONE]\n\n"
    }

    static func toolCall(id: String, args: String = "{}") -> String {
        frame(
            "\"tool_calls\":[{\"index\":0,\"id\":\"\(id)\",\"type\":\"function\",\"function\":{\"name\":\"get_current_time\",\"arguments\":\"\(args)\"}}]"
        ) + frame("", finish: "tool_calls") + "data: [DONE]\n\n"
    }

    static let offeredTool = Tool(
        function: ToolFunction(
            name: "get_current_time", description: "Current time",
            parameters: .object(["type": .string("object"), "properties": .object([:])])))

    private func run(
        _ responses: [String],
        interactive: Bool = true,
        sessionId: String? = nil
    ) async throws -> (deltas: [String], bodies: [String]) {
        AnnounceFixtureProtocol.configure(responses: responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnnounceFixtureProtocol.self]
        let provider = RemoteProvider(
            name: "Fixture", host: AnnounceFixtureProtocol.host, providerProtocol: .https,
            port: nil, basePath: "/v1", customHeaders: [:], authType: .none,
            providerType: .openaiLegacy, enabled: true, autoConnect: false, timeout: 5)
        let engine = ChatEngine(provider: provider, session: URLSession(configuration: configuration))
        let request = ChatCompletionRequest(
            model: "fixture-model", messages: [ChatMessage(role: "user", content: "Write the file.")],
            tools: [Self.offeredTool])
        let stream = try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
            try await ChatExecutionContext.$interactiveChatRun.withValue(interactive) {
                try await engine.streamChat(request: request)
            }
        }
        var deltas: [String] = []
        for try await delta in stream { deltas.append(delta) }
        return (deltas, AnnounceFixtureProtocol.bodies)
    }

    @Test("An announced call is nudged, with what the model said kept in history (#2480)")
    func announcementIsNudged() async throws {
        let (deltas, bodies) = try await run([Self.answer("Let me write the file:"), Self.answer("I could not.")])
        #expect(bodies.count == 2)
        #expect(bodies[1].contains("described a tool call but did not actually emit one"))
        #expect(bodies[1].contains("Let me write the file:"))
        #expect(bodies[1].contains("get_current_time"))
        #expect(deltas.last == "I could not.")
        #expect(!deltas.contains { StreamingRunEndHint.decodeWrapUp($0) != nil })
    }

    @Test("Two nudges later the run ends with a tool-free status step request")
    func exhaustedAnnouncementsWrapUp() async throws {
        let (deltas, bodies) = try await run([
            Self.answer("Let me write the file:"), Self.answer("Now I will write it:"),
            Self.answer("Let me write the file now:"),
        ])
        #expect(bodies.count == 3)
        let notice = try #require(deltas.compactMap(StreamingRunEndHint.decodeWrapUp).first)
        #expect(notice == AgentToolLoop.announceExhaustedWrapUpNotice(announcements: 3))
    }

    @Test("A finished answer is never nudged, and neither is a headless run")
    func answersAndHeadlessRunsAreUntouched() async throws {
        let normal = try await run([Self.answer("It is noon.")])
        #expect(normal.bodies.count == 1)
        let headless = try await run([Self.answer("Let me write the file:"), Self.answer("never sent")], interactive: false)
        #expect(headless.bodies.count == 1)
        #expect(!headless.deltas.contains { StreamingRunEndHint.decodeWrapUp($0) != nil })
    }

    @Test("A continuation request with a todo pending is told to continue (#2480)")
    func continuationRequestIsNudged() async throws {
        let session = "slice3-todo-\(UUID().uuidString)"
        _ = await AgentTodoStore.shared.setTodo(markdown: "- [ ] write the file\n- [ ] verify it", for: session)
        let (deltas, bodies) = try await run(
            [Self.answer("Step one is done. Would you like me to continue?"), Self.answer("Writing now.")],
            sessionId: session)
        #expect(bodies.count == 2)
        #expect(bodies[1].contains("You asked whether to continue. Yes"))
        #expect(bodies[1].contains("2 items remain"))
        #expect(deltas.last == "Writing now.")
    }

    @Test("The same question with nothing pending is a real question and ends the run")
    func continuationRequestWithoutATodoStands() async throws {
        let (_, bodies) = try await run(
            [Self.answer("Done with step one. Would you like me to continue?"), Self.answer("never sent")],
            sessionId: "slice3-none-\(UUID().uuidString)")
        #expect(bodies.count == 1)
    }

    @Test("A denied call ends the chat run with the closing line; the model is not asked again")
    func deniedCallEndsTheRun() async throws {
        ToolRegistry.shared.setPolicy(.deny, for: "get_current_time")
        defer { ToolRegistry.shared.clearPolicy(for: "get_current_time") }
        let (deltas, bodies) = try await run([Self.toolCall(id: "call_1"), Self.answer("never sent")])
        #expect(bodies.count == 1)
        let done = deltas.compactMap(StreamingToolHint.decodeDone)
        #expect(done.count == 1)
        #expect(done[0].result.contains("was not run"))
        let text = try #require(deltas.compactMap(StreamingRunEndHint.decodeToolRejected).first)
        #expect(text.hasPrefix("The requested action was not completed."))
        #expect(!deltas.contains("never sent"))
    }

    @Test("Outside the chat a denied call still goes back to the model")
    func deniedCallOutsideTheChatKeepsLooping() async throws {
        ToolRegistry.shared.setPolicy(.deny, for: "get_current_time")
        defer { ToolRegistry.shared.clearPolicy(for: "get_current_time") }
        let (deltas, bodies) = try await run([Self.toolCall(id: "call_1"), Self.answer("Understood.")], interactive: false)
        #expect(bodies.count == 2)
        #expect(deltas.last == "Understood.")
        #expect(!deltas.contains { StreamingRunEndHint.decodeToolRejected($0) != nil })
    }

    @Test("An approved call is unaffected")
    func approvedCallKeepsGoing() async throws {
        let (deltas, bodies) = try await run([Self.toolCall(id: "call_1"), Self.answer("It is noon.")])
        #expect(bodies.count == 2)
        #expect(deltas.last == "It is noon.")
        #expect(!deltas.contains { StreamingRunEndHint.decodeToolRejected($0) != nil })
    }
}

private final class AnnounceFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let host = "announce-fixture.invalid"
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
