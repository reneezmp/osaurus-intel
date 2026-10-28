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

## Layer 2: Computer Use pieces and the model step (2026-10-28)

What the desktop subagents share, minus Computer Use's own action model:

- **Taken from upstream:** `ComputerUse/Feed/ComputerUsePromptQueue` (the
  process-wide confirmation queue), `Views/Chat/ComputerUseConfirmOverlay`
  (now mounted in `ChatView`'s prompt overlay layer, as upstream's chat
  overlay), `ComputerUse/Policy/AutonomyPolicy`, `EffectClass`,
  `ComputerUse/Recipes/AppRecipe`, `ComputerUse/Loop/ComputerUseTraceLog`.
  The feed view's Stop now also cancels the run's pending prompts.
- **`Gate.swift`:** `ActionPreview` and `GateDecision` taken; the gate
  itself judges Computer Use's `AgentAction`, so it is fenced until
  `W-computer-use` (as are `AgentAction` and `EffectClassifier`). The trace
  log names the Computer Use tool by its string.
- **`RunLimits`:** extracted from upstream's `ComputerUseLoop.swift` into
  `ComputerUse/Loop/RunLimits.swift`.
- **`AgentLoopBudget`:** `Services/Chat/IntelAgentLoopBudget.swift` carries
  upstream's context window, budget manager and per-iteration assembly
  (trim, then transient notices) on Intel's `ContextBudgetManager`
  (upstream's `AgentToolLoop.swift` is the chat loop Intel's engine
  replaces). Upstream's native-image notice exception is MLX-only and left
  out.
- **Model step:** upstream's desktop loops call
  `DesktopResponsesModelStep` on its Responses-style engine interface, which
  is built on upstream's newer request model and the OpenResponses types
  (Intel's request predates it; `OpenResponsesAPI.swift` is excluded). Intel's
  `ComputerUse/Loop/DesktopResponsesModelStep.swift` keeps upstream's API
  (`completeResponse`, `actionCall` with upstream's validation unchanged,
  `DesktopResponsesAttempt`, and `ResponsesInferenceRequest` /
  `ResponsesGenerationResult` / `ResponsesEngineProtocol` / `ModelActionCall`
  reduced to what the loops read) on `ChatEngine.streamChat` with a new
  request flag, `stopAtToolCalls`: the engine ends the stream at the round
  that proposes tool calls and yields them in one sentinel
  (`StreamingToolHint.encodeProposed`) instead of running them. Both engine
  paths honour it (the chat-completions path, which the Anthropic and Gemini
  adapters use, and the Codex Responses path). Usage counts and reasoning
  are not reported back (nil / empty); the diagnostics fields exist for the
  trace log.

Tests: upstream's `ComputerUsePromptQueueTests`, and
`IntelDesktopModelStepTests` (a proposed call returns without running or a
second request; text is a final answer; another tool is rejected before any
action; retry stops after output; the sentinel round-trips and is never
text). Upstream's `AppRecipeTests` exercises the Computer Use classifier and
waits for `W-computer-use`.

Package gate: 3,526 tests in 443 suites (6 known issues). The postflight
showed three live-file hits inside the test window; `lsof` attributed them
to the running app (`TEST_STORAGE_SAFETY.md`, 2026-10-28 entry).

## Status

Layers 1 and 2 shipped 2026-10-28. Next: layer 3, the AppleScript kind.
