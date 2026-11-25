//
//  SubagentSettingsSection.swift
//  osaurus
//
//  Subagent policy for the built-in main chat (the Orchestrator), W-subagents
//  stage 5. Custom agents edit the same controls in their Subagents tab; the
//  built-in chat has no agent detail page, so its persisted
//  `SubagentConfiguration` is reachable here.
//
//  Vocabulary (matches upstream): the noun is "subagent", the verb is
//  "delegate"; `spawn_*` survive only as tool ids. Intel: the allowed-agent
//  pool and admitted models are Gate 4 (the Delegation section above), so
//  this section holds permission, limits and the model override only, and
//  has no "Local Models & Memory" subsection (cloud delegation only).
//

import SwiftUI

struct SubagentSettingsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Binding var configuration: SubagentConfiguration

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        SettingsSection(title: "Subagents", icon: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "The Orchestrator hands real work to the agents you allow under Delegation. Each runs as its own chat session with its own prompt, model, tools, and folder (it inherits the Orchestrator's folder when it has none). These controls set how, and how much, they may run.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

                SpawnConfigurationEditor(
                    excludedAgentID: nil,
                    modelOverride: mainChatSpawnModelOverride,
                    spawnableAgentIDs: .constant([]),
                    permissionDefaults: $configuration.permissionDefaults,
                    budgets: $configuration.budgets,
                    onChange: {}
                )
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.tertiaryBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
            }
        }
    }

    /// Main-chat model override for Spawn. The shared editor stores nil as
    /// "Use each agent's model" and trims any explicit model id.
    private var mainChatSpawnModelOverride: Binding<String?> {
        Binding(
            get: { configuration.subagentModelOverrides[SubagentCapabilityRegistry.spawn.id] },
            set: { newValue in
                var overrides = configuration.subagentModelOverrides
                let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let trimmed, !trimmed.isEmpty {
                    overrides[SubagentCapabilityRegistry.spawn.id] = trimmed
                } else {
                    overrides.removeValue(forKey: SubagentCapabilityRegistry.spawn.id)
                }
                configuration.subagentModelOverrides = overrides
            }
        )
    }
}
