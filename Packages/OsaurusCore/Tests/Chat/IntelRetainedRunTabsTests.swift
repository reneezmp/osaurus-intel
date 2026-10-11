//
//  IntelRetainedRunTabsTests.swift
//  osaurusTests
//
//  W-chat-tabs (2026-10-11): finished runs stay as tabs until closed, across
//  relaunch (upstream's retained Activity tabs). Isolated managers persist to
//  a throwaway defaults suite, never the user's.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct IntelRetainedRunTabsTests {
    private func makeRegistryTask(
        title: String,
        status: BackgroundTaskStatus,
        showToast: Bool = true
    ) -> BackgroundTaskState {
        let id = UUID()
        let context = ExecutionContext(id: id, agentId: Agent.defaultId, title: title, source: .schedule)
        return BackgroundTaskState(
            id: id,
            taskTitle: title,
            agentId: Agent.defaultId,
            chatSession: context.chatSession,
            executionContext: context,
            status: status,
            source: .schedule,
            showToast: showToast
        )
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "IntelRetainedRunTabsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func retainedTabsRestoreAcrossManagerRelaunchWithoutLiveSession() async throws {
        try await ChatHistoryTestStorage.run {
            try withDefaults { defaults in
                let first = BackgroundTaskManager.makeForTestingRetaining(defaults: defaults)
                let state = makeRegistryTask(
                    title: "Keep across restart", status: .completed(success: false, summary: "boom"))
                let session = try #require(state.chatSession)
                session.turns = [ChatTurn(role: .user, content: "What did we decide?")]
                session.save()
                first.registerTaskForTesting(state)
                first.dehydrateTaskForTesting(state.id)
                #expect(first.isTaskDehydratedForTesting(state.id))

                // A fresh manager simulates the next launch: metadata only.
                let relaunched = BackgroundTaskManager.makeForTestingRetaining(defaults: defaults)
                let restored = try #require(relaunched.taskState(for: state.id))
                #expect(restored.taskTitle == "Keep across restart")
                #expect(restored.status == .completed(success: false, summary: "boom"))
                #expect(restored.source == .schedule)
                #expect(relaunched.isTaskDehydratedForTesting(state.id))
                #expect(relaunched.tasksForTabs().contains { $0.id == state.id })

                // Closing its tab dismisses it for good.
                relaunched.finalizeTask(state.id)
                let third = BackgroundTaskManager.makeForTestingRetaining(defaults: defaults)
                #expect(third.taskState(for: state.id) == nil)
            }
        }
    }

    @Test func runningAndHeadlessRunsAreNeverRetained() async throws {
        try await ChatHistoryTestStorage.run {
            try withDefaults { defaults in
                let first = BackgroundTaskManager.makeForTestingRetaining(defaults: defaults)
                let running = makeRegistryTask(title: "Still going", status: .running)
                let headless = makeRegistryTask(
                    title: "Headless", status: .completed(success: true, summary: "ok"), showToast: false)
                let done = makeRegistryTask(title: "Done", status: .cancelled)
                for task in [running, headless, done] { first.registerTaskForTesting(task) }
                first.dehydrateTaskForTesting(done.id)

                let relaunched = BackgroundTaskManager.makeForTestingRetaining(defaults: defaults)
                #expect(relaunched.taskState(for: running.id) == nil)
                #expect(relaunched.taskState(for: headless.id) == nil)
                #expect(relaunched.taskState(for: done.id)?.status == .cancelled)
            }
        }
    }

    @Test func aRetainedRunComesBackAsAHibernatedTab_andClosingItDismissesIt() async throws {
        try await ChatHistoryTestStorage.run {
            let manager = BackgroundTaskManager.shared
            let task = makeRegistryTask(title: "Overnight", status: .completed(success: true, summary: "ok"))
            let session = try #require(task.chatSession)
            session.turns = [ChatTurn(role: .user, content: "summarize the night")]
            session.save()
            manager.registerTaskForTesting(task)
            manager.dehydrateTaskForTesting(task.id)
            defer { manager.finalizeTask(task.id) }

            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.session.turns.append(ChatTurn(role: .user, content: "default work"))
            #expect(window.attachRetainedTab(for: task))
            #expect(!window.attachRetainedTab(for: task), "already shown → no duplicate")
            let tab = try #require(window.tabs.first { $0.session.sessionId == task.id })
            #expect(tab.isHibernated)
            #expect(!window.tabLayoutSnapshot().tabs.contains { $0.sessionId == task.id },
                "the registry restores it, not the remembered-tabs record")

            window.closeTab(id: tab.id)
            #expect(manager.taskState(for: task.id) == nil, "closing the tab is the dismiss gesture")
        }
    }
}
