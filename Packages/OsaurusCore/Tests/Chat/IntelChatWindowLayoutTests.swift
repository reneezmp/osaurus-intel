//
//  IntelChatWindowLayoutTests.swift
//  osaurusTests
//
//  Chat window layout on Intel (chat tabs stage 2, #2907 part C;
//  docs/CHAT_WINDOW_LAYOUT_INTEL.md): the Intel pieces upstream's tests
//  don't cover — agent ordering for the navigator's drag-to-reorder, chat
//  sessions reporting their activity, and the History pane's Intel content
//  search.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct IntelChatWindowLayoutTests {

    private func agent(_ name: String, order: Int? = nil) -> Agent {
        var agent = Agent(name: name)
        agent.order = order
        return agent
    }

    @Test func agentsSortByOrderThenName() {
        let sorted = AgentManager.sortedForDisplay([
            agent("Zed"), agent("alpha"), agent("Mid", order: 1), agent("First", order: 0),
        ])
        #expect(sorted.map(\.name) == ["First", "Mid", "alpha", "Zed"])
    }

    @Test func reorderPersistsAndSurvivesReload() async throws {
        try await ChatHistoryTestStorage.run {
            let a = agent("Alpha"), b = agent("Beta"), c = agent("Gamma")
            for each in [a, b, c] { AgentManager.shared.add(each) }
            defer {
                Task { for each in [a, b, c] { _ = await AgentManager.shared.delete(id: each.id) } }
            }
            func names() -> [String] {
                AgentManager.shared.agents.map(\.name).filter { ["Alpha", "Beta", "Gamma"].contains($0) }
            }
            #expect(names() == ["Alpha", "Beta", "Gamma"])

            AgentManager.shared.reorder(orderedIds: [c.id, a.id, b.id])
            #expect(names() == ["Gamma", "Alpha", "Beta"])
            #expect(AgentManager.shared.agents.first?.id == Agent.defaultId, "Default stays first")

            AgentManager.shared.refresh()
            #expect(names() == ["Gamma", "Alpha", "Beta"])
        }
    }

    @Test func sessionsReportActivityToTheMonitor() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let id = UUID()
            session.sessionId = id
            #expect(SessionActivityMonitor.shared.status(for: id) == nil)

            session.isStreaming = true
            #expect(SessionActivityMonitor.shared.status(for: id) == .working)

            session.awaitingClarify = ClarifyPayload(question: "Which one?")
            #expect(SessionActivityMonitor.shared.status(for: id) == .waitingForInput)

            session.awaitingClarify = nil
            session.isStreaming = false
            #expect(SessionActivityMonitor.shared.status(for: id) == nil)
        }
    }

    @Test func historyContentSearchScansMessageText() async throws {
        try await ChatHistoryTestStorage.run {
            ChatSessionsManager.shared.refresh()
            defer { ChatSessionsManager.shared.refresh() }
            let hit = ChatSessionData(
                title: "Groceries",
                turns: [ChatTurnData(id: UUID(), role: .user, content: "buy saffron", createdAt: Date())],
                agentId: Agent.defaultId)
            let miss = ChatSessionData(
                title: "Taxes",
                turns: [ChatTurnData(id: UUID(), role: .user, content: "file the forms", createdAt: Date())],
                agentId: Agent.defaultId)
            ChatSessionsManager.shared.save(hit)
            ChatSessionsManager.shared.save(miss)

            let ids = ChatHistoryList.sessionIds(withContentContaining: "SAFFRON")
            #expect(ids.contains(hit.id))
            #expect(!ids.contains(miss.id))
        }
    }

    @Test func pinWindowShortcutStateAndInspectorLayout() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            #expect(window.isWindowPinned == false)
            #expect(window.inspectorBadgeCount == nil, "no file history on Intel yet")
            window.toggleInspector()
            #expect(window.isRightRailOpen)
            #expect(window.effectiveInspectorPane == .history)
        }
    }

    // MARK: Background runs as tabs (upstream ChatWindowStateScopedTabsTests, step 5)

    private func makeRegistryTask(
        agentId: UUID,
        title: String,
        status: BackgroundTaskStatus = .running,
        source: SessionSource = .schedule
    ) -> BackgroundTaskState {
        let id = UUID()
        let context = ExecutionContext(id: id, agentId: agentId, title: title, source: source)
        return BackgroundTaskState(
            id: id,
            taskTitle: title,
            agentId: agentId,
            chatSession: context.chatSession,
            executionContext: context,
            status: status,
            currentStep: nil,
            source: source,
            sourcePluginId: nil,
            externalSessionKey: nil,
            showToast: true
        )
    }

    @Test func attachBackgroundTabIsNonActivating_andLandsInTheRunsAgentScope() async throws {
        try await ChatHistoryTestStorage.run {
            let agentB = agent("B-\(UUID().uuidString.prefix(6))")
            AgentManager.shared.add(agentB)
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            let activeBefore = window.activeTabId
            let sessionBefore = window.session

            let task = makeRegistryTask(agentId: agentB.id, title: "Nightly digest")
            BackgroundTaskManager.shared.registerTaskForTesting(task)
            defer { BackgroundTaskManager.shared.finalizeTask(task.id) }

            #expect(window.attachBackgroundTab(for: task))
            #expect(!window.attachBackgroundTab(for: task), "already shown → no duplicate")
            #expect(window.activeTabId == activeBefore, "does not steal focus")
            #expect(window.session === sessionBefore)
            #expect(window.tabs.count == 2)
            #expect(window.scopedTabs.count == 1, "invisible while Default is selected")
            #expect(task.chatSession?.windowState === window)

            window.switchAgent(to: agentB.id)
            #expect(window.session === task.chatSession, "picking B shows the run")
            #expect(window.tabs.count == 1, "Default's blank tab was dropped")
            _ = await AgentManager.shared.delete(id: agentB.id)
        }
    }

    @Test func closingARunningRunsTabKeepsTheRun_closingAFinishedOneDismissesIt() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.session.turns.append(ChatTurn(role: .user, content: "default work"))
            let manager = BackgroundTaskManager.shared

            let running = makeRegistryTask(agentId: Agent.defaultId, title: "Long job")
            manager.registerTaskForTesting(running)
            defer { manager.finalizeTask(running.id) }
            window.attachBackgroundTab(for: running)
            let runTab = try #require(window.tabs.first { $0.session === running.chatSession })
            window.closeTab(id: runTab.id)
            #expect(manager.taskState(for: running.id) === running, "the run stays registered")
            #expect(running.chatSession?.windowState == nil, "view link severed")
            #expect(DetachedChatRunRegistry.shared.sessions.isEmpty, "the registry owns it, not the detached holder")

            let done = makeRegistryTask(
                agentId: Agent.defaultId, title: "Done job", status: .completed(success: true, summary: "ok"))
            manager.registerTaskForTesting(done)
            window.attachBackgroundTab(for: done)
            let doneTab = try #require(window.tabs.first { $0.session === done.chatSession })
            window.closeTab(id: doneTab.id)
            #expect(manager.taskState(for: done.id) == nil, "closing the tab is the dismiss gesture")
        }
    }

    @Test func focusTabBringsARunsTabForward_andTheSnapshotSkipsIt() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.session.turns.append(ChatTurn(role: .user, content: "default work"))
            let task = makeRegistryTask(agentId: Agent.defaultId, title: "Same agent run", source: .http)
            task.chatSession?.turns.append(ChatTurn(role: .user, content: "run"))
            BackgroundTaskManager.shared.registerTaskForTesting(task)
            defer { BackgroundTaskManager.shared.finalizeTask(task.id) }
            window.attachBackgroundTab(for: task)
            #expect(window.scopedTabs.count == 2, "same agent: the run shows beside the chat")

            #expect(window.focusTab(forSessionId: task.id))
            #expect(window.session === task.chatSession)
            #expect(!window.tabLayoutSnapshot().tabs.contains { $0.sessionId == task.id },
                "registry runs are not remembered as tabs")
        }
    }
}
