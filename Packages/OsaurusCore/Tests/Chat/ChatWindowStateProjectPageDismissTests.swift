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

/// Upstream 3a17bc04d (#2728), Intel adaptation: the chat floor clamps to
/// what the window's screen can show.
@MainActor
struct ChatWindowMinimumSizeTests {

    @Test func floorClampsToASmallScreenAndKeepsDesignOtherwise() {
        let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
        let design = ChatWindowState.designMinimumContentSize

        window.updateMinimumContentSize(availableContentSize: CGSize(width: 1024, height: 573))
        #expect(window.minimumContentSize == CGSize(width: design.width, height: 573))

        window.updateMinimumContentSize(availableContentSize: CGSize(width: 1440, height: 800))
        #expect(window.minimumContentSize == design)

        // Unknown screen keeps the design floor.
        window.updateMinimumContentSize(availableContentSize: .zero)
        #expect(window.minimumContentSize == design)
    }

    @Test func availableSizeSubtractsTheToolbarStrip() {
        #expect(ChatWindowManager.chatAvailableContentSize(on: nil) == .zero)
    }
}
