# Orchestrator on Intel — implementation plan and focused test contract

**Status (corrected by Rosy QA, 2026-09-13):** Gates 1–2 pass on Intel. Gate 4's
manual Settings sheet and Gate 5B's tool/runtime code exist and have automated
coverage, but the Orchestrator chat receives no orchestration or delegation tools,
so they are not promoted as a working model-facing Orchestrator. The Intel prompt
also omits upstream's compiled-out built-in Orchestrator instructions, and its
default agent omits the standard green avatar. Treat Gates 3–5B as implementation
work awaiting repaired chat exposure and fresh Rosy acceptance.

**Scope:** `intel-fork`, Intel/x86_64, macOS 13 Ventura minimum. This plan is based on
the audited `upstream/main` chain and the active Intel target, including its
`Packages/OsaurusCore/Package.swift` exclusions and Intel conformer replacements.

The Orchestrator has two coupled layers:

1. a built-in agent that stores identity, instructions, generation settings, and
   configuration policy; and
2. a delegation runtime that selects an allowed custom agent or model, runs it
   within bounded policy, and returns a result or artifact to the parent chat.

A settings screen alone is not parity. A feature is promoted only when its store,
runtime action, persistence, failure state, focused tests, and Intel validation all
exist. Explanatory dependency cards remain **Dependency-blocked** until then.

## Audited upstream chain

The relevant upstream work is dependency ordered. It is a map of contracts, not a
cherry-pick queue: the Intel fork diverges in core managers, chat execution, tool
registration, and local runtime ownership.

| Layer | Upstream commits | Contract to recover or adapt |
|---|---|---|
| Delegation foundation | `a29fe877` | Agent delegation, spawn, permissions, artifacts, and residency boundaries |
| Subagent registry | `6facd2bc` | Unified subagent kinds, stores, sessions, feeds, and per-agent settings |
| Model routing | `2a2a06e8`, `85fafd3f` | Per-target model resolution and separate agent/model spawn modes |
| Safety and bounded execution | `c7c3f92c`, `938cf5b8`, `3fb975f4`, `33d3c681`, `afa32e5c`, `bfa62f65`, `f33c9eca` | Admission, cancellation, budgets, concurrency, target tool policy, and residency |
| Orchestrator substrate | `8d7c3dd4` | Declarative configuration, approval, background dispatch, live sessions, artifacts, and prompt grounding |
| Identity and settings | `7aa8d7a3` | Orchestrator identity, generation controls, settings route, and launch/chat presentation |
| Orchestrator-first behavior | `679ba750` | Spawn defaults, same-turn activation, and artifact pass-through |
| Later safety and targets | `c853ca4c`, `49e2faac`, `1c3cbdcb`, `900eefe9`, `940d86a3`, `a4cb24b6`, `00486cc8`, `f2a308d5` | Admission correctness, model-owned reasoning, RAM-safe handoff, workspace and remote targets |

The declarative configuration plane from `8d7c3dd4` is a separate phase. It includes
the manifest, planner, applier, approval queue, schema/model references, YAML
decoding, configuration tool, and approval card. It must not be represented by a
dead “configure” control before the planner and applier are real.

## Intel boundary and dependency gates

The following active Intel files are excluded or replaced and therefore require an
Intel adaptation: `Managers/AgentManager.swift`, `Models/Agent/AgentStore.swift`,
`Services/Chat/ChatEngine.swift`, `Services/Chat/SystemPromptComposer.swift`,
`Tools/ToolRegistry.swift`, `Tools/CapabilityTools.swift`, the sandbox stack, and
parts of the local model/runtime stack. Source presence in the upstream ref does
not mean that source is compiled into the Intel product.

### Gate 0 — source and storage safety

Before editing, record the checkout, HEAD, upstream ref, merge base, current
`Package.swift` exclusions, and unrelated dirty files. Read `FEATURE_PARITY.md`,
`UPSTREAM_SYNC.md`, `TEST_STORAGE_SAFETY.md`, and this plan. Never use the installed
current upstream app as evidence about Intel behavior.

All path-backed tests use a disposable test root, the shared storage lock, and
serial execution where process-global storage overrides are involved. Every run
has live-data preflight and postflight checks. A green test count without storage
integrity is incomplete validation.

### Gate 1 — Intel-safe Orchestrator identity and configuration

**Implemented 2026-09-11.** `DefaultAgentConfiguration` and
`DefaultAgentConfigurationStore` persist the built-in identity, prompt, optional
model override, temperature, and maximum output tokens at
`config/default-agent.json`. Missing fields decode as inherited defaults. Tests
redirect this store to a disposable directory while holding the process-wide
`StoragePathsTestLock`; the live store is not test data.

Implement and test an Intel-specific `DefaultAgentConfiguration` and store. The
first usable slice may contain:

- name and identity presentation;
- system prompt/instructions;
- optional cloud-model override;
- temperature and maximum output tokens;
- restore-defaults behavior; and
- safe decoding of missing or newly added fields.

The store should use the upstream-compatible location, `~/.osaurus/config/default-agent.json`,
while tests redirect it to an isolated temporary root. Existing `chat.json` values
are migration defaults only; migration must not overwrite a user’s existing custom
agent model or capability settings.

Preserve Intel’s existing negative-polarity capability representation (`disableTools`,
`disableMemory`, and related fields). Do not copy current upstream positive-polarity
decoders mechanically. The built-in `Agent.default` remains compatible with
existing agent/session JSON while the Orchestrator store becomes authoritative for
the built-in identity and generation settings.

### Gate 2 — route, presentation, and runtime selection

**Implemented 2026-09-11.** The Agents sidebar now routes to a dedicated
Orchestrator settings page with identity, model, prompt, generation controls, and
Restore Defaults. Saves refresh the built-in agent, bump the Intel capability
revision, and post `agentUpdated`, so new work resolves the saved values through
the active Intel manager. The delegation section is an explanatory dependency
card with no runnable control.

Add the Orchestrator route only when Gate 1 has a real store and runtime consumer.
The settings view must persist edits, restore defaults, and report unavailable
delegation capabilities without presenting enabled-looking controls.

Wire the built-in agent’s effective model, prompt, temperature, and output cap into
the active Intel chat path. New chats must use the selected values; existing live
sessions must either be invalidated/rebuilt or clearly retain their captured
configuration according to an explicit contract. Persistence alone is insufficient.

The sidebar may follow upstream’s placement and naming, but local-only MLX and
unsupported delegation controls must remain visibly unavailable and linked to the
appropriate backlog entry.

### Gate 3 — explicit cloud/custom-agent delegation capability spike

**Internal spike passed 2026-09-11.** `IntelDelegationProbe` proves one admitted
custom agent can be resolved into an immutable, standalone, one-turn child request
and sent through the real Intel `ChatEngine`. The focused fixture uses the actual
HTTP adapter without contacting or billing a remote provider. It verifies typed
denial, timeout, cancellation, concurrency rejection, token/output clamping,
bounded inline text return, and unchanged parent policy.

This does not expose delegation in Settings or to the model. The spike deliberately
suppresses all child tools and does not persist a child session. A paid/live
provider call is separate acceptance evidence, not a substitute for the
deterministic adapter test.

Before restoring the full delegation runtime, run a bounded spike against one
cloud-capable Intel model and one disposable custom agent. The spike must measure,
not assume:

- whether the active Intel chat engine can start a child session without sharing
  mutable parent state;
- whether a child can receive the target agent’s prompt and allowed tools;
- whether parent/child cancellation and timeout are observable;
- whether token, turn, time, and concurrency budgets can be enforced;
- whether a result and a small text artifact can return to the parent safely;
- whether the parent resumes with its original model/tool policy; and
- whether an unavailable or denied target fails closed with an actionable message.

The spike is cloud/custom-agent only. It must not enable local model switching,
sandbox execution, browser/computer use, image generation, remote/workspace
dispatch, or background autonomy merely because the upstream schema contains those
target kinds. Record measured limits and failures in the implementation change and
update this plan if the active Intel runtime invalidates an assumption.

The spike passes only when the complete parent → child → result path works under
bounded policy and has focused tests. Until then, cloud/custom-agent delegation is
**Dependency-blocked** and the UI must say so.

### Gate 4 — bounded text delegation

**Implemented 2026-09-11.** The Intel settings surface now exposes a manual
one-turn sheet. It admits only explicitly selected non-built-in custom agents and
explicitly admitted remote cloud models, revalidating both the target and model
before dispatch. Permission is scoped to the exact Orchestrator/target pair and
supports Ask, Deny, and Always Allow. Ask requires a per-run approval from the
sheet; Deny fails closed; Always Allow remains subject to admission and model
availability checks.

The child is always a fresh, standalone, text-only request. Gate 4 fixes one turn,
one active child globally, and no child tools or nested child creation. It enforces
maximum input characters, child tokens, output characters, and timeout, supports
cancellation, and returns only a bounded inline text result in the manual sheet.
It creates no durable child chat/session, queue, background continuation, filesystem
artifact, or model-owned spawn. Parent state and parent model/tool policy are not
mutated.

The intentionally small surface is the Intel product boundary for this gate. Child
tools and model-owned autonomous delegation move to the later dependency/backlog
work because Intel cloud tool-loop limits are not request-scoped; the current
runtime cannot safely claim per-request child-tool budgets. Default spawn pools,
same-turn activation, durable sessions, background dispatch, and artifact
pass-through likewise remain later contracts.

### Gate 5 — declarative configuration plane

Gate 5 is split at the real approval boundary rather than pretending the Settings
sheet and a model-facing tool are the same feature.

**Gate 5A implemented 2026-09-12.** The Orchestrator Settings page can export,
edit, preview, approve, and atomically apply a strict version-1 JSON document for
the two Intel-owned durable domains that already exist: `default_agent` and
`delegation`. The plan lists every before/after value, is deterministic, binds
approval to the exact current and target fingerprints, rejects stale or replayed
approval, and verifies fresh persisted bytes after saving. Unsupported or unknown
domains fail before mutation. Secret-shaped keys and `env:`/`keychain:` references
are rejected without echoing values.

The supported fields are Orchestrator name, prompt, model, temperature, maximum
tokens, admitted custom-agent IDs and cloud-model IDs, pair-scoped permissions,
and Gate 4 child/input/output/time bounds. Agents, tools, providers, channels,
Knowledge, Memory, schedules, watchers, relay/workspaces, media, and secrets remain
outside this plane until their Intel stores and approval contracts exist.

**Gate 5B implemented 2026-09-12.** The built-in Orchestrator alone receives the
`orchestrator_config` schema. Unbound callers and custom agents fail closed at both
schema composition and dispatch. The tool supports schema inspection, read-only
planning, and attended apply for the same bounded Gate 5A domains. It does not
export the current configuration to the model, so private existing prompt values
do not become provider-visible tool output.

Apply parks the exact fingerprint-bound plan in a process-wide, user-owned queue.
The chat renders a structured before/after card with Apply and Cancel; only an
explicit Apply result lets the service mint the single-use receipt. Denial,
timeout, turn cancellation, missing chat surface, stale state, and replay all fail
without mutation. The tool owns this review, so the generic Always Allow prompt is
skipped while an explicit per-tool Deny still wins. Long values are shortened only
for display; fingerprints bind their complete values.

The queue is intentionally process-local: pending reviews are cancelled by turn
or UI teardown and do not survive relaunch. Durable unattended approvals, secret
references, extra domains, and model-readable export remain outside this gate.

### Gate 6 — promotion and Rosy evidence

Promotion requires x86_64/macOS 13 compilation, focused automated coverage, clean
isolated storage checks, and the Rosy Ventura checklist below. Automated tests and
Rosy observations are separate evidence; one never substitutes for the other.

## Explicitly unavailable or deferred targets

These are product boundaries for the first Intel Orchestrator phases, not
implementation claims:

| Target/capability | Intel state | Required future evidence |
|---|---|---|
| Local MLX/model residency delegation | **Unavailable** | Separate Intel-compatible runtime and measured memory/residency behavior |
| Sandbox workers and autonomous shell execution | **Unavailable** | Intel-safe sandbox/container backend, storage boundary, approval, and cleanup |
| Browser Use | **Unavailable** | Capability spike for Ventura and supported newer macOS, browser engine, auth, and approvals |
| Computer Use / AppleScript | **Unavailable** | Accessibility, Screen Recording, Ventura behavior, action approval, and cancellation spike |
| Image/video delegation | **Unavailable** | Cloud-only media job contract first; local image/edit models remain outside Intel scope |
| Workspace/shared-agent targets | **Dependency-blocked** | Workspace identity, relay/pairing, grants, target liveness, and revocation |
| Remote-agent dispatch | **Dependency-blocked** | Relay and remote connection backend with bounded usage and failure recovery |
| Background autonomous delegation | **Dependency-blocked** | Durable task/session lifecycle, cancellation, notification, and recovery |
| Child tools in delegated runs | **Dependency-blocked** | Intel cloud tool-loop limits are not request-scoped; add request-scoped tool budgets and cancellation before exposing any child tool |
| Model-owned autonomous delegation | **Dependency-blocked** | Model-owned spawning needs an Intel request-scoped admission, budget, and lifecycle contract |

No unavailable target receives an enabled switch, selectable model, runnable tool,
or success-looking empty state. The dependency belongs in the relevant roadmap or
backlog and is linked from the explanatory state.

## Focused automated test contract

Tests must be added with each gate and run against the Intel target. Storage-backed
tests use the isolation rules in `TEST_STORAGE_SAFETY.md`; disposable agents and
temporary roots are mandatory. The matrix below defines the minimum contract.

| Area | Required assertions |
|---|---|
| Default configuration codec | Round-trip name, prompt, cloud model, temperature, max tokens; missing fields receive safe defaults; malformed data fails safely |
| Default configuration persistence | Isolated store creates/reads/updates/resets `default-agent.json`; reload preserves values; live `~/.osaurus` is unchanged |
| Legacy migration | Existing agent JSON preserves name, model, avatar/theme, order, tools, memory, Knowledge, and connection settings; Intel polarity remains correct |
| Effective runtime settings | New built-in chats use stored model/prompt/generation values; reset restores inheritance; live-session invalidation/rebuild behavior is explicit and tested |
| Route and navigation | Orchestrator route resolves, remains selected across tab switches, survives relaunch, and unavailable sections render dependency states without dead actions |
| Target admission | Only explicitly allowed custom agents/admitted cloud models enter schemas; unavailable, removed, denied, or malformed targets fail closed |
| Delegation runtime | Explicit custom-agent/model admission, exact launcher/target permission scope, Ask/Deny/Always Allow, one-turn child, one-child concurrency, no tools, bounded input/tokens/output/timeout, cancellation, and inline result are observable |
| Deferred delegation | Child tools, durable child sessions, filesystem artifacts, queues, background continuation, and model-owned spawning remain unavailable and fail closed |
| Spawn-pool migration | Existing custom agents seed exactly once if enabled; manual removal persists; no hidden or unavailable target is seeded |
| Declarative configuration | Plans are inspectable, only the built-in Orchestrator sees/calls the tool, private current values stay out of tool output, approval/denial/timeout/cancellation are explicit, supported domains apply correctly, unsupported domains reject cleanly, and no secret is logged |
| Intel boundary | No test accidentally enables local MLX, sandbox, browser, computer-use, image, workspace, remote, or background targets |
| Build and architecture | Intel package/build passes for x86_64 with macOS 13 deployment; tests do not rely on Apple-Silicon-only APIs |

The full upstream subagent suite is not an Intel pass criterion by itself. Tests
that require excluded upstream managers, local MLX, sandbox, or absent session
infrastructure must be ported into Intel-specific tests or recorded as unavailable.

## Rosy Ventura manual checklist

These checks are also included in the canonical end-of-roadmap
[`ROSY_FINAL_ACCEPTANCE_CHECKLIST.md`](ROSY_FINAL_ACCEPTANCE_CHECKLIST.md). Keep
both documents synchronized when the Orchestrator contract changes.

Run this only with an isolated Intel build and a disposable test account/agent.
Do not use the current upstream app as the comparison target.

1. Launch with existing Intel data. Confirm the built-in Orchestrator keeps its
   identity, prompt, model inheritance, and generation defaults; confirm existing
   custom agents keep their names, models, avatars, order, themes, and tool/
   memory/Knowledge settings.
2. Open Orchestrator, edit its identity and generation fields, quit, relaunch,
   and confirm every value persists without changing custom agents.
3. Change the Orchestrator model, start a new chat, and confirm the selected
   cloud model is used. Restore defaults and confirm inheritance returns.
4. Start an existing chat and a new chat after changing the Orchestrator prompt;
   confirm the documented live-session invalidation behavior and that no stale
   prompt/model silently survives.
5. Confirm every unavailable target is labelled with its Intel dependency and has
   no dead switch, blank action, or selectable fake model.
6. Use one disposable admitted custom agent with an admitted remote model. Verify
   the manual sheet, Ask pauses for approval, Deny prevents execution, Always
   Allow is scoped to the exact target, cancellation stops the child, limits stop
   over-budget work, the result is bounded inline text, and no child tool, durable
   session, background continuation, or model-owned spawn appears.
7. Remove a permitted target or tool, relaunch, and verify removal persists and
   the target/tool cannot be used by a fresh session. Verify the documented result
   for an already-open session.
8. Switch rapidly between Orchestrator, Agents, and other settings destinations;
   confirm route selection, content, focus, hover states, toggles, and text-field
   indicators remain visible on Ventura.
9. Quit and relaunch again. Confirm no data was written outside the intended
   configuration/agent stores and no unrelated live agent or chat was created.
10. Open Orchestrator → Declarative Configuration and load the current export.
    Preview it unchanged and confirm it is a no-op. Change the name or maximum
    tokens, inspect every before/after row, cancel once, then approve and apply.
    Quit and relaunch; confirm the approved value persisted and personal agents
    were untouched.
11. Create a plan, change the same Orchestrator setting elsewhere, then try the
    old plan. It must reject the stale approval without overwriting the newer
    value. Confirm a second use of one approval is also rejected.
12. Confirm `{"version":1,"agents":[]}` is rejected as unsupported and an
    `api_key` field is rejected without displaying its value. Confirm the ordinary
    `max_tokens` field is accepted; token limits are configuration, not secrets.
13. In a new built-in Orchestrator chat, confirm `orchestrator_config` is visible.
    Confirm a custom-agent chat and an unbound tool request cannot see or execute
    it.
14. Ask the Orchestrator to plan a supported change. Confirm the tool result lists
    changed paths and fingerprints without revealing the current private prompt or
    other before-values.
15. Ask it to apply the plan. Confirm the review card appears only in the chat that
    requested it, shows the exact local before/after values, and has only Apply and
    Cancel. Cancel once and verify nothing changed; retry, Apply, quit, and relaunch
    to verify persistence.
16. While a card is pending, change the same setting elsewhere and then Apply. The
    stale plan must fail without overwriting the newer value. Stop or close the
    originating chat during another pending review and confirm cancellation leaves
    configuration untouched.
17. Set the tool policy to Deny and confirm the call is blocked without a review
    card. Restore Ask/Auto and confirm the dedicated card still appears and offers
    no Always Allow path.

Record Rosy results separately from automated output, including macOS version,
Intel model, build identifier, data-root mode, and any screen-sharing/titlebar
conditions that could affect visual evidence.

## Completion and documentation rule

When a gate is implemented, update this plan, `FEATURE_PARITY.md`, and
`UPSTREAM_SYNC.md` in the same change with the exact product state, dependency
cluster, automated evidence, and Rosy evidence. Do not use “synced,” “reviewed,”
or “ported” as a substitute for behavior. Any new important finding, failed
assumption, compatibility constraint, dependency, changed validation command, or
Rosy result must be written into the relevant manual before the work is considered
complete.

## Gate 1–2 validation record — 2026-09-11

- Focused test suite: `DefaultAgentConfigurationStoreTests`, 3 tests passed with
  an isolated `OSAURUS_TEST_ROOT`, serial execution, and the shared storage lock.
- A first filter using the suite's display name matched zero tests. That run was
  rejected as evidence; the rerun used the test type name and executed all three.
- Intel app build: x86_64, macOS 13 deployment target, `BUILD SUCCEEDED`.
- Artifact: `build/intel-debug/Build/Products/Debug/osaurus.app`; its executable
  was inspected as Mach-O 64-bit x86_64.
- Rosy Ventura manual QA: pending. Automated build and tests do not promote the
  feature without the separate checklist evidence above.

## Gate 3 validation record — 2026-09-11

- Three independent audits of the compiled Intel target found no existing child
  result contract. The reusable seams are the Intel `ChatEngine`, immutable agent
  settings, cancellation-aware requests, and the existing background-task limits.
- Focused suite: `IntelDelegationProbeTests`, 6 tests passed, including 7
  parameterized admission denials and one request through the real Intel cloud
  adapter using an in-process HTTP fixture.
- The first worker verification stalled because its blocking test continuation
  ignored cancellation. That run was rejected; the gate was replaced with a
  cancellation-aware wait before the suite was rerun.
- A first real-adapter fixture returned SSE text to the non-streaming completion
  API and correctly failed JSON decoding. The fixture was corrected to return the
  endpoint's actual JSON completion contract; the complete suite then passed.
- Tests ran with an isolated `OSAURUS_TEST_ROOT`, explicit serial flags, and live
  configuration/agent-inventory preflight and postflight hashes. Live data was
  unchanged.
- The app rebuilt successfully for x86_64 with a macOS 13 deployment target from
  the same working tree. The dependency plugin emitted its known stale-output
  copy-denial noise during prebuild, but Xcode completed with `BUILD SUCCEEDED`
  and produced an x86_64 executable.
- Proven now: one admitted custom-agent target, one explicitly admitted model,
  fresh child session identity, standalone system/user request, no tools, one
  active child, timeout/cancellation, bounded text/inline artifact, and no parent
  mutation.
- Still later: child tools, durable child sessions, filesystem artifacts, queues,
  background continuation, and model-owned tool/spawn exposure to the Orchestrator.

## Gate 4 validation record — 2026-09-11

- M4 automated validation ran the focused configuration/runtime suite on
  `arm64e-apple-macos14.0`: 11 tests in 2 suites passed. The separate Intel app
  build targeted x86_64 with a macOS 13 deployment target and completed with
  `BUILD SUCCEEDED`. Together they cover the admitted-target checks, exact
  permission scope, Ask approval, Deny, Always Allow, one-child concurrency,
  no-tools request, input/token/output/timeout bounds, cancellation, bounded
  inline text, and no parent mutation.
- Final integration found that directly decoding malformed UUIDs, permission
  enum values, or negative bounds could discard the whole parent Orchestrator
  configuration. The decoder now preserves valid parent identity/instructions,
  drops invalid admissions, treats unknown permission as Ask, and clamps unsafe
  bounds. A focused regression covers this migration path.
- An earlier delegated documentation pass reported 13 tests in 3 suites before
  the final tree had been independently run. That claim was rejected and
  replaced with the measured 11-test result above. Documentation counts and
  build claims must come from the final integrated checkout, after the last
  production or test edit.
- The focused run used an isolated `OSAURUS_TEST_ROOT`. The live
  `default-agent.json` hash matched its Gate 4 preflight value. Live `chat.json`
  had changed at 18:00, before the final test invocation, so it is recorded as
  concurrent app-state drift rather than presented as a frozen-run comparison.
  No test-named agent or Gate 4 fixture was written to the live stores.
- The manual launcher is intentionally a one-turn sheet. It does not create or
  retain a child chat/session, enqueue work, continue in the background, write a
  filesystem artifact, or allow the model to spawn another child.
- Child tools and model-owned autonomous delegation are later dependency/backlog
  work because Intel cloud tool-loop limits are not request-scoped.
- Rosy Ventura manual QA: pending. M4 build/test results are automated evidence
  only and do not establish Ventura UI behavior, Rosy persistence behavior, or
  live-provider behavior.

## Gate 5A validation record — 2026-09-12

- Focused suite: `IntelDeclarativeConfigContractTests`, 13 tests in 1 suite
  passed with a fresh `OSAURUS_TEST_ROOT`, explicit serial execution, and the
  XCTest runner disabled. It covers strict decoding, deterministic/no-op plans,
  exact approval, stale/mismatched/replayed approval, isolated apply, unsupported
  domains, secret redaction, and strict numeric values.
- Review found that the first persistence adapter updated its in-memory cache
  before writing and then reloaded that cache for verification. A disk failure
  could therefore look successful. The checked path now writes atomically first,
  updates the cache only after success, and verifies by decoding fresh disk bytes.
- The initial secret-key detector treated every field containing `token` as a
  credential and rejected the legitimate `max_tokens` setting. Secret detection
  now uses exact credential names and credential-specific suffixes. Keep a
  positive `max_tokens` regression whenever this detector changes.
- JSON numbers bridge through `NSNumber`, including booleans. Temperature parsing
  now explicitly rejects `CFBoolean` and enforces the existing 0...2 UI range;
  maximum output tokens enforce 1...65,536.
- The model-facing tool and chat approval card are not implemented by Gate 5A.
  They remain Gate 5B until a caller-independent approval queue exists.
- The final app build targeted x86_64 with deployment minimum macOS 13.0 and
  completed with `BUILD SUCCEEDED`. The `swift-secp256k1` prebuild plugin again
  emitted its known copy-denial noise against stale generated outputs; the final
  Intel sources compiled and linked, but this dependency warning remains build
  hygiene to resolve rather than evidence to suppress.
- Rosy Ventura manual QA: pending. The checklist above is the promotion evidence;
  M4 tests and an x86_64 build do not establish Rosy UI or persistence behavior.

## Gate 5B validation record — 2026-09-12

- M4 focused validation executed 23 tests in 3 suites: 13 Gate 5A contract tests,
  5 approval-queue tests, and 5 model-tool tests. They cover strict planning and
  apply, exact approval and persistence, stale/replay rejection, cancellation and
  timeout, built-in-only registry/dispatch scope, private plan output, denial, and
  session-scoped review-surface ownership.
- The first filtered Gate 5B run reported success while executing zero tests
  because the test files repeated the production-only `OSAURUS_INTEL` guard. The
  guards were removed and the zero-test result was rejected. Test counts must be
  read from the executed suite summary, not inferred from a successful build.
- A first multi-window hardening edit used SwiftUI's two-value `onChange`, which is
  macOS 14-only. Compilation against the macOS 13 deployment target rejected it.
  The card now remounts by session identity using Ventura-compatible APIs, and the
  complete 23-test suite passed afterward.
- The model receives changed paths and fingerprints only. Existing prompt and
  configuration values remain local to the review card. Model-readable export was
  deliberately omitted because returning those current values would expose them
  to the selected provider before the user could review the disclosure.
- The final Rosy deploy build completed with `BUILD SUCCEEDED`; the signed app
  contains a thin Mach-O x86_64 executable, declares macOS 13.0 minimum, and has
  `OsaurusCanonicalData = true`. Rosy Ventura manual QA remains pending and the
  feature stays Partial until checklist items 13–17 are recorded on Rosy.
