//
//  IntelBackgroundRunQueueTests.swift
//  OsaurusCoreTests
//
//  `W-background-runs-sync` stage 1 (docs/UPSTREAM_SYNC.md, "Background
//  runs, stage 1"): upstream's queue-scheduling suite from
//  `AgentRequestLifecycleTests.swift` (`bce907045`) on Intel's
//  `BackgroundTaskManager`:
//
//  - admission over capacity QUEUES (FIFO) instead of rejecting; the
//    deferred start has no execution side effects until promoted;
//  - freeing a slot (finalize, completion, cancel) promotes the oldest
//    eligible queued request; an agent at its per-agent cap is skipped
//    without head-of-line blocking other agents' work;
//  - `.waitingForInput` releases the execution slot and resumes to
//    `.running` without re-queueing;
//  - cancelling a queued request drops its deferred start permanently;
//  - `cancelAllTasks` (app shutdown) cancels running AND queued work.
//
//  Intel differences: the toast-ordering and window-binding tests, and the
//  toast-list check in the first test, wait for stage 2 (`sortedToastTasks`,
//  window binding); upstream's agent-loop hook suite in the same file needs
//  upstream's `AgentLoopHooks`, which Intel doesn't have; a minimal engine
//  stands in for upstream's `MockChatEngine` (whose file needs upstream's
//  response types).
//

import Foundation
import Testing

@testable import OsaurusCore

/// Never asked for anything: the queue tests drive `isStreaming` and the
/// clarify payload directly.
private struct IntelQueueTestEngine: ChatEngineProtocol {
    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw CancellationError()
    }
}

// MARK: - Helpers

/// Records whether a queued task's deferred start closure ever ran.
@MainActor
private final class StartProbe {
    private(set) var started = false
    func makeStart() -> @MainActor () async -> Void {
        { self.started = true }
    }
}

@MainActor
private func makeTaskState(
    agentId: UUID,
    title: String,
    status: BackgroundTaskStatus = .running
) -> BackgroundTaskState {
    let context = ExecutionContext(agentId: agentId)
    // Intel: `chatEngineFactory` takes no arguments.
    context.chatSession.chatEngineFactory = { IntelQueueTestEngine() }
    return BackgroundTaskState(
        id: UUID(),
        taskTitle: title,
        agentId: agentId,
        chatSession: context.chatSession,
        executionContext: context,
        status: status,
        currentStep: status == .running ? "Running..." : nil
    )
}

private func waitUntil(
    timeout: Duration = .seconds(3),
    _ predicate: @MainActor @escaping () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "IntelBackgroundRunQueueTests", code: 1)
}

// MARK: - Queue scheduling

@Suite(.serialized)
@MainActor
struct AgentRequestQueueSchedulingTests {

    /// Isolated manager instance: these tests saturate capacity, zero the
    /// global limit, and run `cancelAllTasks` — against `.shared` that
    /// would cancel/stall tasks registered by concurrently-running suites
    /// (e.g. `ChatWindowSessionDetachTests`' adopted sessions).
    private let mgr = BackgroundTaskManager.makeForTesting()

    /// Fill the per-agent cap (5) with directly-registered running tasks
    /// for a unique agent id, isolating capacity math from anything other
    /// suites may have in flight on the shared manager.
    private func fillAgentCap(_ agentId: UUID) -> [BackgroundTaskState] {
        (0..<5).map { i in
            let state = makeTaskState(agentId: agentId, title: "filler-\(i)")
            mgr.registerTaskForTesting(state)
            return state
        }
    }

    @Test func saturatedAgent_admissionQueuesInsteadOfRejecting() async throws {
        let agent = UUID()
        let fillers = fillAgentCap(agent)
        defer { fillers.forEach { mgr.finalizeTask($0.id) } }

        let probe = StartProbe()
        let queued = makeTaskState(agentId: agent, title: "queued-6")
        mgr.admitTaskForTesting(queued, start: probe.makeStart())
        defer { mgr.finalizeTask(queued.id) }

        #expect(queued.status == .queued)
        #expect(mgr.taskState(for: queued.id) != nil, "queued request must be registered, not dropped")
        #expect(probe.started == false, "queued request must have no execution side effects")
        // (Upstream also checks the toast list here: `sortedToastTasks`, stage 2.)
    }

    @Test func slotFree_promotesQueuedInFIFOOrder() async throws {
        let agent = UUID()
        let fillers = fillAgentCap(agent)

        let probe6 = StartProbe()
        let probe7 = StartProbe()
        let queued6 = makeTaskState(agentId: agent, title: "queued-6")
        let queued7 = makeTaskState(agentId: agent, title: "queued-7")
        mgr.admitTaskForTesting(queued6, start: probe6.makeStart())
        mgr.admitTaskForTesting(queued7, start: probe7.makeStart())
        defer {
            fillers.forEach { mgr.finalizeTask($0.id) }
            mgr.finalizeTask(queued6.id)
            mgr.finalizeTask(queued7.id)
        }
        #expect(queued6.status == .queued)
        #expect(queued7.status == .queued)

        // First slot frees: the OLDER queued task is promoted, not the newer.
        mgr.finalizeTask(fillers[0].id)
        #expect(queued6.status == .running)
        #expect(queued7.status == .queued)
        try await waitUntil { probe6.started }
        #expect(probe7.started == false)

        // Second slot frees: the remaining queued task follows.
        mgr.finalizeTask(fillers[1].id)
        #expect(queued7.status == .running)
        try await waitUntil { probe7.started }
    }

    @Test func waitingForInput_releasesSlotAndResumesWithoutRequeue() async throws {
        let agent = UUID()
        var fillers = (0..<4).map { i in
            let state = makeTaskState(agentId: agent, title: "filler-\(i)")
            mgr.registerTaskForTesting(state)
            return state
        }
        // Fifth slot: a task with a live observed session that will pause
        // on a clarify prompt.
        let pausing = makeTaskState(agentId: agent, title: "pausing")
        mgr.registerTaskForTesting(pausing)
        mgr.observeChatTask(pausing, session: pausing.chatSession!)
        fillers.append(pausing)

        let probe = StartProbe()
        let queued = makeTaskState(agentId: agent, title: "queued")
        mgr.admitTaskForTesting(queued, start: probe.makeStart())
        defer {
            fillers.forEach { mgr.finalizeTask($0.id) }
            mgr.finalizeTask(queued.id)
        }
        #expect(queued.status == .queued)

        // The run pauses for user input: it stays alive but releases its
        // slot, so the queued request is promoted instead of starving.
        pausing.chatSession?.isStreaming = true
        try await Task.sleep(for: .milliseconds(10))
        pausing.chatSession?.awaitingClarify =
            ClarifyPayload(question: "Which db?", options: [], allowMultiple: false)
        try await Task.sleep(for: .milliseconds(10))

        #expect(pausing.status == .waitingForInput)
        #expect(queued.status == .running)
        try await waitUntil { probe.started }

        // The user answers: the paused run resumes straight to `.running`
        // — it is never demoted back into the queue.
        pausing.chatSession?.awaitingClarify = nil
        pausing.chatSession?.isStreaming = true
        try await Task.sleep(for: .milliseconds(10))
        #expect(pausing.status == .running)
    }

    @Test func naturalCompletion_promotesQueued() async throws {
        let agent = UUID()
        var fillers = (0..<4).map { i in
            let state = makeTaskState(agentId: agent, title: "filler-\(i)")
            mgr.registerTaskForTesting(state)
            return state
        }
        let finishing = makeTaskState(agentId: agent, title: "finishing")
        mgr.registerTaskForTesting(finishing)
        mgr.observeChatTask(finishing, session: finishing.chatSession!)
        fillers.append(finishing)

        let probe = StartProbe()
        let queued = makeTaskState(agentId: agent, title: "queued")
        mgr.admitTaskForTesting(queued, start: probe.makeStart())
        defer {
            fillers.forEach { mgr.finalizeTask($0.id) }
            mgr.finalizeTask(queued.id)
        }
        #expect(queued.status == .queued)

        // The running task's stream ends cleanly → terminal `.completed`
        // → its slot promotes the queued request.
        finishing.chatSession?.isStreaming = true
        try await Task.sleep(for: .milliseconds(10))
        finishing.chatSession?.isStreaming = false
        try await Task.sleep(for: .milliseconds(10))

        #expect(finishing.status == .completed(summary: "Chat completed"))
        #expect(queued.status == .running)
        try await waitUntil { probe.started }
    }

    @Test func cancelQueuedTask_dropsDeferredStartPermanently() async throws {
        let agent = UUID()
        let fillers = fillAgentCap(agent)

        let probe = StartProbe()
        let queued = makeTaskState(agentId: agent, title: "queued-cancel")
        mgr.admitTaskForTesting(queued, start: probe.makeStart())
        #expect(queued.status == .queued)

        mgr.cancelTask(queued.id)
        #expect(queued.status == .cancelled)

        // Free every slot: the cancelled request must never be resurrected
        // by the promotion pass.
        fillers.forEach { mgr.finalizeTask($0.id) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.started == false)
        #expect(queued.status == .cancelled)

        mgr.finalizeTask(queued.id)
    }

    @Test func promotion_skipsAgentAtCapWithoutBlockingOtherAgents() async throws {
        let agentX = UUID()
        let agentY = UUID()
        let fillers = fillAgentCap(agentX)

        // Force BOTH follow-ups into the queue by zeroing the global limit,
        // then restore it: agent X's request stays capacity-blocked by the
        // per-agent cap while agent Y's is not.
        let originalConfig = ToastManager.shared.configuration
        var zeroed = originalConfig
        zeroed.maxConcurrentTasks = 0
        ToastManager.shared.updateConfiguration(zeroed)

        let probeX = StartProbe()
        let probeY = StartProbe()
        let queuedX = makeTaskState(agentId: agentX, title: "queued-x")
        let queuedY = makeTaskState(agentId: agentY, title: "queued-y")
        mgr.admitTaskForTesting(queuedX, start: probeX.makeStart())
        mgr.admitTaskForTesting(queuedY, start: probeY.makeStart())
        defer {
            fillers.forEach { mgr.finalizeTask($0.id) }
            mgr.finalizeTask(queuedX.id)
            mgr.finalizeTask(queuedY.id)
        }
        #expect(queuedX.status == .queued)
        #expect(queuedY.status == .queued)

        ToastManager.shared.updateConfiguration(originalConfig)
        mgr.pumpQueueForTesting()

        // Y jumps past the capacity-blocked X (no head-of-line blocking);
        // X stays queued in place.
        #expect(queuedY.status == .running)
        #expect(queuedX.status == .queued)
        try await waitUntil { probeY.started }
        #expect(probeX.started == false)

        // Once agent X frees a slot, its queued request follows.
        mgr.finalizeTask(fillers[0].id)
        #expect(queuedX.status == .running)
        try await waitUntil { probeX.started }
    }

    @Test func cancelAllTasks_cancelsRunningAndQueued() async throws {
        let agent = UUID()
        let running = makeTaskState(agentId: agent, title: "running")
        mgr.registerTaskForTesting(running)
        // Saturate the agent so the second request queues.
        let fillers = (0..<4).map { i in
            let state = makeTaskState(agentId: agent, title: "filler-\(i)")
            mgr.registerTaskForTesting(state)
            return state
        }

        let probe = StartProbe()
        let queued = makeTaskState(agentId: agent, title: "queued")
        mgr.admitTaskForTesting(queued, start: probe.makeStart())
        #expect(queued.status == .queued)

        mgr.cancelAllTasks()

        #expect(running.status == .cancelled)
        #expect(queued.status == .cancelled)
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.started == false)

        ([running, queued] + fillers).forEach { mgr.finalizeTask($0.id) }
    }
}
