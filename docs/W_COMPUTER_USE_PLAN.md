# W-computer-use: plan and status

Backlog item `W-computer-use` (upstream Classic 0.25.x, 40 files, about 15k
lines; see `INTEL_MISSING_FEATURES_APPENDIX.md`). Ported from
`upstream/classic` only. Nothing in stages 1-2 can act on the real screen,
mouse or keyboard: no tool, no driver, no UI is registered.

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
| 2 | Perception with fakes: `CloudVisionConsent`, `FrameScrubber` (Vision), `VisionAttachment`, `CaptureRouter`, `ScreenContextSnapshot`; consent and scrub-failure tests | planned |
| 3 | Native driver, not yet reachable: `Accessibility`, `ElementCache`, `Screenshot` (ScreenCaptureKit 14+, `CGWindowListCreateImage` / `CGDisplayCreateImage` on 13), `InputController`, `BackgroundDriver`, `SkyLightBridge` (dlsym, nil-safe), `NativeMacDriver`, `AutomationSession`, `CaptureMode`; route and bounds tests over fakes | planned |
| 4 | `ComputerUseLoop`, `ComputerUseRunMetrics`, `AxResolvableSweep`, `ComputerUseTool`, `ComputerUseKind`; registry and `resolveTools` gates; loop tests on `MockMacDriver` and a scripted model step | planned |
| 5 | Settings and consent UI: `ComputerUseSettingsView`, `ComputerUseDiagnosticsPanel`, `ComputerUsePermissionDoctor`, `ComputerUseGateInspector`, Abilities switch, quit/stop wiring, `/computer-use/prompts` consumers; i18n | planned |
| 6 | Screen context: `ScreenContextDistiller`, `[Screen Context]` prefix (composer row 30), per-agent screen-context option, `ScreenContextPreview`, guide topic, composer guidance loop row 12 | planned |

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
