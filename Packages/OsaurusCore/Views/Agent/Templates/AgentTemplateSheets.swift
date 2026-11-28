//
//  AgentTemplateSheets.swift
//  osaurus
//
//  Rename a library template, and the display names / icons for template
//  requirement kinds (upstream #3172). Shares the `AgentSheetHeader` /
//  `AgentSheetFooter` chrome with the Create Agent sheet.
//
//  Intel: only the Rename sheet and the requirement presentation are here.
//  Upstream's `SaveAgentTemplateSheet` is Intel's own `SaveAgentAsTemplateSheet`
//  in `AgentTemplatesGalleryView`.
//

import SwiftUI

// MARK: - Rename

struct RenameAgentTemplateSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = TemplateStore.shared

    let template: AgentTemplate
    let onDone: () -> Void

    @State private var name: String = ""
    @State private var errorMessage: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var collides: Bool {
        let slug = AgentTemplate.slug(for: trimmed)
        return store.allTemplates(kind: template.kind).contains { $0.slug == slug && $0.id != template.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            AgentSheetHeader(icon: "pencil", title: "Rename Template", subtitleText: template.name, onClose: onDone)
            VStack(alignment: .leading, spacing: 8) {
                AgentSheetSectionLabel("New Name")
                StyledTextField(placeholder: L("Template Name"), text: $name, icon: "textformat")
                if collides {
                    Text("Another template already uses this name.", bundle: .module)
                        .font(.system(size: 11)).foregroundColor(theme.warningColor)
                }
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 11)).foregroundColor(theme.errorColor)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            AgentSheetFooter(
                primary: AgentSheetFooter.Action(
                    label: "Rename", isEnabled: !trimmed.isEmpty && !collides && trimmed != template.name,
                    handler: rename),
                secondary: AgentSheetFooter.Action(label: "Cancel", handler: onDone),
                hint: nil
            )
        }
        .fittedSheetFrame(width: 440, height: 240)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1))
        .onAppear { if name.isEmpty { name = template.name } }
    }

    private func rename() {
        do {
            try store.rename(id: template.id, to: trimmed)
            onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Requirement presentation

extension TemplateRequirement.Kind {
    var title: String {
        switch self {
        case .workingFolder: return L("Folder")
        case .knowledgeCollection: return L("Knowledge")
        case .plugin: return L("Plugin")
        case .mcpServer: return L("MCP server")
        case .systemPermission: return L("Permission")
        case .model: return L("Model")
        case .secret: return L("Secret")
        case .network: return L("Network")
        case .tool: return L("Tool")
        case .skill: return L("Skill")
        }
    }

    var icon: String {
        switch self {
        case .workingFolder: return "folder"
        case .knowledgeCollection: return "books.vertical"
        case .plugin: return "puzzlepiece.extension"
        case .mcpServer: return "server.rack"
        case .systemPermission: return "lock.shield"
        case .model: return "cube"
        case .secret: return "key"
        case .network: return "network"
        case .tool: return "wrench.and.screwdriver"
        case .skill: return "lightbulb"
        }
    }
}
