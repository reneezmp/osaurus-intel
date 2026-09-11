# Orchestrator on Intel — implementation plan and focused test contract

**Status (2026-09-11):** Gates 1–2 are implemented in the Intel fork: the built-in
Orchestrator has a persistent configuration store, a real settings route, and
effective model/prompt/generation routing in the Intel chat runtime. Delegation
remains dependency-blocked pending the Gate 3 measured spike. Rosy Ventura QA is
still pending.

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

After a passing spike, port the smallest real text path: allowed custom agents and
explicitly admitted cloud models, one-model residency at a time, bounded turns,
tokens, time, and concurrency, cancellation, permission modes, target tool policy,
and text/artifact return. Keep the dispatcher separate from settings and preserve
the Intel chat engine’s ownership boundaries.

The default spawn pool, same-turn activation, artifact pass-through, and model
override behavior from `679ba750` and later commits are follow-up contracts. Each
must have a test before being exposed. Do not seed hidden targets or silently add
all existing agents to a runnable pool.

### Gate 5 — declarative configuration plane

Port the configuration manifest, planner, applier, approval queue, schema references,
secret references, document decoding, tool, and approval card only after the
underlying Intel stores and mutation APIs exist. Configuration plans must show the
intended changes before applying them, preserve approval semantics, and reject
unsupported domains. No plan may claim to configure a backend that Intel does not
compile.

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
| Delegation spike | Parent/child isolation, prompt and tool-policy transfer, result return, artifact return, timeout, cancellation, and parent-resume behavior are observable |
| Delegation budgets | Token, turn, time, and concurrency ceilings stop work deterministically; denied and always-allow modes behave distinctly |
| Tool policy | Child receives only its allowed tools; removing a tool affects fresh and existing sessions according to the documented invalidation contract |
| Spawn-pool migration | Existing custom agents seed exactly once if enabled; manual removal persists; no hidden or unavailable target is seeded |
| Declarative configuration | Plans are inspectable, approval is required before mutation, supported domains apply correctly, unsupported domains reject cleanly, and no secret is logged |
| Intel boundary | No test accidentally enables local MLX, sandbox, browser, computer-use, image, workspace, remote, or background targets |
| Build and architecture | Intel package/build passes for x86_64 with macOS 13 deployment; tests do not rely on Apple-Silicon-only APIs |

The full upstream subagent suite is not an Intel pass criterion by itself. Tests
that require excluded upstream managers, local MLX, sandbox, or absent session
infrastructure must be ported into Intel-specific tests or recorded as unavailable.

## Rosy Ventura manual checklist

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
6. If the cloud/custom-agent spike has passed, use one disposable custom agent:
   verify Ask pauses, Deny prevents execution, Always Allow behaves as configured,
   cancellation stops the child, limits stop over-budget work, and the parent
   receives the result/artifact and resumes with its own settings.
7. Remove a permitted target or tool, relaunch, and verify removal persists and
   the target/tool cannot be used by a fresh session. Verify the documented result
   for an already-open session.
8. Switch rapidly between Orchestrator, Agents, and other settings destinations;
   confirm route selection, content, focus, hover states, toggles, and text-field
   indicators remain visible on Ventura.
9. Quit and relaunch again. Confirm no data was written outside the intended
   configuration/agent stores and no unrelated live agent or chat was created.

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
