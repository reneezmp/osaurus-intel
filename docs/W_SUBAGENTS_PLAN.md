# W-subagents port plan and progress

Copied from the stage-1 agent report (2026-11-19) so later stages can find the plan and mapping decision. Stage 1 is merged; update this file as stages land.

# W-subagents port report (stage 1 of 6 done)

Worktree: `/Users/renee/Developer/osaurus/.claude/worktrees/agent-ab6dfb982576b1160`, branch `worktree-agent-ab6dfb982576b1160` (reset to `intel-fork` d4952c0f5). Port source: `upstream/classic` only.

## Stage plan

1. **Model, stores, pure policy (DONE, `abdd93881`).** Spawn authority snapshots un-fenced; `SessionSource.delegation`; `SpawnInputContract` + descriptor value types; `DelegatedRunContract`; `SpawnResultCompaction`; `SpawnArtifactCollector`; trimmed `SpawnFanOutPolicy`; `IntelSpawnPool` (Gate 4 mapping).
2. **Delegated-run plumbing.** `DispatchRequest` gains the three delegation caps + `delegationModel`; `ExecutionContext`/`ChatSession.delegationBudget` clamps (Intel's `ChatView.swift` ~L3838 `maxAttempts`, max tokens, context window; upstream ChatView L7342-7490); `BackgroundTaskManager.awaitCompletionWithToolFailure` + `DelegatedToolFailure`; composer strips spawn tools from `.delegation` sessions; `delegated_conversations` memory provenance (`bufferDelegatedTurn`); box the `approvalWaitObserver` task-local (#3381).
3. **`AgentDelegationDispatcher` + `TextSubagentKind` (remote-only) + `SpawnAgentTool`.** Dispatcher runs the child as a real headless chat of the target agent (`dispatchChat`, source `.delegation`); kind keeps Gate 4 rules at execution (allowlisted custom agent, admitted cloud model via `IntelOrchestratorAdmission`, Gate 4 permission mode Ask/Deny/Always Allow, nothing auto-approved); tool registration, visibility, `spawnGuidance`, `SpawnTargetAvailabilitySnapshot` resolver on Gate 4 admission; harvest of the child's session from `ChatSessionsManager`. Then `orchestrator_delegate` becomes a thin legacy alias or stays for the manual sheet.
4. **Declarative + templates + inspect.** `osaurus_inspect`, `spawn_agent` in the config addendum, per-agent `subagents` keys (map onto agent `spawnableAgentIDs`/budgets), rest of #2936, `spawn_agent` refusal of a template-flagged agent (`setupRefusal`), #3121 cache.
5. **UI.** `SpawnConfigurationEditor` / `SubagentSettingsSection` on Ventura rules, Delegations list (`DelegationRecord`), Activity mirrors, run-log replay in `SubagentFeedView`, Orchestrator narrowed to `file_read`/`file_search` once workers do folder work.
6. **Waves, background spawn, residual.** `SpawnWaveGate` + `SpawnPermissionGate` (need `W-engine-parallel-tools`; Intel's engine is sequential), `recordTerminalToolRejection`, `SubagentReportBack`/`SubagentBackgroundTaskBridge`, background-spawn Stop, `continue`, same-turn staging, #3321 memo of `connectedSpawnModelTargetIndex`, image/video kinds (`W-media-generation`).

## Mapping decision (evidence)

Upstream's `spawn_agent` runs the child as a real headless chat session of the target agent through `BackgroundTaskManager.dispatchChat` (`AgentDelegationDispatcher.run`, source `.delegation`); `AgentSubagentRunner` survives upstream only for an eval seam. Intel already has: a headless `ExecutionContext`/`ChatSession` path (`ExecutionContext.swift`), `dispatchChat` with the same request type, the subagent host (`SubagentSession`, feed, config store from Layer 1), and `AgentSubagentRunner` (desktop kinds). Intel's Orchestrator `orchestrator_delegate` (Gate 4) is a one-turn, tool-free `ChatEngine` request (`IntelDelegationProbe`), which cannot carry the target's tools, folder or approvals, and its plan lists "child tools / model-owned spawning" as blocked until request-scoped budgets exist. Upstream's `DelegatedRunContract` is exactly that request-scoped budget, enforced by `ChatSession` clamps, so the dependency is now solvable. Decision: follow upstream (real child session on `dispatchChat`), not Intel's in-memory runner, and keep Intel's gates:

- **Pool = Gate 4.** The Default (Orchestrator) launcher's spawn pool is `OrchestratorDelegationConfiguration.customAgentAllowlist` (`IntelSpawnPool`, hooked into `SubagentToolVisibility.effectiveSpawnableAgents`). The stored upstream pool (`SubagentConfiguration.spawnableAgentIDs`) is neither read nor seeded (no `seedSpawnPoolIfNeeded`), matching declarative stage 4 (`delegation.spawnable_agents` writes Gate 4). `SubagentConfigurationStore` keeps budgets/permissions/overrides; `OrchestratorDelegationConfiguration` keeps allowlist, admitted cloud models, permission modes. Execution-time revalidation against Gate 4 (stage 3) replaces ABA revisions for the pool, because the authority snapshot still compares the stored pool (kept upstream-verbatim so upstream's store tests hold).
- Custom launchers keep upstream's per-agent toggle and list (default off); stage 3 must additionally require the target's model to be an admitted cloud model.
- Budgets/concurrency are upstream defaults, never raised (`SpawnFanOutPolicy` reads the stored budgets; no Intel override). Tool approvals in a child follow the user's tool permissions through its own chat session; no auto-approve path is added.

## Stage 1 outcome

Files: `Models/AgentDelegation/SubagentConfiguration(+Store).swift` (upstream verbatim; spawn snapshots live; the three `knowledge*` fields of `SpawnTargetAuthority` dropped because Intel's `AgentSettings` has none), `Subagent/IntelSpawnPool.swift`, `Subagent/SpawnDescriptors.swift` (value types and `SpawnInputContract` only), `DelegatedRunContract.swift`, `SpawnResultCompaction.swift`, `SpawnArtifactCollector.swift`, `SpawnFanOutPolicy.swift` (no vMLX window/residency bridge), `AgentLoopBudget.defaultResponseReservation`, `SessionSource.delegation` (+ trigger kind, sidebar badge; "Delegated" key already in the catalog). Not ported (MLX or later stage): `SpawnBatchConcurrencyContractTests` (VMLX settings), `DelegatedBudgetEnforcementTests` (needs stage 2's `ChatSession.delegationBudget`).
Tests: upstream's `SubagentConfigurationStoreTests` (full, incl. the spawn-authority revision case), `SubagentBudgetsRemoteLimitTests`, `SpawnResultCompactionTests`; new `IntelSpawnPoolTests` (Gate 4 pool, stored pool ignored, custom launcher pool, contract derive/clamp/fail-closed, blank input, session source, fan-out message).
`bash scripts/i18n/check.sh`: OK.

## Docs paragraph (for the lead to merge into SUBAGENTS_INTEL.md / backlog)

**W-subagents stage 1 (2026-11-19).** Decision: `spawn_agent` follows upstream Classic (child = real headless chat of the target agent via `dispatchChat`, source `.delegation`, bounded by `DelegatedRunContract`), not Intel's in-memory runner. Intel's Orchestrator spawn pool is its Gate 4 allowlist (`IntelSpawnPool`); upstream's stored pool is unused and never seeded; admitted models, permission modes and runtime revalidation stay Gate 4. Taken: spawn authority snapshots, `SessionSource.delegation`, `DelegatedRunContract`, `SpawnInputContract`, result compaction, artifact collector, fan-out limits (upstream defaults). Left per stage 2-6 above. Found: Intel's `AgentSettings` has no knowledge fields, so `SpawnTargetAuthority` omits them; `ChatSession` (`Views/Chat/ChatView.swift`) is where the delegation clamps land; waves need parallel tool batches (`W-engine-parallel-tools`).

## Manual test steps for a Ventura tester (stage 1 is internal; nothing user-visible yet)

1. Launch the candidate build with an existing data folder; confirm chats, agents and Settings → Orchestrator open as before (the shared `agent-delegation.json` still decodes).
2. In Settings → Orchestrator, allow one custom agent and admit its cloud model; confirm the delegation sheet still lists only that agent (Gate 4 unchanged).
3. Open the chat sidebar with a history that includes scheduled/imported chats; confirm no crash and badges render.
4. Run the Orchestrator's manual delegation once (Ask), confirm the approval prompt, the bounded text result and no spawn tool in the tool list (`spawn_agent` arrives in stage 3).

## Results

Filtered gate (`subs1`): `Test run with 802 tests in 141 suites passed after 5.259 seconds`; mdat unchanged, live hits empty. Full suite (`fullrun_pty.sh`, no filter): `Test run with 5905 tests in 766 suites passed after 101.651 seconds with 6 known issues`; mdat unchanged, live hits empty, no watchdog stall.
