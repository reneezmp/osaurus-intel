//
//  IntelSpawnAdmission.swift
//  OsaurusCore — Subagent framework
//
//  W-subagents stage 3: Gate 4's admission rules applied to `spawn_agent`
//  (docs/W_SUBAGENTS_PLAN.md, "Mapping decision"). Upstream's spawn target
//  resolver reads the local-model catalog and the connected-provider index;
//  Intel runs only cloud models, so a target is runnable here when:
//
//   • it is a custom (non-built-in) agent that is not the launcher itself;
//   • it is in the launcher's spawn pool (the Orchestrator's pool is its
//     Gate 4 allowlist, `IntelSpawnPool`; a custom launcher's pool is its own
//     per-agent list while its Spawn switch is on);
//   • its model (the launcher's per-agent spawn override, else the target
//     agent's own) is an ADMITTED cloud model (`admittedCloudModelIDs`);
//   • that model is a currently available remote chat model
//     (`ModelPickerItemCache`, never a `claude-code/` id);
//   • the Gate 4 permission for the launcher/target pair is not Deny.
//
//  The same pure `evaluate` runs at planning (schema enum, prompt roster) and
//  again at execution (`TextSubagentKind`), so a change between the two is
//  refused rather than run on stale authority.
//

import Foundation

enum IntelSpawnAdmission {
    /// Everything `evaluate` needs, captured once so planning and execution
    /// agree on the facts they judged.
    struct Facts: Sendable, Equatable {
        let launcherID: UUID
        let isDefaultLauncher: Bool
        /// The launcher's effective spawn pool (`SubagentToolVisibility`;
        /// Gate 4's allowlist for the Orchestrator).
        let pool: [UUID]
        let configuration: OrchestratorDelegationConfiguration
        /// Currently available remote chat model ids.
        let availableCloudModelIDs: Set<String>
        /// The launcher's per-agent spawn model override, when set.
        let launcherModelOverride: String?
    }

    struct TargetFacts: Sendable, Equatable {
        let id: UUID
        let name: String
        let isBuiltIn: Bool
        /// The target agent's own effective model.
        let effectiveModel: String?
    }

    struct Admitted: Sendable, Equatable {
        let targetID: UUID
        let targetName: String
        /// The exact model the child will run on.
        let model: String
        let scope: OrchestratorDelegationPermissionScope
        /// Gate 4's permission for this launcher/target pair.
        let pairPermission: OrchestratorDelegationPermission
    }

    enum Denial: Error, Sendable, Equatable {
        case missingTarget
        case selfTarget
        case builtInTarget
        case notSpawnable
        case noModel
        case modelNotAdmitted(String)
        case modelUnavailable(String)
        case permissionDenied
    }

    /// Pure admission verdict. Fail-closed: every unknown is a denial.
    static func evaluate(
        _ facts: Facts, targetID: UUID, target: TargetFacts?
    ) -> Result<Admitted, Denial> {
        guard targetID != facts.launcherID else { return .failure(.selfTarget) }
        guard let target, target.id == targetID else { return .failure(.missingTarget) }
        guard !target.isBuiltIn, targetID != Agent.defaultId else { return .failure(.builtInTarget) }
        guard facts.pool.contains(targetID) else { return .failure(.notSpawnable) }
        let override = facts.launcherModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (override?.isEmpty == false ? override : nil) ?? target.effectiveModel
        guard let model = OrchestratorDelegationConfiguration.normalizedModelID(candidate ?? "") else {
            return .failure(.noModel)
        }
        guard facts.configuration.admits(modelID: model) else { return .failure(.modelNotAdmitted(model)) }
        guard facts.availableCloudModelIDs.contains(model) else { return .failure(.modelUnavailable(model)) }
        let scope = OrchestratorDelegationPermissionScope(
            launcherAgentID: facts.launcherID, targetAgentID: targetID)
        let permission = facts.configuration.permission(for: scope)
        guard permission != .deny else { return .failure(.permissionDenied) }
        return .success(
            Admitted(
                targetID: targetID, targetName: target.name, model: model,
                scope: scope, pairPermission: permission))
    }

    /// The tool-result / refusal copy for a denial. Names the repair.
    static func error(for denial: Denial, targetLabel: String, isDefaultLauncher: Bool) -> SubagentError {
        switch denial {
        case .missingTarget:
            return .unavailable("Agent '\(targetLabel)' not found.")
        case .selfTarget:
            return .denied("An agent cannot spawn itself. Choose a different configured agent.")
        case .builtInTarget:
            return .denied("The built-in Default agent cannot be spawned. Choose a custom configured agent.")
        case .notSpawnable:
            return .denied(
                isDefaultLauncher
                    ? "Agent '\(targetLabel)' is not spawnable. Add it in Settings → Orchestrator → Delegation."
                    : "Agent '\(targetLabel)' is not spawnable from this agent. Add it in the agent's Subagents tab."
            )
        case .noModel:
            return .unavailable("Agent '\(targetLabel)' has no available model configured.")
        case .modelNotAdmitted(let model):
            return .denied(
                "Agent '\(targetLabel)' uses \(model), which is not an admitted cloud model. "
                    + "Admit it in Settings → Orchestrator → Delegation before delegating to this agent.")
        case .modelUnavailable(let model):
            return .unavailable(
                "Agent '\(targetLabel)' uses \(model), which is not an available cloud chat model right now. "
                    + "Check the provider connection and try again.")
        case .permissionDenied:
            return .denied(
                "Delegation to '\(targetLabel)' is denied for this agent in Settings → Orchestrator → Delegation.")
        }
    }

    // MARK: - Live facts

    /// Test seam: the available cloud model ids, bypassing the provider
    /// model cache (which tests cannot fill without a provider). Production
    /// never binds it.
    @TaskLocal static var availableModelIDsOverrideForTests: Set<String>?

    /// The remote chat model ids a child may run on (same filter as
    /// Gate 4's `orchestrator_targets`: remote, chat-capable, never
    /// `claude-code/`). Callers prewarm the cache first.
    @MainActor
    static func availableCloudModelIDs() -> Set<String> {
        if let override = availableModelIDsOverrideForTests { return override }
        return Set(
            ModelPickerItemCache.shared.items.compactMap { item -> String? in
                guard case .remote = item.source, item.isLikelyChatCapable,
                    !item.id.hasPrefix("claude-code/")
                else { return nil }
                return item.id
            })
    }

    /// One main-actor read of everything `evaluate` needs for `launcherID`.
    @MainActor
    static func liveFacts(launcherID: UUID) -> Facts {
        let isDefault = launcherID == Agent.defaultId
        let stored = SubagentConfigurationStore.snapshot()
        let gate4 = DefaultAgentConfigurationStore.load().delegation
        let settings = AgentManager.shared.agent(for: launcherID)?.settings
        let pool = SubagentToolVisibility.effectiveSpawnableAgents(
            isDefault: isDefault,
            config: stored,
            perAgentEnabled: settings?.spawnDelegationEnabled ?? false,
            perAgentTargets: settings?.spawnableAgentIDs ?? [])
        let override = SubagentToolVisibility.effectiveSubagentModel(
            capabilityId: SubagentCapabilityRegistry.spawn.id,
            isDefault: isDefault, config: stored, settings: settings)
        return Facts(
            launcherID: launcherID, isDefaultLauncher: isDefault, pool: pool,
            configuration: gate4, availableCloudModelIDs: availableCloudModelIDs(),
            launcherModelOverride: override)
    }

    @MainActor
    static func targetFacts(_ id: UUID) -> TargetFacts? {
        guard let agent = AgentManager.shared.agent(for: id) else { return nil }
        return targetFacts(agent)
    }

    /// Agent-instance overload (upstream #3121): callers iterating a snapshot of
    /// `AgentManager.agents` pass the record they already hold, so each target
    /// costs no second `@Published` array read.
    @MainActor
    static func targetFacts(_ agent: Agent) -> TargetFacts {
        TargetFacts(
            id: agent.id, name: agent.name, isBuiltIn: agent.isBuiltIn,
            effectiveModel: AgentManager.shared.effectiveModel(for: agent))
    }

    /// Request-local target availability for the schema enum and the prompt
    /// roster: the launcher's pool, each target judged by `evaluate`. Never
    /// reads the connected-provider index (provider discovery is a separate
    /// workstream); `ModelPickerItemCache` is the availability source, as for
    /// `orchestrator_targets`.
    @MainActor
    static func resolveTargets(launcherID: UUID) -> SpawnTargetAvailabilitySnapshot {
        let facts = liveFacts(launcherID: launcherID)
        // Snapshot the @Published array once (upstream #3121); the per-target
        // lookups below read this copy instead of `agents` again.
        var snapshot: [UUID: Agent] = [:]
        for agent in AgentManager.shared.agents where snapshot[agent.id] == nil {
            snapshot[agent.id] = agent
        }
        let targets = facts.pool.map { id -> SpawnAgentTarget in
            let agent = snapshot[id]
            let target = agent.map { targetFacts($0) }
            let verdict = evaluate(facts, targetID: id, target: target)
            let model: String? = {
                if case .success(let admitted) = verdict { return admitted.model }
                return target?.effectiveModel
            }()
            let state: SpawnTargetState
            switch verdict {
            case .success: state = .runnable
            case .failure(.missingTarget): state = .missing
            case .failure(.modelUnavailable): state = .disconnected
            case .failure: state = .missing
            }
            return SpawnAgentTarget(
                descriptor: SpawnAgentDescriptor(
                    id: id,
                    name: agent?.name ?? id.uuidString,
                    description: agent.map { AgentDescriptionPolicy.normalized($0.routingDescription) }
                        .flatMap { $0.isEmpty ? nil : $0 },
                    modelId: model,
                    isLocal: model == nil ? nil : false,
                    providerName: nil,
                    workingFolderPath: agent.flatMap {
                        let path = $0.workingFolderPath?.trimmingCharacters(in: .whitespacesAndNewlines)
                        return path?.isEmpty == false ? path : nil
                    }),
                state: state)
        }
        return SpawnTargetAvailabilitySnapshot(agentTargets: targets)
    }
}
