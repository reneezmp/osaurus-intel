# W-computer-use: plan and status

Backlog item `W-computer-use` (upstream Classic 0.25.x, 40 files, about 15k
lines; see `INTEL_MISSING_FEATURES_APPENDIX.md`). Ported from
`upstream/classic` only. Stages 1-3 cannot act on the real screen,
mouse or keyboard. From stage 4 the tool `computer_use` is registered and can
reach the native driver, but only under the gates listed in the stage 4 log.

## Owner policy (hard rules for every stage)

- Computer Use controls the user's real screen, mouse and keyboard. It runs
  only when the user turned it on for that agent (`Agent.computerUseEnabled`,
  default off) and approved the run. Upstream's per-session consent and every
  "Ask" confirmation stay exactly as upstream.
- It stops at once on Stop and at quit (`InterruptToken`,
  `SubagentFeed` interrupt centre, `AppDelegate` teardown in stage 5).
- It never types passwords, payment details or credentials, never approves
  system or permission dialogs for the user, never bypasses CAPTCHAs. The
  guards live in `EffectClassifier` and `ComputerUseGate` (see below) and are
  covered by `GateHardeningTests`; stage 4 adds the loop-level checks.
- Screenshots stay local except what goes to the model the user chose
  (`CloudVisionConsent`, `FrameScrubber`, #3084: a scrub failure stops the
  cloud attachment).
- Accessibility and Screen Recording are requested only by a user click in
  settings (`ComputerUsePermissionDoctor`, stage 5), never at launch or by a
  tool call.
- Tests use `MockMacDriver` and fakes: no real mouse, keys, screen, network,
  keychain or `~/.osaurus`.

## Mapping onto Intel's desktop subagents

Intel already has AppleScript (`applescript` + read-only `mac_query`, own
loop, `AppleScriptEffectClassifier`) and Browser Use on the shared
`Subagent` host (`SubagentCapabilityRegistry`, `SubagentFeed`,
`ComputerUsePromptQueue`, `ConfirmOverlay`, `AutonomyPolicy`, `EffectClass`,
`ActionPreview`, `GateDecision`, `RunLimits`, `DesktopResponsesModelStep`).
Computer Use is the third desktop kind and the only one that perceives and
drives other apps through Accessibility, screenshots and synthesized input.

Decision: Computer Use is a new kind beside them, not a replacement.
`applescript` / `mac_query` stay the preferred route for scriptable apps
(upstream's own guidance says so); `computer_use` is the fallback for apps
without a scripting dictionary. It reuses everything Intel already shares:
the registry entry (`SubagentCapabilityRegistry.computerUse`, currently
naming the tool by its string), the prompt queue and confirm overlay, the
autonomy policy and store, the trace log, the model step and run limits,
and the feed. What it adds is the action model, the driver contract with its
native implementation, perception, the loop, and the tool and kind.

## Stages

| # | Content | Status |
|---|---|---|
| 1 | Model and policy: `AgentAction`, `AgentView`, the `MacDriver` contract with `MockMacDriver`, `TargetResolver`, un-fenced `EffectClassifier`, `Gate` (`ComputerUseGating`, `HardwiredGate`) and `ComputerUseGate`; upstream tests for each | done |
| 2 | Perception with fakes: `CloudVisionConsent`, `FrameScrubber` (Vision; fail-closed, see log), `VisionAttachment`, `CaptureRouter`, `ScreenContextSnapshot`, `AxResolvableSweep`, `ComputerUseRunMetrics`; router, consent, scrub, attachment and metrics tests | done |
| 3 | Native driver, not yet reachable: `Accessibility`, `ElementCache`, `Screenshot` (ScreenCaptureKit 14+, `CGWindowListCreateImage` / `CGDisplayCreateImage` on 13), `InputController`, `BackgroundDriver`, `SkyLightBridge` (dlsym, nil-safe), `NativeMacDriver`, `AutomationSession`, `CaptureMode`; route, bounds, self-guard and open-folder tests over fakes | done |
| 4 | `ComputerUseLoop`, `ComputerUseTool`, `ComputerUseKind` (metrics and sweep were already in from stage 2); registry, `resolveTools` and execution gates; loop tests on `MockMacDriver` and a scripted model step | done (reachable from an attended chat only when the agent's switch is on; the switch has no UI until stage 5) |
| 5 | Settings and consent UI: `ComputerUseSettingsView`, `ComputerUseDiagnosticsPanel`, `ComputerUsePermissionDoctor`, `ComputerUseGateInspector`, Abilities switch, quit/stop wiring, `/computer-use/prompts` consumers; i18n | done (gates in the log; not yet seen on screen on Ventura, see the checklist below) |
| 6 | Screen context: `ScreenContextDistiller`, `[Screen Context]` prefix (composer row 30), per-agent screen-context option, `ScreenContextPreview`, guide topic, composer guidance loop row 12 | done (gates in the log; not yet seen on screen on Ventura, see the checklist below) |

Evals (`Packages/OsaurusEvals`) are not part of Intel's package; skipped.

## macOS 13 API findings (checked against upstream sources)

- `SCScreenshotManager.captureImage` is macOS 14+. Intel already has the
  pattern in `Services/ScreenshotCaptureService.swift`: ScreenCaptureKit on
  14+, `CGDisplayCreateImage` on 13. Stage 3 does the same for window
  capture (`CGWindowListCreateImage` with a window id on 13; it cannot see
  off-Space windows, so on Ventura those return "not capturable").
- `SCShareableContent.excludingDesktopWindows` exists on 12.3+, usable.
- `AXUIElement*`, `AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess`,
  `CGEvent`, `CGEvent.postToPid` are all macOS 13 safe.
- SkyLight (`SLEventPostToPid`, `SLEventPostToPSN`) is loaded with
  `dlopen`/`dlsym` and every symbol is optional; a missing symbol falls
  back to `CGEvent.postToPid`. The #2316 argument-order fix concerns macOS
  26.4+ only and is inert on Ventura.
- `Vision` text recognition (`VNRecognizeTextRequest`) is macOS 10.15+;
  `FrameScrubber` uses it. Upstream builds the request with the newest
  revision; stage 2 pins a revision available on 13.
- No arm64-only binary or model is involved.

## Safety guards and where they live

- `Agent.computerUseEnabled` off by default; `AgentCapabilityReadiness` and
  `SubagentCapabilityRegistry.computerUse` gate per agent (already in).
- `EffectClassifier.classify` only ever raises the verb's baseline effect:
  send / delete / purchase / publish buttons, recipients on a commit,
  command-Return, unidentified click targets, secure text fields.
- `ComputerUseGate.evaluate`: allowlist first; dangerous apps (System
  Settings, Keychain Access, password managers, Terminal) always confirm;
  per-agent ceiling caps autonomy; an unavailable confirmation queue
  rejects rather than runs.
- `ComputerUsePromptQueue` and `ComputerUseConfirmOverlay` (already in)
  carry the per-run approval. `HardwiredGate` confirms everything past
  `navigate`.

## Log

- 2026-11-26 stage 1 done. Filtered gate: 312 tests in 55 suites passed.
  - **Hard stops are Intel additions.** Upstream only escalates secure fields
    to a confirm; it has no CAPTCHA or system-dialog guard. `ComputerUseHardStops`
    / `HardStopGate` (new, `ComputerUse/Policy/`) refuse password and
    credential fields, card-number text, CAPTCHAs and permission/authorization
    dialogs (SecurityAgent, UserNotificationCenter, ...) before any policy, even
    on "Autonomous" and even if an "Ask" would be approved. Stage 4 must wrap
    the run's gate in `HardStopGate` and pass the resolved element's role and
    label (and the focused element for a target-less `type`) to
    `ComputerUseHardStops.rejection`.
  - **The gate runs Swift Testing only (`--disable-xctest`).** Upstream's
    Computer Use tests are XCTest and would silently not run; the ported ones
    were converted to `@Suite` / `@Test` / `#expect` (mechanical). The earlier
    `Tests/ComputerUse/Feed/ComputerUsePromptQueueTests.swift` is still XCTest
    and does not run under the gate; convert it when next touched.
  - **Moved to stage 3:** `SnapshotIdFormat` (in `Accessibility.swift`) and
    `keyCode(for:)` / `parseModifierFlags` (in `InputController.swift`) with
    their two test classes; `InputRoute` (from `BackgroundDriver.swift`) and the
    `CaptureMode` enum live in small stand-in files until then (stage 3 removes
    the duplicates when it ports those files whole).
- 2026-11-26 stage 2 done. Filtered gate: 342 tests in 65 suites passed. One
  live hit (`~/.osaurus/memory/memory.sqlite-wal`, 10:56:50 inside the window)
  is held open by the user's running upstream `osaurus` app (`lsof`); no test
  here touches memory.
  - **`FrameScrubber` is fail-closed on Intel.** Upstream's `.pii` mode masks
    only regions flagged by the Privacy Filter (`RegexEntityDetector`,
    `PrivacyFilterStore`, `PrivacyFilterEngine`), which Intel lacks
    (`W-privacy-filter`). The port keeps the API (`ScrubbedFrame` stays
    unconstructible outside the scrubber, `honorUserRules` /
    `useModelDetection` are accepted and ignored) but `.pii` masks every
    recognized text region like `.allText`, so a cloud-bound screenshot never
    carries readable text. When `W-privacy-filter` lands, restore upstream's
    detector branch in `recognizeAndDetect` / `scrub`. #3084 (a scrub failure
    stops the cloud attachment) is the loop-level part and lands in stage 4.
  - `FrameScrubFailureTests` keeps its scrubber half; its cloud-send loop half
    needs `ComputerUseLoop` and returns in stage 4 (the full upstream file is
    in the stage 4 notes: re-take it from `upstream/classic`).
  - Vision OCR (`VNRecognizeTextRequest`, `.accurate`) is on-device and
    available on macOS 13.
- 2026-11-26 stage 3 done (native driver, unreachable). Ported whole from
  `upstream/classic`: `Mac/Accessibility`, `ElementCache`, `Screenshot`,
  `InputController`, `BackgroundDriver`, `SkyLightBridge`, `AutomationSession`,
  `CaptureMode`, and `NativeMacDriver`. The stage-1 stand-ins (`InputRoute.swift`,
  the trimmed `CaptureMode.swift`) are gone: the ported files own those types.
  Nothing outside `ComputerUse/Driver` constructs `NativeMacDriver`; only
  `ExternalPlugin` uses `AccessibilityManager.serialQueue` (it replaces the
  one-member stand-in in `IntelPluginShims.swift`, same queue label).
  - **Intel adaptations (3).** (a) `Screenshot.swift`: window and display capture
    use ScreenCaptureKit on 14+ (`@available(macOS 14.0, *)` helpers) and, on
    13, `CGDisplayCreateImage` for displays and `CGWindowListCreateImage` for a
    window id, resolved with `dlopen`/`dlsym` because the call is `unavailable`
    to the compiler on the current SDK (macOS 27.2). The Ventura window path sees
    only windows on the current Space; others return nil ("not capturable").
    (b) `BackgroundDriver.InputDebug` wrote through upstream's
    `RuntimeDiagnostics` (vmlx package, not linked here); it writes to stderr
    (only with `OSAURUS_CU_INPUT_DEBUG=1`). (c) the `AccessibilityManager` stand-in
    removed. `SkyLightBridge` was already `dlsym`-based and nil-safe, no change.
  - **No permission prompt anywhere in the driver.** It only calls
    `AXIsProcessTrusted` / `CGPreflightScreenCaptureAccess` (checks). Requesting
    permissions stays with stage 5's Permission Doctor, user click only.
  - **Tests (Swift Testing, fakes only):** `BackgroundDriverRouteTests` (every
    synthesized event goes through one injected spy transport; nothing is posted
    to a real pid), `AccessibilitySelfGuardTests` (our own pid yields nothing),
    `AccessibilityBoundedElementSourceTests` (source guard: one
    `AXUIElementCreateApplication`, inside `axApp`, with a messaging timeout),
    `OpenFolderPathTests` (temp dir only). **Not ported on purpose:**
    upstream's `NativeMacDriverLiveTests` and `BackgroundDriverLiveInputTests`
    (they capture the real screen and post real input) and `ComputerUseEvidencePackTests`
    (needs the stage-4 loop). The plan's earlier note that `SnapshotIdFormat` /
    `keyCode(for:)` had their own test classes was wrong: upstream has none.
  - **XCTest conversion.** `InsightsImageRedactionTests` and
    `ComputerUsePromptQueueTests` were XCTest and never ran under the gate; both
    are now Swift Testing with the same assertions; both pass unchanged, no code bug found.
  - **Gate results.** Filtered: 293 tests in 65 suites passed, live hits empty, mdat
    unchanged. Full suite (`gate_pty.sh`): 6518 tests in 847 suites passed with 6
    known issues, live hits empty.
- 2026-11-26 stage 4 done: `ComputerUseLoop`, `ComputerUseTool`, `ComputerUseKind`
  ported whole from `upstream/classic`, plus the registry wiring. **This is the
  first stage that can reach the real mouse, keys and screen.** How a run starts
  and which consents gate it (Intel owner policy on top of upstream):
  1. The agent's own switch `Agent.settings.computerUseEnabled` (default off;
     custom agents only, off while the agent's Tools is off):
     `AgentManager.effectiveComputerUseEnabled`. It strips `computer_use` from
     the model's tool list (`IntelDataConformers` compose) and is checked again
     at execution (`ToolRegistry.runtimeCapabilityDenial`) and in
     `ComputerUseKind.validateAuthority`. There is no settings UI for it before
     stage 5; it can be set today only through a config document.
  2. Attended chat only (`ComputerUseKind.unattendedRefusal`, Intel addition):
     `currentSessionSource` must be `.chat` or `.imported`, `isUnattendedDispatch`
     and `isExternalSurface` must be false. Schedules, watchers, self-scheduled
     wake-ups, plugins, HTTP/MCP callers, delegated children and an unpublished
     source are refused at the registry and again in the kind. `computer_use` is
     also in `externallyDeniedHostToolNames` (hidden from `/mcp/tools`).
  3. Every action goes through upstream's per-action gate: `ComputerUseGate`
     (policy, allowlist, per-agent ceiling) and the confirm card
     (`ComputerUsePromptQueue`); a missing card surface rejects, never runs
     (`confirmUnavailable`). The host permission stays `.allow`, as upstream: the
     card is the consent. Accessibility is preflighted by `PermissionedTool`.
  4. Stage 1 hard stops are enforced in the loop (Intel addition): the loop
     wraps any injected gate in `HardStopGate`, and before the gate it judges
     password/credential fields, card numbers, CAPTCHAs and system dialogs
     against the resolved element, or the focused element for a target-less
     `type`. A hard stop is a rejection, never a confirm card.
  5. Stop: `InterruptToken` / `SubagentFeed` interrupt centre, as upstream; the
     quit hook is stage 5.
  - **Intel adaptations.** `RunLimits` stays in `RunLimits.swift` and
    `ModelActionCall` in `DesktopResponsesModelStep.swift` (removed from the
    loop file; they were already extracted there). The loop's engine is
    `ChatEngine(source: .agent)` (as the AppleScript loop), without upstream's
    inference-source and auto-scrub privacy mode. `ComputerUseTool.modelAcceptsImages`
    has no on-device branch (every Intel model is remote; Router catalog for
    vision), and `modelIsLocal` is always false. `FeatureTelemetry.computerUseRun` /
    `computerUseRefused` are no-op stubs (Intel sends no telemetry).
    `authorizationRefusal` takes `toolsDisabled` where upstream reads
    `agent.toolsEnabled`. `ComputerUseEvalHarness` is kept (unused; evals are not
    in Intel's package).
  - **Frame scrubber unchanged:** while `W-privacy-filter` is missing it keeps
    masking all text; no hook was added for the privacy filter.
  - **Tests (Swift Testing, fakes only):** upstream's `ComputerUseLoopActTests`,
    `ComputerUseLoopRunTests`, `ComputerUseLoopTests`, `StaleViewCompactionTests`,
    `ComputerUseAuthorizationTests`, `ComputerUseEvidencePackTests` and the full
    `FrameScrubFailureTests` (cloud-send half), converted from XCTest with a
    mechanical script; new `ComputerUseLoopHardStopTests` and source-gate tests.
    Not ported: `ResponsesDesktopModelStepTests` (Intel has its own
    `IntelDesktopModelStepTests`).
  - **Accessibility check in the kind.** Upstream preflights Accessibility in
    `ToolRegistry.runPermissionGate`; Intel's registry has no such gate, so
    `ComputerUseKind.run` refuses (check only, no prompt) when `AXIsProcessTrusted`
    is false, before the loop starts.
  - **Gate results.** Filtered (ComputerUse, Computer, Screen, Accessibility,
    Desktop, Subagent, ToolRegistry, Spawn, IntelVenturaControlGuard, FrameScrub,
    StaleView, ExternalSurface, Mcp): 564 tests in 103 suites, only 2 issues, both
    `FrameScrubberTests` (stage 2). Full (`gate_pty.sh`): 6629 tests in 859 suites,
    13 issues = the 6 known + 7 Vision OCR failures
    (`TextRecognition.CRImageReaderError` code 1: `FrameScrubberTests` x2,
    `CaptureRouterTests`, `IntelRichFolderFormatsTests` OCR, and others in the
    same family). **Vision text recognition stopped working on the build Mac
    during the 2026-11-26 session** (the same tests passed in the stage 2 and 3
    gates that morning and fail identically in other worktrees and in isolation);
    nothing in stage 4 touches it. Re-run those suites after a reboot before
    blaming code. Live hits listed only files the running upstream app holds open.
  - **Stage 5 not started.** The Computer Use switch has no UI yet; until
    stage 5 it can be set only through the declarative config.
- 2026-11-27 stage 5 done: settings and consent UI. **Reachable by a user now.**
  - **Where things are.** Settings tab `Computer Use` (`ManagementTab.computerUse`,
    sidebar section Automation, deep link `osaurus://settings?tab=computerUse`,
    search entry and anchor `computerUse.enable`): `Views/Settings/ComputerUseSettingsView`
    (about, Setup with the two permission rows, how to turn it on, consent,
    autonomy presets, Advanced: per-app rules, app allowlist, cloud vision, and
    `ComputerUseDiagnosticsPanel` with the Permission Doctor and Gate Inspector).
    The per-agent switch is `Views/Agent/IntelComputerUseAbilitySection` in the agent's
    **Abilities** tab (custom agents only; model override, autonomy ceiling,
    Accessibility warning with a button to Settings). Off by default; the only
    place `computerUseEnabled` is set from UI is that toggle.
  - **Permissions by click only.** `requestPermission(` appears once, in the
    Grant button of `ComputerUsePermissionRow`; appear/refresh use checks only
    (`startPeriodicRefresh`, `cachedIsGranted`). A source guard test enforces it.
    Screen Recording's Grant only opens System Settings (macOS offers no prompt).
  - **Stop and quit.** `ComputerUseTeardown` (new): `ChatSession.stop()` trips the
    token of this chat's Computer Use runs (matched by feed `parentSessionId`, the
    session id or the `chatwindow-` sentinel) and denies their cards, besides the
    existing Task cancellation the loop polls; `applicationShouldTerminate` calls
    `stopEverything()` first (all tokens tripped, every pending card denied, never
    approved); `applicationWillTerminate` trips tokens again and flushes
    `ComputerUsePolicyStore`. New small members: `SubagentInterruptCenter.interruptAll`,
    `SubagentFeedRegistry.liveFeeds`, `ComputerUsePromptQueue.denyAllPending`.
  - **Prompt consumers** were already in: `ComputerUseConfirmOverlay` is mounted in
    both chat prompt layers (registers as presenter), and `IntelHTTPApprovals`
    serves `GET/POST /computer-use/prompts` for the paired phone. Nothing new needed.
  - **Intel changes against upstream.** No Models sub-tab (on-device AppleScript
    models need MLX); no Screen context card, toggle or Doctor row (stage 6; the
    Doctor keeps the row, the panel hides it); no "mask only detected text"
    toggle (no Privacy Filter: the scrubber masks all text either way) and the
    Doctor no longer calls `.pii` a reduced-privacy state; the Gate Inspector
    preview also runs `ComputerUseHardStops` so a password-field preview shows
    Block, like the live loop. Upstream's tests were XCTest; converted.
  - **Tests (Swift Testing, fakes and source guards only):** `ComputerUsePermissionDoctorTests`,
    `ComputerUseGateInspectorTests`, `ComputerUseGateInspectorHardStopTests`,
    `ComputerUseSettingsSafetyTests`, `ComputerUseTeardownTests`.
  - **How to verify on screen on Ventura (Rosy, not done yet):** (1) Settings →
    Computer Use opens, search "computer use" lands on it; (2) opening the tab
    shows no macOS permission prompt; Grant on Accessibility opens the system
    prompt only after the click; (3) agent → Abilities → Computer Use is off on
    a new agent, the Default agent shows the "never controls your Mac" note;
    (4) turn it on, Accessibility warning shows while ungranted; (5) in a chat,
    start a run and press Stop mid-run: it ends at once, also with a confirm
    card showing; (6) quit during a run: the app quits, no keys or clicks go on
    afterwards; (7) Advanced → Diagnostics: Gate Inspector previews a type into
    a password field as Block.
- 2026-11-27 stage 6 done: screen context (opt-in, per agent).
  - **What it is.** At the first send of a chat, a frozen, text-only
    `[Screen Context]` block (open windows, the app the user was working in,
    the focused field's draft, a small sample of on-screen text; no
    screenshot) is prepended to that user turn and replayed byte for byte on
    later turns (upstream #1610 / #1763 / #1618). It goes only to the model the
    user chose for the chat.
  - **Where things are.** `ComputerUse/Perception/ScreenContextDistiller`
    (ported whole; `captureForChat()` uses `NativeMacDriver` and
    `FrontmostAppTracker`), `ScreenContextFreeze` (new: `ScreenContextGate` +
    capture-once freeze, pure and fakeable), `AgentSettings.screenContextEnabled`,
    `AgentManager.effectiveScreenContextEnabled(for:)`, the `screenContext:`
    argument of `SystemPromptComposer.composeInjectedUserPrefix` and
    `ChatSession.freezeInjectedContextOntoLatestUserTurn` (order as upstream:
    automation, screen, memory, time), the "Screen Context" row of the context
    budget (`ContextBreakdown.from(... screenContextTokens:)`, tint pink),
    `Views/Settings/ScreenContextPreview`, the **Share screen context** toggle
    plus **Preview screen context** popover in `IntelComputerUseAbilitySection`,
    the Settings → Computer Use "Screen context" card, the Permission Doctor row
    (now shown) and the Guide topic (`Resources/Guide/guide-automation.md`,
    section "Computer Use and screen context"; `guide-intel-mac.md` no longer
    lists Computer Use as missing).
  - **Owner policy, enforced.** Off by default, and **Intel's default differs
    from upstream**: upstream decodes a missing key and defaults new agents to
    on once Computer Use is on; Intel defaults and decodes to OFF (an explicit
    `true` in a file is honoured). Effective only when the agent's own Computer
    Use is on (`effectiveComputerUseEnabled`: custom agent, Tools on) AND its
    option is on. Capture happens only from an attended chat
    (`ScreenContextGate` reuses `ComputerUseKind.unattendedRefusal`: schedules,
    watchers, self-scheduled wake-ups, plugins, HTTP/MCP, delegated children and
    an unpublished source never capture). A send that is not allowed neither
    captures nor freezes, and replays nothing after the user turned the option
    off. Capture only *checks* Accessibility (`driver.availability()`); no
    permission request exists in the distiller, the freeze or the preview (source
    guards). The global Settings card's preview captures only on Refresh
    (`autoCaptureOnAppear: false`); the per-agent popover captures when opened.
  - **Update 2026-11-27:** since `W-privacy-filter` stage 3 (`914bd0a55`) the block rides the user turn and is scrubbed with it when the filter is on; the preview note says so. The paragraph below is the stage 6 state.
  - **What Intel could not do (stage 6).** The text block was **not scrubbed**: upstream runs
    it through the Privacy Filter before a cloud send, and Intel has none
    (`W-privacy-filter`). `CloudVisionConsent` and `FrameScrubber` guard
    screenshots only; screen context has no image, so they do not apply, and the
    UI says so in plain words (preview note, card, toggle caption, Guide). When
    `W-privacy-filter` lands, route the block through it the way upstream's
    `latestUserTurnSegments()` does and restore the note upstream shows.
  - **Intel adaptations.** (a) `ScreenContextPreview` drops the Privacy Filter
    note and masked-count code. (b) The per-agent option lives in the Abilities
    tab (Intel has no Subagents tab), not `AgentsView`. (c) No composer
    "Screen context from <app>" chip: `FloatingInputCard` has no empty-chat
    signal on Intel and the chip would need a `ChatContentView` change; the
    budget row and the preview cover it. (d) Not ported on purpose:
    `injectScreenContextPrefix` (upstream's chat path does not call it; it was
    the older per-request injector) and its XCTest, the OsaurusEvals fixtures
    and suites, `ScreenContextCapabilityTests` (rewritten for Intel's switch).
    (e) `ScreenContextDistillerTests` converted from XCTest, assertions unchanged.
  - **Composer guidance loop (audit row 12).** The registry-driven loop was
    already in (`SubagentCapabilityRegistry.computerUse`, `guidanceSectionId`
    `computerUse`, rendered when `computer_use` resolves). On Intel, as upstream
    (#2250), a custom agent takes the lean prompt, which returns before that loop,
    and only a custom agent can have Computer Use; so the section never renders
    in practice and the model relies on the tool's own description. Pinned by a
    test; do not "fix" it without deciding the lean-prompt policy (audit 5b row 4).
  - **Tests (Swift Testing, fakes only):** `ScreenContextStage6Tests` (gate,
    capture-once freeze, prefix order, frozen turn prefix, default off and
    codable round trip, effective capability, budget row, guidance loop and lean
    skip, source guards) and `ScreenContextDistillerTests` (21 tests over
    `MockMacDriver`). `IntelAgentUnknownFieldsTests` now uses a made-up
    upstream-only key, since `screenContextEnabled` is Intel-known.
  - **How to verify on screen on Ventura (Rosy, not done yet):** (1) agent →
    Abilities → Computer Use on: **Share screen context** is off for a new
    agent; (2) turn it on, the preview link opens a popover that shows a text
    snapshot only when Accessibility is granted (else a hint, and no macOS
    prompt appears); (3) Settings → Computer Use → Screen context card: opening
    the tab reads nothing, Refresh shows the snapshot; (4) new chat with that
    agent, send a message about "this window": the model refers to the app you
    were in; the context budget popover lists a Screen Context row; a second
    message does not capture again; (5) switch the option off, new chat: no row,
    nothing shared; (6) a schedule or watcher run of the same agent shares
    nothing; (7) Permission Doctor shows the Screen Context row On/Off.
  - **Gate results.** Filtered (ComputerUse, ScreenContext, Composer,
    SystemPrompt, Agent, Settings, IntelVenturaControlGuard, IntelFrozenUserPrefix,
    IntelLeanPrompt, OsaurusHelpTool, ContextBudget): 1109 tests in 209 suites
    passed. Full (`gate_pty.sh`): 6919 tests in 896 suites passed with 6 known
    issues, mdat unchanged, live hits empty. The filtered run listed one hit,
    `~/.osaurus/memory/memory.sqlite-wal` at 15:12:21, before the test window
    (held by the user's running upstream app); the Vision OCR failures of
    stage 4 did not appear in this run.
