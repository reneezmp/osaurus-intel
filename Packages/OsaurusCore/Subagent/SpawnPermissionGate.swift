//
//  SpawnPermissionGate.swift
//  OsaurusCore
//
//  One permission owner for `spawn_agent`. Ported from upstream Classic
//  (W-subagents stages 3 and 6). Sibling `spawn_agent` calls of one model
//  message (a wave) rendezvous in `SpawnWaveGate` for ONE card and one
//  fan-out limit check; a call outside a wave raises its own card.
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
        await effectivePolicy(for: scope, pairScopes: pairScope.map { [$0] } ?? [])
    }

    /// Same, for a wave card that covers several Gate 4 pairs: the strictest
    /// of the launcher's own policy and every pair wins.
    static func effectivePolicy(
        for scope: SubagentScope,
        pairScopes: [OrchestratorDelegationPermissionScope]
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
        if !pairScopes.isEmpty {
            let delegation = await MainActor.run { DefaultAgentConfigurationStore.load().delegation }
            for pairScope in pairScopes {
                policies.append(
                    TextSubagentKind.combine(launcher: .alwaysAllow, pair: delegation.permission(for: pairScope)))
            }
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
        pairScope: OrchestratorDelegationPermissionScope? = nil,
        waveMember: SpawnWaveGate.Member? = nil,
        pairScopes explicitPairScopes: [OrchestratorDelegationPermissionScope]? = nil
    ) async -> SubagentDecision {
        let pairScopes = explicitPairScopes ?? pairScope.map { [$0] } ?? []
        if case .deny = policy {
            return .denied("Spawning is denied by this agent's permission settings.")
        }

        // Sibling wave (upstream): one approval and one fan-out limit check
        // for the whole set. Always Allow still joins, so the limit applies
        // to the wave instead of letting N unprompted calls each pass alone.
        if let waveMember,
            let wave = ChatExecutionContext.spawnWave,
            wave.expectedCallIds.contains(waveMember.callId)
        {
            let limits = await MainActor.run {
                SpawnFanOutPolicy.effectiveFanOutLimits(scope: scope)
            }
            let rendezvous = OwnedSubagentOperation<SubagentDecision?> {
                await SpawnWaveGate.shared.join(waveMember, wave: wave, limits: limits)
            }
            do {
                if let decision = try await rendezvous.value(cancellationRequested: { Task.isCancelled }) {
                    return decision
                }
            } catch {
                return .userDenied("Spawn permission was cancelled.")
            }
            if Task.isCancelled {
                return .userDenied("Spawn permission was cancelled.")
            }
            // Not a member after all (late arrival): fall through to this
            // call's own card with the policy as it stands now.
        }

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
        if ChatExecutionContext.isExternalSurface || ChatExecutionContext.denyUnapprovedToolPrompts
            || ChatExecutionContext.isUnattendedDispatch
        {
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
            Self.silentResolution(for: await effectivePolicy(for: scope, pairScopes: pairScopes))
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
            if await effectivePolicy(for: scope, pairScopes: pairScopes) == .alwaysAllow {
                return .allow
            }
            let persisted = await persistAlwaysAllow(launchingAgentId: scope.agentId, pairScopes: pairScopes)
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
        await persistAlwaysAllow(launchingAgentId: launchingAgentId, pairScopes: pairScope.map { [$0] } ?? [])
    }

    @discardableResult
    static func persistAlwaysAllow(
        launchingAgentId: UUID,
        pairScopes: [OrchestratorDelegationPermissionScope]
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
            if !pairScopes.isEmpty {
                var configuration = DefaultAgentConfigurationStore.load()
                for pairScope in pairScopes {
                    configuration.delegation.setPermission(.alwaysAllow, for: pairScope)
                }
                AgentManager.shared.updateDefaultAgentConfiguration(configuration)
            }
            return persisted
        }
    }
}
