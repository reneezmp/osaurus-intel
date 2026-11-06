//
//  BackgroundTaskRegistrationSignalTests.swift
//  osaurusTests
//
//  `BackgroundTaskManager.taskRegistered` is how chat windows learn that a
//  run should appear as a tab of its agent. It must fire for visible runs
//  backed by a chat session (dispatched, adopted, and runs hosted for a
//  remote caller of a shared agent) and stay silent for spawned-helper
//  mirrors (no chat of their own) and headless `showToast == false` runs.
//  `tasksForTabs()` applies the same filter for windows that open later.
//
//  Intel: upstream's mirror and inbound-run cases are left out until Intel
//  has subagent mirrors (`W-subagents`) and inbound shared runs
//  (`W-workspaces-sharing`). The test target has no `OSAURUS_INTEL` define,
//  so they are removed rather than `#if`-fenced.
//

import Combine
import Foundation
import Testing

@testable import OsaurusCore

@MainActor
private func makeState(
    agentId: UUID = UUID(),
    status: BackgroundTaskStatus = .running,
    source: SessionSource = .schedule,
    showToast: Bool = true
) -> BackgroundTaskState {
    let id = UUID()
    let context = ExecutionContext(id: id, agentId: agentId, title: "run", source: source)
    context.chatSession.chatEngineFactory = { MockChatEngine() }
    return BackgroundTaskState(
        id: id,
        taskTitle: "run",
        agentId: agentId,
        chatSession: context.chatSession,
        executionContext: context,
        status: status,
        currentStep: nil,
        source: source,
        sourcePluginId: nil,
        externalSessionKey: nil,
        showToast: showToast
    )
}

@MainActor
struct BackgroundTaskRegistrationSignalTests {

    private let mgr = BackgroundTaskManager.makeForTesting()

    @Test func taskRegistered_firesForVisibleRunsWithASession() {
        var received: [UUID] = []
        let sub = mgr.taskRegistered.sink { received.append($0.id) }
        defer { sub.cancel() }

        let scheduled = makeState(source: .schedule)
        let api = makeState(source: .http)
        let adopted = makeState(source: .chat)
        [scheduled, api, adopted].forEach { mgr.registerTaskThroughProductionPathForTesting($0) }
        defer { [scheduled, api, adopted].forEach { mgr.finalizeTask($0.id) } }

        #expect(received == [scheduled.id, api.id, adopted.id], "one synchronous signal per registration, in order")
    }

    @Test func taskRegistered_staysSilentForMirrorsAndHeadlessRuns() {
        var received: [UUID] = []
        let sub = mgr.taskRegistered.sink { received.append($0.id) }
        defer { sub.cancel() }

        let headless = makeState(source: .http, showToast: false)
        mgr.registerTaskThroughProductionPathForTesting(headless)
        defer { mgr.finalizeTask(headless.id) }

        #expect(received.isEmpty)
    }


    @Test func tasksForTabs_matchesTheSignalsFilter_andOrdersByCreation() {
        let first = makeState(source: .schedule)
        let headless = makeState(showToast: false)
        let finished = makeState(status: .completed(summary: "ok"))
        [first, headless, finished].forEach { mgr.registerTaskForTesting($0) }
        defer { [first, headless, finished].forEach { mgr.finalizeTask($0.id) } }

        let ids = mgr.tasksForTabs().map(\.id)
        #expect(ids.contains(first.id))
        #expect(ids.contains(finished.id), "finished runs stay visible as tabs until dismissed")
        #expect(!ids.contains(headless.id))
    }

    @Test func taskOwningSession_resolvesLiveInstanceAndIdStandIn() {
        let run = makeState()
        mgr.registerTaskForTesting(run)
        defer { mgr.finalizeTask(run.id) }
        let live = run.chatSession!

        #expect(mgr.task(owning: live) === run)

        // A cold stand-in for the same persisted row (hibernated / retained
        // tab) resolves by id.
        let standIn = ChatSession()
        standIn.sessionId = run.id
        #expect(mgr.task(owning: standIn) === run)


        let unrelated = ChatSession()
        unrelated.sessionId = UUID()
        #expect(mgr.task(owning: unrelated) == nil)
    }
}
