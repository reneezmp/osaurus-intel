//
//  SubagentBackgroundDispatchTests.swift
//  OsaurusCoreTests
//
//  W-subagents stage 6, ported from upstream Classic: the `background: true`
//  spawn contract. The tool call returns an acknowledgment immediately while
//  the prepared run continues detached; Stop reaches the detached run through
//  the interrupt center (and a Stop on the launching turn trips it); the
//  terminal digest is delivered to the launching session as a follow-up turn
//  once that session is idle (never mid-stream, never into a pending clarify),
//  also after the user stopped the worker (as upstream; owner decision
//  2026-11-26). Scripted kinds; no model, network or keychain.
//

import Foundation
import Testing

@testable import OsaurusCore

private final class ScriptedKind: SubagentKind, @unchecked Sendable {
    let capability: SubagentCapability
    var plannedSession: UUID?
    var body:
        @Sendable (SubagentScope, ResolvedModel, SubagentFeed, InterruptToken) async throws ->
            SubagentResult
    var failResolve = false

    var plannedSessionId: UUID? { plannedSession }

    init(
        id: String = "bg-scripted",
        body:
            @escaping @Sendable (SubagentScope, ResolvedModel, SubagentFeed, InterruptToken)
                async throws -> SubagentResult = { _, _, feed, _ in
                    feed.emitPhase("running")
                    return SubagentResult(payload: ["summary": "done"], summary: "done")
                }
    ) {
        self.capability = SubagentCapability(id: id, toolNames: [id], gate: .sandboxExec)
        self.body = body
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        if failResolve { throw SubagentError.unavailable("no such target") }
        return ResolvedModel(name: "scripted-model", id: "scripted-model", isLocal: false)
    }

    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision { .allow }

    func run(
        _ scope: SubagentScope, _ resolved: ResolvedModel, feed: SubagentFeed, interrupt: InterruptToken
    ) async throws -> SubagentResult {
        try await body(scope, resolved, feed, interrupt)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private func waitUntil(
    timeout: Duration = .seconds(5),
    _ predicate: @MainActor @escaping () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "SubagentBackgroundDispatchTests", code: 1)
}

@MainActor
private func makeSession() -> (session: ChatSession, context: ExecutionContext) {
    let context = ExecutionContext(id: UUID(), agentId: Agent.defaultId)
    context.chatSession.chatEngineFactory = { MockChatEngine() }
    return (context.chatSession, context)
}

@Suite(.serialized)
@MainActor
struct SubagentBackgroundDispatchTests {

    @Test("background dispatch acks immediately while the feed keeps running")
    func ackReturnsWhileRunContinues() async throws {
        let toolCallId = "bg-dispatch-\(UUID().uuidString)"
        let release = Flag()
        let kind = ScriptedKind(body: { _, _, feed, _ in
            feed.emitPhase("running")
            while !release.isSet { try await Task.sleep(for: .milliseconds(10)) }
            return SubagentResult(payload: ["summary": "digest-done"], summary: "digest-done")
        })

        let envelope = await ChatExecutionContext.$currentToolCallId.withValue(toolCallId) {
            await SubagentSession.dispatchInBackground(kind, tool: "bg_test")
        }
        #expect(ToolEnvelope.isSuccess(envelope))
        #expect(SubagentSession.isBackgroundAck(envelope))
        let payload = ToolEnvelope.successPayload(envelope) as? [String: Any]
        #expect(payload?["dispatched"] as? Bool == true)
        #expect((payload?["note"] as? String)?.contains("follow-up message") == true)

        let feed = try #require(SubagentFeedRegistry.shared.feed(for: toolCallId))
        #expect(feed.currentStatus() == .running)
        release.set()
        try await waitUntil { feed.currentStatus() == .finished(success: true, summary: "digest-done") }
        SubagentFeedRegistry.shared.removeNow(toolCallId: toolCallId)
    }

    @Test("the ack names the worker session when the kind plans one")
    func ackCarriesPlannedSessionId() {
        let id = UUID()
        let withSession = SubagentSession.backgroundAck(tool: "spawn_agent", helper: "Delegated to X", sessionId: id)
        let payload = ToolEnvelope.successPayload(withSession) as? [String: Any]
        #expect(payload?["session_id"] as? String == id.uuidString)
        let without = SubagentSession.backgroundAck(tool: "bg", helper: "H", sessionId: nil)
        #expect((ToolEnvelope.successPayload(without) as? [String: Any])?["session_id"] == nil)
        #expect(!SubagentSession.isBackgroundAck(ToolEnvelope.success(tool: "spawn_agent", result: ["kind": "spawn_result"])))
    }

    @Test("a delegated text spawn plans its session id before the run; continue reuses the handle")
    func textSpawnPlansSessionId() {
        let fresh = TextSubagentKind(agentID: UUID(), input: "task")
        #expect(fresh.plannedSessionId != nil)
        let resumed = UUID()
        #expect(TextSubagentKind(agentID: UUID(), input: "task", continueSessionId: resumed).plannedSessionId == resumed)
    }

    @Test("a preparation failure returns the failure envelope synchronously and runs nothing")
    func prepareFailureStaysSynchronous() async {
        let toolCallId = "bg-dispatch-\(UUID().uuidString)"
        let kind = ScriptedKind()
        kind.failResolve = true
        let envelope = await ChatExecutionContext.$currentToolCallId.withValue(toolCallId) {
            await SubagentSession.dispatchInBackground(kind, tool: "bg_test")
        }
        #expect(ToolEnvelope.isError(envelope))
        #expect(!SubagentSession.isBackgroundAck(envelope))
        // The feed (if the registry still lingers on it) ended as a failure; nothing runs.
        if let feed = SubagentFeedRegistry.shared.feed(for: toolCallId) {
            if case .finished(let success, _) = feed.currentStatus() { #expect(!success) } else {
                Issue.record("a failed preparation must finish its feed")
            }
            SubagentFeedRegistry.shared.removeNow(toolCallId: toolCallId)
        }
    }

    @Test("the digest lands in the launching session as a follow-up turn, kept out of memory")
    func reportBackDeliversToIdleSession() async throws {
        try await ChatHistoryTestStorage.run {
            let (session, context) = makeSession()
            _ = context
            let box = WeakChatSessionBox(session)
            let toolCallId = "bg-dispatch-\(UUID().uuidString)"
            let workerID = UUID()
            let kind = ScriptedKind(body: { _, _, _, _ in
                SubagentResult(
                    payload: [
                        "kind": "spawn_result", "summary": "digest-report-123",
                        "session_id": workerID.uuidString,
                    ],
                    summary: "digest-report-123")
            })
            let envelope = await ChatExecutionContext.$currentToolCallId.withValue(toolCallId) {
                await ChatExecutionContext.$currentChatSessionBox.withValue(box) {
                    await SubagentSession.dispatchInBackground(kind, tool: "bg_test")
                }
            }
            #expect(ToolEnvelope.isSuccess(envelope))
            try await waitUntil {
                session.turns.contains {
                    $0.role == .user && $0.content.contains("[Helper report]")
                        && $0.content.contains("finished") && $0.content.contains("digest-report-123")
                        && $0.content.contains("Worker session_id (spawn_agent continue): \(workerID.uuidString)")
                }
            }
            SubagentFeedRegistry.shared.removeNow(toolCallId: toolCallId)
        }
    }

    @Test("a worker the user stopped is reported back like any other, as upstream does")
    func stoppedWorkerIsReported() async throws {
        try await ChatHistoryTestStorage.run {
            let (session, context) = makeSession()
            _ = context
            let box = WeakChatSessionBox(session)
            let toolCallId = "bg-dispatch-\(UUID().uuidString)"
            let started = Flag()
            let kind = ScriptedKind(body: { _, _, feed, interrupt in
                feed.emitPhase("running")
                started.set()
                while !interrupt.isInterrupted { try await Task.sleep(for: .milliseconds(10)) }
                throw CancellationError()
            })
            _ = await ChatExecutionContext.$currentToolCallId.withValue(toolCallId) {
                await ChatExecutionContext.$currentChatSessionBox.withValue(box) {
                    await SubagentSession.dispatchInBackground(kind, tool: "bg_test")
                }
            }
            try await waitUntil { started.isSet }
            let feed = try #require(SubagentFeedRegistry.shared.feed(for: toolCallId))
            // The card's / Activity row's / launching turn's Stop: same token.
            #expect(SubagentInterruptCenter.shared.interrupt(toolCallId))
            try await waitUntil {
                if case .finished(let success, _) = feed.currentStatus() { return !success }
                return false
            }
            try await waitUntil {
                session.turns.contains {
                    $0.role == .user && $0.content.contains("[Helper report]") && $0.content.contains("failed")
                }
            }
            SubagentFeedRegistry.shared.removeNow(toolCallId: toolCallId)
        }
    }

    @Test("report-back never invents a resume handle from a summary or failed result")
    func reportBackRejectsUnqualifiedHandles() {
        let id = UUID().uuidString
        let baseline = "[Helper report] Helper finished: summary \(id)"
        let malformed = [
            "not-json",
            ToolEnvelope.success(tool: "browser_use", result: ["kind": "browser_result", "session_id": id]),
            ToolEnvelope.success(tool: "spawn_agent", result: ["kind": "spawn_result", "session_id": "bad-id"]),
            ToolEnvelope.success(tool: "spawn_agent", result: ["kind": "spawn_result"]),
            ToolEnvelope.failure(kind: .executionError, message: id, tool: "spawn_agent"),
        ]
        for envelope in malformed {
            #expect(
                SubagentReportBack.message(
                    title: "Helper", success: true, summary: "summary \(id)", completedEnvelope: envelope)
                    == baseline)
        }
        let completed = ToolEnvelope.success(tool: "spawn_agent", result: ["kind": "spawn_result", "session_id": id])
        #expect(
            SubagentReportBack.message(title: "Helper", success: false, summary: "cancelled", completedEnvelope: completed)
                == "[Helper report] Helper failed: cancelled")
    }

    @Test("delivery waits out a streaming session and a pending clarify")
    func reportBackDefersWhileSessionIsBusy() async throws {
        try await ChatHistoryTestStorage.run {
            let (session, context) = makeSession()
            _ = context
            let box = WeakChatSessionBox(session)
            session.isStreaming = true
            let delivery = Task {
                await SubagentReportBack.deliver(
                    title: "spawn → Helper", success: true, summary: "deferred-digest", to: box)
            }
            try await Task.sleep(for: .milliseconds(400))
            #expect(!session.turns.contains { $0.content.contains("deferred-digest") })

            session.awaitingClarify = ClarifyPayload(question: "Which one?", options: [], allowMultiple: false)
            session.isStreaming = false
            try await Task.sleep(for: .milliseconds(400))
            #expect(!session.turns.contains { $0.content.contains("deferred-digest") })

            session.awaitingClarify = nil
            try await waitUntil {
                session.turns.contains { $0.role == .user && $0.content.contains("deferred-digest") }
            }
            await delivery.value
        }
    }

    @Test("a deallocated launching session drops the report cleanly")
    func reportBackDropsWhenSessionIsGone() async {
        var context: ExecutionContext? = ExecutionContext(id: UUID(), agentId: Agent.defaultId)
        let box = WeakChatSessionBox(context!.chatSession)
        context = nil
        #expect(box.session == nil)
        await SubagentReportBack.deliver(title: "spawn → Helper", success: false, summary: "gone", to: box)
    }

    @Test("Stop on the launching turn reaches a background worker it launched; the spawn tool exposes `background`")
    func launchingTurnStopIsWired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let chat = try String(contentsOf: root.appendingPathComponent("Views/Chat/ChatView.swift"), encoding: .utf8)
        // stop() trips the workers before cancelling the run; a background ack records the call id.
        let stopRange = try #require(chat.range(of: "func stop(preservesCancelledMarker"))
        let tail = String(chat[stopRange.upperBound...])
        let interruptAt = try #require(tail.range(of: "interruptBackgroundSpawnsOfCurrentRun()"))
        let cancelAt = try #require(tail.range(of: "task?.cancel()"))
        #expect(interruptAt.lowerBound < cancelAt.lowerBound)
        #expect(chat.contains("backgroundSpawnCallIdsThisRun.append(done.callId)"))

        let tool = try String(contentsOf: root.appendingPathComponent("Tools/SpawnAgentTool.swift"), encoding: .utf8)
        #expect(tool.contains("\"background\": .object("))
        #expect(tool.contains("SubagentSession.dispatchInBackground(kind, tool: name)"))
        let schema = SpawnAgentTool().parameters
        guard case .object(let object)? = schema, case .object(let properties)? = object["properties"] else {
            Issue.record("schema")
            return
        }
        #expect(properties["background"] != nil)
    }
}
