//
//  KnowledgeView.swift
//  osaurus
//
//  Intel management surface for the local Knowledge collection registry and
//  background indexer.
//

import AppKit
import SwiftUI

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

    var body: some View {
        VStack(spacing: 0) {
            header
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            ZStack {
                if integration.collections.isEmpty {
                    emptyState
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
        }
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

    private var header: some View {
        ManagerHeaderWithActions(
            title: L("Knowledge"),
            subtitle: L("Searchable folders of guides, policies, and templates"),
            count: integration.collections.count
        ) {
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

    private var emptyState: some View {
        SettingsEmptyState(
            icon: "books.vertical.fill",
            title: L("Add Your First Knowledge Collection"),
            subtitle: L(
                "Point Osaurus at a folder of guides, templates, and standards so agents can consult it on demand."
            ),
            examples: [
                .init(
                    icon: "doc.text",
                    title: L("Guides & Policies"),
                    description: L("How your team does things")
                ),
                .init(
                    icon: "square.on.square",
                    title: L("Templates"),
                    description: L("Wording you reuse")
                ),
                .init(
                    icon: "book",
                    title: L("How-To Steps"),
                    description: L("Instructions for everyday tasks")
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
                showToast("Added \"\(name)\"")
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
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onOpenDetail: () -> Void

    private enum CategoryStatus: Equatable {
        case checking
        case allCategorized
        case uncategorized(Int)
    }

    @State private var categoryStatus: CategoryStatus = .checking

    private var categoryLabel: String {
        switch categoryStatus {
        case .checking:
            return "Checking categories…"
        case .allCategorized:
            return "All categorized"
        case .uncategorized(let count):
            return count == 1 ? "1 doc uncategorized" : "\(count) docs uncategorized"
        }
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
        let uncategorized = documents.filter {
            $0.docType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        await MainActor.run {
            categoryStatus =
                uncategorized == 0
                ? .allCategorized
                : .uncategorized(uncategorized)
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
                            if !document.docType.isEmpty {
                                Text(document.docType)
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
