//
//  ChatWindowSessionOwnershipTests.swift
//  osaurusTests
//
//  Upstream 979d53b40, Intel adaptation: a saved conversation has one
//  mutable window owner. Opening it from another window must reveal the
//  owner instead of hydrating a competing copy that could overwrite saves.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ChatWindowSessionOwnershipTests {

    @Test
    func openSessionRoutesToItsOwningWindow() {
        let sessionId = UUID()
        let owner = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
        owner.session.sessionId = sessionId

        ChatWindowManager.shared.withRegisteredWindowStateForTesting(owner) {
            #expect(
                ChatWindowManager.shared.revealOpenSession(sessionId, showImmediately: false)
                    == owner.windowId
            )
            // The owner itself is never treated as a competing copy.
            #expect(
                ChatWindowManager.shared.revealOpenSession(
                    sessionId, excludingWindowId: owner.windowId, showImmediately: false
                ) == nil
            )
            #expect(ChatWindowManager.shared.revealOpenSession(UUID(), showImmediately: false) == nil)
        }
    }

    @Test
    func secondWindowDoesNotLoadACopyOfAnOwnedSession() {
        let sessionId = UUID()
        let owner = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
        owner.session.sessionId = sessionId
        let other = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
        let otherBefore = other.session.sessionId

        var data = ChatSessionData(id: sessionId, selectedModel: nil, agentId: Agent.defaultId)
        data.title = "Owned"
        ChatWindowManager.shared.withRegisteredWindowStateForTesting(owner) {
            other.loadSession(data)
        }
        #expect(other.session.sessionId == otherBefore)
        #expect(owner.session.sessionId == sessionId)
    }
}
