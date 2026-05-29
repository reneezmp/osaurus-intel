//
//  ChatSidebarSection.swift
//  OsaurusCore
//
//  M10.5 Phase B: Extracted sidebar section from ChatView.
//  Separate View struct preserves @ObservedObject identity and gets its
//  own per-expression type-checking budget.
//

import SwiftUI

struct ChatSidebarSection: View {
    @ObservedObject var windowState: ChatWindowState
    var sessionId: UUID?
    var sidebarWidth: CGFloat

    var body: some View {
        let fSessions: [ChatSessionData] = windowState.filteredSessions
        let aId: UUID = windowState.agentId
        let sessId: UUID? = sessionId
        VStack(alignment: .leading, spacing: 0) {
            if windowState.showSidebar {
                ChatSessionSidebar(
                    sessions: fSessions,
                    agentId: aId,
                    currentSessionId: sessId,
                    onSelect: { [weak windowState] data in windowState?.loadSession(data) },
                    onNewChat: { [weak windowState] in windowState?.startNewChat() },
                    onDelete: { _ in },
                    onRename: { _, _ in },
                    onSetArchived: { _, _ in },
                    onExport: { _, _ in }
                )
            }
        }
        .frame(width: sidebarWidth, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .zIndex(1)
    }
}
