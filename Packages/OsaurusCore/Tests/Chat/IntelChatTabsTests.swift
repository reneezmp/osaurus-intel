//
//  IntelChatTabsTests.swift
//  osaurusTests
//
//  Browser-style chat tabs on Intel (upstream #2630, #2740, #2911;
//  docs/CHAT_TABS_INTEL.md). Ports upstream's scoped-tab and remembered-tab
//  cases that do not depend on the background-task registry, plus the
//  Intel pieces: running tabs held by `DetachedChatRunRegistry`, in-memory
//  hibernation, ⇧⌘T, the window shortcuts and the pre-tabs migration.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct IntelChatTabsTests {

    private func makeAgent(_ label: String) -> Agent {
        let agent = Agent(name: "\(label)-\(UUID().uuidString.prefix(6))")
        AgentManager.shared.add(agent)
        return agent
    }

    private func addTurn(_ session: ChatSession, _ text: String) {
        session.turns.append(ChatTurn(role: .user, content: text))
    }

    /// A saved conversation in `ChatSessionsManager` (the test root).
    private func storedSession(_ title: String, agentId: UUID = Agent.defaultId) -> ChatSessionData {
        var data = ChatSessionData(
            title: title,
            turns: [ChatTurnData(id: UUID(), role: .user, content: title, createdAt: Date())],
            agentId: agentId
        )
        data.updatedAt = Date()
        ChatSessionsManager.shared.save(data)
        return data
    }

    /// Runs `body` with chat history, agents and the sessions manager
    /// pointed at a throwaway root (docs/TEST_STORAGE_SAFETY.md).
    private func withStorage(_ body: @MainActor @Sendable () async throws -> Void) async throws {
        try await ChatHistoryTestStorage.run {
            ChatSessionsManager.shared.refresh()
            DetachedChatRunRegistry.shared.removeAllForTesting()
            defer {
                DetachedChatRunRegistry.shared.removeAllForTesting()
                ChatSessionsManager.shared.refresh()
            }
            try await body()
        }
    }

    private func flushMainQueue() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { cont.resume() }
        }
    }

    // MARK: Scope (upstream ChatWindowStateScopedTabsTests)

    @Test func scopedTabsShowOnlyTheActiveAgentsTabs_andBlankOutgoingTabIsDropped() async throws {
        try await withStorage {
            let agentB = makeAgent("B")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            addTurn(window.session, "default work")
            let defaultTab = window.activeTabId

            window.newTab(agentId: agentB.id)
            #expect(window.activeScope == .local(agentB.id))
            #expect(window.tabs.count == 2)
            #expect(window.scopedTabs.map(\.id) == [window.activeTabId])

            window.switchAgent(to: Agent.defaultId)
            #expect(window.activeTabId == defaultTab)
            #expect(window.tabs.count == 1, "B's blank tab is dropped, not left behind")
            _ = await AgentManager.shared.delete(id: agentB.id)
        }
    }

    @Test func switchingAgentFromAConversationKeepsItInItsTab() async throws {
        try await withStorage {
            let agentB = makeAgent("B")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            addTurn(window.session, "keep me")
            let kept = window.session

            window.switchAgent(to: agentB.id)
            #expect(window.tabs.count == 2)
            #expect(window.session !== kept)
            #expect(window.session.agentId == agentB.id)
            #expect(kept.turns.count == 1, "the conversation was not reset")

            // A blank tab is repurposed instead of opening another one.
            window.switchAgent(to: Agent.defaultId)
            let c = makeAgent("C")
            window.newTab()
            let blank = window.activeTabId
            window.switchAgent(to: c.id)
            #expect(window.activeTabId == blank)
            #expect(window.session.agentId == c.id)
            _ = await AgentManager.shared.delete(id: agentB.id)
            _ = await AgentManager.shared.delete(id: c.id)
        }
    }

    @Test func switchAgentPrefersTabAwaitingInput_thenMostRecentlyUsed() async throws {
        try await withStorage {
            let agentB = makeAgent("B")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            addTurn(window.session, "default work")

            window.newTab(agentId: agentB.id)
            let b1 = window.activeTabId
            addTurn(window.session, "b1")
            window.newTab(agentId: agentB.id)
            let b2 = window.activeTabId
            addTurn(window.session, "b2")
            window.selectTab(id: b1)

            window.switchAgent(to: Agent.defaultId)
            #expect(window.tabs.count == 3, "non-blank tabs are never dropped")
            window.switchAgent(to: agentB.id)
            #expect(window.activeTabId == b1, "most recently used B tab wins")

            window.switchAgent(to: Agent.defaultId)
            let b2Session = try #require(window.tabs.first { $0.id == b2 }?.session)
            b2Session.awaitingClarify = ClarifyPayload(question: "which one?")
            window.switchAgent(to: agentB.id)
            #expect(window.activeTabId == b2, "the tab that needs input wins")
            b2Session.awaitingClarify = nil
            _ = await AgentManager.shared.delete(id: agentB.id)
        }
    }

    @Test func adjacentAndMoveStayInsideTheActiveAgent() async throws {
        try await withStorage {
            let agentB = makeAgent("B")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            addTurn(window.session, "d1")
            let d1 = window.activeTabId
            window.newTab(agentId: agentB.id)
            addTurn(window.session, "b1")
            let b1 = window.activeTabId
            window.newTab(agentId: Agent.defaultId)
            addTurn(window.session, "d2")
            let d2 = window.activeTabId
            #expect(window.tabs.map(\.id) == [d1, b1, d2])
            #expect(window.scopedTabs.map(\.id) == [d1, d2])

            window.selectAdjacentTab(offset: 1)
            #expect(window.activeTabId == d1, "wraps within Default's tabs, skipping B")
            window.selectAdjacentTab(offset: -1)
            #expect(window.activeTabId == d2)

            window.moveTab(id: d2, to: 0)
            #expect(window.scopedTabs.map(\.id) == [d2, d1])
            #expect(window.tabs.map(\.id) == [d2, d1, b1])
            _ = await AgentManager.shared.delete(id: agentB.id)
        }
    }

    @Test func closingTabsPicksTheNeighbor_andTheLastConversationLeavesABlankChat() async throws {
        try await withStorage {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            addTurn(window.session, "one")
            let first = window.activeTabId
            window.newTab()
            addTurn(window.session, "two")
            let second = window.activeTabId

            window.closeTab(id: second)
            #expect(window.activeTabId == first)
            #expect(window.tabs.count == 1)

            // ⌘W on the lone conversation: a blank chat replaces it.
            #expect(window.closeActiveTabIfPossible())
            #expect(window.tabs.count == 1)
            #expect(window.session.turns.isEmpty)
            // ⌘W on the lone blank tab falls through to closing the window.
            #expect(!window.closeActiveTabIfPossible())
        }
    }

    @Test func newChatReusesABlankTab_otherwiseOpensAnother() async throws {
        try await withStorage {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.startNewChat()
            #expect(window.tabs.count == 1)
            addTurn(window.session, "busy")
            window.startNewChat()
            #expect(window.tabs.count == 2)
            #expect(window.session.turns.isEmpty)
            // ⌘T always opens another tab, even from a blank one.
            window.newTab()
            #expect(window.tabs.count == 3)
        }
    }

    // MARK: Opening saved chats

    @Test func openingAChatAlreadyInAnotherTabFocusesIt() async throws {
        try await withStorage {
            let a = storedSession("Alpha")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.openSessionInNewTab(a)
            let alphaTab = window.activeTabId
            #expect(window.tabs.count == 1, "the blank tab is reused")
            #expect(window.session.turns.count == 1)

            window.newTab()
            window.loadSession(a)
            #expect(window.activeTabId == alphaTab, "focused, not loaded twice")

            window.openSessionInNewTab(a)
            #expect(window.activeTabId == alphaTab)
        }
    }

    @Test func otherWindowsTabsOwnTheirChats() async throws {
        try await withStorage {
            let a = storedSession("Alpha")
            let owner = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { owner.cleanup() }
            owner.openSessionInNewTab(a)
            owner.newTab()
            let other = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { other.cleanup() }

            ChatWindowManager.shared.withRegisteredWindowStateForTesting(owner) {
                #expect(
                    ChatWindowManager.shared.revealOpenSession(a.id, showImmediately: false)
                        == owner.windowId,
                    "an inactive tab still owns its chat")
                other.loadSession(a)
            }
            #expect(other.session.sessionId == nil, "no competing copy")
        }
    }

    @Test func deletingAChatShownInAnInactiveTabClosesThatTab() async throws {
        try await withStorage {
            let a = storedSession("Alpha")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.openSessionInNewTab(a)
            window.newTab()
            #expect(window.tabs.count == 2)

            window.prepareForSessionDeletion(id: a.id)
            ChatSessionsManager.shared.delete(id: a.id)
            #expect(window.tabs.count == 1)
            #expect(ChatSessionsManager.shared.session(for: a.id) == nil)
        }
    }

    @Test func sidebarEditsReachEveryOpenTabOfThatChat() async throws {
        try await withStorage {
            let a = storedSession("Alpha")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.openSessionInNewTab(a)
            let alpha = window.session
            window.newTab()
            window.syncTabSessions(withId: a.id) { $0.title = "Renamed" }
            #expect(alpha.title == "Renamed")
        }
    }

    // MARK: Running tabs (DetachedChatRunRegistry)

    @Test func closingARunningTabKeepsItAlive_andReopeningAttachesTheSameInstance() async throws {
        try await withStorage {
            let a = storedSession("Running")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.openSessionInNewTab(a)
            let running = window.session
            running.isStreaming = true
            window.newTab()

            let runningTab = try #require(window.tabs.first { $0.session === running })
            window.closeTab(id: runningTab.id)
            #expect(DetachedChatRunRegistry.shared.liveSession(forSessionId: a.id) === running)
            #expect(running.windowState == nil)

            window.loadSession(a)
            #expect(window.session === running, "the live run, not a copy from disk")
            #expect(running.windowState === window)
            #expect(DetachedChatRunRegistry.shared.liveSession(forSessionId: a.id) == nil)
            running.isStreaming = false
        }
    }

    @Test func aDetachedRunLeavesTheRegistryWhenItEnds() async throws {
        try await withStorage {
            let a = storedSession("Ending")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.openSessionInNewTab(a)
            let running = window.session
            running.isStreaming = true
            window.newTab()
            window.closeTab(id: try #require(window.tabs.first { $0.session === running }).id)
            #expect(DetachedChatRunRegistry.shared.sessions.count == 1)

            running.isStreaming = false
            await flushMainQueue()
            await flushMainQueue()
            #expect(DetachedChatRunRegistry.shared.sessions.isEmpty)
        }
    }

    @Test func loadingAChatOverARunningTabOpensItInANewTab() async throws {
        try await withStorage {
            let a = storedSession("Alpha")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            addTurn(window.session, "working")
            let running = window.session
            running.isStreaming = true

            window.loadSession(a)
            #expect(window.tabs.count == 2)
            #expect(window.session !== running)
            #expect(window.session.sessionId == a.id)
            running.isStreaming = false
        }
    }

    // MARK: Recently closed (⇧⌘T)

    @Test func reopenLastClosedTabBringsItBackInPlace() async throws {
        try await withStorage {
            let a = storedSession("Alpha")
            let b = storedSession("Beta")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.openSessionInNewTab(a)
            window.openSessionInNewTab(b)
            let alphaTab = window.tabs[0].id
            #expect(!window.canReopenClosedTab)

            window.closeTab(id: alphaTab)
            #expect(window.canReopenClosedTab)
            window.reopenLastClosedTab()
            #expect(window.session.sessionId == a.id)
            #expect(window.tabs.map { $0.session.sessionId } == [a.id, b.id])
        }
    }

    // MARK: Hibernation

    @Test func coldTabsHibernate_andWakeWithTheirTranscript() async throws {
        try await withStorage {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            let chats = (0..<(ChatWindowState.warmTabLimit + 2)).map { storedSession("Chat \($0)") }
            for chat in chats { window.openSessionInNewTab(chat) }

            let hibernated = window.tabs.filter(\.isHibernated)
            #expect(!hibernated.isEmpty)
            #expect(window.liveTabSessions.count <= ChatWindowState.warmTabLimit)
            let cold = try #require(hibernated.first)
            #expect(cold.session.turns.isEmpty)
            #expect(!cold.session.title.isEmpty)

            window.selectTab(id: cold.id)
            let woken = try #require(window.tabs.first { $0.id == cold.id })
            #expect(!woken.isHibernated)
            #expect(window.session.turns.count == 1)
        }
    }

    // MARK: Remembered tabs (upstream ChatTabLayoutPersistenceTests)

    private func makeStore() -> (ChatTabLayoutStore, UserDefaults, String) {
        let suite = "osaurus-tab-layout-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ChatTabLayoutStore(defaults: defaults), defaults, suite)
    }

    @Test func storeRoundTripsRecords_andForgetsRemovedWindows() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = UUID()
        let record = ChatTabLayoutRecord(
            tabs: [.init(sessionId: UUID(), lastActivatedAt: Date())],
            activeSessionId: nil, savedAt: Date())
        store.save(ChatTabLayout(windows: [window: record]))
        #expect(store.load().windows[window] == record)
        #expect(store.orphanRecords(openWindowIds: [window]).isEmpty)
        #expect(store.orphanRecords(openWindowIds: []).count == 1)
        store.remove(windowIds: [window])
        #expect(store.load().windows.isEmpty)
    }

    @Test func snapshotRecordsSavedTabsInOrder_andSkipsBlankOnes() async throws {
        try await withStorage {
            let a = storedSession("Alpha")
            let b = storedSession("Beta")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.openSessionInNewTab(a)
            window.openSessionInNewTab(b)
            window.newTab()

            let snapshot = window.tabLayoutSnapshot()
            #expect(snapshot.tabs.map(\.sessionId) == [a.id, b.id])
            #expect(snapshot.activeSessionId == nil, "the blank tab is not a saved chat")
            window.selectTab(id: window.tabs[1].id)
            #expect(window.tabLayoutSnapshot().activeSessionId == b.id)
        }
    }

    @Test func restoreBringsTabsBackHibernated_andOpensOnTheRememberedChat() async throws {
        try await withStorage {
            let a = storedSession("Alpha")
            let b = storedSession("Beta")
            let gone = UUID()
            let record = ChatTabLayoutRecord(
                tabs: [
                    .init(sessionId: a.id, lastActivatedAt: Date()),
                    .init(sessionId: gone, lastActivatedAt: Date()),
                    .init(sessionId: b.id, lastActivatedAt: Date()),
                ],
                activeSessionId: b.id, savedAt: Date())
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            #expect(window.restoreTabs(from: record) == 2, "the deleted chat is skipped")
            #expect(window.tabs.count == 2, "the initial blank tab was dropped")
            #expect(window.session.sessionId == b.id)
            #expect(window.session.turns.count == 1, "the active one is awake")
            let alpha = try #require(window.tabs.first { $0.session.sessionId == a.id })
            #expect(alpha.isHibernated)
        }
    }

    @Test func restoreKeepsAChatTheUserAlreadyOpened() async throws {
        try await withStorage {
            let a = storedSession("Alpha")
            let b = storedSession("Beta")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.openSessionInNewTab(a)
            let record = ChatTabLayoutRecord(
                tabs: [.init(sessionId: b.id, lastActivatedAt: Date())],
                activeSessionId: b.id, savedAt: Date())
            #expect(window.restoreTabs(from: record) == 1)
            #expect(window.session.sessionId == a.id)
        }
    }

    /// A window opened for something specific (an agent, Ask AI) keeps its
    /// fresh chat in front; remembered tabs come back behind it.
    @Test func restoreWithoutSelectingKeepsTheFreshChatInFront() async throws {
        try await withStorage {
            let a = storedSession("Alpha")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            let fresh = window.activeTabId
            let record = ChatTabLayoutRecord(
                tabs: [.init(sessionId: a.id, lastActivatedAt: Date())],
                activeSessionId: a.id, savedAt: Date())
            #expect(window.restoreTabs(from: record, selectsActive: false) == 1)
            #expect(window.activeTabId == fresh)
            #expect(window.tabs.count == 2)
        }
    }

    @Test func thePreTabsLastChatComesBackOnce() async throws {
        let suite = "osaurus-last-chat-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IntelLastChatStore(defaults: defaults)
        let id = UUID()
        defaults.set(id.uuidString, forKey: IntelLastChatStore.defaultsKey)

        let record = try #require(ChatWindowManager.legacyLastChatRecord(from: store))
        #expect(record.tabs.map(\.sessionId) == [id])
        #expect(record.activeSessionId == id)
        #expect(ChatWindowManager.legacyLastChatRecord(from: store) == nil)
    }

    // MARK: Scroll memory (#2911)

    @Test func hibernationSharesTheSavedScrollPosition() async throws {
        try await withStorage {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            let chats = (0..<(ChatWindowState.warmTabLimit + 1)).map { storedSession("Chat \($0)") }
            window.openSessionInNewTab(chats[0])
            let store = window.session.scrollPositionStore
            store.position = ThreadScrollPosition(isPinnedToBottom: false, blockId: "b", offsetFromRowTop: 4)
            for chat in chats.dropFirst() { window.openSessionInNewTab(chat) }

            let first = try #require(window.tabs.first { $0.session.sessionId == chats[0].id })
            #expect(first.isHibernated)
            #expect(first.session.scrollPositionStore === store)
        }
    }

    // MARK: Shortcuts

    @Test func tabShortcutsParse() {
        #expect(ChatTabShortcut(keyCode: 17, characters: "t", flags: .command) == .newTab)
        #expect(ChatTabShortcut(keyCode: 17, characters: "T", flags: [.command, .shift]) == .reopenClosedTab)
        #expect(ChatTabShortcut(keyCode: 48, characters: "\t", flags: .control) == .nextTab)
        #expect(ChatTabShortcut(keyCode: 48, characters: "\t", flags: [.control, .shift]) == .previousTab)
        #expect(ChatTabShortcut(keyCode: 30, characters: "}", flags: [.command, .shift]) == .nextTab)
        #expect(ChatTabShortcut(keyCode: 33, characters: "{", flags: [.command, .shift]) == .previousTab)
        // ⌘N stays with the File menu (Settings ▸ Conversation decides).
        #expect(ChatTabShortcut(keyCode: 45, characters: "n", flags: .command) == nil)
        #expect(ChatTabShortcut(keyCode: 17, characters: "t", flags: []) == nil)
    }

    @Test func shortcutsStandDownOnTheProjectPage() async throws {
        try await withStorage {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.openProjectId = UUID()
            #expect(!ChatTabShortcut.newTab.perform(on: window))
            #expect(window.tabs.count == 1)
            window.openProjectId = nil
            #expect(ChatTabShortcut.newTab.perform(on: window))
            #expect(window.tabs.count == 2)
        }
    }
}
