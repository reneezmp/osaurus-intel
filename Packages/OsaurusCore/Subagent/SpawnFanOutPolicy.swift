//
//  SpawnFanOutPolicy.swift
//  OsaurusCore — Subagent framework
//
//  Shared fan-out policy for delegation. Several `spawn_agent` calls in one
//  model message form one wave (`SpawnWaveGate`); this type owns the limits
//  that wave is checked against.
//
//  Intel (docs/SUBAGENTS_INTEL.md, W-subagents stage 1): upstream's file also
//  holds the vMLX engine admission window and the local residency-to-capacity
//  bridge (`engineAdmissionWindow`, `makeLocalAdmissionPlan`). Intel has no
//  local models, so every child is remote and those two are not taken.
//  Limits are upstream's defaults and are never raised here.
//

import Foundation

enum SpawnFanOutPolicy {
    /// Typed, retryable message for a wave that asks for more workers than
    /// the launcher allows.
    static func fanOutLimitMessage(requested: Int, limit: Int, kind: String) -> String {
        "This wave asks for \(requested) \(kind) subagents, but this agent allows at most "
            + "\(limit) \(kind) subagents at once. Run the extra work after these finish, "
            + "or ask the user to raise the limit in the Subagents settings."
    }

    /// Deterministic eval seam. Production never binds this value; scripted
    /// wave evaluations pin the fan-out ceiling so a developer machine's
    /// persisted limits cannot change the contract under test.
    @TaskLocal
    static var limitsOverrideForTests: SpawnFanOutLimits?

    /// Per-launcher fan-out limits: `local` is the Concurrent Sessions
    /// ceiling (unused on Intel); `remote` is independent (cloud workers
    /// consume no local GPU or RAM).
    @MainActor
    static func effectiveFanOutLimits(scope: SubagentScope) -> SpawnFanOutLimits {
        if let limitsOverrideForTests { return limitsOverrideForTests }
        let budgets = effectiveBudgets(scope: scope)
        return SpawnFanOutLimits(
            local: budgets.maxParallelSpawns,
            remote: budgets.maxRemoteParallelSpawns
        )
    }

    @MainActor
    static func effectiveMaxParallel(scope: SubagentScope) -> Int {
        effectiveBudgets(scope: scope).maxParallelSpawns
    }

    @MainActor
    static func effectiveBudgets(scope: SubagentScope) -> SubagentBudgets {
        let config = SubagentConfigurationStore.snapshot()
        let isDefault = scope.agentId == Agent.defaultId
        let settings = AgentManager.shared.agent(for: scope.agentId)?.settings
        return SubagentToolVisibility.effectiveBudgets(
            isDefault: isDefault,
            config: config,
            settings: settings,
            // Intel: no MLX server runtime; the shared value is the
            // configuration's own (`SpawnBatchConcurrencyContract`).
            sharedParallelLimit: SpawnBatchConcurrencyContract.configuredLimit(for: config)
        ).normalized
    }
}
