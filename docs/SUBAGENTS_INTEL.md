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

## Layer 3: AppleScript (2026-10-28, `W-applescript-agent` complete)

Taken from upstream: `AppleScript/` (literals, app knowledge, dictionary
service, recipes, the loop, its trace log, `AppleScriptAction`, the effect
classifier, `AppleScriptTool` / `MacQueryTool` and their dispatch),
`Subagent/Kinds/AppleScriptKind`, `ComputerUse/Perception/FrontmostAppTracker`
(started in `AppDelegate`), and `MockAppleScriptWorld` for the tests.
Intel's earlier `AppleScriptLanguage.swift` extract is gone (the enum is
back in `AppleScriptAction.swift`). `EffectClassifier` is back with only its
`AgentAction` classifier fenced: the AppleScript classifier reuses its word
lists.

Intel edits:

- **Model:** upstream runs AppleScript on a dedicated on-device model
  (`AppleScriptModelCatalog`), with resident-model swaps and keep-warm.
  Intel's `AppleScriptKind.resolveModel` picks a cloud model: the agent's
  `appleScriptModelId` when the picker lists it, else the chat's current
  model (`ChatExecutionContext.currentModelName`), else the agent's default.
  An assignment that can't run here (for example an on-device id an Apple
  Silicon build wrote into the shared `~/.osaurus`) is reported with the
  fix, never replaced (upstream's rule). The global config default is not
  used for the same reason. Admission is remote; no residency, keep-warm or
  resident-model reuse for `mac_query`.
- **Loop engine:** `ChatEngine(source: .agent)` (Intel's initializer; no
  Privacy Filter to auto-scrub). Each script step goes through layer 2's
  model step.
- **Scope:** the engine binds `currentModelName` and `currentUserRequest`
  around every tool call (`ChatEngine.withSubagentScope`); the chat send
  binds the exact visible user text first, which the dispatch uses to keep
  the user's own wording authoritative.
- **Gating:** `applescript` and `mac_query` are registered built-ins; the
  agent's switch is the grant (`AgentManager.effectiveAppleScriptEnabled`,
  custom agents only) in tool resolution and `runtimeCapabilityDenial`. The
  per-script consent is the loop's own execution-mode gate (confirm each
  changing script in the overlay, or auto-run with a warning), as upstream.
- **Prompt:** when either tool is in the schema, the composer adds
  `SystemPromptTemplates.intelAppleScriptGuidance` (upstream's text with the
  on-device sentence replaced) as an "AppleScript" section.
- **UI:** Agents → (agent) → Abilities → Overview → **AppleScript**
  (`IntelAppleScriptAbilitySection`): the Mac Automation switch, the
  execution mode and the model ("Use the chat's model" or a chat model).
- The tool-resolution filter chain in `IntelDataConformers` hit the type
  checker's limit; the media/AppleScript switches are now a separate filter.

Tests: upstream's `AppleScriptTests` (minus the warm-residency,
capability-gating and on-device model-routing suites: MLX residency,
`AgentConfigSnapshot`, `AppleScriptModelCatalog`) and
`AppleScriptStringContentsPromotionTests`, plus `IntelAppleScriptTests`.
Upstream's `AppleScriptEvaluatorProbeTests` and `AppleScriptModelAssignmentTests`
test MLX-only pieces.

**Found here:** `AgentLoopBudget.resolveContextWindow` first hopped to the
main actor (`IntelContextBudget.resolveWindow` is `@MainActor`). In a full
test run the main actor was busy and one model-free loop test waited 272 s
(alone it took 0.03 s). Both sources it reads (`ModelInfo.load`,
`ChatConfiguration.shared`) are thread-safe, so it now reads them directly
in the same order. A desktop loop must not wait on the main actor for a
number.

Package gate: 3,702 tests in 458 suites (6 known issues), 61 s.

## Browser Use (2026-10-28, `W-browser-use` complete)

Taken from upstream: `Browser/` (configuration store, plugin migration,
the WebKit session, catalog, manager, support, window controller, child
tools, executor, `BrowserUseTool`), `Subagent/Kinds/BrowserUseKind`,
`Views/Settings/BrowserSettingsView` (a new **Browser Use** settings tab
under Automation, upstream's `.browser`), and
`ComputerUse/Policy/ComputerUsePolicyStore`.

New base piece: **`Services/AgentDelegation/AgentSubagentRunner.swift`**,
Intel's version of upstream's bounded tool loop for subagent kinds (Browser
Use now, spawn later). Upstream streams it through its typed Responses
engine; Intel keeps upstream's types and `run` signature and drives it on
the desktop model step: one model turn, the proposed calls run through the
private toolset (anything not offered is refused, not run), the results fed
back, until a text answer. Same exits and cancellation causes as upstream,
plus a bounded nudge for empty turns and a stop after three identical tool
rounds; token counts are estimates (Intel's engine reports no usage).
Intel's `ServiceToolInvocation` was an empty stub; it is upstream's real
struct now.

Intel edits:

- **Profiles (Ventura, decided by Renée 2026-10-11):**
  `Browser/Runtime/BrowserProfileStore.swift` returns upstream's per-agent
  `WKWebsiteDataStore(forIdentifier:)` on macOS 14+, and the app's shared
  default store on Ventura (no separate persistent store exists before 14).
  On Ventura every agent's Browser Use shares cookies and sign-ins; the
  settings tab, the reset confirmations and the agent section say so.
  Deleting an agent on Ventura closes its session and forgets its record
  without wiping the shared data (`BrowserSessionManager.forgetSession`);
  on 14+ it wipes the agent's own profile, as upstream.
- **Kind:** Intel has no `Agent.toolsEnabled` (uses
  `effectiveToolsDisabled`); the child prompt's policy line comes from
  `AutonomyPolicy.summary` (upstream's `ComputerUseTool.policySummary`; the
  Computer Use tool waits for `W-computer-use`). Model: upstream's
  per-agent `browser_use` override, else the chat's model, through the
  shared resolver.
- **Autonomy:** Intel has no Computer Use settings panel yet, so the
  autonomy policy is upstream's default (or whatever `computer-use.json`
  in the shared folder says). The settings tab no longer points at "your
  Computer Use autonomy level". `AgentSettings.computerUseCeiling` is
  stored (no editor yet).
- **Wiring:** `browser_use` is a registered built-in; the agent's switch is
  the grant (`AgentManager.effectiveBrowserUseEnabled`, custom agents only)
  in tool resolution and `runtimeCapabilityDenial`; upstream's
  `browserUseGuidance` is added to the prompt when the tool is offered.
  Agents → Abilities → **Browser Use** (`IntelBrowserUseAbilitySection`):
  the switch and model. `AppDelegate` runs `BrowserPluginMigration` at
  launch and closes every session at quit.
- `gap_features.py`: the row's pattern was `Browser`, which also caught
  `Networking/BonjourBrowser.swift` (Bonjour peer discovery); it is now
  `^Browser/|BrowserSettingsView|BrowserUse`.

Tests: upstream's `BrowserCatalogTests`, `BrowserGatingTests`,
`BrowserSubagentTests`, `BrowserSupportTests`, `BrowserUseGoalTargetTests`
and `BrowserWebKitSmokeTests` (the last skips itself under `swift test`;
WebKit needs a full app context), plus `IntelBrowserUseTests` (the runner
on a scripted engine: calls through the toolset, refusal of unoffered
tools, empty-turn nudge, repetition stop, cap and cancellation causes; the
profile choice; registration and gate).

Package gate: 3,824 tests in 475 suites (6 known issues).

## Status

Layers 1–3 shipped 2026-10-28; `W-applescript-agent` and `W-browser-use`
are complete. Still to
come on this base: Intel's `image` / `video` tools onto the host
(upstream's kinds), and the kinds of `W-subagents` (spawn), `W-computer-use`
and `W-browser-use`.
