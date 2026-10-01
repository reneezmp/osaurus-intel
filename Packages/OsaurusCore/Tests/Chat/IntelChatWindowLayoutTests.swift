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
}
