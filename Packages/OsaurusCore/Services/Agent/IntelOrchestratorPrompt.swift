//
//  IntelOrchestratorPrompt.swift
//  OsaurusCore
//
//  Stable built-in role for Intel's Orchestrator. The editable prompt is a
//  persona extension; it never replaces the product's safety contract.
//

#if OSAURUS_INTEL

import Foundation

enum IntelOrchestratorPrompt {
    struct DelegationTarget: Equatable, Sendable {
        let id: UUID
        let name: String
        let modelID: String
    }

    static func compose(
        agentID: UUID,
        editablePrompt: String,
        delegationTargets: [DelegationTarget] = []
    ) -> String {
        guard agentID == Agent.defaultId else { return editablePrompt }

        var role = """
            You are Osaurus, the built-in Orchestrator for this Mac. Help the user configure Osaurus and coordinate bounded work through the tools you are actually given.

            Use `orchestrator_targets` to inspect the live admitted target roster when asked, especially after settings change. A target appears only when an allowed custom agent's exact effective model is both admitted and available. The prompt roster below is a snapshot, not proof of current availability. Delegation is available only through `orchestrator_delegate`. Delegate only to a custom agent and cloud model the user explicitly admitted in Orchestrator settings. Each child is fresh, standalone, tool-free, limited to one turn, bounded by input, token, output, and timeout limits, cancellable, and returned only as inline text. Never claim that a child chat, file, background task, nested delegation, or durable artifact was created.

            Configuration is available only through `orchestrator_config`. Inspect or plan before applying changes, and apply only after the exact review flow approves them. Do not invent tools, permissions, targets, models, or completed actions. When a gate denies a request, explain the real gate and let the user change it explicitly.
            """

        if delegationTargets.isEmpty {
            role += """


                ## Admitted delegation targets
                No custom agent is configured with an admitted cloud model in this prompt snapshot. If the user asks about targets, call `orchestrator_targets` for live state and any mismatch reason. Do not ask the user for an agent UUID.
                """
        } else {
            let rows = delegationTargets
                .sorted { lhs, rhs in
                    let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    return comparison == .orderedSame
                        ? lhs.id.uuidString < rhs.id.uuidString
                        : comparison == .orderedAscending
                }
                .map { target in
                    "- \(target.name): target_agent_id=`\(target.id.uuidString)`, model=`\(target.modelID)`"
                }
                .joined(separator: "\n")
            role += """


                ## Admitted delegation targets
                These are the only targets currently configured for `orchestrator_delegate`. Use the exact `target_agent_id`; the runtime will revalidate admission, availability, and permission before dispatch.
                \(rows)
                """
        }

        let persona = editablePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !persona.isEmpty else { return role }
        return role + "\n\n## User-defined persona\n" + persona
    }
}

/// One admission calculation shared by the settings preview, the prompt,
/// and live target discovery. Availability is optional for the prompt (the
/// dispatcher always rechecks it), but required for runnable UI/tool rows.
enum IntelOrchestratorAdmission {
    struct Evaluation: Sendable {
        let targets: [IntelOrchestratorPrompt.DelegationTarget]
        let blocked: [String]
    }

    static func evaluate(
        configuration: OrchestratorDelegationConfiguration,
        agents: [Agent],
        effectiveModel: (UUID) -> String?,
        availableModelIDs: Set<String>? = nil
    ) -> Evaluation {
        var byID: [UUID: Agent] = [:]
        var duplicateIDs = Set<UUID>()
        for agent in agents {
            if byID.updateValue(agent, forKey: agent.id) != nil {
                duplicateIDs.insert(agent.id)
            }
        }
        var targets: [IntelOrchestratorPrompt.DelegationTarget] = []
        var blocked: [String] = []
        for id in configuration.customAgentAllowlist.sorted(by: { $0.uuidString < $1.uuidString }) {
            if duplicateIDs.contains(id) {
                blocked.append("An allowed agent has a duplicate identity and cannot be delegated to.")
                continue
            }
            guard let agent = byID[id], !agent.isBuiltIn else {
                blocked.append("An allowed custom agent is missing or is built in.")
                continue
            }
            guard let modelID = effectiveModel(id), !modelID.isEmpty else {
                blocked.append("\(agent.displayName) has no effective model.")
                continue
            }
            guard configuration.admits(modelID: modelID) else {
                blocked.append("\(agent.displayName) uses \(modelID), which is not an admitted model.")
                continue
            }
            if let availableModelIDs, !availableModelIDs.contains(modelID) {
                blocked.append("\(agent.displayName) uses \(modelID), which is not an available remote chat model.")
                continue
            }
            targets.append(.init(id: id, name: agent.displayName, modelID: modelID))
        }
        if configuration.customAgentAllowlist.isEmpty {
            blocked.append("No custom agent is allowed.")
        }
        if configuration.admittedCloudModelIDs.isEmpty {
            blocked.append("No remote cloud model is admitted.")
        }
        return Evaluation(targets: targets, blocked: blocked)
    }
}

#endif
