//
//  TextSubagentKind.swift
//  OsaurusCore — Subagent framework
//
//  The delegation kind behind `spawn_agent`. Ported from upstream Classic
//  (W-subagents stage 3) and made REMOTE-ONLY for Intel:
//
//   • resolve a user-configured spawnable Agent and run a real chat session of
//     that agent (its prompt + model + tools) through
//     `AgentDelegationDispatcher`, under the shared host (`SubagentSession`):
//     recursion guard, live feed, compact result envelope;
//   • no local models (no residency handoff, no RAM admission, no
//     `AgentSubagentRunner` eval seam, no workspace-agent targets — those are
//     `W-workspaces-sharing`);
//   • Intel's Gate 4 rules stay (docs/W_SUBAGENTS_PLAN.md): the target must be
//     in the launcher's pool (the Orchestrator's pool is its Gate 4
//     allowlist), a custom (non-built-in) agent, and run on an ADMITTED cloud
//     model that is available; the Gate 4 permission for the launcher/target
//     pair (Ask / Deny / Always Allow) gates the run. All of it is judged
//     again immediately before execution (`validateExecutionAuthority`), not
//     only at planning;
//   • nothing auto-approves: an `.ask` that cannot reach a user (external
//     surface, headless) is refused.
//

import Foundation

final class TextSubagentKind: SubagentKind, @unchecked Sendable {
    let capability = SubagentCapabilityRegistry.spawn

    private let agentID: UUID
    private let input: String
    /// `spawn_agent(continue:)`: reattach to this persisted worker session
    /// (returned as `session_id` by an earlier call) instead of starting a
    /// fresh one, so the worker keeps its context for a follow-up.
    private let continueSessionId: UUID?
    /// The persisted worker session a fresh delegated run will be created
    /// under (a `continue` reuses `continueSessionId` instead).
    private let freshSessionId = UUID()

    /// What the user approved (or the policy allowed) and what execution will
    /// re-check. Gate 4 facts are part of it: a revoked admission between the
    /// approval card and the run is refused.
    private struct AuthoritySnapshot: Sendable, Equatable {
        let launcher: SpawnLauncherAuthority
        let target: SpawnTargetAuthority?
        let isDefaultLauncher: Bool
        let pool: [UUID]
        let admittedModels: Set<String>
        let model: String?
        let launcherPolicy: SubagentPermissionPolicy
        let pairPermission: OrchestratorDelegationPermission
        var effectivePermission: SubagentPermissionPolicy {
            TextSubagentKind.combine(launcher: launcherPolicy, pair: pairPermission)
        }
    }

    private var approvalAuthority: AuthoritySnapshot?
    private var executionAuthority: AuthoritySnapshot?

    /// Cap on the digest handed back to the parent.
    private static let digestMaxChars = 8_000

    // Resolved up front in `resolveModel`, read by permission/run.
    private var resolvedAgentName: String = ""
    private var resolvedAgentId: UUID?
    private var resolvedScope: OrchestratorDelegationPermissionScope?
    /// The enforced run contract, derived ONCE in `resolveAgentTarget` from
    /// the launcher's budgets, the seed, the target agent's tool posture and
    /// the context window. `runDelegated` enforces it
    /// (`ChatSession.delegationBudget`). Fail-closed: no contract, no run.
    var delegatedContract: DelegatedRunContract?
    private var budgets = SubagentBudgets()
    private var resolvedPermission: SubagentPermissionPolicy = .ask

    /// The spawn input never changes after construction.
    init(
        agentID: UUID,
        agentName: String? = nil,
        input: String,
        continueSessionId: UUID? = nil
    ) {
        self.agentID = agentID
        self.input = input
        self.continueSessionId = continueSessionId
        if let agentName, !agentName.isEmpty {
            self.resolvedAgentName = agentName
        }
    }

    /// Human label of the spawn target for error/result copy: the resolved
    /// agent name (or the UUID pre-resolve).
    private var targetLabel: String {
        resolvedAgentName.isEmpty ? agentID.uuidString : resolvedAgentName
    }

    /// Feed / activity title: "Delegated to X".
    var feedTitle: String { "Delegated to \(targetLabel)" }

    /// A delegated run registers its own real background task (with a
    /// working "Open Chat"), so the subagent feed must not be mirrored
    /// into a second Activity row.
    var suppressActivityMirror: Bool { true }

    /// The worker session this run will resume or create — the same value
    /// `runDelegated` hands the dispatcher.
    var plannedSessionId: UUID? { continueSessionId ?? freshSessionId }

    /// Every Intel child is a remote cloud chat: it fans out concurrently and
    /// never touches a local GPU queue.
    func admissionClass(_ resolved: ResolvedModel) -> SubagentAdmissionClass { .remote }

    // MARK: Resolution

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        let resolved = try await resolveCurrentModel(scope)
        if approvalAuthority == nil {
            approvalAuthority = await authoritySnapshot(for: scope)
        }
        return resolved
    }

    private func resolveCurrentModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        let config = SubagentConfigurationStore.snapshot()
        let isDefault = scope.agentId == Agent.defaultId
        let settings = await MainActor.run {
            AgentManager.shared.agent(for: scope.agentId)?.settings
        }
        let stored = SubagentToolVisibility.effectivePermission(
            capabilityId: capability.id, isDefault: isDefault, config: config, settings: settings)
        if stored == .deny && !isDefault {
            throw SubagentError.denied("Spawning is denied by this agent's permission settings.")
        }
        self.budgets = await MainActor.run { SpawnFanOutPolicy.effectiveBudgets(scope: scope) }

        // The chat model cache is the only availability source (cloud only);
        // warm it exactly as `orchestrator_targets` does.
        if IntelSpawnAdmission.availableModelIDsOverrideForTests == nil {
            await ModelPickerItemCache.shared.prewarmModelCache()
        }
        let (facts, target) = await MainActor.run {
            (IntelSpawnAdmission.liveFacts(launcherID: scope.agentId), IntelSpawnAdmission.targetFacts(agentID))
        }
        let admitted: IntelSpawnAdmission.Admitted
        switch IntelSpawnAdmission.evaluate(facts, targetID: agentID, target: target) {
        case .success(let value): admitted = value
        case .failure(let denial):
            throw IntelSpawnAdmission.error(
                for: denial, targetLabel: target?.name ?? agentID.uuidString, isDefaultLauncher: isDefault)
        }
        self.resolvedAgentName = admitted.targetName
        self.resolvedAgentId = admitted.targetID
        self.resolvedScope = admitted.scope
        // Default launcher: Gate 4's pair permission IS the policy the user
        // edits in Settings → Orchestrator. A custom launcher also honours
        // its own per-agent policy; the stricter of the two applies.
        self.resolvedPermission = Self.combine(
            launcher: isDefault ? .alwaysAllow : stored, pair: admitted.pairPermission)
        if resolvedPermission == .deny {
            throw IntelSpawnAdmission.error(
                for: .permissionDenied, targetLabel: admitted.targetName, isDefaultLauncher: isDefault)
        }
        try await deriveContract(model: admitted.model)
        return ResolvedModel(name: admitted.model, id: nil, isLocal: false)
    }

    /// The stricter of the launcher's own spawn policy and Gate 4's pair
    /// permission: Deny wins, then Ask, then Always Allow.
    static func combine(
        launcher: SubagentPermissionPolicy, pair: OrchestratorDelegationPermission
    ) -> SubagentPermissionPolicy {
        let pairPolicy: SubagentPermissionPolicy
        switch pair {
        case .deny: pairPolicy = .deny
        case .ask: pairPolicy = .ask
        case .alwaysAllow: pairPolicy = .alwaysAllow
        }
        return SpawnPermissionGate.combinedPolicy([launcher, pairPolicy])
    }

    /// Derive the enforced contract from what the dispatched session will
    /// actually run (upstream): the wrapped delegated prompt, the composed
    /// chat system prompt for the target agent (composed as a delegated
    /// child, so spawn tools and `clarify` are not priced), and the composer's
    /// own tool-schema reservation. Fails closed: with no contract the child
    /// would run unclamped, so the run is refused.
    private func deriveContract(model: String) async throws {
        let window = await AgentLoopBudget.resolveContextWindow(modelId: model)
        let dispatchedPrompt = AgentDelegationDispatcher.delegatedPrompt(
            input: input, resuming: continueSessionId != nil)
        let composed = await ChatExecutionContext.$currentSessionSource.withValue(.delegation) {
            await SystemPromptComposer.composeChatContext(
                agentId: agentID, model: model, query: dispatchedPrompt)
        }
        guard
            let contract = DelegatedRunContract.derive(
                seedCharacters: dispatchedPrompt.count,
                systemPromptCharacters: composed.prompt.count,
                toolSchemaTokens: composed.toolTokens,
                budgets: budgets,
                toolEnabled: !composed.tools.isEmpty,
                resolvedContextWindow: window)
        else {
            throw SubagentError.unavailable(
                "Could not bound the delegated run for '\(targetLabel)', so it was not started.")
        }
        self.delegatedContract = contract
    }

    // MARK: Permission

    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        let argumentsJSON = approvalArgumentsJSON(resolvedModel: resolved.name)
        return await SpawnPermissionGate.authorize(
            scope: scope,
            policy: resolvedPermission,
            toolName: toolName,
            description: permissionDescription(model: resolved.name),
            argumentsJSON: argumentsJSON,
            pairScope: resolvedScope,
            // Sibling `spawn_agent` calls of one model message share one
            // card and one fan-out check (`SpawnWaveGate`); a lone call is
            // not a member and keeps its own card.
            waveMember: SpawnWaveGate.Member(
                callId: scope.toolCallId,
                toolName: toolName,
                scope: scope,
                argumentsJSON: argumentsJSON,
                isLocal: false,
                pairScope: resolvedScope
            )
        )
    }

    func revalidateAfterPermission(
        _ scope: SubagentScope,
        approved resolved: ResolvedModel
    ) async throws -> ResolvedModel {
        guard let approvedAuthority = approvalAuthority else {
            throw SubagentError.denied(
                "Spawn authorization state was not captured. No subagent was started.")
        }
        let afterPermission = await authoritySnapshot(for: scope)
        guard Self.matchesApprovedAuthority(approvedAuthority, current: afterPermission) else {
            throw SubagentError.denied(
                "Spawn settings, launcher, or target agent changed while approval was open. "
                    + "No subagent was started; review the current settings and retry.")
        }
        let currentResolved = try await resolveCurrentModel(scope)
        let afterResolution = await authoritySnapshot(for: scope)
        guard afterResolution == afterPermission, currentResolved == resolved else {
            throw SubagentError.denied(
                "Spawn settings, target, or resolved model changed after approval. "
                    + "No subagent was started; review the current settings and retry.")
        }
        executionAuthority = afterResolution
        return currentResolved
    }

    /// Final check immediately before the run: Gate 4 admission, the pool,
    /// the model and the permission are re-read and must equal what was
    /// approved. A revoked admission or a re-pointed agent is refused here,
    /// not only at planning.
    func validateExecutionAuthority(
        _ scope: SubagentScope,
        resolved: ResolvedModel
    ) async throws {
        guard let approved = executionAuthority else {
            throw SubagentError.denied("Spawn execution authority was not captured. No subagent was started.")
        }
        let current = await authoritySnapshot(for: scope)
        guard current == approved else {
            throw SubagentError.denied(
                "Spawn settings, launcher, or target agent changed before execution. "
                    + "No subagent was started; review the current settings and retry.")
        }
        // The admission verdict itself, from fresh facts (a model dropping
        // out of the provider's list between approval and run is refused).
        let (facts, target) = await MainActor.run {
            (IntelSpawnAdmission.liveFacts(launcherID: scope.agentId), IntelSpawnAdmission.targetFacts(agentID))
        }
        switch IntelSpawnAdmission.evaluate(facts, targetID: agentID, target: target) {
        case .success(let admitted):
            guard admitted.model == resolved.name else {
                throw SubagentError.denied(
                    "The target's model changed before execution. No subagent was started.")
            }
        case .failure(let denial):
            throw IntelSpawnAdmission.error(
                for: denial, targetLabel: target?.name ?? agentID.uuidString,
                isDefaultLauncher: scope.agentId == Agent.defaultId)
        }
    }

    private func authoritySnapshot(for scope: SubagentScope) async -> AuthoritySnapshot {
        let config = SubagentConfigurationStore.snapshot()
        let isDefault = scope.agentId == Agent.defaultId
        let targetID = agentID
        let (launcherAgent, targetAgent, facts) = await MainActor.run {
            (
                AgentManager.shared.agent(for: scope.agentId),
                AgentManager.shared.agent(for: targetID),
                IntelSpawnAdmission.liveFacts(launcherID: scope.agentId)
            )
        }
        let stored = SubagentToolVisibility.effectivePermission(
            capabilityId: capability.id, isDefault: isDefault, config: config,
            settings: launcherAgent?.settings)
        let pairScope = OrchestratorDelegationPermissionScope(
            launcherAgentID: scope.agentId, targetAgentID: agentID)
        return AuthoritySnapshot(
            launcher: SpawnLauncherAuthority(
                id: scope.agentId, isDefault: isDefault, configuration: config,
                agent: launcherAgent, sharedParallelLimit: SpawnBatchConcurrencyContract.configuredLimit(for: config)),
            target: targetAgent.map(SpawnTargetAuthority.init),
            isDefaultLauncher: isDefault,
            pool: facts.pool,
            admittedModels: facts.configuration.admittedCloudModelIDs,
            model: targetAgent.flatMap { AgentManager.shared.effectiveModel(for: $0.id) },
            launcherPolicy: isDefault ? .alwaysAllow : stored,
            pairPermission: facts.configuration.permission(for: pairScope))
    }

    /// The approval may legitimately change the policy exactly once: Ask →
    /// Always Allow when the user picks "Always Allow" on the card. Anything
    /// else that moved is a change of authority.
    private static func matchesApprovedAuthority(
        _ approved: AuthoritySnapshot, current: AuthoritySnapshot
    ) -> Bool {
        guard approved.launcher == current.launcher,
            approved.target == current.target,
            approved.isDefaultLauncher == current.isDefaultLauncher,
            approved.pool == current.pool,
            approved.admittedModels == current.admittedModels,
            approved.model == current.model
        else { return false }
        if approved.effectivePermission == current.effectivePermission { return true }
        return approved.effectivePermission == .ask && current.effectivePermission == .alwaysAllow
    }

    private var toolName: String { SubagentCapabilityRegistry.spawnAgentToolName }

    /// One-line permission prompt. Names the target and says where it runs
    /// and that it uses the cloud account, so the user knows what approving
    /// spends.
    private func permissionDescription(model: String) -> String {
        L("Let this agent delegate a task to \(targetLabel)? It runs as a chat of that agent on \(model) and may use your cloud account.")
    }

    private func approvalArgumentsJSON(resolvedModel: String) -> String {
        let payload: [String: Any] = [
            "target_type": "agent",
            "target": agentID.uuidString,
            "agent_name": resolvedAgentName,
            "input": input,
            "resolved_model": resolvedModel,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    // MARK: Run

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        guard let targetAgentId = resolvedAgentId, let contract = delegatedContract else {
            throw SubagentError.unavailable("Agent target was not resolved before delegation.")
        }
        // Upstream's fan-out limit is per wave (`SpawnWaveGate`). Intel also
        // keeps it as a hard per-launcher cap on delegated runs in flight, so
        // background workers launched in different turns cannot pile up past
        // it on a 2-core Mac. Never raised: extra calls get a retryable
        // refusal.
        let limit = budgets.normalized.maxRemoteParallelSpawns
        guard let lease = SpawnConcurrencyGuard.shared.acquire(launcher: scope.agentId, limit: limit) else {
            throw SubagentError.executionFailed(
                message: SpawnFanOutPolicy.fanOutLimitMessage(
                    requested: limit + 1, limit: limit, kind: "remote"),
                retryable: true)
        }
        defer { SpawnConcurrencyGuard.shared.release(lease) }

        feed.emitPhase("running", detail: resolved.name)
        let budgets = self.budgets.normalized
        // The requester's folder is inherited when the target has none, so a
        // folder-less worker still reads inputs / writes deliverables where
        // the launcher can `file_read` them: the launching chat's mounted
        // folder (`currentFolderRoot`), else the launcher's own folder.
        let launcherFolder: DelegatedWorkingFolder? = await MainActor.run {
            if let root = ChatExecutionContext.currentFolderRoot {
                return DelegatedWorkingFolder(bookmark: nil, path: root.path)
            }
            let agent = AgentManager.shared.agent(for: scope.agentId)
            let path = agent?.workingFolderPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard agent?.workingFolderBookmark != nil || path?.isEmpty == false else { return nil }
            return DelegatedWorkingFolder(
                bookmark: agent?.workingFolderBookmark, path: path?.isEmpty == false ? path : nil)
        }
        let outcome = try await AgentDelegationDispatcher.run(
            targetAgentId: targetAgentId,
            targetAgentName: resolvedAgentName,
            input: input,
            maxElapsedSeconds: budgets.maxElapsedSeconds,
            // The enforced delegated contract: the dispatched session clamps
            // its per-generation max tokens, its tool-loop turns and its
            // history window to these (tighten-only).
            maxResponseTokens: contract.responseTokens,
            maxAssistantTurns: contract.assistantTurns,
            maxContextPositions: contract.contextPositions,
            // The Gate 4 admitted model, exactly: the child never falls back
            // to the target agent's current default.
            model: resolved.name,
            feed: feed,
            interrupt: interrupt,
            parentSessionId: scope.sessionId,
            launcherWorkingFolder: launcherFolder,
            continueSessionId: continueSessionId,
            freshSessionId: freshSessionId
        )
        let artifactPaths = await SpawnResultCompaction.artifactPaths(forWorkerSession: outcome.sessionId)
        return result(
            from: outcome, resolved: resolved, targetAgentId: targetAgentId, feed: feed,
            artifactPaths: artifactPaths)
    }

    /// The `spawn_result` payload (upstream's envelope; Intel has no
    /// residency, so `handoff` is false and `residency_mode` is `none`).
    private func result(
        from outcome: AgentDelegationOutcome, resolved: ResolvedModel, targetAgentId: UUID,
        feed: SubagentFeed, artifactPaths: [String] = []
    ) -> SubagentResult {
        let digest = outcome.finalText
        let capped =
            digest.count > Self.digestMaxChars
            ? String(digest.prefix(Self.digestMaxChars)) + "\n[digest truncated]"
            : digest
        feed.emitStreamDelta(kind: .response, title: "response", delta: capped)
        var payload: [String: Any] = [
            "kind": "spawn_result",
            "model": resolved.name,
            "agent": resolvedAgentName,
            "agent_id": targetAgentId.uuidString,
            "summary": capped,
            // The child's persisted chat session — openable from the target
            // agent's Recent Chats and from the background task's Open Chat,
            // and the handle for `spawn_agent(continue:)` follow-ups.
            "session_id": outcome.sessionId.uuidString,
            "needs_input": outcome.needsInput,
            "delegated": true,
            "iterations": outcome.assistantTurns,
            "elapsed_seconds": outcome.elapsed,
            "handoff": false,
            "residency_mode": ResidencyPlan.none.mode,
        ]
        // Compact count only — the typed artifacts were adopted into the
        // parent's store and travel through `SpawnArtifactCollector`, never
        // through this model-visible payload.
        if outcome.artifactsShared > 0 {
            payload["artifacts_shared"] = outcome.artifactsShared
        }
        // `NEEDS INPUT:` is a prefix contract. A marker buried mid-text keeps
        // `needs_input` false but is flagged so the flag/text mismatch is
        // visible in the payload and the log instead of silently dropped.
        if AgentDelegationDispatcher.hasOffPrefixNeedsInputMarker(digest) {
            payload["needs_input_marker_off_prefix"] = true
            print(
                "[TextSubagentKind] worker \(resolvedAgentName) (\(outcome.sessionId.uuidString)) "
                    + "used NEEDS INPUT off-prefix; needs_input stays false")
        }
        // Deliverables (#2936): the files the child's session wrote (its
        // file-change journal, net of reverts), as paths the parent can
        // `file_read` instead of asking for the content in the digest.
        if !artifactPaths.isEmpty {
            payload["artifact_paths"] = artifactPaths
        }
        var usage: [String: Any] = [:]
        if let completionTokens = outcome.completionTokens {
            usage["completion_tokens"] = completionTokens
        }
        if let tps = outcome.tokensPerSecond {
            usage["tokens_per_second"] = (tps * 10).rounded() / 10
        }
        if !usage.isEmpty {
            payload["usage"] = usage
        }
        let digestTokens = TokenEstimator.estimate(capped)
        payload["context"] = [
            "worker_tokens_estimated": outcome.transcriptTokenEstimate,
            "digest_tokens": digestTokens,
            "context_saved_tokens": max(0, outcome.transcriptTokenEstimate - digestTokens),
        ]
        return SubagentResult(payload: payload, summary: capped)
    }
}

/// Process-wide cap on delegated runs in flight per launching agent
/// (`maxRemoteParallelSpawns`, upstream's default, never raised). Backs up
/// `SpawnWaveGate`'s per-wave limit across turns and background workers.
final class SpawnConcurrencyGuard: @unchecked Sendable {
    static let shared = SpawnConcurrencyGuard()
    struct Lease: Sendable, Equatable {
        let id: UUID
        let launcher: UUID
    }

    private let lock = NSLock()
    private var active: [UUID: UUID] = [:]  // lease id -> launcher

    func acquire(launcher: UUID, limit: Int) -> Lease? {
        lock.lock()
        defer { lock.unlock() }
        guard active.values.filter({ $0 == launcher }).count < max(1, limit) else { return nil }
        let lease = Lease(id: UUID(), launcher: launcher)
        active[lease.id] = launcher
        return lease
    }

    func release(_ lease: Lease) {
        lock.lock()
        defer { lock.unlock() }
        active.removeValue(forKey: lease.id)
    }

    func activeCount(launcher: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return active.values.filter { $0 == launcher }.count
    }
}
