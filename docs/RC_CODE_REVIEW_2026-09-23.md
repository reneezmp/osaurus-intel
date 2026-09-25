# Release-candidate code review — 2026-09-23

Scope: the accumulated Intel/Rosy changes reviewed at candidate `1.0.48` build
`49` and resolved in `1.0.49` build `50`, including Knowledge grants/cards,
Ventura controls and Settings chrome, Agent General/Appearance,
Abilities/Tools, and Automation.

## Verdict

**CLEARED WITH MANUAL GATES — `1.0.49` build `50` resolves the code-review
findings and may proceed to the cumulative Rosy checklist.** Build `49` remains
superseded and must not be deployed.

## Findings

### P1 — Self-scheduling is presented as functional but its Intel tools are absent

`AgentsView` exposes an enabled Self-scheduling toggle and says the agent can
choose its next run. The Intel `ToolRegistry` registers Knowledge, Web Search,
and Orchestrator tools only. `SchedulerTools.swift`, which defines
`schedule_next_run`, `cancel_next_run`, and `notify`, is excluded from the Intel
target.

The new regression proves only the denial boundary: when Self-scheduling is
off, those schemas are absent and dispatch rejects a stale call. When the agent
is changed to Ambient, `effectiveSelfSchedulingEnabled` becomes true but the
three tools are still unavailable. The shipped toggle is therefore a dead or
misleading control.

Release resolution must be one of:

1. Port and register an Intel-safe implementation of all three tools, then add
   positive schema and execution tests; or
2. render Self-scheduling as explicitly unavailable on Intel and prevent the UI
   from persisting an enabled state.

Conventional user-authored schedules and folder watchers use separate manager
paths and are not blocked by this missing model-callable tool bridge.

**Resolved in build 50:** both Self-scheduling surfaces now render an explicit
unavailable explanation with no toggle or mode picker. Intel's effective policy
returns false even for legacy enabled records, and regression coverage confirms
that those records cannot advertise scheduler schemas. No user data is silently
rewritten.

### P2 — Rosy build metadata has unsafe implicit defaults

`scripts/build/build_rosy.sh` defaults `VERSION=1.0` and `BUILD_NUMBER=1` when
the caller omits them. The current ZIP was invoked with explicit `1.0.48` / `49`
and validates correctly, so the artifact is not mislabeled. The default remains
a future release hazard: an otherwise successful build can silently regress its
bundle version. Require explicit values or derive validated project values
before the next promoted build.

**Resolved in build 50:** the build script now fails before Xcode unless both
values are supplied and validates the version shape and positive integer build
number. The fail-fast path and the explicit replacement build both passed.

### P2 — Automation proof remains integration-limited

The 16 focused Automation tests cover schedule anchoring, fresh/reattached
folder mounting, mocked assistant completion, and ability policy. Swift Testing
reported an arm64e macOS 14 host even when invoked through `arch -x86_64`.
These tests do not exercise Rosy's x86_64 FSEvents, real provider completion,
bookmark restoration, file-tool access, or manager CRUD persistence. Section 7
of `ROSY_2026-09-22_AGENT_GENERAL_RETEST.md` correctly retains those as manual
promotion gates.

## Reviewed areas without a release-blocking finding

- Knowledge grant publication, persistence boundary, independent Knowledge
  admission, card/category rendering, edit reachability, and shared deletion
  confirmation.
- Chat-local versus agent-default model ownership, Claude configuration, custom
  avatar refresh, and Delete Agent Data scope.
- Settings frame-root traffic lights, chat native-parent traffic lights,
  inactive-window appearance, lifecycle repair, and the custom Core Model
  selector. Rosy has already accepted this chrome split.
- Live Tools-master/allowlist/Web Search/Knowledge denial boundaries.
- Direct schedule/watcher card action buttons, destructive confirmation, and
  background folder propagation plumbing.
- Rosy archive architecture, minimum OS, canonical data root, signing,
  framework symlinks, and ZIP integrity.

## Required pre-Rosy gate

- [x] Resolve P1 and add a positive test or an explicit unavailable-state test.
- [x] Harden build-version input before producing the replacement artifact.
- [x] Rerun focused nonzero-count suites.
- [x] Build and validate a new x86_64 candidate; do not reuse build `49`.
- [x] Update the cumulative checklist and this verdict with the new artifact.

All five code-side gates are complete for `1.0.49` build `50`. Validation:

- 38/38 General/Abilities/Automation focused tests pass.
- 8/8 Ventura rendering tests pass.
- Thin x86_64 build, macOS 13.0 minimum, canonical `~/.osaurus`, signature,
  six framework symlinks, and ZIP integrity validate.
- Artifact: `Osaurus-Intel-Reviewed-Automation-2026-09-23.zip`
- SHA-256: `c052d760f7d92f3f7926192098fa44952ed3833229373639b74d262f6a1e2861`
