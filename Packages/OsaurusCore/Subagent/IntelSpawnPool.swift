//
//  IntelSpawnPool.swift
//  OsaurusCore — Subagent framework
//
//  Intel's mapping of upstream's Default-launcher spawn pool
//  (`SubagentConfiguration.spawnableAgentIDs`) onto the Orchestrator's Gate 4
//  allowlist (`OrchestratorDelegationConfiguration.customAgentAllowlist`).
//  See docs/SUBAGENTS_INTEL.md ("W-subagents").
//
//  Why: on Intel `delegation.spawnable_agents` (declarative config stage 4),
//  Settings → Orchestrator and `orchestrator_delegate` already read the
//  Gate 4 allowlist. A second, separately editable pool would let
//  `spawn_agent` reach agents the user never allowed, and the one-time
//  "seed every custom agent" migration upstream runs (`seedSpawnPoolIfNeeded`)
//  would widen it. So the Default launcher's effective pool is the Gate 4
//  allowlist and nothing else; the stored pool is neither read nor seeded.
//  This is only the pool: admitted cloud models, permission modes and
//  runtime revalidation stay the Gate 4 rules (`IntelOrchestratorAdmission`).
//

import Foundation

enum IntelSpawnPool {
    /// The Default (Orchestrator) launcher's spawnable agent ids: Gate 4's
    /// allowlist in a stable order (upstream's pool is an ordered array, and
    /// the `spawn_agent` enum and prompt must be byte-stable).
    static func defaultLauncherAgentIDs(
        gate4 allowlist: Set<UUID>,
        storedPool _: [UUID] = []
    ) -> [UUID] {
        allowlist.sorted { $0.uuidString < $1.uuidString }
    }

    /// Live read of the Orchestrator's persisted Gate 4 allowlist. The stored
    /// pool argument is accepted so upstream's call sites keep their shape and
    /// is deliberately ignored.
    static func defaultLauncherAgentIDs(storedPool _: [UUID]) -> [UUID] {
        defaultLauncherAgentIDs(
            gate4: DefaultAgentConfigurationStore.load().delegation.customAgentAllowlist
        )
    }
}
