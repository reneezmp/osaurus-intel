//
//  IntelOrchestratorConfigSheet.swift
//  OsaurusCore
//
//  Gate 5 UI: a deliberately narrow, inspectable configuration surface for
//  the Intel Orchestrator. The bridge keeps the view independent of the
//  declarative configuration store and planner.
//

#if OSAURUS_INTEL

import SwiftUI

/// The view-facing shape of one planned configuration change.
///
/// The IntelDeclarative core can map its richer plan into this value without
/// making the settings view depend on storage, decoding, or approval policy.
struct IntelOrchestratorConfigurationUIChange: Identifiable, Equatable, Sendable {
    let id: String
    let field: String
    let before: String
    let after: String
    let risk: String?
}

/// A reviewable plan returned by the declarative configuration planner.
struct IntelOrchestratorConfigurationUIPlan: Equatable, Sendable {
    let id: String
    let summary: String
    let changes: [IntelOrchestratorConfigurationUIChange]
    let unsupportedDomains: [String]
}

/// Adapter boundary for the Gate 5 view.
///
/// The production implementation belongs under IntelDeclarative. Keeping the
/// boundary here lets the UI land independently and prevents the view from
/// reaching into stores or accidentally applying a document on its own.
protocol IntelOrchestratorConfigurationUIBridge: Sendable {
    func exportDocument() async -> String
    func preview(document: String) async throws -> IntelOrchestratorConfigurationUIPlan
    func apply(document: String, planID: String) async throws -> String
}

struct UnavailableIntelOrchestratorConfigurationUIBridge: IntelOrchestratorConfigurationUIBridge {
    func exportDocument() async -> String {
        """
        {
          "version": 1,
          "default_agent": {},
          "delegation": {}
        }
        """
    }

    func preview(document: String) async throws -> IntelOrchestratorConfigurationUIPlan {
        throw IntelOrchestratorConfigurationUIError.coreUnavailable
    }

    func apply(document: String, planID: String) async throws -> String {
        throw IntelOrchestratorConfigurationUIError.coreUnavailable
    }
}

/// The live adapter for the Gate 5 core slice. Keeping this translation in
/// the view file makes the UI contract easy to replace if the planner's
/// presentation model changes later.
struct LiveIntelOrchestratorConfigurationUIBridge: IntelOrchestratorConfigurationUIBridge {
    private let service: IntelDeclarativeConfigurationService

    init(service: IntelDeclarativeConfigurationService = IntelDeclarativeConfigurationService()) {
        self.service = service
    }

    func exportDocument() async -> String {
        guard let data = try? await service.exportJSON() else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func preview(document: String) async throws -> IntelOrchestratorConfigurationUIPlan {
        let plan = try await service.plan(json: Data(document.utf8))
        return makeUIPlan(from: plan)
    }

    func apply(document: String, planID: String) async throws -> String {
        let plan = try await service.plan(json: Data(document.utf8))
        guard plan.id.uuidString == planID else {
            throw IntelDeclarativeConfigurationError.invalidApproval
        }
        let approval = await service.approve(plan)
        _ = try await service.apply(plan, approval: approval)
        return plan.isNoOp ? "No changes were needed." : "The approved configuration was saved and verified."
    }

    private func makeUIPlan(from plan: IntelDeclarativeConfigurationPlan) -> IntelOrchestratorConfigurationUIPlan {
        IntelOrchestratorConfigurationUIPlan(
            id: plan.id.uuidString,
            summary: plan.isNoOp ? "No changes detected." : String(plan.changes.count) + " change(s) are ready for review.",
            changes: plan.changes.map { change in
                IntelOrchestratorConfigurationUIChange(
                    id: change.path,
                    field: change.path,
                    before: change.before,
                    after: change.after,
                    risk: "Requires approval"
                )
            },
            unsupportedDomains: []
        )
    }
}

enum IntelOrchestratorConfigurationUIError: LocalizedError {
    case coreUnavailable

    var errorDescription: String? {
        switch self {
        case .coreUnavailable:
            return "The Intel declarative configuration backend is not attached to this build yet. No changes were applied."
        }
    }
}

struct IntelOrchestratorConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeManager = ThemeManager.shared

    private let bridge: any IntelOrchestratorConfigurationUIBridge

    @State private var document = ""
    @State private var plan: IntelOrchestratorConfigurationUIPlan?
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var isLoading = false
    @State private var isApplying = false
    @State private var showApproval = false

    init(bridge: any IntelOrchestratorConfigurationUIBridge = LiveIntelOrchestratorConfigurationUIBridge()) {
        self.bridge = bridge
    }

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    scopeSection
                    documentSection

                    if let errorMessage {
                        messageCard(title: "Configuration error", message: errorMessage, icon: "exclamationmark.triangle", color: .orange)
                    }

                    if let resultMessage {
                        messageCard(title: "Configuration applied", message: resultMessage, icon: "checkmark.circle", color: .green)
                    }

                    if let plan {
                        planSection(plan)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
        }
        .frame(minWidth: 760, minHeight: 640)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
        .task {
            guard document.isEmpty else { return }
            document = await bridge.exportDocument()
        }
        .confirmationDialog(
            "Apply this configuration?",
            isPresented: $showApproval,
            titleVisibility: .visible
        ) {
            Button("Apply Changes") { applyApprovedPlan() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This applies the exact plan shown below. The operation will be rejected if the current configuration changed since the plan was created.", bundle: .module)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Declarative Configuration", bundle: .module)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.primaryText)
                Text("Inspect a bounded plan before anything changes.", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 19))
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.secondaryText)
            .accessibilityLabel("Close declarative configuration")
        }
        .padding(24)
        .background(theme.secondaryBackground)
    }

    private var scopeSection: some View {
        SettingsSection(title: "Supported scope", icon: "checkmark.shield") {
            VStack(alignment: .leading, spacing: 10) {
                scopeRow("default_agent", "Identity, system prompt, model, temperature, and max output tokens")
                scopeRow("delegation", "Gate 4 admissions, permissions, and bounded child-run limits")
                Divider().overlay(theme.cardBorder)
                Text("This Intel slice rejects agents, tools, providers, channels, knowledge, memory, schedules, watchers, secrets, and unknown domains. Those areas need their own stores and approval contracts before they can be linked here.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func scopeRow(_ key: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(key)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }
        }
    }

    private var documentSection: some View {
        SettingsSection(title: "Configuration document", icon: "doc.text") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("JSON", bundle: .module)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                    Spacer()
                    Button("Load current") { loadCurrent() }
                        .buttonStyle(SettingsButtonStyle())
                }

                TextEditor(text: $document)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 230)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(theme.inputBackground).overlay(
                        RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1)
                    ))

                Text("Planning validates the complete document before producing any mutation. Secret values are never accepted into this surface.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    private func planSection(_ plan: IntelOrchestratorConfigurationUIPlan) -> some View {
        SettingsSection(title: "Plan preview", icon: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 12) {
                Text(plan.summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)

                if !plan.unsupportedDomains.isEmpty {
                    messageCard(
                        title: "Unsupported domains",
                        message: plan.unsupportedDomains.joined(separator: ", "),
                        icon: "xmark.octagon",
                        color: .orange
                    )
                }

                if plan.changes.isEmpty {
                    Text("The document produces no changes.", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                } else {
                    ForEach(plan.changes) { change in
                        changeRow(change)
                    }
                }
            }
        }
    }

    private func changeRow(_ change: IntelOrchestratorConfigurationUIChange) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(change.field)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                Spacer()
                if let risk = change.risk {
                    Text(risk)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                valueBox(label: "Before", value: change.before)
                Image(systemName: "arrow.right")
                    .foregroundColor(theme.tertiaryText)
                    .padding(.top, 16)
                valueBox(label: "After", value: change.after)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.inputBackground).overlay(
            RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1)
        ))
    }

    private func valueBox(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Button("Cancel", action: { dismiss() })
                .buttonStyle(SettingsButtonStyle())
            Spacer()
            Button(isLoading ? "Planning…" : "Preview Plan") { previewPlan() }
                .buttonStyle(SettingsButtonStyle())
                .disabled(isLoading || isApplying || document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(isApplying ? "Applying…" : "Apply") { showApproval = true }
                .buttonStyle(SettingsButtonStyle())
                .disabled(isLoading || isApplying || plan == nil || plan?.changes.isEmpty == true || plan?.unsupportedDomains.isEmpty == false)
        }
        .padding(16)
        .background(theme.secondaryBackground)
    }

    private func messageCard(title: String, message: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.10)))
    }

    private func loadCurrent() {
        isLoading = true
        errorMessage = nil
        resultMessage = nil
        Task {
            let current = await bridge.exportDocument()
            await MainActor.run {
                document = current
                plan = nil
                isLoading = false
            }
        }
    }

    private func previewPlan() {
        isLoading = true
        errorMessage = nil
        resultMessage = nil
        plan = nil
        let requestedDocument = document
        Task {
            do {
                let nextPlan = try await bridge.preview(document: requestedDocument)
                await MainActor.run {
                    plan = nextPlan
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = boundedMessage(error)
                    isLoading = false
                }
            }
        }
    }

    private func applyApprovedPlan() {
        guard let plan else { return }
        isApplying = true
        errorMessage = nil
        resultMessage = nil
        let requestedDocument = document
        Task {
            do {
                let result = try await bridge.apply(document: requestedDocument, planID: plan.id)
                await MainActor.run {
                    resultMessage = result
                    isApplying = false
                    self.plan = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = boundedMessage(error)
                    isApplying = false
                }
            }
        }
    }

    private func boundedMessage(_ error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? String(error.localizedDescription.prefix(1_000))
        return String(message.prefix(1_000))
    }
}

#endif
