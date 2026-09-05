//
//  ProjectPageView.swift
//  osaurus
//
//  Full-width project page rendered in the chat window's main content area
//  (see `ChatWindowState.openProjectId` / `ChatContentView`). Replaces
//  `ProjectDetailView`'s themed-alert-sheet presentation — clicking a
//  project used to open a modal with no "inside a project" state at all;
//  closing it left you nowhere, and clicking again just reopened the same
//  modal. This is the real route upstream has: instructions editor, member
//  chat list, and a way back to the chat you came from, all inline instead
//  of stacked in a sheet.
//
//  Reuses `ProjectDetailView`'s logic verbatim (debounced instructions
//  auto-save, search, Add Existing sheet, remove-from-project) — only the
//  shell changed, from a themed-alert's fixed-width custom content to a
//  full-width scrollable page with its own header.
//

import SwiftUI

struct ProjectPageView: View {
    let projectId: UUID
    /// Loads a member chat — the caller is expected to also leave the page
    /// (clear `openProjectId`) so the loaded chat is what's visible.
    var onSelectChat: (ChatSessionData) -> Void
    /// Starts a brand-new chat tagged to this project and leaves the page.
    var onNewChat: () -> Void
    /// Leaves the project page, back to whichever chat is currently loaded
    /// in this window — no session change, just a route change.
    var onLeave: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.themedAlertScope) private var alertScope
    @ObservedObject private var projectManager = ProjectManager.shared
    @ObservedObject private var sessionsManager = ChatSessionsManager.shared
    @ObservedObject private var agentManager = AgentManager.shared

    @State private var instructions: String = ""
    @State private var saveTask: Task<Void, Never>?
    /// Which project the `instructions` buffer currently belongs to. The page
    /// stays mounted across project switches, so this is what a pending save
    /// must be keyed to — `projectId` has already moved on by then.
    @State private var editingProjectId: UUID?
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
        VStack(alignment: .leading, spacing: 0) {
            pageHeader

            Divider().opacity(0.3)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    instructionsSection
                    Divider().opacity(0.5)
                    chatsSection
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { loadInstructions() }
        // The page can stay mounted while `projectId` changes (leave one
        // project, open another without ever unmounting ChatContentView's
        // main area) — flush the outgoing project's pending edit, THEN resync
        // the buffer. Without the flush the resync's own `onChange` cancels
        // the in-flight debounce and the last keystrokes are lost.
        .onChange(of: projectId) { _ in
            flushInstructions()
            loadInstructions()
        }
        // Leaving the page (back to a chat) tears the view down mid-debounce.
        .onDisappear { flushInstructions() }
        .sheet(isPresented: $showingAddChats) {
            addChatsSheet
        }
    }

    // MARK: - Header

    private var pageHeader: some View {
        HStack(spacing: 10) {
            Button(action: onLeave) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.secondaryBackground.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .localizedHelp("Back to Chat")

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.accentColor.opacity(theme.isDark ? 0.18 : 0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: "folder.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }

            Text(verbatim: project?.name ?? "")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)

            Button(action: presentRename) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .localizedHelp("Rename Project")

            Spacer()

            Button(action: onNewChat) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("New Chat", bundle: .module)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(theme.accentColor.opacity(theme.isDark ? 0.18 : 0.12))
                )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .localizedHelp("New Chat in This Project")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func presentRename() {
        guard let project else { return }
        let requestId = UUID()
        let scope = alertScope
        let sheet = ProjectNamePromptSheet(initialName: project.name, submitLabel: "Save") { name in
            var updated = project
            updated.name = name
            projectManager.update(updated)
            ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
        }
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: L("Rename Project"),
                message: nil,
                buttons: [.cancel(L("Cancel"))],
                showsCloseButton: true,
                customContent: AnyView(sheet),
                width: 360,
                onDismiss: { ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId) }
            ),
            scope: scope
        )
    }

    // MARK: - Instructions

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Instructions", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text("Shared context added to every chat in this project.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)

            TextEditor(text: $instructions)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140, maxHeight: 260)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.primaryBackground.opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
                .onChange(of: instructions) { newValue in
                    // Debounced auto-save — same 600ms debounce as
                    // `ProjectDetailView`, just re-housed.
                    let target = editingProjectId ?? projectId
                    saveTask?.cancel()
                    saveTask = Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run { writeInstructions(newValue, to: target) }
                    }
                }
        }
    }

    // MARK: - Instructions Persistence

    /// Loads the editor buffer for the current project and records which
    /// project it belongs to.
    private func loadInstructions() {
        saveTask?.cancel()
        saveTask = nil
        instructions = project?.instructions ?? ""
        editingProjectId = projectId
    }

    /// Writes any pending edit through immediately, cancelling the debounce.
    /// Called when the page is switching projects or being torn down — the
    /// 600ms timer does not survive either.
    private func flushInstructions() {
        saveTask?.cancel()
        saveTask = nil
        guard let target = editingProjectId else { return }
        writeInstructions(instructions, to: target)
    }

    /// Single write path. No-ops when the text is unchanged so a buffer
    /// resync cannot churn `updatedAt` or clobber a newer value.
    @MainActor
    private func writeInstructions(_ text: String, to target: UUID) {
        guard var proj = projectManager.project(for: target), proj.instructions != text
        else { return }
        proj.instructions = text
        projectManager.update(proj)
    }

    // MARK: - Chats

    private var chatsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                LazyVStack(spacing: 2) {
                    ForEach(filteredChats) { session in
                        chatRow(session)
                    }
                }
            }
        }
    }

    private var chatsHeader: some View {
        HStack {
            Text("Chats", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
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
                            diameter: 24,
                            customImageURL: agent.customAvatarURL,
                            monogramFontSize: 10,
                            borderWidth: 0
                        )
                    } else {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 24, height: 24)
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
