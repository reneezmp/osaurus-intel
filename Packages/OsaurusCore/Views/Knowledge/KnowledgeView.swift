//
//  KnowledgeView.swift
//  osaurus
//
//  Intel management surface for the local Knowledge collection registry and
//  background indexer.
//

import AppKit
import SwiftUI

/// Sub-navigation for the Knowledge tab (upstream). History has its own tab
/// because it is unbounded; it stays hidden until an agent has written.
enum KnowledgeTab: String, CaseIterable, AnimatedTabItem {
    case collections
    case history

    var title: String {
        switch self {
        case .collections: return L("Collections")
        case .history: return L("History")
        }
    }
}

struct KnowledgeView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var integration = KnowledgeUIIntegration.shared
    @ObservedObject private var managementState = ManagementStateManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false
    @State private var isCreating = false
    @State private var createPrefillName = ""
    @State private var createGrantProjectId: UUID?
    @State private var selectedCollection: KnowledgeUICollection?
    @State private var editingCollection: KnowledgeUICollection?
    @State private var toastMessage: String?
    @State private var toastIsError = false
    /// Agent writes, grouped by run, for the History tab (upstream; see
    /// docs/KNOWLEDGE_WRITE_INTEL.md). The tab appears once there are any.
    @State private var writeRuns: [KnowledgeWriteRun] = []
    @State private var selectedTab: KnowledgeTab = .collections
    /// Open staleness tickets agents filed (upstream curation list).
    @State private var openTickets: [KnowledgeTicket] = []
    /// A freshly created collection awaiting upstream's "grant to agents"
    /// prompt (#2117), so access is granted inline instead of in each agent.
    @State private var grantingCollection: KnowledgeGrantTarget?

    var body: some View {
        VStack(spacing: 0) {
            header
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            ZStack {
                if integration.collections.isEmpty {
                    emptyState
                } else if selectedTab == .history, !writeRuns.isEmpty {
                    ScrollView { historySection }
                } else {
                    collectionGrid
                }

                if let toastMessage {
                    VStack {
                        Spacer()
                        ThemedToastView(
                            toastMessage,
                            type: toastIsError ? .error : .success
                        )
                        .padding(.bottom, 20)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
            integration.reload()
            applyPendingRequests()
            reloadWriteHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .knowledgeWritesChanged)) { _ in
            reloadWriteHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .knowledgeCurationChanged)) { _ in
            reloadTickets()
        }
        .onAppear { reloadTickets() }
        .onReceive(managementState.$pendingKnowledgeCreate) { _ in
            applyPendingRequests()
        }
        .onReceive(managementState.$pendingKnowledgeDetailId) { _ in
            applyPendingRequests()
        }
        .onReceive(integration.$collections) { _ in
            applyPendingRequests()
        }
        .sheet(isPresented: $isCreating) {
            KnowledgeCollectionEditorSheet(
                initialName: createPrefillName,
                onSave: createCollection,
                onCancel: { isCreating = false }
            )
        }
        .sheet(item: $grantingCollection) { target in
            KnowledgeGrantAgentsSheet(
                target: target,
                onDone: { grantedCount in
                    grantingCollection = nil
                    if grantedCount > 0 {
                        showToast(
                            grantedCount == 1
                                ? L("Granted \"\(target.name)\" to 1 agent")
                                : L("Granted \"\(target.name)\" to \(grantedCount) agents")
                        )
                    }
                }
            )
        }
        .sheet(item: $editingCollection) { collection in
            KnowledgeCollectionEditorSheet(
                title: "Edit Knowledge Collection",
                initialName: collection.name,
                initialSummary: collection.summary,
                initialFolderPath: collection.folderPath,
                initialIncludeGlobs: collection.includeGlobs,
                initialExcludeGlobs: collection.excludeGlobs,
                saveTitle: "Save",
                onSave: { name, summary, folderPath, includeGlobs, excludeGlobs in
                    updateCollection(
                        collection.id, name: name, summary: summary,
                        folderPath: folderPath, includeGlobs: includeGlobs,
                        excludeGlobs: excludeGlobs)
                },
                onCancel: { editingCollection = nil }
            )
        }
        .sheet(item: $selectedCollection) { collection in
            KnowledgeCollectionDetailSheet(
                collection: collection,
                onEnableChanged: { enabled in
                    integration.setCollection(collection.id, enabled: enabled)
                    selectedCollection = integration.collection(for: collection.id)
                },
                onReindex: {
                    integration.reindexCollection(collection.id)
                    showToast("Re-indexing \"\(collection.name)\"")
                },
                onEdit: {
                    selectedCollection = nil
                    DispatchQueue.main.async { editingCollection = collection }
                },
                onDelete: {
                    selectedCollection = nil
                    presentDeleteConfirmation(for: collection)
                },
                onClose: { selectedCollection = nil }
            )
        }
    }

    /// Upstream: tabs join the header only once an agent has written
    /// something, so the common case keeps the plain header.
    @ViewBuilder
    private var header: some View {
        if writeRuns.isEmpty {
            ManagerHeaderWithActions(
                title: L("Knowledge"),
                subtitle: L("Folders of documents your agents can search and read on demand"),
                count: integration.collections.count
            ) { headerActions }
        } else {
            ManagerHeaderWithTabs(
                title: L("Knowledge"),
                subtitle: L("Folders of documents your agents can search and read on demand"),
                count: integration.collections.count,
                actions: { headerActions },
                tabsRow: {
                    HeaderTabsRow(selection: $selectedTab, counts: [.history: writeRuns.count])
                }
            )
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        Group {
            HeaderIconButton(
                "arrow.clockwise",
                isLoading: integration.isRefreshing,
                help: "Refresh"
            ) {
                integration.reload()
            }

            Button(action: beginCreate) {
                Label("Add Collection", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
        }
    }

    // MARK: - History (agent writes)

    /// Upstream's History tab: every agent write, grouped by run, with revert.
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Everything agents have written to your collections, newest first. Reverting puts the document back the way it was before that run.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            KnowledgeWriteHistoryView(
                runs: writeRuns,
                onRevertRun: { run in
                    Task {
                        let failures = await KnowledgeWriteService.shared.revertRun(runId: run.runId)
                        if let only = run.records.first, run.records.count == 1 {
                            if failures.isEmpty {
                                showToast(L("Reverted \(only.relPath)"))
                            } else {
                                showToast(
                                    L("Did not revert \(only.relPath): the document changed after the agent wrote it."),
                                    isError: true)
                            }
                        } else if failures.isEmpty {
                            showToast(L("Reverted \(run.records.count) documents"))
                        } else {
                            showToast(
                                L(
                                    "Reverted \(run.records.count - failures.count) of \(run.records.count) documents. The rest changed after the agent wrote them, so they were left alone."
                                ),
                                isError: true)
                        }
                        reloadWriteHistory()
                    }
                },
                onRevertRecord: { record in
                    Task {
                        do {
                            try await KnowledgeWriteService.shared.revert(recordId: record.id)
                            showToast(L("Reverted \(record.relPath)"))
                        } catch {
                            showToast(L("Could not revert: \(error.localizedDescription)"), isError: true)
                        }
                        reloadWriteHistory()
                    }
                }
            )
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Upstream "Sync": pull (fast-forward only) and push; the outcome message
    /// says what happened or what needs attention.
    private func syncCollection(_ id: UUID) {
        guard let collection = KnowledgeManager.shared.collection(for: id) else { return }
        showToast(L("Syncing \"\(collection.name)\"…"))
        Task {
            let outcome = await KnowledgeManager.shared.syncNow(collection)
            switch outcome {
            case .upToDate, .updated: showToast(outcome.message)
            case .needsAttention, .failed: showToast(outcome.message, isError: true)
            }
            integration.reload()
        }
    }

    // MARK: - Tickets (upstream curation)

    @ViewBuilder
    private var ticketsSection: some View {
        if !openTickets.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Curation", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "Agents leave a note here when a document looks out of date but fixing it was not the task at hand. Open one in a chat to have an agent correct it; you review the change before it is saved.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(openTickets) { ticket in
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.bubble")
                            .font(.system(size: 13))
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(format: L("Ticket #%lld: %@"), ticket.id, ticket.relPath))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.primaryText)
                            Text(ticket.reason)
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        Button {
                            startTicketFix(for: ticket)
                        } label: {
                            Text("Fix in a chat", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(ThemedBorderedButtonStyle())
                        Button {
                            Task.detached(priority: .userInitiated) {
                                try? await KnowledgeCurationService.shared.dismissTicket(ticketId: ticket.id)
                            }
                        } label: {
                            Text("Dismiss", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(ThemedBorderedButtonStyle())
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.secondaryBackground))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
        }
    }

    private func reloadTickets() {
        Task.detached(priority: .utility) {
            if !KnowledgeDatabase.shared.isOpen { try? KnowledgeDatabase.shared.open() }
            guard KnowledgeDatabase.shared.isOpen else { return }
            let tickets = (try? KnowledgeDatabase.shared.listTickets(collectionIds: nil, status: .open)) ?? []
            await MainActor.run {
                if tickets.map(\.id) != openTickets.map(\.id) { openTickets = tickets }
            }
        }
    }

    /// Upstream: open a chat with an agent granted this collection, its
    /// composer pre-filled with a briefing; the fix goes through the write
    /// tools and their approval card.
    private func startTicketFix(for ticket: KnowledgeTicket) {
        let manager = AgentManager.shared
        guard let collectionUUID = UUID(uuidString: ticket.collectionId),
            let agent = manager.agents.first(where: {
                manager.knowledgeEnabled(for: $0.id)
                    && manager.knowledgeCollectionIds(for: $0.id).contains(collectionUUID)
            })
        else {
            showToast(L("No agent has this collection yet. Grant it to one in the collection's details."), isError: true)
            return
        }
        let windowId = ChatWindowManager.shared.createWindow(agentId: agent.id)
        let collectionName = KnowledgeManager.shared.collection(for: collectionUUID)?.name ?? ""
        let collectionClause = collectionName.isEmpty ? "" : " in the \"\(collectionName)\" collection"
        let briefing =
            "Please work knowledge ticket #\(ticket.id) for `\(ticket.relPath)`\(collectionClause).\n"
            + "Reported issue: \(ticket.reason)\n\n"
            + "Read the current document, and if it is out of date, use "
            + "edit_knowledge (or write_knowledge) to correct it. Keep the existing frontmatter. "
            + "I will review the diff before it is saved."
        ChatWindowManager.shared.windowState(id: windowId)?.session.input = briefing
        showToast(L("Opened \(agent.name) with a briefing for ticket #\(ticket.id). Review it and hit send."))
    }

    /// Load recent writes off the main thread. The write log is primary data
    /// (not the rebuildable index), so it opens on its own.
    private func reloadWriteHistory() {
        Task.detached(priority: .utility) {
            if !KnowledgeWriteLogDatabase.shared.isOpen {
                try? KnowledgeWriteLogDatabase.shared.open()
            }
            guard KnowledgeWriteLogDatabase.shared.isOpen else { return }
            let writes = (try? KnowledgeWriteLogDatabase.shared.recentRecords(limit: 200)) ?? []
            let names = await MainActor.run {
                Dictionary(
                    KnowledgeManager.shared.collections.map { ($0.id.uuidString, $0.name) },
                    uniquingKeysWith: { first, _ in first })
            }
            let runs = KnowledgeWriteRun.group(writes, collectionNames: names)
            await MainActor.run {
                let incoming = runs.flatMap { $0.records.map { "\($0.id):\($0.isReverted)" } }
                let current = writeRuns.flatMap { $0.records.map { "\($0.id):\($0.isReverted)" } }
                if incoming != current { writeRuns = runs }
                if runs.isEmpty { selectedTab = .collections }
            }
        }
    }

    private var emptyState: some View {
        SettingsEmptyState(
            icon: "books.vertical.fill",
            title: L("Add Your First Knowledge Collection"),
            subtitle: L(
                "Point Osaurus at a folder of guides, templates, and standards and grant it to agents so they can consult it on demand. Markdown, plain text, code, PDF, Word, Excel, PowerPoint, and CSV files are supported."
            ),
            examples: [
                .init(
                    icon: "doc.text",
                    title: L("Guides & Policies"),
                    description: L("How your team does things, written down")
                ),
                .init(
                    icon: "square.on.square",
                    title: L("Templates"),
                    description: L("Wording you reuse, like email replies")
                ),
                .init(
                    icon: "book",
                    title: L("How-To Steps"),
                    description: L("Simple instructions for everyday tasks")
                ),
            ],
            primaryAction: .init(
                title: L("Add Collection"),
                icon: "plus",
                handler: beginCreate
            ),
            hasAppeared: hasAppeared
        )
        .padding(.horizontal, 32)
    }

    private var collectionGrid: some View {
        ScrollView {
            ticketsSection
            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 300), spacing: 20),
                    GridItem(.flexible(minimum: 300), spacing: 20),
                ],
                spacing: 20
            ) {
                ForEach(Array(integration.collections.enumerated()), id: \.element.id) { index, collection in
                    KnowledgeCollectionCard(
                        collection: collection,
                        animationDelay: Double(index) * 0.05,
                        hasAppeared: hasAppeared,
                        onToggle: { enabled in
                            integration.setCollection(collection.id, enabled: enabled)
                        },
                        onReindex: {
                            integration.reindexCollection(collection.id)
                            showToast("Re-indexing \"\(collection.name)\"")
                        },
                        onSync: { syncCollection(collection.id) },
                        onEdit: { editingCollection = collection },
                        onDelete: { presentDeleteConfirmation(for: collection) },
                        onOpenDetail: { selectedCollection = collection }
                    )
                }
            }
            .padding(24)
        }
        .opacity(hasAppeared ? 1 : 0)
    }

    private func presentDeleteConfirmation(for collection: KnowledgeUICollection) {
        KnowledgeDeleteConfirmation.present(collectionName: collection.name) {
            integration.deleteCollection(collection.id)
            showToast("Deleted \"\(collection.name)\"")
        }
    }

    private func beginCreate() {
        createPrefillName = ""
        createGrantProjectId = nil
        isCreating = true
    }

    private func createCollection(
        name: String,
        summary: String,
        folderPath: String,
        includeGlobs: [String],
        excludeGlobs: [String]
    ) {
        isCreating = false
        Task { @MainActor in
            do {
                let collectionId = try await integration.createCollection(
                    name: name,
                    summary: summary,
                    folderPath: folderPath,
                    includeGlobs: includeGlobs,
                    excludeGlobs: excludeGlobs
                )
                if let projectId = createGrantProjectId,
                    var project = ProjectManager.shared.project(for: projectId)
                {
                    if !project.knowledgeCollectionIds.contains(collectionId) {
                        project.knowledgeCollectionIds.append(collectionId)
                        ProjectManager.shared.update(project)
                    }
                }
                createPrefillName = ""
                createGrantProjectId = nil
                showToast("Added \"\(name)\", indexing in the background")
                grantingCollection = KnowledgeGrantTarget(id: collectionId, name: name)
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    private func updateCollection(
        _ id: UUID,
        name: String,
        summary: String,
        folderPath: String,
        includeGlobs: [String],
        excludeGlobs: [String]
    ) {
        do {
            try integration.updateCollection(
                id, name: name, summary: summary, folderPath: folderPath,
                includeGlobs: includeGlobs, excludeGlobs: excludeGlobs)
            editingCollection = nil
            showToast("Saved \"\(name)\"")
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    private func applyPendingRequests() {
        if let request = managementState.pendingKnowledgeCreate {
            managementState.pendingKnowledgeCreate = nil
            createPrefillName = request.prefillName
            createGrantProjectId = request.grantProjectId
            isCreating = true
        }

        if let id = managementState.pendingKnowledgeDetailId,
            let collection = integration.collection(for: id)
        {
            managementState.pendingKnowledgeDetailId = nil
            selectedCollection = collection
        }
    }

    private func showToast(_ message: String, isError: Bool = false) {
        toastMessage = message
        toastIsError = isError
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if toastMessage == message { toastMessage = nil }
        }
    }
}

@MainActor
enum KnowledgeDeleteConfirmation {
    static func present(
        collectionName: String,
        scope: ThemedAlertScope = .management,
        onConfirm: @escaping () -> Void
    ) {
        let requestId = UUID()
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Delete \"\(collectionName)\"?",
                message: L(
                    "This removes the collection and search index. Files in its folder are not changed."
                ),
                buttons: [
                    .cancel(L("Cancel")),
                    .destructive(L("Delete Collection"), action: onConfirm),
                ],
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }
}

private struct KnowledgeCollectionCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var projectManager = ProjectManager.shared

    let collection: KnowledgeUICollection
    let animationDelay: Double
    let hasAppeared: Bool
    let onToggle: (Bool) -> Void
    let onReindex: () -> Void
    var onSync: () -> Void = {}
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onOpenDetail: () -> Void

    private enum CategoryStatus: Equatable {
        case checking
        case allCategorized
        case uncategorized(Int)
    }

    @State private var categoryStatus: CategoryStatus = .checking
    /// Upstream #2132: tapping the chip lists the uncategorized documents.
    @State private var showingCategoryAlert = false
    @State private var uncategorizedPaths: [String] = []

    private var categoryLabel: String {
        switch categoryStatus {
        case .checking:
            return L("Checking categories…")
        case .allCategorized:
            return L("All categorized")
        case .uncategorized(let count):
            return count == 1 ? L("1 doc uncategorized") : String(format: L("%lld docs uncategorized"), count)
        }
    }

    private var categoryHelp: String {
        switch categoryStatus {
        case .allCategorized:
            return L(
                "Every document has a category, so agents can filter the library by it. Categories come from frontmatter `type:` or are inferred automatically from folder names."
            )
        case .uncategorized(let count):
            return count == 1
                ? L(
                    "1 document has no category. This is optional, agents can still search and read it. To let agents filter by category, add a `type:` line (e.g. `type: policy`) to the top of the file. Click for the list."
                )
                : String(
                    format: L(
                        "%lld documents have no category. This is optional, agents can still search and read them. To let agents filter by category, add a `type:` line (e.g. `type: policy`) to the top of each file. Click for the list."
                    ), count)
        case .checking:
            return L("Checking that every document declares a category (its `type`)…")
        }
    }

    private var categoryAlertTitle: String {
        if uncategorizedPaths.isEmpty { return L("All documents categorized") }
        return uncategorizedPaths.count == 1
            ? L("1 document has no category")
            : String(format: L("%lld documents have no category"), uncategorizedPaths.count)
    }

    private var categoryAlertMessage: String {
        if uncategorizedPaths.isEmpty {
            return L(
                "Every document has a category, from its frontmatter `type:` or inferred from its folder name. Agents can filter this collection by category."
            )
        }
        let sample = uncategorizedPaths.prefix(8).joined(separator: "\n")
        let more = uncategorizedPaths.count - min(8, uncategorizedPaths.count)
        return L(
            "This is optional. Agents can still search and read these documents.\n\nTo let agents filter by category, move them into a folder (the folder name becomes the category) or add a `type:` line to their frontmatter.\n\n"
        ) + sample + (more > 0 ? "\n" + String(format: L("and %lld more"), more) : "")
    }

    private var categoryIcon: String {
        switch categoryStatus {
        case .checking: return "checkmark.seal"
        case .allCategorized: return "checkmark.seal.fill"
        case .uncategorized: return "tag.slash"
        }
    }

    private var categoryColor: Color {
        switch categoryStatus {
        case .allCategorized: return .green
        case .checking, .uncategorized: return theme.secondaryText
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(theme.accentColor.opacity(0.12)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(collection.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    Text(collection.folderPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { collection.isEnabled },
                        set: onToggle
                    )
                )
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .controlSize(.mini)
            }

            if !collection.summary.isEmpty {
                Text(collection.summary)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
            }


            let grantedAgents = agentManager.agents.filter {
                !$0.isBuiltIn && agentManager.knowledgeCollectionIds(for: $0.id).contains(collection.id)
            }
            if grantedAgents.isEmpty {
                Label("No agents with access", systemImage: "person.2.slash")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            } else {
                HStack(spacing: 6) {
                    HStack(spacing: -6) {
                        ForEach(Array(grantedAgents.prefix(4))) { agent in
                            AgentAvatarView(
                                mascotId: agent.avatar,
                                name: agent.name,
                                tint: theme.accentColor,
                                diameter: 22,
                                customImageURL: agent.customAvatarURL,
                                monogramFontSize: 9,
                                borderWidth: 1
                            )
                        }
                    }
                    Text("\(grantedAgents.count) \(grantedAgents.count == 1 ? "agent" : "agents")")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
            }

            let projects = projectManager.projects.filter { $0.knowledgeCollectionIds.contains(collection.id) }
            if let project = projects.first {
                Label(
                    projects.count == 1 ? "Used by project \(project.name)" : "Used by \(projects.count) projects",
                    systemImage: "folder"
                )
                .font(.system(size: 10))
                .foregroundColor(theme.secondaryText)
            }

            Button(action: {
                Task {
                    await refreshCategoryStatus()
                    showingCategoryAlert = true
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: categoryIcon)
                        .font(.system(size: 9))
                    Text(verbatim: categoryLabel)
                        .font(.system(size: 9, weight: .bold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(categoryColor.opacity(0.15)))
                .foregroundColor(categoryColor)
            }
            .buttonStyle(.plain)
            .help(categoryHelp)
            .themedAlert(
                categoryAlertTitle,
                isPresented: $showingCategoryAlert,
                message: categoryAlertMessage,
                primaryButton: .cancel(L("OK"))
            )
            .task(id: collection.updatedAt) { await refreshCategoryStatus() }
            .onChange(of: collection.isIndexing) { indexing in
                if !indexing { Task { await refreshCategoryStatus() } }
            }

            HStack(spacing: 8) {
                if !collection.isAvailable {
                    Label(collection.statusMessage ?? "Source folder unavailable", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(theme.errorColor)
                } else if let documentCount = collection.documentCount, let chunkCount = collection.chunkCount {
                    Label(
                        "\(documentCount) \(documentCount == 1 ? "document" : "documents") · \(chunkCount) \(chunkCount == 1 ? "chunk" : "chunks")",
                        systemImage: "doc.text"
                    )
                } else {
                    Label(collection.statusMessage ?? "Not indexed yet", systemImage: "clock")
                }
                if collection.isIndexing {
                    Label("Indexing…", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundColor(theme.accentColor)
                }
                if collection.gitRemoteURL != nil {
                    Label("Git", systemImage: "arrow.triangle.branch")
                }
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)

            if let statusMessage = collection.statusMessage, collection.isAvailable {
                Text(statusMessage)
                    .font(.system(size: 10))
                    .foregroundColor(theme.errorColor)
            }

            HStack {
                Button("Details", action: onOpenDetail)
                    .buttonStyle(.borderless)
                Spacer()
                if collection.gitRemoteURL != nil {
                    // Upstream: fast-forward pull + push for a git repo folder.
                    Button(action: onSync) {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath.circle")
                    }
                    .buttonStyle(.borderless)
                }
                Button(action: onReindex) {
                    Label("Re-index", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.borderless)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(Text("Delete collection", bundle: .module))
            }
            .font(.system(size: 11, weight: .medium))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder.opacity(0.7), lineWidth: 1)
                )
        )
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 12)
        .animation(
            .spring(response: 0.4, dampingFraction: 0.8).delay(animationDelay),
            value: hasAppeared
        )
    }

    private func refreshCategoryStatus() async {
        let collectionId = collection.id.uuidString
        let documents = await Task.detached(priority: .utility) {
            if !KnowledgeDatabase.shared.isOpen { try? KnowledgeDatabase.shared.open() }
            return (try? KnowledgeDatabase.shared.listDocuments(collectionId: collectionId)) ?? []
        }.value
        // Upstream `uncategorizedDocuments` (#2132): no explicit or inferred
        // category, markdown only (other formats have no frontmatter to
        // fix), and never the collection's own `index.md` / `log.md`.
        let reserved: Set<String> = ["index.md", "log.md"]
        let uncategorized = documents.filter { document in
            document.effectiveType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !reserved.contains(document.relPath.lowercased())
                && KnowledgeIndexService.markdownExtensions.contains(
                    (document.relPath as NSString).pathExtension.lowercased())
        }.map(\.relPath)
        await MainActor.run {
            uncategorizedPaths = uncategorized
            categoryStatus =
                uncategorized.isEmpty
                ? .allCategorized
                : .uncategorized(uncategorized.count)
        }
    }
}

private struct KnowledgeCollectionEditorSheet: View {
    @Environment(\.theme) private var theme

    let onSave: (String, String, String, [String], [String]) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var summary = ""
    @State private var folderPath = ""
    @State private var includeGlobs = ""
    @State private var excludeGlobs = ""
    @State private var validationMessage: String?
    let title: String
    let saveTitle: String

    init(
        title: String = "Add Knowledge Collection",
        initialName: String = "",
        initialSummary: String = "",
        initialFolderPath: String = "",
        initialIncludeGlobs: [String] = [],
        initialExcludeGlobs: [String] = [],
        saveTitle: String = "Add",
        onSave: @escaping (String, String, String, [String], [String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _name = State(initialValue: initialName)
        _summary = State(initialValue: initialSummary)
        _folderPath = State(initialValue: initialFolderPath)
        _includeGlobs = State(initialValue: initialIncludeGlobs.joined(separator: ", "))
        _excludeGlobs = State(initialValue: initialExcludeGlobs.joined(separator: ", "))
        self.title = title
        self.saveTitle = saveTitle
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text(
                "Choose a folder whose contents should remain the source of truth. Osaurus indexes it in place.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)

            StyledSettingsTextField(
                label: "Name", text: $name,
                placeholder: "WordPress Development", help: ""
            )

            StyledSettingsTextField(
                label: "Summary (optional)", text: $summary,
                placeholder: "What this corpus contains, shown to agents", help: ""
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Folder", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                HStack(spacing: 10) {
                    TextField("/path/to/knowledge-folder", text: $folderPath)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                    Button("Choose…", action: chooseFolder)
                        .buttonStyle(SettingsButtonStyle())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder))
                )
                Text("Files in this folder are indexed in place and never modified. Markdown, plain text, code, and documents (PDF, Word, Excel, PowerPoint, CSV) are supported; YAML frontmatter (`type`, `tags`, …) in markdown is used for filtering.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Index filters (optional)", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                StyledSettingsTextField(
                    label: "Include", text: $includeGlobs,
                    placeholder: "docs/**, *.md", help: ""
                )
                StyledSettingsTextField(
                    label: "Exclude", text: $excludeGlobs,
                    placeholder: "src/**, test/**", help: ""
                )
                Text("Junk and .gitignore files are skipped automatically. Most folders need nothing here.\n• Include: index only matching files, e.g. docs/**\n• Exclude: skip matching files. Wins over Include.\n• * matches inside a folder, ** across folders.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 11))
                    .foregroundColor(theme.errorColor)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(LocalizedStringKey(saveTitle), action: save)
                    .buttonStyle(SettingsButtonStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
        .intelControlRendering(theme: theme)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = url.lastPathComponent
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Enter a name for this collection."
            return
        }
        guard !trimmedPath.isEmpty else {
            validationMessage = "Choose a folder for this collection."
            return
        }
        onSave(
            trimmedName,
            summary.trimmingCharacters(in: .whitespacesAndNewlines),
            trimmedPath,
            Self.parseGlobs(includeGlobs),
            Self.parseGlobs(excludeGlobs)
        )
    }

    private static func parseGlobs(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// The collection a grant prompt is for.
private struct KnowledgeGrantTarget: Identifiable, Equatable {
    let id: UUID
    let name: String
}

/// Upstream's "grant to agents" prompt (#2117), shown right after a
/// collection is created. Intel keeps grants in `AgentManager`
/// (`updateKnowledgeSettings`), and an agent's Knowledge switch lives under
/// Abilities.
private struct KnowledgeGrantAgentsSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let target: KnowledgeGrantTarget
    /// Passes the number of agents actually granted (0 when none/skipped).
    let onDone: (Int) -> Void

    /// Editable agents, in display order (the built-in agent has no grants).
    private let agents: [Agent]
    @State private var selectedIds: Set<UUID>

    init(target: KnowledgeGrantTarget, onDone: @escaping (Int) -> Void) {
        self.target = target
        self.onDone = onDone
        let manager = AgentManager.shared
        let editable = manager.agents.filter { !$0.isBuiltIn }
        self.agents = editable
        // Pre-select agents that already have Knowledge on, so the common
        // "grant this to my knowledge-using agents" path is one click.
        _selectedIds = State(
            initialValue: Set(editable.filter { manager.knowledgeEnabled(for: $0.id) }.map(\.id))
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Grant \"\(target.name)\" to agents", bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "Pick which agents can search and read this collection. You can change this later in each agent's Abilities → Knowledge section.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            if agents.isEmpty {
                Text(
                    "No agents to grant yet. Create an agent, then enable Knowledge for it in its Abilities section.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(agents) { agent in
                            agentRow(agent)
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 320)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.secondaryBackground))
            }

            HStack {
                Spacer()
                Button {
                    onDone(0)
                } label: {
                    Text(agents.isEmpty ? "Close" : "Skip", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle())
                .keyboardShortcut(.cancelAction)
                if !agents.isEmpty {
                    Button {
                        grant()
                    } label: {
                        Text("Grant Access", bundle: .module)
                    }
                    .buttonStyle(SettingsButtonStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedIds.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
    }

    private func agentRow(_ agent: Agent) -> some View {
        let selected = selectedIds.contains(agent.id)
        return Button {
            if selected {
                selectedIds.remove(agent.id)
            } else {
                selectedIds.insert(agent.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(selected ? theme.accentColor : theme.tertiaryText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    if !agent.displayDescription.isEmpty {
                        Text(agent.displayDescription)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if !AgentManager.shared.knowledgeEnabled(for: agent.id) {
                    Text("Enables Knowledge", bundle: .module)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Add the collection to every selected agent and turn Knowledge on so
    /// the grant takes effect. Agents already holding it are left untouched.
    private func grant() {
        let manager = AgentManager.shared
        var granted = 0
        for agent in agents where selectedIds.contains(agent.id) {
            var ids = manager.knowledgeCollectionIds(for: agent.id)
            if manager.knowledgeEnabled(for: agent.id), ids.contains(target.id) { continue }
            if !ids.contains(target.id) { ids.append(target.id) }
            manager.updateKnowledgeSettings(enabled: true, collectionIds: ids, for: agent.id)
            granted += 1
        }
        onDone(granted)
    }
}

private struct KnowledgeCollectionDetailSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var projectManager = ProjectManager.shared
    @ObservedObject private var integration = KnowledgeUIIntegration.shared

    let collection: KnowledgeUICollection
    let onEnableChanged: (Bool) -> Void
    let onReindex: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var documents: [KnowledgeDocument] = []
    @State private var documentsLoaded = false

    private var live: KnowledgeUICollection {
        integration.collection(for: collection.id) ?? collection
    }

    private var editableAgents: [Agent] {
        agentManager.agents.filter { !$0.isBuiltIn }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 20))
                    .foregroundColor(theme.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(live.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    if !live.summary.isEmpty {
                        Text(live.summary)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { live.isEnabled },
                        set: onEnableChanged
                    )
                )
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .labelsHidden()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    locationSection
                    statusSection
                    projectsSection
                    accessSection
                    documentsSection
                }
                .padding(20)
            }

            Divider()

            HStack(spacing: 10) {
                Button("Delete", action: onDelete)
                    .buttonStyle(SettingsButtonStyle(isDestructive: true))
                Button("Edit", action: onEdit)
                    .buttonStyle(SettingsButtonStyle())
                Spacer()
                Button("Re-index", action: onReindex)
                    .buttonStyle(SettingsButtonStyle())
                Button("Done", action: onClose)
                    .buttonStyle(SettingsButtonStyle(isPrimary: true))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .frame(width: 560, height: 640)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
        .intelControlRendering(theme: theme)
        .onAppear(perform: loadDocuments)
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title, bundle: .module)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(theme.secondaryText)
            .textCase(.uppercase)
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Location")
            Label {
                Text(live.folderPath)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } icon: { Image(systemName: "folder.fill") }
            .foregroundColor(theme.secondaryText)
            Text("Created \(live.createdAt.formatted(date: .abbreviated, time: .shortened)) · Updated \(live.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Status")
            HStack(spacing: 8) {
                statusPill(
                    icon: "doc.text",
                    text: "\(live.documentCount ?? documents.count) \((live.documentCount ?? documents.count) == 1 ? "document" : "documents")",
                    color: theme.secondaryText)
                statusPill(
                    icon: "square.stack.3d.up",
                    text: "\(live.chunkCount ?? 0) \((live.chunkCount ?? 0) == 1 ? "chunk" : "chunks")",
                    color: theme.secondaryText)
                if live.isIndexing {
                    statusPill(icon: "arrow.triangle.2.circlepath", text: "Indexing…", color: theme.accentColor)
                }
            }
            if !live.isAvailable {
                Label(live.statusMessage ?? "Source folder unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(theme.errorColor)
            }
        }
    }

    private func statusPill(icon: String, text: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    @ViewBuilder private var projectsSection: some View {
        let projects = projectManager.projects.filter { $0.knowledgeCollectionIds.contains(collection.id) }
        if !projects.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Projects using this collection")
                ForEach(projects) { project in
                    Label(project.name, systemImage: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }
            }
        }
    }

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Agents with access")
            if editableAgents.isEmpty {
                Text("No custom agents available", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            } else {
                VStack(spacing: 0) {
                    ForEach(editableAgents) { agent in
                        let granted = agentManager.knowledgeCollectionIds(for: agent.id).contains(collection.id)
                        HStack(spacing: 10) {
                            AgentAvatarView(
                                mascotId: agent.avatar, name: agent.name,
                                tint: theme.accentColor, diameter: 24,
                                customImageURL: agent.customAvatarURL,
                                monogramFontSize: 10, borderWidth: 0)
                            Text(agent.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.primaryText)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { granted },
                                set: { _ in toggleAccess(agent) }
                            ))
                            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                            .labelsHidden()
                        }
                        .padding(10)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.secondaryBackground))
            }
        }
    }

    private var documentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Documents")
            if !documentsLoaded {
                ProgressView().controlSize(.small)
            } else if documents.isEmpty {
                Text("No documents indexed yet", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            } else {
                VStack(spacing: 0) {
                    ForEach(documents) { document in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .foregroundColor(theme.tertiaryText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.title.isEmpty ? URL(fileURLWithPath: document.relPath).deletingPathExtension().lastPathComponent : document.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.primaryText)
                                    .lineLimit(1)
                                Text(document.relPath)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(theme.tertiaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if !document.effectiveType.isEmpty {
                                Text(document.effectiveType)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(theme.accentColor)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(theme.accentColor.opacity(0.14)))
                            }
                        }
                        .padding(10)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.secondaryBackground))
            }
        }
    }

    private func toggleAccess(_ agent: Agent) {
        var ids = agentManager.knowledgeCollectionIds(for: agent.id)
        if ids.contains(collection.id) {
            ids.removeAll { $0 == collection.id }
        } else {
            ids.append(collection.id)
        }
        agentManager.updateKnowledgeSettings(enabled: !ids.isEmpty, collectionIds: ids, for: agent.id)
    }

    private func loadDocuments() {
        let id = collection.id.uuidString
        Task.detached(priority: .userInitiated) {
            if !KnowledgeDatabase.shared.isOpen { try? KnowledgeDatabase.shared.open() }
            let values = (try? KnowledgeDatabase.shared.listDocuments(collectionId: id)) ?? []
            await MainActor.run {
                documents = values
                documentsLoaded = true
            }
        }
    }
}
