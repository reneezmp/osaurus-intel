//
//  SpawnConfigurationEditor.swift
//  osaurus
//
//  Shared editor for the spawn capability's persisted policy (W-subagents
//  stage 5; upstream Classic's `SpawnConfigurationEditor`). The custom-agent
//  Subagents tab and Settings → Orchestrator both use this view so
//  permission, limits and the model override cannot drift into two
//  independently maintained control stacks.
//
//  Intel differences from upstream:
//  - The Orchestrator's allowed-agent pool is Gate 4's allowlist
//    (`OrchestratorDelegationConfiguration.customAgentAllowlist`, edited in
//    the Delegation section above), so for the Orchestrator this editor shows
//    no pool picker; the stored upstream pool is never read (`IntelSpawnPool`).
//    A custom agent keeps upstream's per-agent list.
//  - No shared (workspace) agents, local-model controls, "Local Models &
//    Memory" handoff warning or Server Concurrent Sessions mirror: Intel
//    delegates to cloud models only.
//  - Permission uses the themed segmented picker (`.segmented` renders blank
//    on Ventura). An unset launcher permission shows as Ask: at run time the
//    stricter of this and Gate 4's per-target permission applies, and Gate 4
//    defaults to Ask, so this editor can never loosen it.
//  - Limits keep upstream's bounds (`SubagentBudgets`) and are never raised.
//

import SwiftUI

struct SpawnConfigurationEditor: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var modelPickerCache = ModelPickerItemCache.shared

    /// A custom agent cannot spawn itself. `nil` identifies the built-in
    /// Orchestrator, whose pool is Gate 4's allowlist.
    let excludedAgentID: UUID?
    @Binding var modelOverride: String?
    @Binding var spawnableAgentIDs: [UUID]
    @Binding var permissionDefaults: SubagentPermissionDefaults
    @Binding var budgets: SubagentBudgets
    let onChange: () -> Void

    @State private var agentPickerPresented = false
    @State private var agentSearch = ""
    @State private var advancedExpanded = false

    private var isOrchestrator: Bool { excludedAgentID == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isOrchestrator {
                allowedSubagentsHeading
                allowedAgents
                divider
            }
            permissionRow
            divider
            budgetRows
            divider
            advancedSection
        }
        .task(id: advancedExpanded) {
            if advancedExpanded { await modelPickerCache.prewarmModelCache() }
        }
        .onAppear(perform: pruneMissingAgents)
        .onReceive(agentManager.$agents) { _ in pruneMissingAgents() }
    }

    // MARK: - Allowed subagents (custom agents)

    private var allowedSubagentsHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Allowed subagents", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(
                "The agents this agent may hand a task to. Each runs with its own prompt, model, and tools. An empty list keeps delegation off.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var allowedAgents: some View {
        let selected = spawnableAgentIDs.filter { id in agentCandidates.contains { $0.id == id } }
        let addable = agentCandidates.filter { !selected.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            AgentSheetSectionLabel("Allowed agents")
            if selected.isEmpty {
                emptyHint("None yet. Add an agent to delegate a task to it (using its own prompt + model).")
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(selected, id: \.self) { id in
                        if let candidate = agentCandidates.first(where: { $0.id == id }) {
                            removableChip(label: candidate.name) {
                                setAgent(id, included: false)
                            }
                        }
                    }
                }
                emptyHint(
                    "Agents with their own Working Folder read and write files there. Agents without one inherit this agent's chat folder for the run."
                )
            }
            if agentCandidates.isEmpty {
                emptyHint("No other agents yet — create one to make it spawnable.")
            } else {
                addButton(
                    title: "Add agent",
                    isPresented: $agentPickerPresented,
                    disabled: addable.isEmpty
                ) {
                    agentAddList
                }
            }
            emptyHint(
                "Each agent must also use a cloud model admitted in Settings → Orchestrator → Delegation, or the run is refused."
            )
        }
    }

    private var agentAddList: some View {
        let selected = spawnableAgentIDs
        let query = agentSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = agentCandidates.filter { candidate in
            !selected.contains(candidate.id)
                && (query.isEmpty
                    || candidate.name.localizedCaseInsensitiveContains(query)
                    || candidate.displayDescription.localizedCaseInsensitiveContains(query))
        }
        return VStack(alignment: .leading, spacing: 8) {
            SearchField(
                text: $agentSearch,
                placeholder: "Search agents",
                width: 264,
                compact: true
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if filtered.isEmpty {
                        emptyHint("No matching agents.").padding(.vertical, 6)
                    } else {
                        ForEach(filtered) { candidate in
                            addRow(
                                title: candidate.name,
                                subtitle: candidate.displayDescription.isEmpty
                                    ? nil : candidate.displayDescription
                            ) {
                                setAgent(candidate.id, included: true)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(12)
        .frame(width: 292)
    }

    // MARK: - Permission

    private var permissionRow: some View {
        controlRow(
            "Permission",
            subtitle:
                "Whether to ask before this launcher's agents run. The stricter of this and the per-agent permission in Settings → Orchestrator → Delegation applies, so Ask stays the default until you choose Always Allow for an agent."
        ) {
            ThemedSegmentedPicker(
                selection: permissionSelection,
                options: SubagentPermissionPolicy.allCases.map { ($0, $0.displayName) },
                fontSize: 11
            )
            .frame(maxWidth: 260)
        }
    }

    /// An unset launcher permission reads as Ask (never as upstream's stored
    /// default, Always Allow); choosing a value stores it explicitly.
    private var permissionSelection: Binding<SubagentPermissionPolicy> {
        let kindId = SubagentCapabilityRegistry.spawn.id
        return Binding(
            get: {
                permissionDefaults.hasExplicitPolicy(for: kindId)
                    ? permissionDefaults.policy(for: kindId) : .ask
            },
            set: { newValue in
                var updated = permissionDefaults
                updated.setPolicy(newValue, for: kindId)
                permissionDefaults = updated
                onChange()
            }
        )
    }

    // MARK: - Limits

    private var budgetRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentSheetSectionLabel("Limits")
                Spacer(minLength: 8)
                Text(limitsSummary)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }
            budgetStepper(
                title: "Max output tokens per subagent",
                help:
                    "Total generated tokens per model turn, including reasoning and the final answer. Reasoning can use the entire limit; this does not reserve answer tokens or set a separate thinking budget.",
                keyPath: \.maxDelegateTokens,
                range: SubagentBudgets.tokenBounds,
                step: 256
            )
            budgetStepper(
                title: "Max turns per subagent",
                help: "Model turns (tool-call rounds) one subagent may take before it must answer.",
                keyPath: \.maxDelegateTurns,
                range: SubagentBudgets.turnBounds,
                step: 1
            )
            budgetStepper(
                title: "Time limit per subagent (seconds)",
                help: "Wall-clock limit for one subagent, including model loading.",
                keyPath: \.maxElapsedSeconds,
                range: SubagentBudgets.elapsedBounds,
                step: 15
            )
            budgetStepper(
                title: "Max cloud subagents at once",
                help: "Cloud subagents that may run in parallel in one wave. Intel delegates to cloud models only.",
                keyPath: \.maxRemoteParallelSpawns,
                range: SubagentBudgets.remoteParallelSpawnBounds,
                step: 1
            )
        }
    }

    private var limitsSummary: String {
        let normalized = budgets.normalized
        return String(
            format: L("%@ tok · %d turns · %ds · %d at once"),
            normalized.maxDelegateTokens.formatted(),
            normalized.maxDelegateTurns,
            normalized.maxElapsedSeconds,
            normalized.maxRemoteParallelSpawns
        )
    }

    private func budgetStepper(
        title: LocalizedStringKey,
        help: LocalizedStringKey,
        keyPath: WritableKeyPath<SubagentBudgets, Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        let value = budgetBinding(keyPath)
        return controlRow(title, subtitle: help) {
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .frame(width: 64, alignment: .trailing)
            }
            .frame(maxWidth: 180)
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    advancedExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(advancedExpanded ? 90 : 0))
                    AgentSheetSectionLabel("Advanced")
                    Spacer(minLength: 8)
                    if !advancedExpanded, let current = normalized(modelOverride) {
                        Text(current)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if advancedExpanded {
                modelOverrideRow
            }
        }
    }

    private var modelOverrideRow: some View {
        controlRow(
            "Agent-target model override",
            subtitle:
                "Optional. Runs every delegated agent on this model instead of the agent's own. It must still be an admitted cloud model, or the run is refused. Leave it on \"Use each agent's model\" unless you need one model for all subagents."
        ) {
            Menu {
                Button {
                    setOverride(nil)
                } label: {
                    Text("Use each agent's model", bundle: .module)
                }
                ForEach(overrideCandidates, id: \.id) { item in
                    Button(item.displayName) { setOverride(item.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(overrideLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// Remote chat models only (what Gate 4 can admit), never Claude Code.
    private var overrideCandidates: [ModelPickerItem] {
        modelPickerCache.items.filter { item in
            guard case .remote = item.source else { return false }
            return item.isLikelyChatCapable && !item.id.hasPrefix("claude-code/")
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var overrideLabel: String {
        guard let current = normalized(modelOverride) else { return L("Use each agent's model") }
        if let item = overrideCandidates.first(where: { $0.id == current }) { return item.displayName }
        return String(format: L("%@ (unavailable)"), current)
    }

    private func setOverride(_ id: String?) {
        modelOverride = normalized(id)
        onChange()
    }

    // MARK: - Bindings and candidates

    private var agentCandidates: [Agent] {
        agentManager.agents.filter { candidate in
            if let excludedAgentID { return candidate.id != excludedAgentID }
            return !candidate.isBuiltIn
        }
    }

    /// Drop ids that no longer name a live agent from the bound list, so a
    /// deletion that raced this editor can never be re-persisted by its
    /// next save (and never renders as a bare UUID chip).
    private func pruneMissingAgents() {
        guard !isOrchestrator, !agentManager.agents.isEmpty else { return }
        let live = Set(agentManager.agents.map(\.id))
        let pruned = spawnableAgentIDs.filter { live.contains($0) }
        guard pruned.count != spawnableAgentIDs.count else { return }
        spawnableAgentIDs = pruned
        onChange()
    }

    private func budgetBinding(_ keyPath: WritableKeyPath<SubagentBudgets, Int>) -> Binding<Int> {
        Binding(
            get: { budgets[keyPath: keyPath] },
            set: { newValue in
                var updated = budgets
                updated[keyPath: keyPath] = newValue
                budgets = updated.normalized
                onChange()
            }
        )
    }

    private func setAgent(_ id: UUID, included: Bool) {
        var ids = spawnableAgentIDs.filter { $0 != id }
        if included { ids.append(id) }
        spawnableAgentIDs = SpawnableAgentIdentity.normalizedIDs(ids)
        onChange()
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Shared chrome

    private func controlRow<Control: View>(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title, bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                if let subtitle {
                    Text(subtitle, bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
    }

    private var divider: some View {
        Divider().overlay(theme.inputBorder)
    }

    private func emptyHint(_ text: LocalizedStringKey) -> some View {
        Text(text, bundle: .module)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func removableChip(label: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(theme.tertiaryBackground))
        .overlay(Capsule().stroke(theme.inputBorder, lineWidth: 1))
    }

    private func addButton<Content: View>(
        title: LocalizedStringKey,
        isPresented: Binding<Bool>,
        disabled: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Button {
            isPresented.wrappedValue = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                Text(title, bundle: .module).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(disabled ? theme.tertiaryText : theme.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .popover(isPresented: isPresented, arrowEdge: .bottom) {
            content()
        }
    }

    private func addRow(
        title: String,
        subtitle: String?,
        onAdd: @escaping () -> Void
    ) -> some View {
        Button(action: onAdd) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(theme.accentColor)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }
}
