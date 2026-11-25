//
//  SpawnPermissionGate.swift
//  OsaurusCore
//
//  One permission owner for `spawn_agent`. Ported from upstream Classic
//  (W-subagents stage 3), without the sibling-wave rendezvous (`SpawnWaveGate`,
//  stage 6): every call raises its own card, which is stricter, never looser.
//
//  Intel's permission is the MORE RESTRICTIVE of:
//   • the launcher's own spawn policy (a custom launcher's
//     `subagentPermissions`; the Orchestrator has none of its own), and
//   • Gate 4's Ask / Deny / Always Allow for the exact launcher/target pair
//     (`OrchestratorDelegationConfiguration.permissionModes`), default Ask.
//  "Always Allow" on the card persists both. Nothing here auto-approves: an
//  `.ask` with no one to answer (an external surface, a run that denies
//  unapproved prompts, a test process) is refused.
//

import Foundation

enum SpawnPermissionGate {
    enum PromptChoice: Sendable, Equatable {
        case deny
        case allowOnce
        case alwaysAllow
    }

    struct PromptRequest: Sendable, Equatable {
        let toolName: String
        let description: String
        let argumentsJSON: String
        let launchingAgentId: UUID
    }

    /// Deterministic model-free seam. Production never binds this value; tests
    /// can count prompts or choose allow/deny/always without an AppKit panel.
    @TaskLocal
    static var promptOverride:
        (@Sendable (PromptRequest) async throws -> PromptChoice)?

    /// The strictest policy across several sources: Deny wins, then Ask, then
    /// Always Allow.
    static func combinedPolicy(_ policies: [SubagentPermissionPolicy]) -> SubagentPermissionPolicy {
        if policies.contains(.deny) { return .deny }
        if policies.contains(.ask) { return .ask }
        return .alwaysAllow
    }

    /// The live combined policy for the launcher (and, when known, the exact
    /// Gate 4 launcher/target pair). Re-read at every decision point.
    static func effectivePolicy(
        for scope: SubagentScope,
        pairScope: OrchestratorDelegationPermissionScope?
    ) async -> SubagentPermissionPolicy {
        let config = SubagentConfigurationStore.snapshot()
        let isDefault = scope.agentId == Agent.defaultId
        let settings = await MainActor.run {
            AgentManager.shared.agent(for: scope.agentId)?.settings
        }
        let stored = SubagentToolVisibility.effectivePermission(
            capabilityId: SubagentCapabilityRegistry.spawn.id,
            isDefault: isDefault, config: config, settings: settings)
        var policies: [SubagentPermissionPolicy] = [isDefault ? .alwaysAllow : stored]
        if let pairScope {
            let pair = await MainActor.run {
                DefaultAgentConfigurationStore.load().delegation.permission(for: pairScope)
            }
            policies.append(TextSubagentKind.combine(launcher: .alwaysAllow, pair: pair))
        }
        return combinedPolicy(policies)
    }

    /// Resolve one spawn policy decision before the run starts.
    static func authorize(
        scope: SubagentScope,
        policy: SubagentPermissionPolicy,
        toolName: String,
        description: String,
        argumentsJSON: String,
        pairScope: OrchestratorDelegationPermissionScope? = nil
    ) async -> SubagentDecision {
        switch policy {
        case .deny:
            return .denied("Spawning is denied by this agent's permission settings.")
        case .alwaysAllow:
            return .allow
        case .ask:
            break
        }

        // No one to answer: refuse, never approve. External callers (a
        // non-loopback HTTP run) and runs that deny unapproved prompts cannot
        // reach the user's card.
        if ChatExecutionContext.isExternalSurface || ChatExecutionContext.denyUnapprovedToolPrompts {
            return .userDenied("Spawn permission was not approved.")
        }
        if Task.isCancelled {
            return .userDenied("Spawn permission was cancelled.")
        }

        let request = PromptRequest(
            toolName: toolName, description: description, argumentsJSON: argumentsJSON,
            launchingAgentId: scope.agentId)
        // The card may wait in the shared approval queue behind a sibling
        // spawn card. If that sibling's "Always Allow" (or a settings edit)
        // changed the policy meanwhile, settle silently instead of asking the
        // same question twice.
        let revalidate: @Sendable () async -> ToolPermissionPromptService.PolicyApprovalOutcome? = {
            Self.silentResolution(for: await effectivePolicy(for: scope, pairScope: pairScope))
        }
        let operation = OwnedSubagentOperation<PromptChoice> {
            if let promptOverride {
                if let early = await revalidate() {
                    return Self.promptChoice(for: early)
                }
                return try await promptOverride(request)
            }
            let outcome = await ToolPermissionPromptService.requestPolicyApproval(
                toolName: request.toolName,
                description: request.description,
                argumentsJSON: request.argumentsJSON,
                revalidate: revalidate
            )
            return Self.promptChoice(for: outcome)
        }

        let choice: PromptChoice
        do {
            choice = try await operation.value(cancellationRequested: { Task.isCancelled })
        } catch {
            return .userDenied("Spawn permission was cancelled.")
        }
        if Task.isCancelled {
            return .userDenied("Spawn permission was cancelled.")
        }

        switch choice {
        case .deny:
            return .userDenied("User denied spawning subagents.")
        case .allowOnce:
            return .allow
        case .alwaysAllow:
            // A sibling card may already have persisted Always Allow; writing
            // it again would advance the permission twice.
            if await effectivePolicy(for: scope, pairScope: pairScope) == .alwaysAllow {
                return .allow
            }
            let persisted = await persistAlwaysAllow(launchingAgentId: scope.agentId, pairScope: pairScope)
            if !persisted {
                // The current click still grants this run.
                print("[Osaurus] Could not persist spawn Always Allow for agent \(scope.agentId.uuidString)")
            }
            return .allow
        }
    }

    /// Policy re-read for a queued prompt: a persisted Always Allow or Deny
    /// settles the request without a panel; Ask means the card is still owed.
    static func silentResolution(
        for policy: SubagentPermissionPolicy
    ) -> ToolPermissionPromptService.PolicyApprovalOutcome? {
        switch policy {
        case .alwaysAllow: return .allowOnce
        case .deny: return .denied
        case .ask: return nil
        }
    }

    static func promptChoice(
        for outcome: ToolPermissionPromptService.PolicyApprovalOutcome
    ) -> PromptChoice {
        switch outcome {
        case .denied: return .deny
        case .allowOnce: return .allowOnce
        case .alwaysAllow: return .alwaysAllow
        }
    }

    /// Persist into the policy sources actually read for this launcher: a
    /// custom launcher's own spawn policy, and Gate 4's pair permission.
    /// Never writes `ToolRegistry`'s unrelated generic tool policy.
    @discardableResult
    static func persistAlwaysAllow(
        launchingAgentId: UUID,
        pairScope: OrchestratorDelegationPermissionScope?
    ) async -> Bool {
        await MainActor.run {
            var persisted = true
            if launchingAgentId != Agent.defaultId {
                if var agent = AgentManager.shared.agent(for: launchingAgentId), !agent.isBuiltIn {
                    agent.settings.subagentPermissions.setPolicy(
                        .alwaysAllow, for: SubagentCapabilityRegistry.spawn.id)
                    AgentManager.shared.update(agent)
                } else {
                    persisted = false
                }
            }
            if let pairScope {
                var configuration = DefaultAgentConfigurationStore.load()
                configuration.delegation.setPermission(.alwaysAllow, for: pairScope)
                AgentManager.shared.updateDefaultAgentConfiguration(configuration)
            }
            return persisted
        }
    }
}
