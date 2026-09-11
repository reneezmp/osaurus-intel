//
//  OrchestratorDelegationSheet.swift
//  OsaurusCore
//
//  The deliberately small, manual Gate 4 delegation surface.
//

#if OSAURUS_INTEL

import SwiftUI

/// Admission and limits for the only currently supported delegation shape:
/// one text-only cloud child chosen from explicitly admitted custom agents.
struct OrchestratorDelegationSettings: View {
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    @Binding var configuration: OrchestratorDelegationConfiguration
    let pickerItems: [ModelPickerItem]
    let onPersist: (OrchestratorDelegationConfiguration) -> Void
    let onRun: () -> Void

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var remoteModels: [ModelPickerItem] {
        pickerItems.filter { item in
            guard case .remote = item.source else { return false }
            return item.isLikelyChatCapable && !item.id.hasPrefix("claude-code/")
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var eligibleAgents: [Agent] {
        agentManager.agents.filter { agent in
            guard !agent.isBuiltIn, let modelID = agentManager.effectiveModel(for: agent.id) else {
                return false
            }
            return remoteModels.contains { $0.id == modelID }
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var admittedAgents: [Agent] {
        eligibleAgents.filter { configuration.customAgentAllowlist.contains($0.id) }
    }

    private var runnableAgents: [Agent] {
        admittedAgents.filter { agent in
            guard let modelID = agentManager.effectiveModel(for: agent.id) else { return false }
            return configuration.admits(modelID: modelID)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield")
                    .foregroundColor(theme.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Manual, bounded cloud delegation", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Every run is one turn, one child, and no tools. The target and its exact remote model are checked again before a request leaves this Mac.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsSubsection(label: "Allowed Custom Agents") {
                if eligibleAgents.isEmpty {
                    Text("No custom agent currently resolves to an available remote chat model.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                } else {
                    VStack(spacing: 8) {
                        ForEach(eligibleAgents) { agent in
                            Toggle(isOn: admissionBinding(for: agent.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.displayName)
                                    Text(agentManager.effectiveModel(for: agent.id) ?? "")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(theme.tertiaryText)
                                }
                            }
                            .toggleStyle(.switch)
                        }
                    }
                }
            }

            SettingsSubsection(label: "Admitted Remote Cloud Models") {
                if remoteModels.isEmpty {
                    Text("No remote chat models are available from enabled providers.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                } else {
                    VStack(spacing: 8) {
                        ForEach(remoteModels) { item in
                            Toggle(isOn: modelAdmissionBinding(for: item.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayName)
                                    Text(item.id)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(theme.tertiaryText)
                                }
                            }
                            .toggleStyle(.switch)
                        }
                    }
                }
            }

            if !admittedAgents.isEmpty {
                SettingsSubsection(label: "Permission by Target") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(admittedAgents) { agent in
                            HStack {
                                Text(agent.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Picker("Permission for \(agent.displayName)", selection: permissionBinding(for: agent.id)) {
                                    Text("Ask", bundle: .module).tag(OrchestratorDelegationPermission.ask)
                                    Text("Deny", bundle: .module).tag(OrchestratorDelegationPermission.deny)
                                    Text("Always Allow", bundle: .module).tag(OrchestratorDelegationPermission.alwaysAllow)
                                }
                                .labelsHidden()
                                .frame(width: 140)
                            }
                        }
                    }
                }
            }

            SettingsSubsection(label: "Bounds") {
                HStack(spacing: 16) {
                    boundedNumberField(
                        label: "Max child tokens",
                        value: configuration.maximumChildTokens,
                        range: 1 ... 65_536
                    ) { update in
                        mutate { $0.maximumChildTokens = update }
                    }
                    boundedNumberField(
                        label: "Timeout (seconds)",
                        value: Int(configuration.timeoutSeconds),
                        range: 1 ... 600
                    ) { update in
                        mutate { $0.timeoutSeconds = UInt64(update) }
                    }
                }
            }

            HStack {
                Text("Fixed: 1 turn  ·  1 child  ·  No tools", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                Button("Run One Turn…", action: onRun)
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(runnableAgents.isEmpty)
            }
        }
    }

    private func boundedNumberField(
        label: String,
        value: Int,
        range: ClosedRange<Int>,
        onCommit: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
            TextField(label, value: Binding(
                get: { value },
                set: { onCommit(min(range.upperBound, max(range.lowerBound, $0))) }
            ), formatter: NumberFormatter())
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)
        }
    }

    private func admissionBinding(for agentID: UUID) -> Binding<Bool> {
        Binding(
            get: { configuration.customAgentAllowlist.contains(agentID) },
            set: { admitted in
                mutate {
                    if admitted { $0.customAgentAllowlist.insert(agentID) }
                    else { $0.customAgentAllowlist.remove(agentID) }
                }
            }
        )
    }

    private func modelAdmissionBinding(for modelID: String) -> Binding<Bool> {
        Binding(
            get: { configuration.admits(modelID: modelID) },
            set: { admitted in
                mutate {
                    if admitted { $0.admittedCloudModelIDs.insert(modelID) }
                    else { $0.admittedCloudModelIDs.remove(modelID) }
                }
            }
        )
    }

    private func permissionBinding(for targetID: UUID) -> Binding<OrchestratorDelegationPermission> {
        let scope = OrchestratorDelegationPermissionScope(
            launcherAgentID: Agent.defaultId,
            targetAgentID: targetID
        )
        return Binding(
            get: { configuration.permission(for: scope) },
            set: { permission in mutate { $0.setPermission(permission, for: scope) } }
        )
    }

    private func mutate(_ operation: (inout OrchestratorDelegationConfiguration) -> Void) {
        var updated = configuration
        operation(&updated)
        configuration = updated
        onPersist(updated)
    }
}

/// A manual launcher for a fresh, one-turn child. It does not make a chat or
/// retain a child session; the bounded text result is intentionally shown only
/// in this sheet.
struct OrchestratorDelegationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var selectedTargetID: UUID?
    @State private var requestText = ""
    @State private var isRunning = false
    @State private var resultTitle: String?
    @State private var resultText = ""
    @State private var approvalScope: OrchestratorDelegationPermissionScope?
    @State private var showApproval = false
    @State private var runTask: Task<Void, Never>?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var remoteModelIDs: Set<String> {
        Set(ModelPickerItemCache.shared.items.compactMap { item in
            guard case .remote = item.source, item.isLikelyChatCapable,
                  !item.id.hasPrefix("claude-code/") else { return nil }
            return item.id
        })
    }

    private var selectableAgents: [Agent] {
        let config = DefaultAgentConfigurationStore.load().delegation
        return agentManager.agents.filter { agent in
            guard !agent.isBuiltIn, config.customAgentAllowlist.contains(agent.id),
                  let modelID = agentManager.effectiveModel(for: agent.id) else { return false }
            return config.admits(modelID: modelID) && remoteModelIDs.contains(modelID)
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Delegate One Turn", bundle: .module)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("One child, one text response, no tools.", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
                Button(action: cancelAndClose) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.secondaryText)
                .accessibilityLabel("Cancel delegation")
            }

            if selectableAgents.isEmpty {
                Text("There is no currently admitted custom agent with an admitted remote cloud model. Add both in Orchestrator settings, then try again.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Target", selection: $selectedTargetID) {
                    Text("Choose an admitted agent", bundle: .module).tag(UUID?.none)
                    ForEach(selectableAgents) { agent in
                        Text(agent.displayName).tag(Optional(agent.id))
                    }
                }
                .onChange(of: selectableAgents.map(\.id)) { ids in
                    if let selectedTargetID, !ids.contains(selectedTargetID) {
                        self.selectedTargetID = nil
                    }
                }

                if let selectedTargetID, let agent = agentManager.agent(for: selectedTargetID) {
                    Text(agentManager.effectiveModel(for: agent.id) ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Request", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    TextEditor(text: $requestText)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(theme.inputBackground).overlay(
                            RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1)
                        ))
                }
            }

            if let resultTitle {
                VStack(alignment: .leading, spacing: 6) {
                    Text(resultTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    ScrollView {
                        Text(resultText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(theme.inputBackground))
                }
            }

            HStack {
                Button("Cancel", action: cancelAndClose)
                    .buttonStyle(SettingsButtonStyle())
                Spacer()
                Button(isRunning ? "Running…" : "Run") {
                    beginRun(approval: .none)
                }
                .buttonStyle(SettingsButtonStyle())
                .disabled(isRunning || selectedTargetID == nil || requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(theme.primaryBackground)
        .onAppear {
            Task { await ModelPickerItemCache.shared.prewarmModelCache() }
        }
        .onDisappear { runTask?.cancel() }
        .confirmationDialog(
            "Allow this one turn?",
            isPresented: $showApproval,
            titleVisibility: .visible
        ) {
            Button("Allow Once") {
                guard let approvalScope else { return }
                beginRun(approval: .approved(approvalScope))
            }
            Button("Deny", role: .cancel) {
                resultTitle = "Delegation denied"
                resultText = "No request was sent."
            }
        } message: {
            Text("This sends one text-only request to the selected custom agent. It cannot use tools or start another child.", bundle: .module)
        }
    }

    private func beginRun(approval: IntelOrchestratorDelegationRuntime.PerRunApproval) {
        guard let admission = currentAdmission() else { return }
        isRunning = true
        resultTitle = nil
        resultText = ""
        runTask?.cancel()
        runTask = Task {
            let runtime = IntelOrchestratorDelegationRuntime(
                configuration: admission.configuration,
                targetResolver: { requestedID in requestedID == admission.snapshot.agentID ? admission.snapshot : nil },
                cloudModelValidator: { modelID in admission.availableModelIDs.contains(modelID) },
                engineFactory: { ChatEngine() }
            )
            let outcome = await runtime.run(
                .init(launcherAgentID: Agent.defaultId, targetAgentID: admission.snapshot.agentID, text: requestText),
                approval: approval
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { present(outcome) }
        }
    }

    private func currentAdmission() -> Admission? {
        guard let targetID = selectedTargetID,
              let agent = agentManager.agent(for: targetID), !agent.isBuiltIn,
              let modelID = agentManager.effectiveModel(for: targetID)
        else {
            showError("The selected target is no longer available.")
            return nil
        }

        let configuration = DefaultAgentConfigurationStore.load().delegation
        guard configuration.customAgentAllowlist.contains(targetID), configuration.admits(modelID: modelID) else {
            showError("That target or its model is no longer admitted.")
            return nil
        }
        let availableModelIDs = remoteModelIDs
        guard availableModelIDs.contains(modelID) else {
            showError("That remote cloud model is no longer available.")
            return nil
        }

        return Admission(
            configuration: configuration,
            snapshot: .init(
                agentID: agent.id,
                isBuiltIn: agent.isBuiltIn,
                systemPrompt: agentManager.effectiveSystemPrompt(for: agent.id),
                effectiveModel: modelID,
                effectiveTemperature: agentManager.effectiveTemperature(for: agent.id),
                effectiveMaxTokens: agentManager.effectiveMaxTokens(for: agent.id)
            ),
            availableModelIDs: availableModelIDs
        )
    }

    @MainActor
    private func present(_ outcome: IntelOrchestratorDelegationRuntime.Outcome) {
        isRunning = false
        switch outcome {
        case let .succeeded(success):
            resultTitle = "Result from \(success.modelID)"
            resultText = success.text
        case .approvalRequired(let approval):
            approvalScope = approval.scope
            showApproval = true
        case let .denied(denial):
            showError("Delegation was denied: \(denial.rawValue).")
        case .timedOut:
            showError("The child exceeded its timeout. No further child work remains active.")
        case .cancelled:
            showError("The child was cancelled.")
        case let .failed(message):
            showError(boundedError(message))
        }
    }

    private func showError(_ message: String) {
        resultTitle = "Delegation failed"
        resultText = boundedError(message)
    }

    private func boundedError(_ message: String) -> String {
        String(message.prefix(1_000))
    }

    private func cancelAndClose() {
        runTask?.cancel()
        dismiss()
    }

    private struct Admission: Sendable {
        let configuration: OrchestratorDelegationConfiguration
        let snapshot: IntelOrchestratorDelegationRuntime.TargetSnapshot
        let availableModelIDs: Set<String>
    }
}

#endif
