# Subagent base on Intel

Started 2026-10-28. Renée's decision (2026-10-28, while starting
`W-applescript-agent`): build the shared base first, then AppleScript on
top, rather than a lighter AppleScript-only port.

## Why

Upstream's AppleScript agent (`applescript`, `mac_query`) is a subagent
kind (`AppleScriptKind`) run by the subagent host (`SubagentSession`), with
its steps shown in a live feed (`SubagentFeed`, `SubagentFeedView`) and each
script confirmed through Computer Use's queue and overlay
(`ComputerUsePromptQueue`, `ComputerUseConfirmOverlay`, `Gate`). Its model
step goes through Computer Use's `DesktopResponsesModelStep` on upstream's
Responses-style engine interface. Intel has none of these. The same base
serves `W-subagents` (spawn), `W-computer-use`, `W-browser-use`, and
upstream's `image` / `video` kinds.

## The cut

Upstream's host also schedules local MLX models on the GPU: admission
classes, residency plans and handoffs, batch admission, keep-warm. On Intel
every subagent runs on a cloud model, so those become pass-throughs
(remote admission, `ResidencyPlan.none`), kept under upstream's names so
the kinds compile unchanged.

| Layer | Upstream files | Intel |
|---|---|---|
| 1. Host and feed | `SubagentKind`, `SubagentCore`, `SubagentSession`, `SubagentFeed`, `OwnedSubagentOperation`, `SubagentCapabilityRegistry`, `SubagentConfiguration(+Store)`, `SubagentFeedView` (mounted by `NativeToolCallGroupView`) | Taken; admission/residency as remote-only shims; spawn (`TextSubagentKind`) fenced until `W-subagents` proper |
| 2. Computer Use pieces | `Gate` (`ActionPreview`), `ComputerUsePromptQueue`, `ComputerUseConfirmOverlay`, `DesktopResponsesModelStep`, `AgentAction`, `RunLimits` / `ModelActionCall`, `AppRecipe`, `EffectClass(ifier)` | Taken; the Responses engine interface implemented over `CloudChatEngine` |
| 3. AppleScript | `AppleScriptKind`, loop, tools, knowledge, settings | The kind resolves a cloud model (the agent's model, or a per-agent choice) instead of `AppleScriptModelCatalog` (MLX) |

Afterwards Intel's `image` / `video` tools can move onto the host with
upstream's `ImageSubagentKind` / `VideoSubagentKind` (cloud branches).

## Layer 1: host and feed (2026-10-28)

Taken from upstream: `Subagent/SubagentKind`, `SubagentCore`, `SubagentFeed`
(feed, registry, interrupt centre), `OwnedSubagentOperation`,
`SubagentCapabilityRegistry` (+ `SubagentToolVisibility`),
`SubagentModelResolution`, `SubagentAdmission` (admission classes),
`SubagentBatchAdmissionPlanner` (its request-estimate type is in the kind
protocol), `AdmissionPositionLimit`, `SpawnRemoteModelIdentity`,
`Models/AgentDelegation/SubagentConfiguration(+Store)`,
`SpawnBatchConcurrencyContract`, and `Views/Chat/SubagentFeedView`.

Intel edits:

- **Host** (`SubagentSession`): upstream's file with `runPrepared` cut to
  its remote path (feed + interrupt registration, the execution-authority
  check, the scope task-locals and recursion guard, the kind's handoff
  around `run`, the same envelope / feed finish / telemetry). The GPU
  admission slots, batch capacity, residency handoffs and cache snapshots
  are gone; `skipAdmission` and friends stay as parameters. Background
  dispatch (`dispatchInBackground`, `SubagentReportBack`) is fenced: it
  serves background spawn only.
- **Residency:** `Subagent/IntelSubagentResidency.swift` replaces
  `SubagentResidency.swift` and `ResidencyHandoff.swift` with upstream's
  names: every model is remote, the plan is `.none`, the handoff is
  `PassthroughHandoff`.
- **Spawn-only code fenced** (comes with `W-subagents` proper): the spawn
  authority snapshots at the end of `SubagentConfiguration` and their cache
  in the store, the MLX server-settings half of
  `SpawnBatchConcurrencyContract`, and the registry's
  `AgentConfigSnapshot` helpers (Intel resolves tools its own way). Not
  taken yet: `SpawnFanOutPolicy`, `SubagentAdmissionLease`,
  `DelegatedRunContract`, `SubagentReportBack`, `TextSubagentKind`.
- **Model resolution:** no installed local bundles and no spawn-only remote
  ids on Intel, so an override is valid when the picker lists it.
- **Settings:** `AgentSettings` gained upstream's subagent fields
  (`computerUseEnabled`, `browserUseEnabled`, `spawnDelegationEnabled`,
  `appleScriptEnabled`, `appleScriptModelId`, `appleScriptExecutionMode`,
  `spawnableAgentIDs`, `spawnableWorkspaceAgents`, `imageEditModelId`,
  `subagentPermissions`, `subagentBudgets`, `subagentModelOverrides`),
  stored now and used as each kind arrives. `AppleScriptExecutionMode` is
  its own file (the catalog around it is MLX). `ChatExecutionContext`
  gained `currentModelName`, `currentEnableThinking`,
  `currentReasoningEffort`, `currentUserRequest`, `currentSessionSource`.
- **Prompt guidance:** upstream's subagent guidance strings are in
  `SystemPromptTemplates`, verbatim and not yet rendered; each kind adjusts
  the wording (cloud models, no local swaps) when it is wired in.
- **Feed in chat:** `NativeToolCallGroupView` mounts `SubagentFeedView` for
  a row whose tool-call id has a live feed (upstream). The finished-run log
  replay (`SubagentRunLogArchive`) comes with spawn. In the feed view, Stop
  skips the Computer Use prompt queue until layer 2, two-value `onChange`
  became single-value, and "open delegated chat" only focuses an open
  window.

Tests: upstream's `SubagentSessionTests`, `SubagentFeedTests`,
`SubagentConfigurationTests`, `SubagentConfigurationStoreTests` (minus the
spawn-authority revision case), `SubagentModelResolutionTests`,
`SubagentModelOverrideResolverTests`, `SubagentScopeReasoningTests`,
`SubagentTelemetryTests`, `InterruptTokenObserverTests`,
`SpawnRemoteModelIdentityTests`, with `SubagentStoreTestLock`. Left for
spawn: the run log, operation cancellation, capability-registry,
tool-availability and remote-budget suites.

Also: two SF Symbols newer than macOS 13 (`gauge.with.dots.needle.33percent`
in `SubagentFeed`, `bubble.left.and.text.bubble.right` in the feed view)
became `gauge` / `bubble.left.and.bubble.right` (the Ventura guard caught
them). `IntelAgentUnknownFieldsTests` used `browserUseEnabled` as its
example of an upstream-only setting; Intel knows it now, so the test uses
`screenContextEnabled`.

Package gate: 3,521 tests in 442 suites (6 known issues).

Nothing user-visible changes yet: no Intel tool runs through the host.

## Status

Layer 1 shipped 2026-10-28. Next: layer 2 (Computer Use pieces and the
Responses engine interface over `CloudChatEngine`), then AppleScript.
