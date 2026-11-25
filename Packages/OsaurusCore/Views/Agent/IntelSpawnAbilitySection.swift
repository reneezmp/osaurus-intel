//
//  IntelSpawnAbilitySection.swift
//  osaurus
//
//  W-subagents stage 5: a custom agent's switch and shared editor for
//  `spawn_agent`. Upstream keeps these in the agent's Subagents tab
//  (`SpawnConfigurationEditor`); Intel mounts them in the Abilities tab next
//  to Browser Use. Custom agents only: the Orchestrator's controls live in
//  Settings → Orchestrator. Every target must also use an admitted cloud model
//  (Gate 4), and the permission is the stricter of this agent's setting and
//  Gate 4's per-target mode.
//

import SwiftUI

struct IntelSpawnAbilitySection: View {
    @ObservedObject private var agentManager = AgentManager.shared

    let agentId: UUID
    let theme: ThemeProtocol

    private var settings: AgentSettings? { agentManager.agent(for: agentId)?.settings }

    var body: some View {
        AgentDetailSection(title: L("Subagents"), icon: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 10) {
                if agentId == Agent.defaultId {
                    note(
                        "The Orchestrator's allowed agents, permissions and limits are in Settings → Orchestrator."
                    )
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.accentColor)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 9).fill(theme.accentColor.opacity(0.10)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Delegate to subagents"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            Text(
                                L(
                                    "Let the agent hand a task to other agents you allow below. Each runs as its own chat with its own prompt, model, and tools, and you are asked before it runs."
                                )
                            )
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { settings?.spawnDelegationEnabled ?? false },
                                set: { value in update { $0.spawnDelegationEnabled = value } }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(ThemedSwitchToggleStyle())
                        .accessibilityLabel(Text(L("Delegate to subagents")))
                    }
                    if settings?.spawnDelegationEnabled == true {
                        SpawnConfigurationEditor(
                            excludedAgentID: agentId,
                            modelOverride: modelOverride,
                            spawnableAgentIDs: Binding(
                                get: { settings?.spawnableAgentIDs ?? [] },
                                set: { value in update { $0.spawnableAgentIDs = value } }
                            ),
                            permissionDefaults: Binding(
                                get: { settings?.subagentPermissions ?? SubagentPermissionDefaults() },
                                set: { value in update { $0.subagentPermissions = value } }
                            ),
                            budgets: Binding(
                                get: { settings?.subagentBudgets ?? SubagentBudgets() },
                                set: { value in update { $0.subagentBudgets = value } }
                            ),
                            onChange: {}
                        )
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(theme.tertiaryBackground)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1))
                        )
                        note(
                            "Delegation runs on cloud models only. The agents and models you admit under Settings → Orchestrator → Delegation still apply."
                        )
                    }
                }
            }
        }
    }

    private var modelOverride: Binding<String?> {
        let key = SubagentCapabilityRegistry.spawn.id
        return Binding(
            get: { settings?.subagentModelOverrides[key] },
            set: { value in
                update { s in
                    if let value, !value.isEmpty {
                        s.subagentModelOverrides[key] = value
                    } else {
                        s.subagentModelOverrides.removeValue(forKey: key)
                    }
                }
            }
        )
    }

    private func update(_ change: (inout AgentSettings) -> Void) {
        guard var agent = agentManager.agent(for: agentId), !agent.isBuiltIn else { return }
        change(&agent.settings)
        agent.updatedAt = Date()
        agentManager.update(agent)
    }

    private func note(_ text: String) -> some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
