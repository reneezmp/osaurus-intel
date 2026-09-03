//
//  ProjectDetailView.swift
//  osaurus
//
//  Project page: shared instructions editor + member chat list with search.
//  Presented via `ThemedAlertCenter` custom content from the sidebar's
//  Projects tab (see `ChatSessionSidebar.presentProjectDetail`).
//
//  Intel fork note: upstream's project page is a full two-column content-
//  view replacement with a Knowledge section and per-project default
//  agent picker. This fork keeps Knowledge amputated and, to stay inside
//  the amputation-scarred `ChatView.swift` without risking the build,
//  presents the project page as a themed-alert sheet instead of swapping
//  the window's main content — same data, a lighter-weight shell.
//

import SwiftUI

struct ProjectDetailView: View {
    let projectId: UUID
    var onSelectChat: (ChatSessionData) -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var projectManager = ProjectManager.shared
    @ObservedObject private var sessionsManager = ChatSessionsManager.shared
    @ObservedObject private var agentManager = AgentManager.shared

    @State private var instructions: String = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var query: String = ""
    @FocusState private var isSearchFocused: Bool
    @State private var showingAddChats = false

    private var project: Project? { projectManager.project(for: projectId) }

    private var memberChats: [ChatSessionData] {
        sessionsManager.sessions(forProject: projectId)
    }

    private var filteredChats: [ChatSessionData] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return memberChats }
        return memberChats.filter { SearchService.matches(query: trimmed, in: $0.title) }
    }

    private var ungroupedChats: [ChatSessionData] {
        sessionsManager.sessions.values
            .filter { $0.projectId == nil && !$0.archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            instructionsSection

            Divider().opacity(0.5)

            chatsHeader

            SidebarSearchField(
                text: $query,
                placeholder: "Search chats...",
                isFocused: $isSearchFocused,
                isSearching: false,
                showsRestingBorder: true
            )

            if memberChats.isEmpty {
                emptyChats
            } else if filteredChats.isEmpty {
                SidebarNoResultsView(searchQuery: query) { query = "" }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredChats) { session in
                            chatRow(session)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .onAppear { instructions = project?.instructions ?? "" }
        .sheet(isPresented: $showingAddChats) {
            addChatsSheet
        }
    }

    // MARK: - Instructions

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Instructions", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text("Shared context added to every chat in this project.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)

            TextEditor(text: $instructions)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 90, maxHeight: 160)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.primaryBackground.opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
                .onChange(of: instructions) { newValue in
                    // Debounced auto-save — mirrors upstream's "auto-save
                    // project instructions" so there's no separate Save step.
                    saveTask?.cancel()
                    saveTask = Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard !Task.isCancelled, var proj = project else { return }
                        proj.instructions = newValue
                        await MainActor.run { projectManager.update(proj) }
                    }
                }
        }
    }

    // MARK: - Chats

    private var chatsHeader: some View {
        HStack {
            Text("Chats", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Spacer()
            Button(action: { showingAddChats = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("Add Existing", bundle: .module)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
    }

    private var emptyChats: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 22))
                .foregroundColor(theme.secondaryText.opacity(0.5))
            Text("No chats in this project yet", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func chatRow(_ session: ChatSessionData) -> some View {
        let agent = agentManager.agents.first { $0.id == session.agentId }
        return HStack(spacing: 10) {
            Button {
                onSelectChat(session)
            } label: {
                HStack(spacing: 10) {
                    if let agent {
                        AgentAvatarView(
                            mascotId: agent.avatar,
                            name: agent.name,
                            tint: theme.accentColor,
                            diameter: 22,
                            customImageURL: agent.customAvatarURL,
                            monogramFontSize: 9,
                            borderWidth: 0
                        )
                    } else {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 22, height: 22)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: session.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                        if let agent {
                            Text(verbatim: agent.displayName)
                                .font(.system(size: 10))
                                .foregroundColor(theme.secondaryText.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Button {
                ChatSessionsManager.shared.setProject(id: session.id, projectId: nil)
            } label: {
                Image(systemName: "folder.badge.minus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .localizedHelp("Remove from Project")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .pointingHandCursor()
    }

    // MARK: - Add Existing Chats Sheet

    private var addChatsSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add Chats to Project", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button(action: { showingAddChats = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider().opacity(0.3)

            AddChatsToProjectSheet(candidates: ungroupedChats) { selected in
                for id in selected {
                    ChatSessionsManager.shared.setProject(id: id, projectId: projectId)
                }
                showingAddChats = false
            }
            .padding(16)
        }
        .frame(width: 420, height: 480)
        .background(theme.primaryBackground)
    }
}
