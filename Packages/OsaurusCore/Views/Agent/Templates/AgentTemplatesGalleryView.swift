//
//  AgentTemplatesGalleryView.swift
//  osaurus
//
//  The Templates gallery for agents (W-agent-templates stage 4, after
//  upstream Classic's Templates page): built-in and saved agent templates,
//  Use Template, Export File, Import Template (Choose File), Save an Agent as
//  a Template, library management (Rename, Delete) and the "Show to
//  Orchestrator" switch, under the "What is a template?" explainer card.
//
//  Intel differences, on purpose:
//   - A sheet from the Agents header rather than a pushed page (Intel's
//     `AgentsView` is its own file), and plain controls that exist on
//     macOS 13 (no `.segmented` / `.bordered` styles, one-value `onChange`).
//   - Use Template does NOT write an agent straight away. It closes this
//     sheet and opens the Set Up Agent wizard (`AgentSetupWizardView`, as
//     upstream does) on an unsaved draft; the wizard shows the plan the
//     Orchestrator's `osaurus_config` would show (changes, risks, notes) and
//     only its Create Agent click saves anything.
//   - Imported files are untrusted data: they are parsed and validated by the
//     strict document decoder, shown for review (signature, requirements) and
//     never executed. Only Choose File or a drop; no link, clipboard or
//     network path.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentTemplatesGalleryView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var store = TemplateStore.shared
    @ObservedObject private var agentManager = AgentManager.shared

    let onClose: () -> Void
    /// Use Template: the host closes this sheet and opens the setup wizard.
    let onUse: (AgentTemplate) -> Void

    @State private var renaming: AgentTemplate?
    /// The explainer card above the list stays until the user closes it.
    @AppStorage("agentTemplatesIntroDismissed") private var introDismissed = false
    @State private var importText: String?
    @State private var showingSaveAgent = false
    @State private var message: String?
    @State private var isDropTargeted = false

    private var theme: ThemeProtocol { themeManager.currentTheme }
    private var templates: [AgentTemplate] { store.allTemplates(kind: .agent) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if templates.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if !introDismissed {
                            AgentTemplatesIntroCard(onDismiss: {
                                withAnimation(.easeInOut(duration: 0.2)) { introDismissed = true }
                            })
                            .padding(.bottom, 8)
                            .transition(.opacity)
                        }
                        ForEach(templates) { template in
                            AgentTemplateRow(
                                template: template,
                                isBuiltIn: store.isBuiltIn(template),
                                onUse: { onUse(template) },
                                onRename: { renaming = template },
                                onExport: { TemplateFileExport.export(template) },
                                onToggleOrchestrator: { toggleOrchestrator(template) },
                                onSaveToLibrary: { saveToLibrary(template) },
                                onDelete: { delete(template) }
                            )
                        }
                    }
                    .padding(20)
                }
            }
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
        .onAppear { store.reload() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            TemplateFileExport.loadDroppedFile(
                providers, onText: { importText = $0 }, onError: { message = $0 })
        }
        .sheet(item: $renaming) { template in
            RenameAgentTemplateSheet(template: template, onDone: { renaming = nil })
                .environment(\.theme, theme)
        }
        .sheet(
            isPresented: Binding(get: { importText != nil }, set: { if !$0 { importText = nil } })
        ) {
            ImportTemplateSheet(
                text: importText ?? "",
                onDone: { text in
                    importText = nil
                    if let text { message = text }
                })
        }
        .sheet(isPresented: $showingSaveAgent) {
            SaveAgentAsTemplateSheet(
                agents: agentManager.agents.filter { !$0.isBuiltIn },
                onDone: { text in
                    showingSaveAgent = false
                    if let text { message = text }
                })
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Agent Templates"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(L("Start an agent from a template, or share yours as a file."))
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
            Button(L("Save an Agent as Template")) { showingSaveAgent = true }
                .disabled(agentManager.agents.allSatisfy { $0.isBuiltIn })
            Button(L("Import Template")) {
                TemplateFileExport.chooseFile(
                    onText: { importText = $0 }, onError: { message = $0 })
            }
            Button(L("Done"), action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 28))
                .foregroundColor(theme.tertiaryText)
            Text(L("No templates yet"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(L("Save an agent as a template, or import a template file someone shared with you."))
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Actions

    private func toggleOrchestrator(_ template: AgentTemplate) {
        store.setAvailableToOrchestrator(!template.availableToOrchestrator, id: template.id)
        message =
            template.availableToOrchestrator
            ? L("Hidden from the Orchestrator") : L("Visible to the Orchestrator")
    }

    /// A built-in copied into the library keeps its id, so it shadows the
    /// bundled one and becomes editable (hide, delete).
    private func saveToLibrary(_ template: AgentTemplate) {
        var copy = template
        copy.author = nil
        do {
            try store.save(copy, changelog: L("Saved from the built-in template"))
            message = L("Saved \"\(template.name)\" to your library")
        } catch {
            message = error.localizedDescription
        }
    }

    private func delete(_ template: AgentTemplate) {
        do {
            try store.delete(id: template.id)
            message = L("Deleted \"\(template.name)\"")
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct AgentTemplateRow: View {
    @Environment(\.theme) private var theme

    let template: AgentTemplate
    let isBuiltIn: Bool
    let onUse: () -> Void
    let onRename: () -> Void
    let onExport: () -> Void
    let onToggleOrchestrator: () -> Void
    let onSaveToLibrary: () -> Void
    let onDelete: () -> Void

    private var signature: TemplateSignatureStatus { TemplateSigner.status(of: template) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(template.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("v\(template.version)")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                if isBuiltIn {
                    Text(L("Built-in")).font(.system(size: 11)).foregroundColor(theme.accentColor)
                }
                if !template.availableToOrchestrator {
                    Text(L("Hidden from Orchestrator")).font(.system(size: 11)).foregroundColor(theme.tertiaryText)
                }
                Spacer()
            }
            if let summary = template.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !template.requires.isEmpty {
                Text(L("Needs") + ": " + TemplateRequirementText.list(template.requires))
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if signature != .unsigned {
                Text(signature.label).font(.system(size: 11)).foregroundColor(theme.tertiaryText)
            }
            HStack(spacing: 8) {
                Button(L("Use Template"), action: onUse)
                Button(L("Export File"), action: onExport)
                Menu(L("More")) {
                    Button(
                        template.availableToOrchestrator
                            ? L("Hide from Orchestrator") : L("Show to Orchestrator"),
                        action: onToggleOrchestrator)
                    if isBuiltIn {
                        Button(L("Save to Library"), action: onSaveToLibrary)
                    } else {
                        Button(L("Rename…"), action: onRename)
                        Button(L("Delete"), action: onDelete)
                    }
                }
                .fixedSize()
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder, lineWidth: 1))
    }
}

/// One-line requirement text for rows and the import review.
enum TemplateRequirementText {
    static func list(_ items: [TemplateRequirement]) -> String {
        items.map { item in
            switch item.kind {
            case .model: return L("model") + " " + item.value
            case .mcpServer: return L("MCP server") + " " + item.value
            case .plugin: return L("plugin") + " " + item.value
            case .workingFolder: return L("folder") + " " + item.value
            case .systemPermission: return L("permission") + " " + (item.label ?? item.value)
            case .knowledgeCollection: return L("knowledge") + " " + item.value
            case .secret: return L("secret") + " " + item.value
            case .network: return L("network") + " " + item.value
            case .tool: return L("tool") + " " + item.value
            case .skill: return L("skill") + " " + item.value
            }
        }.joined(separator: ", ")
    }
}

// MARK: - Import

private struct ImportTemplateSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var store = TemplateStore.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let text: String
    let onDone: (String?) -> Void

    @State private var parsed: Result<Template, Error>?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Import Template"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.primaryText)
            switch parsed {
            case .success(let template):
                review(template)
            case .failure(let failure):
                Text(failure.localizedDescription)
                    .font(.system(size: 12))
                    .foregroundColor(theme.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                Text(L("Reading…")).font(.system(size: 12)).foregroundColor(theme.secondaryText)
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundColor(theme.errorColor)
            }
            HStack {
                Spacer()
                Button(L("Cancel")) { onDone(nil) }.keyboardShortcut(.cancelAction)
                if case .success(let template) = parsed {
                    Button(L("Import")) { importIt(template) }
                        .disabled(TemplateSigner.status(of: template) == .invalid)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
        .onAppear { parsed = Result { try Template.parse(text) } }
    }

    private func review(_ template: Template) -> some View {
        let status = TemplateSigner.status(of: template)
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(template.name)  v\(template.version)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
            if let summary = template.summary, !summary.isEmpty {
                Text(summary).font(.system(size: 12)).foregroundColor(theme.secondaryText)
            }
            Text(status.label).font(.system(size: 11)).foregroundColor(
                status == .invalid ? theme.errorColor : theme.tertiaryText)
            if let author = template.author?.name, !author.isEmpty {
                Text(L("Author") + ": " + author).font(.system(size: 11)).foregroundColor(theme.tertiaryText)
            }
            if !template.requires.isEmpty {
                Text(L("Needs") + ": " + TemplateRequirementText.list(template.requires))
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            if let prompt = template.agent.systemPrompt, !prompt.isEmpty {
                Text(L("System prompt"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                ScrollView {
                    Text(prompt)
                        .font(.system(size: 11))
                        .foregroundColor(theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 140)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.inputBackground))
            }
            Text(L("Importing only saves the template. Nothing runs and no agent is created until you use it."))
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
    }

    private func importIt(_ template: Template) {
        do {
            let taken = store.takenSlugs
            let disposition = store.disposition(for: template)
            let saved: Template
            switch disposition {
            case .conflict, .signerMismatch:
                // Same id and version with different content, or a signer
                // change: never overwrite. Keep a copy under a new name.
                saved = try store.importTemplate(
                    template, resolution: .keepBoth(name: template.suggestedImportName(takenSlugs: taken)))
            default:
                saved = try store.importTemplate(template)
            }
            onDone(L("Imported \"\(saved.name)\""))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Save an agent as a template

private struct SaveAgentAsTemplateSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let agents: [Agent]
    let onDone: (String?) -> Void

    @State private var selectedID: UUID?
    @State private var name = ""
    @State private var visibleToOrchestrator = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Save an Agent as Template"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Picker(L("Agent"), selection: $selectedID) {
                ForEach(agents) { agent in Text(agent.name).tag(Optional(agent.id)) }
            }
            TextField(L("Template name"), text: $name)
                .textFieldStyle(.roundedBorder)
            Toggle(L("Show to Orchestrator"), isOn: $visibleToOrchestrator)
            Text(L("Saved answers, secret values and absolute paths never go into a template."))
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            if let error {
                Text(error).font(.system(size: 12)).foregroundColor(theme.errorColor)
            }
            HStack {
                Spacer()
                Button(L("Cancel")) { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button(L("Save Template")) { save() }
                    .disabled(selectedID == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
        .onAppear {
            selectedID = agents.first?.id
            name = agents.first?.name ?? ""
        }
        .onChange(of: selectedID) { id in
            if let agent = agents.first(where: { $0.id == id }) { name = agent.name }
        }
    }

    private func save() {
        guard let agent = agents.first(where: { $0.id == selectedID }) else { return }
        let store = TemplateStore.shared
        let finalName = Template.availableName(
            for: name, takenSlugs: agent.sourceTemplateID == nil ? store.takenSlugs : [])
        let template = Template.make(
            from: agent, name: finalName, availableToOrchestrator: visibleToOrchestrator)
        do {
            let saved = try store.save(TemplateExportSanitizer.sanitized(template))
            onDone(L("Saved template \"\(saved.name)\""))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
