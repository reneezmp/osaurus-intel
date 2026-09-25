//
//  ChatWindowStateProjectPageDismissTests.swift
//  osaurusTests
//
//  Upstream ee9adf6ae (#2709), Intel adaptation: picking an agent in the
//  sidebar dismisses the project page, including the already-active agent
//  where `switchAgent` returns early.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ChatWindowStateProjectPageDismissTests {

    @Test func pickingTheActiveAgentClosesTheProjectPage() {
        let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
        window.openProjectId = UUID()
        window.switchAgent(to: window.agentId)
        #expect(window.openProjectId == nil)
        #expect(window.isProjectPageVisible == false)
    }
}
