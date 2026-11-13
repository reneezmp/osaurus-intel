//
//  IntelAgentLoopTerminalTests.swift
//  osaurusTests
//
//  `W-cov-reaudit` stage 3c-1 (docs/COV_REAUDIT.md): upstream's agent-loop
//  fixes on Intel's own loop.
//  - #1681 / #2167 / #2344: a round with no tool call that is empty,
//    reasoning only, or cut at the output limit is not a finished answer
//    (`IntelTerminalRecovery`, wired into `CloudChatEngine`). Upstream's
//    classifier itself is covered by its `ReasoningOnlyTurnClassificationTests`.
//  - #2235: the step-limit wrap-up skips the engine's recovery.
//  - #1725 / #1679: loaded tool schemas are checked; a bad id fails for good.
//  - #2171: a `complete` that leaves todo items unchecked reads "Blocked".
//  - #2173: the `[Current Time]` block rides the latest user message.
//  The engine runs against an in-process HTTP fixture, never a provider.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Recovery

struct IntelTerminalRecoveryTests {
    @Test func emptyTurnsAreReaskedTwiceThenGetAFallback() {
        var recovery = IntelTerminalRecovery()
        #expect(recovery.action(for: .emptyResponse, completedToolWork: false) == .retry(notice: AgentToolLoop.emptyTurnNotice))
        #expect(recovery.action(for: .emptyResponse, completedToolWork: false) == .retry(notice: AgentToolLoop.emptyTurnNotice))
        #expect(recovery.action(for: .emptyResponse, completedToolWork: false) == .finishWithText(AgentToolLoop.emptyTurnFallback))
    }

    @Test func afterToolWorkTheFallbackSaysTheTaskMayBeIncomplete() {
        var recovery = IntelTerminalRecovery()
        _ = recovery.action(for: .emptyResponse, completedToolWork: true)
        _ = recovery.action(for: .emptyResponse, completedToolWork: true)
        #expect(recovery.action(for: .emptyResponse, completedToolWork: true) == .finishWithText(AgentToolLoop.emptyToolTaskFallback))
    }

    @Test func aToolRoundResetsTheEmptyTurnBudget() {
        var recovery = IntelTerminalRecovery()
        _ = recovery.action(for: .emptyResponse, completedToolWork: false)
        _ = recovery.action(for: .emptyResponse, completedToolWork: false)
        recovery.noteToolRound()
        #expect(recovery.action(for: .emptyResponse, completedToolWork: true) == .retry(notice: AgentToolLoop.emptyTurnNotice))
    }

    @Test func reasoningOnlyGetsOneFreshRetryPerRun() {
        var recovery = IntelTerminalRecovery()
        #expect(recovery.action(for: .incompleteReasoning, completedToolWork: false) == .retryInFreshTurn)
        recovery.noteToolRound()
        #expect(recovery.action(for: .incompleteReasoning, completedToolWork: true) == .finishWithText(AgentToolLoop.incompleteReasoningFallback))
    }

    @Test func outputLimitAndAnswersEndTheRun() {
        var recovery = IntelTerminalRecovery()
        #expect(recovery.action(for: .lengthExhausted, completedToolWork: false) == .finishWithText(AgentToolLoop.lengthExhaustedFallback))
        #expect(recovery.action(for: .finalResponse, completedToolWork: false) == .finish)
        #expect(recovery.action(for: .announcedToolCall, completedToolWork: false) == .finish)
    }

    @Test func aTruncatedToolCallIsRetriedOnceThenGetsTheFallback() {
        var recovery = IntelTerminalRecovery()
        let step = AgentLoopModelStep.truncatedToolCall(toolName: "file_write", argumentCharacters: 4_000)
        let first = recovery.action(for: step, completedToolWork: false)
        #expect(first == .retry(notice: AgentToolLoop.truncatedToolCallNotice(toolName: "file_write", argumentCharacters: 4_000)))
        #expect(recovery.action(for: step, completedToolWork: false) == .finishWithText(AgentToolLoop.truncatedToolCallFallback))
        guard case .retry(let notice) = first else { return }
        #expect(notice.contains("`file_write`"))
        #expect(notice.contains("\(WorkspaceToolContract.recommendedWriteChunkCharacters) characters"))
    }

    @Test func dataMovementCallsAreOnlyBulkLoads() {
        #expect(AgentToolLoop.isDataMovementCall(name: "db_import", argsJSON: "{}"))
        #expect(AgentToolLoop.isDataMovementCall(name: "db_insert", argsJSON: #"{"rows":[{"a":1}]}"#))
        #expect(AgentToolLoop.isDataMovementCall(name: "db_upsert", argsJSON: #"{"rows":[{"a":1}]}"#))
        #expect(!AgentToolLoop.isDataMovementCall(name: "db_insert", argsJSON: #"{"row":{"a":1}}"#))
        #expect(!AgentToolLoop.isDataMovementCall(name: "db_insert", argsJSON: #"{"rows":[]}"#))
        #expect(!AgentToolLoop.isDataMovementCall(name: "file_write", argsJSON: "{}"))
    }

    @Test func onlySuccessfulUnheldBulkLoadsAreRefunded() {
        let args = #"{"rows":[{"a":1}]}"#
        func moved(_ result: String, held: Bool = false) -> Bool {
            AgentToolLoop.isSuccessfulDataMovement(
                name: "db_insert", argumentsJSON: args, result: result, wasHeld: held)
        }
        #expect(moved(#"{"ok":true}"#))
        #expect(!moved(#"{"ok":false,"error":"quota"}"#))
        #expect(!moved("\u{26D4}\u{FE0F} denied"))
        #expect(!moved(#"{"ok":true}"#, held: true))
        #expect(!moved("not json"))
        #expect(AgentToolLoop.maxDataMovementSteps(maxIterations: 40) == 16)
        #expect(AgentToolLoop.maxDataMovementSteps(maxIterations: 5) == 5)
    }

    @Test func theInsightsRowSumsEveryRound() {
        // A 5-round run: 5 x (100, 10) is 500 / 50, not the last round's 100 / 10.
        let all = ChatEngine.loggedTokenCounts(runPrompt: 500, runCompletion: 50, lastPrompt: 100, lastCompletion: 10)
        #expect(all.prompt == 500 && all.completion == 50)
        let none = ChatEngine.loggedTokenCounts(runPrompt: 0, runCompletion: 0, lastPrompt: nil, lastCompletion: nil)
        #expect(none.prompt == nil && none.completion == nil)
        let fallback = ChatEngine.loggedTokenCounts(runPrompt: 0, runCompletion: 0, lastPrompt: 7, lastCompletion: 3)
        #expect(fallback.prompt == 7 && fallback.completion == 3)
    }

    @Test func aResponsesStreamCutInsideAFunctionCallReportsTheTruncation() throws {
        var decoder = IntelCodexResponsesSSEDecoder(allowedToolNames: ["file_write"])
        let events = [
            #"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"c1","name":"file_write","arguments":""}}"#,
            #"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"path\":\"a"}"#,
            #"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}"#,
        ]
        let sse = events.map { "data: \($0)\n\n" }.joined()
        do {
            _ = try decoder.append(Data(sse.utf8))
            Issue.record("expected the output-limit error")
        } catch let error as IntelCodexResponsesAdapter.Error {
            guard case .outputLimitDuringToolCall(let name, _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(name == "file_write")
        }
        // Without a call in flight it stays an ordinary terminal failure.
        var plain = IntelCodexResponsesSSEDecoder(allowedToolNames: [])
        let incomplete =
            #"data: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}"#
            + "\n\n"
        #expect(throws: IntelCodexResponsesAdapter.Error.self) { _ = try plain.append(Data(incomplete.utf8)) }
    }

    @Test func theFallbackFollowsVisibleTextAfterABlankLine() {
        #expect(IntelTerminalRecovery.appendedText("Note.", afterVisible: "") == "Note.")
        #expect(IntelTerminalRecovery.appendedText("Note.", afterVisible: "  \n") == "Note.")
        #expect(IntelTerminalRecovery.appendedText("Note.", afterVisible: "Partial") == "\n\nNote.")
    }
}

// MARK: - Engine

@Suite("Intel terminal recovery engine", .serialized)
struct IntelTerminalRecoveryEngineTests {
    private static func frame(_ delta: String, finish: String? = nil) -> String {
        let reason = finish.map { "\"\($0)\"" } ?? "null"
        return "data: {\"choices\":[{\"index\":0,\"delta\":{\(delta)},\"finish_reason\":\(reason)}]}\n\n"
    }

    static func answer(_ text: String) -> String {
        frame("\"content\":\"\(text)\"") + frame("", finish: "stop") + "data: [DONE]\n\n"
    }

    static let empty = frame("", finish: "stop") + "data: [DONE]\n\n"

    static func reasoningOnly(_ text: String) -> String {
        frame("\"reasoning_content\":\"\(text)\"") + frame("", finish: "stop") + "data: [DONE]\n\n"
    }

    static func cut(_ text: String) -> String {
        frame("\"content\":\"\(text)\"") + frame("", finish: "length") + "data: [DONE]\n\n"
    }

    static let offeredTool = Tool(
        function: ToolFunction(
            name: "get_current_time", description: "Current time",
            parameters: .object(["type": .string("object"), "properties": .object([:])])))

    private func run(
        _ responses: [String],
        tools: [Tool]? = nil,
        interactive: Bool = true,
        wrapUp: Bool = false,
        notices: [String] = []
    ) async throws -> (deltas: [String], bodies: [String]) {
        TerminalFixtureProtocol.configure(responses: responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TerminalFixtureProtocol.self]
        let provider = RemoteProvider(
            name: "Fixture", host: TerminalFixtureProtocol.host, providerProtocol: .https,
            port: nil, basePath: "/v1", customHeaders: [:], authType: .none,
            providerType: .openaiLegacy, enabled: true, autoConnect: false, timeout: 5)
        let engine = ChatEngine(provider: provider, session: URLSession(configuration: configuration))
        var request = ChatCompletionRequest(
            model: "fixture-model", messages: [ChatMessage(role: "user", content: "What time is it?")],
            tools: tools)
        request.isToolFreeWrapUp = wrapUp
        request.transientNotices = notices
        let stream = try await ChatExecutionContext.$interactiveChatRun.withValue(interactive) {
            try await engine.streamChat(request: request)
        }
        var deltas: [String] = []
        for try await delta in stream { deltas.append(delta) }
        return (deltas, TerminalFixtureProtocol.bodies)
    }

    @Test("An empty turn is re-asked with upstream's notice")
    func emptyTurnIsReasked() async throws {
        let (deltas, bodies) = try await run([Self.empty, Self.answer("It is noon.")])
        #expect(bodies.count == 2)
        #expect(bodies[1].contains("Your previous turn produced no output."))
        #expect(!deltas.contains(StreamingGroundedRetryHint.sentinel))
        #expect(deltas.last == "It is noon.")
    }

    @Test("Three empty turns end with the visible fallback (#1681)")
    func repeatedEmptyTurnsShowTheFallback() async throws {
        let (deltas, bodies) = try await run([Self.empty, Self.empty, Self.empty])
        #expect(bodies.count == 3)
        #expect(deltas.last == AgentToolLoop.emptyTurnFallback)
    }

    @Test("Reasoning only with tools offered retries once in a fresh turn (#2344)")
    func reasoningOnlyWithToolsRetries() async throws {
        let (deltas, bodies) = try await run(
            [Self.reasoningOnly("I have a tool for this. Let me call it."), Self.answer("It is noon.")],
            tools: [Self.offeredTool])
        #expect(deltas.contains(StreamingGroundedRetryHint.sentinel))
        #expect(bodies.count == 2)
        #expect(deltas.last == "It is noon.")
    }

    @Test("Reasoning only with no tools and no tool work is a finished answer")
    func reasoningOnlyWithoutToolsFinishes() async throws {
        let (deltas, bodies) = try await run([Self.reasoningOnly("Just thinking.")])
        #expect(bodies.count == 1)
        #expect(!deltas.contains(StreamingGroundedRetryHint.sentinel))
    }

    @Test("A reply cut at the output limit gets the limit notice after it")
    func lengthStopAddsTheNotice() async throws {
        let (deltas, bodies) = try await run([Self.cut("Partial answer")])
        #expect(bodies.count == 1)
        #expect(deltas.last == "\n\n" + AgentToolLoop.lengthExhaustedFallback)
    }

    static let cutToolCall =
        frame(
            #""tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_current_time","arguments":"{\"a"}}]"#
        ) + frame("", finish: "length") + "data: [DONE]\n\n"

    @Test("A tool call cut by the output limit is retried once with the smaller-chunks notice")
    func truncatedToolCallIsRetried() async throws {
        let (deltas, bodies) = try await run([Self.cutToolCall, Self.answer("Done.")], tools: [Self.offeredTool])
        #expect(bodies.count == 2)
        #expect(bodies[1].contains("reached the model output limit"))
        // The cut call never ran: no result card, and the half-built card is cleared.
        #expect(!deltas.contains { StreamingToolHint.decodeDone($0) != nil })
        #expect(deltas.contains(StreamingToolHint.encode("")))
        #expect(deltas.last == "Done.")
    }

    @Test("A second cut ends the run with the visible fallback, not a raw error")
    func truncatedToolCallTwiceShowsTheFallback() async throws {
        let (deltas, bodies) = try await run([Self.cutToolCall, Self.cutToolCall], tools: [Self.offeredTool])
        #expect(bodies.count == 2)
        #expect(deltas.last == AgentToolLoop.truncatedToolCallFallback)
    }

    @Test("Outside the chat a cut tool call still fails as before")
    func truncatedToolCallOutsideTheChatStillThrows() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await run([Self.cutToolCall, Self.answer("never sent")], tools: [Self.offeredTool], interactive: false)
        }
    }

    @Test("Runs outside the chat and the step-limit wrap-up keep a blank reply as is")
    func nonChatRunsAndTheWrapUpAreUnaffected() async throws {
        let headless = try await run([Self.empty, Self.answer("never sent")], interactive: false)
        #expect(headless.bodies.count == 1)
        let wrapUp = try await run(
            [Self.empty, Self.answer("never sent")], wrapUp: true,
            notices: [AgentToolLoop.iterationCapWrapUpNotice])
        #expect(wrapUp.bodies.count == 1)
        #expect(!wrapUp.deltas.contains(AgentToolLoop.emptyTurnFallback))
    }

    @Test("The step-limit notice rides the wrap-up request (#2235), first round only")
    func wrapUpNoticeReachesTheRequest() async throws {
        let (_, bodies) = try await run(
            [Self.answer("Done: two of three files read; the third is unfinished.")], wrapUp: true,
            notices: [AgentToolLoop.iterationCapWrapUpNotice])
        #expect(bodies.count == 1)
        #expect(bodies[0].contains("The configured tool-call limit has been reached."))
    }
}

private final class TerminalFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let host = "terminal-fixture.invalid"
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

// MARK: - Capabilities (#1725, #1679)

struct IntelCapabilitySchemaTests {
    private static func tool(_ parameters: JSONValue?, name: String = "plugin_tool") -> Tool {
        Tool(function: ToolFunction(name: name, description: "d", parameters: parameters))
    }

    @Test func wellFormedAndArgumentFreeSchemasPass() {
        #expect(CapabilityLoadBuffer.validateDynamicToolSchema(Self.tool(nil)) == nil)
        let good = Self.tool(
            .object([
                "type": .string("object"),
                "properties": .object(["q": .object(["type": .string("string")])]),
                "required": .array([.string("q")]),
            ]))
        #expect(CapabilityLoadBuffer.validateDynamicToolSchema(good) == nil)
    }

    @Test func malformedSchemasFailClosedAndAreNeverOffered() throws {
        let notObject = Self.tool(.string("anything"), name: "a")
        let wrongType = Self.tool(.object(["type": .string("array")]), name: "b")
        let badRequired = Self.tool(
            .object(["type": .string("object"), "required": .string("q")]), name: "c")
        let blankName = Self.tool(nil, name: "  ")
        for bad in [notObject, wrongType, badRequired, blankName] {
            #expect(CapabilityLoadBuffer.validateDynamicToolSchema(bad) != nil)
        }
        let diagnostic = try #require(CapabilityLoadBuffer.validateDynamicToolSchema(badRequired))
        #expect(diagnostic.field == "parameters.required")
        let valid = CapabilityLoadBuffer.validSpecs([notObject, Self.tool(nil, name: "ok"), wrongType])
        #expect(valid.map(\.function.name) == ["ok"])
    }

    @Test func anUnknownIdFailsAsNotRetryable() async throws {
        let tool = CapabilitiesTool(catalogProvider: { _ in .empty })
        let result = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await tool.execute(argumentsJSON: #"{"ids":["tool/nope"]}"#)
        }
        #expect(ToolEnvelope.isError(result))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect(object["retryable"] as? Bool == false)
    }
}

// MARK: - Blocked completion (#2171)

struct IntelBlockedCompletionTests {
    @Test func aBlockedOutcomeIsReadFromTheCompleteResult() {
        let blocked = ToolEnvelope.success(
            tool: "complete",
            result: ["text": "Tracked task closed with 2 todo items still pending.", "outcome": "blocked"])
        let done = ToolEnvelope.success(tool: "complete", result: ["text": "Task completed.", "outcome": "completed"])
        #expect(ChatSession.completionWasBlocked(result: blocked))
        #expect(!ChatSession.completionWasBlocked(result: done))
        #expect(!ChatSession.completionWasBlocked(result: ToolEnvelope.failure(kind: .invalidArgs, message: "vague")))
    }
}

// MARK: - Time context (#2173)

struct IntelTimeContextTests {
    // Upstream `TimeContextTests`, the two rendering cases verbatim.
    private let fixedInstant = Date(timeIntervalSince1970: 1_785_123_932)  // 2026-07-27 03:45:32 UTC

    @Test func rendersReadableAndISOInTargetZone() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let block = SystemPromptTemplates.timeContext(now: fixedInstant, timeZone: zone)
        #expect(block.hasPrefix("[Current Time]"))
        #expect(block.hasSuffix("[/Current Time]"))
        #expect(block.contains("Monday, July 27, 2026 at 9:15 AM"))
        #expect(block.contains("2026-07-27T09:15+05:30"))
        #expect(block.contains("Asia/Kolkata"))
    }

    @Test func rendersMinuteGranularityAcrossSameMinuteInstants() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let a = SystemPromptTemplates.timeContext(now: fixedInstant, timeZone: zone)
        let b = SystemPromptTemplates.timeContext(now: fixedInstant.addingTimeInterval(20), timeZone: zone)
        #expect(a == b)
    }

    @Test func timeRidesLastOnTheLatestUserMessage() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let time = SystemPromptTemplates.timeContext(now: fixedInstant, timeZone: zone)
        var messages = [
            ChatMessage(role: "system", content: "sys"),
            ChatMessage(role: "user", content: "earlier"),
            ChatMessage(role: "assistant", content: "reply"),
            ChatMessage(role: "user", content: "remind me tomorrow"),
        ]
        SystemPromptComposer.injectMemoryPrefix("a fact", timeContext: time, into: &messages)
        let latest = try #require(messages[3].content)
        #expect(latest.hasPrefix("[Memory]\na fact\n[/Memory]\n\n[Current Time]"))
        #expect(latest.hasSuffix("[/Current Time]\n\nremind me tomorrow"))
        #expect(messages[1].content == "earlier")

        var timeOnly = [ChatMessage(role: "user", content: "hi")]
        SystemPromptComposer.injectMemoryPrefix(nil, timeContext: time, into: &timeOnly)
        #expect(timeOnly[0].content?.hasPrefix("[Current Time]") == true)
    }
}
