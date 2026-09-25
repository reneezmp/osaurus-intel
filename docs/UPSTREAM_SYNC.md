# Upstream → Intel Sync Ledger

> [!WARNING]
> This document tracks **commit coverage**, not product parity. “Reviewed” means
> a commit received a verdict; “ported” may mean only an Intel-relevant slice;
> and “current” means the range is classified. Before any new upstream analysis,
> read [`FEATURE_PARITY.md`](FEATURE_PARITY.md) and update its feature-level
> states. Excluded, absent, large, or conflicting code must still be evaluated
> for an Intel hand port or dependency backlog.

> [!CAUTION]
> Upstream-sync and repair validation must follow
> [`TEST_STORAGE_SAFETY.md`](TEST_STORAGE_SAFETY.md). Tests that touch
> path-backed stores can otherwise write fixtures into live `~/.osaurus` data
> when process-global storage overrides race across suites. Use an isolated test
> root, the shared storage lock, an explicit serial full-suite run, and live-data
> preflight/postflight checks.

**Base commit:** `d0782cbb` (Pin vMLX main runtime and harden server boundaries, #1201)  
**Intel fork:** `github.com/reneezmp/osaurus-intel` (`intel-fork`)  
**Upstream:** `github.com/osaurus-ai/osaurus` (`main`)  
**Last synced upstream commit:** `7e109ade` (cold-load retry ownership, #2668)
**Upstream version era:** `0.24.7` (`0.24.7-24-g7e109ade`)
**Last sync date:** 2026-09-07
**Last full upstream audit:** `a4daf94c4` (2026-09-25; 171 commits after the last synced checkpoint)
**Commit-coverage status:** 🟢 **Classified through `a4daf94c4`**, but **synced only through `7e109ade`**. This does not claim feature parity or that any newly classified work shipped. The previous 53-commit batch after the 0.24.3 checkpoint received verdicts and applicable Intel slices were hand-ported; the new range is an assessment and backlog. Intel releases: 1.0.20 (cache + Ventura layout), 1.0.21 (0.19.15→0.20.0 absorb), 1.0.22 (deferred shelf), 1.0.23 (0.20.0→0.20.3 sync), 1.0.24 (global proxy batch), … 1.0.34 (Projects).

---

## 2026-09-25 — Full upstream feasibility audit through `a4daf94c4`

Fetched `upstream/main` and classified every commit in
[`7e109ade6..a4daf94c4`](https://github.com/osaurus-ai/osaurus/compare/7e109ade6...a4daf94c4):
**171 of 171**, in ancestry order. The complete per-commit evidence, Intel
slice, dependency, and verdict are in
[`UPSTREAM_AUDIT_2026-09-25.md`](UPSTREAM_AUDIT_2026-09-25.md). Counts: 40 Port,
37 Stage, 24 Split, 2 Covered, 5 Superseded, and 63 Omit. A Stage verdict
means feasible after named Intel dependencies, not rejected. An Omit verdict
requires a specific product reason, generally upstream-only MLX/vMLX runtime,
arm64 release metadata, or optional telemetry/marketing.

The near-term implementation queue is MCP argument and canonical-name safety,
chat-history migration, schedule slot accounting, Core Model fallback,
theme/attachment/window fixes, and remaining hosted-model catalog/profile
work. Rich folder formats, native Apple app tools, n8n/Channels, Workspaces,
native subagents, and computer use remain feasible staged projects with
explicit backend and Ventura gates. Their product states and order are in
[`FEATURE_PARITY.md`](FEATURE_PARITY.md) and
[`INTEL_AGENT_SETTINGS_BACKLOG.md`](INTEL_AGENT_SETTINGS_BACKLOG.md).

This audit did not port code, build a new candidate, or change Rosy's current
`1.0.52` (`53`) acceptance state. The targeted DeepSeek update immediately
below remains the only implemented slice from the new range.

---

## 2026-09-25 — DeepSeek hosted V4.1 Flash slug update

Reviewed upstream through `535ea3557` specifically for the latest DeepSeek
hosted-model implementation. Commit `a0aaa945d` records DeepSeek's 2026-09-10
rename of hosted V4.1 Flash from the retired `deepseek-v4-flash` alias to
`deepseek-flash`; `deepseek-v4-pro` remains unchanged. This is a targeted port,
not a claim that all intervening upstream commits have been classified.

Intel now recognizes `deepseek-flash` as the DSV4 family so its reasoning
profile and remote `thinking: {"type":"disabled"}` translation remain active
for the direct/instruct rail. The DeepSeek provider description, Intel chat
fallback catalog, local OpenAI-compatible `/models` response, and title-model
fallback advertise the new hosted slug. Matching for the retired V4-prefixed
form remains intentionally supported for local bundles and saved historical
configuration; AtlasCloud's provider-specific model id is likewise unchanged.
Focused compiled registry tests cover the versionless and provider-qualified
slugs, the unchanged Pro slug, negative DeepSeek V3/chat cases, and the preset
description. The upstream reasoning-policy test was also copied for parity,
although that upstream-only service/suite is excluded from Intel's package
target; Intel's compiled cloud engine already applies the same DSV4 request
translation directly.

Validation passed the focused `IntelDeepSeekHostedModelTests` suite (2 tests)
and an explicit `swift build --package-path Packages/OsaurusCore --arch x86_64`.
The build emits the repository's existing warnings, but no new error. A
residual-source audit leaves `deepseek-v4-flash` only in backward-compatible
local/model tests, a local-server diagnostic comment, and AtlasCloud's distinct
provider-specific model id.

**Rosy result, 2026-09-25:** build `1.0.52` (`53`) passed all four hosted
DeepSeek checks: current Flash/Pro catalog, direct/instruct versus reasoning
rails, Pro replies, and saved/local V4 compatibility. This accepts the
DeepSeek slice only, not the rest of `a0aaa945d` or the 171-commit audit range.
The same candidate still has open Qwen Memory, live stale-tool-call, and
Orchestrator acceptance gates, recorded in
[`ROSY_2026-09-24_RC_RETEST.md`](ROSY_2026-09-24_RC_RETEST.md).

---

## Test-storage isolation incident (2026-09-10)

Agent Settings runtime tests initially saved the global chat configuration while
other suites changed the process-wide storage root. Cross-suite concurrency let
cleanup write a sparse fixture into the live chat configuration and leave one
test agent behind. The live model and tool-attempt fields were recovered from
the preceding application log, the test agent was inspected and removed, and
the affected tests were changed to use disposable agents and the shared storage
lock.

The definitive validation used explicit `--no-parallel --disable-xctest` and
passed **902 tests in 131 suites**. The incident, guardrails, and residue checks
are recorded in [`TEST_STORAGE_SAFETY.md`](TEST_STORAGE_SAFETY.md). A green test
count is not accepted as complete validation unless live storage is also proven
unchanged.

---

## 2026-09-12 — Credits/Router Gate C1

Upstream review had established that hosted inference and the first Credits
screen existed on Intel, but it had not established modern Credits/Router or
Premium Search parity. The new `CREDITS_ROUTER_INTEL_PLAN.md` records the full
dependency chain and forbids treating commit coverage as product coverage.

Gate C1 adds a real persisted Router master switch to the compiled Intel
manager. Turning it off removes the managed Router provider and catalog,
clears cached account state, suppresses Credits polling, and shows an honest
off state after a confirmation. Turning it on reconnects. Top-up conversion is
now bounded before converting to `Int`, closing an upstream overflow trap.

Premium Search remains absent. Unlike upstream's free-only default behavior,
the Intel fork requires explicit Premium opt-in and keeps wallet auto-pay as a
second independent setting. Router enabled alone is never paid-search consent.

Focused M4 validation passed 2 tests in one suite. The signed canonical x86_64
Rosy build succeeded with macOS 13.0 minimum. C1 remains Partial until Rosy
Ventura validates persistence, model removal/restoration, and zero account
traffic while disabled.

Every important implementation or test discovery must update the owning plan,
feature-parity table, sync log, and final Rosy checklist in the same change.
These manuals are part of the product contract, not a retrospective extra.

## 2026-09-12 — Credits/Router Gate C2

The credit-unit, redeem-code, and account-detail portions of upstream commits
`6ecd2133`, `89ccb249`, and `757807f9` were re-evaluated as product behavior,
then hand-ported against the Intel Router contracts. Balances, model prices,
usage, and wallet activity now display credits; Checkout keeps the dollar
charge explicit. The Credits page can redeem a bounded code through a signed
request and presents typed, redacted error states. Its account center summarizes
the existing `/usage` and `/credits/transactions` responses without introducing
an unproven Insights link.

The upstream onboarding/welcome-credit coordinator was not copied: Intel does
not yet have that dependency, and silently coupling it to this page would turn
commit coverage into another false parity claim. It is recorded as backlog work
to link after the coordinator exists. A compile pass caught and corrected an
invalid combined Swift switch pattern before focused validation; the final C2
set passes 8 tests in 4 suites. The Rosy build succeeds as x86_64 with macOS
13.0 minimum and applies the configured signing identity. M4 strict trust
verification reports `CSSMERR_TP_NOT_TRUSTED`; Rosy launch remains the signing
and product promotion gate.

## 2026-09-12 — Credits/Router Gate C3 Premium Web Search

Selectively ported the product contract from upstream `d16b06763`: signed
hosted search and contents, web settings/usage, typed fallback and availability
backoff, and billing metadata. The Intel fork deliberately differs by keeping
Premium Search off until explicit consent and keeping wallet auto-pay as a
second setting. Router availability alone grants neither permission.

The upstream audit exposed a wire detail that source-presence review had missed:
the same idempotency key belongs in both the canonical signed JSON body and the
`Idempotency-Key` header. Focused tests now inspect both for `/v1/search` and
`/v1/contents`. Settings Try It and agent tools share one hosted-first seam;
provider credential tests remain native and pinned. Direct URL extraction runs
the existing private-address/DNS preflight before disclosing a URL to the Router,
then falls back locally once. Hosted redirect safety remains a server dependency
because the local client never follows those redirects.

An accounting review also caught optimistic wallet subtraction for included
requests. Only responses explicitly marked `paid` may now reduce the displayed
balance. Focused M4 validation passes 33 tests in 3 suites. C3 stays Partial
until the x86_64 candidate and real Router behavior pass Rosy Ventura.

## 2026-09-13 — Rosy acceptance retest, sections 1–3

The second Agent Settings acceptance pass materially changes the diagnosis from
2026-09-10. Existing agents now preserve their configuration, display and call
their stored models, reset to inherited defaults, and survive relaunch. Custom
avatar upload/removal and per-agent themes also work. Toggle colour and tab hover
feedback are repaired. These are observed Rosy Ventura results, not inferred
from Codable or M4 tests.

Four defects remain. First, changing the model in a fresh chat also rewrites the
agent's configured model, so chat-local selection and agent defaults are still
incorrectly coupled. Second, Ventura text fields still hide insertion carets,
and several controls use white labels on white backgrounds; the Add Knowledge
Collection sheet is operable only as a blind workflow. Third, no discoverable
Claude Code panel exposes Agent/Text mode or file/shell permissions. The source
contains that panel behind Claude model recognition, so its absence may be a
picker-id/conditional-rendering failure. The source also declares Delete Data
under General → Configure for non-built-in agents, but Rosy shows no visible
button for a disposable custom agent; treat it as an inaccessible UI action,
not an untested backend. Fourth, a selected custom avatar
updates chat but not the Agent Settings header, proving stale presentation state.

Native traffic lights are also still absent. The screenshots prove the visual
failure but do not isolate its owner because the test record does not yet state
whether screen sharing or recording was active; preserve that uncertainty when
repairing the titlebar. Future fixes must be tested on Ventura with explicit
screen-sharing/recording state rather than accepted from M4 appearance alone.

## 2026-09-13 — Rosy acceptance retest, section 4

Ability persistence and several broad gates now have real Ventura evidence:
whole-agent Tools off/on works for fresh and restored chats, Knowledge access is
blocked without losing assignments, Web Search tools follow their toggle, and
the picker/search/provider controls persist. These passes do not establish
per-tool runtime revocation. Rosy showed a removed tool as unselected while the
open chat could still call it. Although `runtimeCapabilityDenial` declares a
live allowlist check, the observed behavior means dispatch lacks the correct
current agent context or bypasses that boundary on the failing path.

Memory produced two distinct failures with `osaurus/qwen-3-8-max`: completed
requests failed response decoding as “The data couldn’t be read because it isn’t
in the correct format,” while attempts after relaunch were skipped as
`no_model:configured_unservable:osaurus/qwen-3-8-max`. Do not collapse these
into one configuration bug. Repair and test provider/model rediscovery across
relaunch separately from tolerant extraction and decoding of the provider's
distillation response. Until then, Memory off/on injection and saving is blocked.

Self-scheduling is currently an Automation link in the Abilities overview, not
an ability toggle, and tested agents report no scheduling tools. Web Search's
passing gate therefore says nothing about scheduling. The source also declares
Intel-unavailable rows for Database, Computer Use, Browser Use, Spawn, media,
and AppleScript, but Rosy displayed no unavailable-ability explanation. Treat
that as a candidate UI reachability/rendering mismatch and verify the shipped
x86_64 bundle rather than claiming the declarations are user-visible.

## 2026-09-13 — Rosy acceptance retest, sections 5–7

Insights now has complete Rosy Ventura acceptance for its current Intel scope.
Ordinary chats, tool-using chats, and harmless provider failures create useful
records with the expected model, duration, request/output, token, completion,
and offered/executed-tool data. The page renders existing records. Newer
per-message diagnostics remain part of the separately deferred chat-interface
revamp and are not an Insights regression.

The Agent Connections surface also passes its Intel contract. Network, Remote
Connections, and Channels open; Bonjour state changes immediately, survives
navigation and relaunch, and matches its status text; and a second device sees
`_osaurus._tcp` only while enabled. Relay, sharing, peer grants, and Channels
remain dependency-blocked, but their cards accurately say so and expose no dead
actions.

Automation remains Partial. Rosy can create and persist a schedule and observe
the next-run banner, but neither schedule nor watcher cards expose the ellipsis
menus that source code declares. Edit, run-now, pause/resume, and delete are
therefore unreachable in the shipped UI. The monitoring-mode picker is still
unreadable on Ventura. More seriously, both scheduled and watched runs lose the
assigned folder in the created chat despite `DispatchRequest` carrying
`folderPath` and `ExecutionContext` declaring Intel folder activation. A watcher
also created and persisted the user turn without generating an assistant reply.
Treat folder activation and background generation completion as separate runtime
failures; do not infer either from successful session creation.

## 2026-09-13 — Rosy acceptance retest, sections 8–10

Agent Memory's navigation and dependency boundary pass: Recent Chats and New
Chat retain the agent, all Database subtabs preserve navigation, and the absent
Intel database backend is explained without fake mutation controls. Pinned-fact,
episode, and compact-empty-state acceptance remains blocked by the existing
distillation regression. Do not record those as independent rendering failures
until Rosy can generate or load trustworthy distilled data again.

The reorganized Settings sidebar passes Rosy Ventura acceptance at narrow,
normal, and full-screen widths, including section and row ordering, counters,
selection, scrolling, the unavailable Intel group, persistent Developer Tools
reveal state, and Check for Updates.

Native Web Search passes its complete Intel acceptance set: default-off agent
gating, keyless built-ins, web/news/image categories, provider lifecycle and
secret handling, fallback/cancellation, category ordering, custom providers,
safe bounded extraction, legacy-plugin suppression, and Premium consent
separation. Image hits deliberately return structured `image_url` and
`thumbnail_url` fields; the current chat shows links because it has no tool-hit
gallery. Track inline thumbnails with chat presentation work, not as a search
backend defect. Funded Router billing remains a Credits/Router acceptance item.

## 2026-09-13 — Rosy Orchestrator acceptance correction

All screenshots and observations in this acceptance sequence were captured
directly on Rosy running Ventura. They are Intel product evidence, not images of
the current upstream build on the M4.

Rosy confirms the Orchestrator settings route, persistence, reset/inheritance,
and editable model/prompt/generation routing. It does not confirm Gates 3–5B as
a usable Orchestrator: the built-in chat receives no orchestration or delegation
tools, so admission, failure, permission, bounds, cancellation, inline-result,
and target-removal contracts cannot be exercised from the product's primary
Orchestrator surface. The same entry failure blocks every manual
`orchestrator_config` check. A manual Settings delegation sheet and automated
runtime tests are implementation evidence, not proof of model-callable
orchestration.

The audit also found two concrete upstream omissions. Upstream's `Agent.default`
sets `avatar: "green"`; Intel does not. Upstream prepends a substantial built-in
role through `DefaultAgentSystemPromptBuilder`, covering configuration reads and
writes, same-turn action, approval, secrets, and specialist delegation. That file
is compiled out under `OSAURUS_INTEL`, while Intel's replacement composer appends
no equivalent and therefore sends only the editable prompt. Rosy also reports
missing assistant message footer actions and statistics in Orchestrator chat;
track that with the broader chat presentation regression while verifying the
Intel footer-synthesis path.

## 2026-09-13 — Owner acceptance scope boundary

Renée completed direct Rosy acceptance for Native Web Search, the feature in the
later roadmap set she actively uses. She explicitly declines sole responsibility
for exhaustive manual testing of Credits/Router, Channels, Browser Use, Computer
Use, cloud Media, Privacy, and the deferred Chat/Workspaces revamps. Those areas
remain available for future-user and contributor field reports. Unchecked cases
mean untested under this owner scope; they are neither observed failures nor
evidence for **Working and tested** status.

## Settings sidebar parity (2026-09-11)

The Intel sidebar follows upstream's section sequence and row ordering for every
settings surface that exists in this fork: General, Models, Agents,
Capabilities, Automation, and Developer Tools. Developer Tools uses upstream's
persistent reveal switch. Do not add working-looking rows for roadmap features
before their settings surfaces exist. Local Models, Voice, and Sandbox remain
disabled together under **Not Available on This Mac**, immediately before the
Developer Tools footer section, so the upstream organization stays recognizable
without misrepresenting Intel support.

The Orchestrator chain is documented as an Intel dependency-ordered plan and
focused test contract in [`ORCHESTRATOR_INTEL_PLAN.md`](ORCHESTRATOR_INTEL_PLAN.md).
Intel Gates 1–4 provide persistent built-in configuration, a real settings route,
effective runtime model/prompt/generation resolution, and a manual one-turn
delegation sheet. Gate 5A adds a Settings-owned declarative planner/applier for
the existing `default_agent` and `delegation` stores. Gate 4 admits only explicitly selected custom agents and remote
cloud models; Ask/Deny/Always Allow is scoped to the exact launcher/target pair;
the child is fresh, one-turn, one-at-a-time, tool-free, bounded by input/tokens/
output/timeout, cancellable, and returned as inline text. M4 automated validation
and the x86_64 build are recorded separately from pending Rosy Ventura QA.
Child tools and model-owned autonomous delegation remain later dependency/backlog
work because Intel cloud tool-loop limits are not request-scoped.

## 2026-09-12 — Intel Orchestrator declarative configuration Gate 5A

Upstream's broad configuration plane was not transplanted. Intel exposes strict
version-1 JSON for two compiled, durable domains only: `default_agent` and
`delegation`. Orchestrator Settings exports the current slice, previews a
deterministic before/after plan, asks the user to approve that exact plan, rejects
stale/mismatched/replayed approval, writes atomically, and verifies fresh disk
bytes. Unknown domains, secret-shaped keys, and secret references fail before
mutation. Other upstream domains stay in their owning backlog until their stores
and approval contracts exist.

Two implementation traps are now part of the sync contract. Persistence
verification must bypass caches: the first adapter cached requested state before
the disk write, which could make a failed save look verified. Secret detection
must distinguish credentials from ordinary limits: a broad `token` substring
check incorrectly rejected `max_tokens`. JSON numeric decoding must also reject
bridged booleans explicitly.

This is Gate 5A, not the model-facing half of upstream parity. A callable tool and
chat approval card remain Gate 5B because they require a caller-independent,
user-owned approval queue. Never expose the Settings receipt-minting method to a
model as a substitute for that boundary. Focused M4 validation passed 13 tests in
one suite with isolated storage. The final app compiled and linked for x86_64 with
minimum macOS 13.0; the known `swift-secp256k1` stale-output copy-denial prebuild
noise remains visible and tracked. Rosy Ventura acceptance remains pending.

## 2026-09-11 — Bounded Intel Orchestrator Gate 4

Gate 4 is implemented as the smallest user-facing text path. The manual sheet
requires explicit admission for both the custom-agent target and its remote model,
rechecks availability before dispatch, and persists the exact target-pair
permission choice. It supports Ask, Deny, and Always Allow, with Ask producing a
per-run approval. The runtime creates one fresh child request, suppresses child
tools and nested spawning, permits one active child globally, enforces input,
token, output, and timeout limits, handles cancellation, and displays a bounded
inline result.

This is Partial product parity until Rosy Ventura validates the built UI and live
behavior. No durable child session, filesystem artifact, queue, background
continuation, or model-owned spawn is claimed. Child tools and model-owned
autonomous delegation stay in the later dependency/backlog because Intel cloud
tool-loop limits are not request-scoped.

---

## Rosy titlebar-control report (2026-09-11)

A screenshot appeared to show missing close, minimize, and zoom controls on Rosy.
The first M4 reproduction attempt was invalid: macOS placed its screen-sharing
indicator directly over the traffic-light area, and the app under inspection was
initially a current upstream build rather than the Intel fork. Accessibility still
reported all three standard controls in the isolated Intel build, but that does
not prove their appearance on Ventura. Do not infer a titlebar regression or land
a speculative fix from a captured screenshot. Validate directly on Rosy with
screen sharing stopped, then record the Ventura result and any confirmed cause.

---

## Post-sync restoration: Knowledge and the full Project page (2026-09-08)

The two deferrals recorded below are now resolved. Intel Knowledge is a real,
local collection registry and encrypted semantic index, backed by the same
pure-Swift embedding path already proven by Memory. Projects now expose the
upstream-style split page with shared instructions, selectable Knowledge
collections, a default agent, shared memory preview/deep-link, and a working
folder inherited by new chats.

Working folders are owned by each chat, persisted in its session JSON, and
resolved through a task-local root during tool execution. This matters for
multi-window safety: choosing a folder in one chat cannot silently redirect
another chat's file tools. Claude Code also receives the active chat folder as
its process working directory. Project recall is additive to agent-scoped
personal recall; project transcripts and distilled episodes continue to build
when personal memory is disabled for that agent.

Validation at this checkpoint: the package build passed, and **793 tests in
120 suites** passed, including concurrent working-folder isolation and legacy
project/session decoding. The signed canonical x86_64 Rosy workspace build also
passed and produced the deployable app.

---

## Sync 0.24.3 → 0.24.7 (2026-09-07)

**Range:** `4528b56f..7e109ade` — **53 commits**. Deterministic exclusion triage produced
33 review candidates, 8 new-subsystem-only commits, 5 infrastructure-only commits,
5 release/docs-only commits, and 2 excluded-only commits. The 33 survivors were read
individually; the complete ledger is
[`UPSTREAM_TRIAGE_0.24.7.md`](UPSTREAM_TRIAGE_0.24.7.md).

**Ported:** the Full Disk Access system-TCC/SQLite-header probe pair; Claude split-export
index and batch-ZIP import guidance; project-aware New Chat; ⌘B sidebar and next-agent
shortcuts; folder-chip accessibility; metadata-only session hydration; UTF-8 token
estimation; and the lock-backed tool-configuration quit drain. The CLI launch fallback
also now waits for the application process instead of mistaking cold server startup for
a failed launch.

**Deferred at this checkpoint (subsequently resolved above):** project folders needed
per-chat folder ownership before they could be safe on Intel, and clickable Knowledge
links waited for the local-first Knowledge milestone. The browser-tab/history shell is a
larger reconciliation with the Intel Projects and toolbar structure. Local vMLX/MTP,
local-model residency, upstream
agent-loop/delegation, sandbox, skill mutation, and upstream appcast changes remain skips.

As in the previous sync, every useful change was hand-ported. No upstream commit was
cherry-picked wholesale.

**Validation:** `swift test --no-parallel` passed **715 tests in 107 suites**;
`swift build --arch x86_64` passed; and the unsigned x86_64 workspace build passed
with deployment target macOS 13.

---

## Completed sync: 0.20.3 → 0.24.3 (triaged 2026-09-02, implemented 2026-09-02/03)

**Range:** `9124d696..4528b56f` — **783 commits**, upstream `0.20.3` → `0.24.3` (+17 untagged).
**Status: Waves A–E are ported and committed on `sync/0.24.3` / `intel-fork`; nothing is released
yet.** See *Sync execution log* at the end of this section. The triage below is what the work was
planned from; the staged execution plan lives in
[`SYNC_0.24.3_PLAN.md`](SYNC_0.24.3_PLAN.md), and the full per-commit verdict table (all 476
reviewed commits) is in [`UPSTREAM_TRIAGE_0.24.3.md`](UPSTREAM_TRIAGE_0.24.3.md).

**Shape of the work (decided 2026-09-02): three releases.**

| Release | Contents |
|---|---|
| `1.0.32` Stabilize | keychain + Router hotfixes, then the Sentry crash/hang set |
| `1.0.33` Modernize | fast-forward the 52 PORT-touched pristine files, then proxy + MCP |
| `1.0.34` **Projects** | `8a9d32ea` rebuilt against the Intel mirrors, then the rest of chat QoL |

Backlogged: `311d9095` (storage encryption — gated on root-causing Rosy's `hmac` decrypt error)
and the 61-commit deferred shelf (re-triage after 1.0.34).

### How this triage was produced

A deterministic classifier (not judgment) first eliminated **307 of 783** by parsing the
164-path `exclude:` list straight out of `Packages/OsaurusCore/Package.swift` and intersecting
it with each commit's touched files:

| Auto-bucket | Count | Rule |
|---|---:|---|
| IGNORE | 92 | docs / `.github` / appcast / `.xcstrings` / evals only |
| NEW-SUBSYSTEM | 90 | touches **only files absent from the fork** — brand-new upstream subsystems |
| INFRA-ONLY | 76 | only `Package.resolved` / `Package.swift` / xcworkspace — vmlx repin churn |
| SKIP | 49 | every touched file is on the `exclude:` list |
| **REVIEW** | **476** | touches ≥1 file the Intel target actually compiles |

The 476 survivors were then split into 5 chronological windows and judged individually.

### Verdict totals (476 reviewed)

| Verdict | Count |
|---|---:|
| ✅ PORT | **211** |
| ⛔️ SKIP | 204 |
| ⏸️ DEFER | 61 |

| Window | Upstream range | Tags | PORT | SKIP | DEFER |
|---|---|---|---:|---:|---:|
| W1 | `b8ef10aa..3bee1703` | 0.20.3 → 0.21.0 | 52 | 32 | 12 |
| W2 | `f09b2123..a15efa73` | 0.21.0 → 0.21.13 | 40 | 45 | 11 |
| W3 | `93e6394e..5bb946f7` | 0.21.13 → 0.22.9 | 26 | 61 | 9 |
| W4 | `d417cdf9..c4d9d140` | 0.22.9 → 0.22.20 | 57 | 29 | 10 |
| W5 | `4e2bcb03..e03127e7` | 0.22.20 → 0.24.3 | 36 | 37 | 19 |

> ⚠️ **Confidence caveat.** The per-commit verdicts are a **first-pass triage by small models**,
> not a review. They are a map of where to dig, not an authorization to cherry-pick. Verify each
> commit against fork reality before it lands. Known first-pass errors already corrected:
> Product Hunt marketing dialogs (`f8b1c02e`, `67eeaf0b`) were mislabelled PORT; the
> swap-pressure banner series (`a9d2a150`, `29fedb38`, `1b58dcf9`) warns about *local model*
> RAM pressure and is meaningless on a cloud-only fork.

### Why 783 collapses to 211

Upstream spent this era building an **agent-orchestration platform**: Orchestrator + delegation,
Agent Channels (Telegram/iMessage), subagent batching, Computer Use + AppleScript, Skills,
Knowledge base, Browser Use, image/video generation, and a community model-compat leaderboard.
The fork amputates every one of those. This is not drift — it is a divergence of *purpose*.
Upstream went agentic-multiplayer; the Intel fork is sovereign cloud inference on old metal.

### The five PORT clusters

1. **Cloud provider & Router hardening** — the fork's lifeline.
   `5f12d260` (remote-provider crashes/hangs, endpoint trust, **Router spend safety**, streaming) ·
   `563f9174` (Router 409 idempotency on refunded iterations) · `6ecd2133` (credits UI dollars→credits) ·
   `89ccb249` + `757807f9` (redeemable credit codes) · `0a8c5008` (providers stuck disconnected after
   relaunch) · `577a3eee` (honor custom-provider context windows) · `4137884f` (media rejection recovery
   + OpenAI hardening) · `f9478c0f` (lenient decode for nonstandard streaming chunks during tool calls) ·
   `f01e5d44` (xAI OAuth stale catalog) · `bbad6ed9` (Fireworks only showing 6 models)
2. **Keychain & identity** — `984debe2` (harden keychain on relaunch + identity restore from recovery
   phrase) · `e06996e3` (specific keychain errors, recover ACL-denied credential saves). Directly on top
   of the fork's stable-signing-identity scar tissue.
3. **Crashes & main-thread hangs** — Sentry-triaged, generic AppKit/SwiftUI: `03ea4c93`, `c8be96cc`,
   `99537680`, `6daf54cb`, `dfd412f6`, `0d07b052` (notch display-reconfig + TextKit), `3ba84c38`,
   `2eac8d32`, `286c4a9a`, `cc6732d7`, `161e6ca5`.
4. **Chat QoL** — full-text search + ⌘F (`5ada76dc`) · Projects/chat grouping (`8a9d32ea`) · pinned chats
   (`6ae20356`) · multi-select delete/archive (`479133ba`) · auto chat titles (`5bb946f7`) + `/title`
   (`3580502c`) · import from ChatGPT/Claude/Grok (`311f327c`, `48c6d197`) · delete individual messages
   (`c4d9d140`) · ⌘N (`e0eeba12`) · ⌘± zoom (`1b955c2b`) · resizable sidebar (`035ed272`) · inline +
   display LaTeX (`f3608d88`, `8a8f01ec`) · escape-eats-your-prompt fix (`08eb8bd8`) · LLM context
   compaction (`ce414b3f`) · `96b05d20` (hide local-memory warnings for cloud models).
5. **Storage, proxy, MCP** — `311d9095` (storage encryption opt-in, 50 files — SQLCipher, handle with
   tongs) · `9ddb49b0` (migration hardening) · `304ad2bb` + `0ba6a01a` + `52d4aa9b` (global proxy) ·
   `774aa836` (MCP session recovery + OAuth single-flight) · `3f4791e7` (paginated tool discovery) ·
   `12ff17c7` (bearer 401 classification) · `f5009855` (MCP URL detection in provider form).

### Blanket SKIP (do not revisit)

Orchestrator / delegation (`8d7c3dd4` alone is a 195-file refactor), Agent Channels + Telegram +
iMessage, Computer Use + AppleScript, Skills, Browser Use, image/video generation,
every MTP / speculative-decoding / vMLX repin, the entire evals harness + community leaderboard,
Sandbox, and upstream's own marketing modals (Product Hunt, "what's new" for amputated features).

> **Not blanket-SKIP: the Knowledge base.** It was previously written off as permanently
> amputated because it needs embeddings. That is obsolete — the fork's pure-Swift model2vec
> `potion-base-8M` static embedder already runs acceptably on Rosy (it powers local semantic
> memory). Knowledge is therefore **viable on Intel and wanted**, just not in this sync. See
> the backlog in [`SYNC_0.24.3_PLAN.md`](SYNC_0.24.3_PLAN.md) §10.

### Sync execution log (2026-09-02/03)

| Commit | Wave | Result |
|---|---|---|
| `9ca6c90f` | A — keychain / Router / provider | 7 candidates → 4 partial ports, 3 dissolved to SKIP |
| `56e3a422..0680502c` | B — crashes & hangs | 11 candidates → 8 hand-ported, 3 SKIP |
| `1c84bf11` | build | `swift-secp256k1` → 0.23.2 (Swift 6.4; see the pin note above) |
| `52cf68ce` | C — pristine fast-forward | 50 selected → 33 landed, 17 reverted as coupled |
| `7b816ca5` | E′ — proxy & MCP | 8 candidates → 5 ported/partial, 3 SKIP |
| `c53a84f0` | D₀ — **Projects** + math | rebuilt against Intel mirrors; knowledge dimension dropped |
| `b1c68b3b` | D₁a — search, pinned chats, multi-select | salvaged after a rate-limit interruption |
| `2d6ee24d` | D₁b — titles, import, delete, resize, shortcuts | 9 ported, 1 declined, 1 SKIP |

**Two numbers worth carrying into the next sync:** **zero** upstream commits applied as a clean
cherry-pick — every single one needed hand-porting or reverting. And **~31%** of first-pass PORT
verdicts dissolved once checked against what the fork actually compiles. Budget for verification,
not transcription.

**Not ported, deliberately:** `ce414b3f` (LLM context compaction — ~3800 lines tied to local
warm-up and KV-cache machinery this fork lacks) and `96b05d20` (hides local RAM/swap warnings that
do not exist here). Both belong to the backlog, not to a future retry-as-is.

---

## Sync 0.20.3 → `9124d696` — global-proxy batch (2026-06-17, Session 10)

12 commits in `7901ec42..9124d696`, all the upstream "Route X through global proxy" series
(threading network calls through `GlobalProxySettings`) plus a couple of fixes. **Ported (4):**

| Upstream | Intel action |
|---|---|
| `23aaa5cc` | router API → global proxy — our `OsaurusRouterAPIClient` (uses `makeSession(base:)` verbatim) |
| `572273a8` | theme API → global proxy — `ThemesAPIClient` (`makeSession(base:)` verbatim) |
| `62755e65` | markdown image downloads → proxy — `MarkdownImageView` + `NativeMarkdownView`; mapped upstream's `sharedSession()` → our `makeSession()` |
| `17f27b4f` | sandbox-plugin manifest fetch → proxy — `SandboxPlugin.fromURL`; `sharedSession()` → `makeSession()` |

> **Proxy-API note:** Intel's `GlobalProxySettings` exposes only `makeSession()` (fresh per
> call), not upstream's cached `sharedSession()`/`currentProxyCacheKey()`. Every upstream
> `sharedSession()` consumer maps to `makeSession()` — functionally equivalent (always honors the
> current proxy), just uncached. Do NOT port `currentProxyCacheKey()`; it only serves the caching design we don't use.

**SKIP (excluded/absent/divergent):** `07ba93e1` (MCP OAuth → proxy — our MCP OAuth is divergent;
`MCPOAuthHTTPTransport`/`noRedirectSession` absent, no valid target), `6e47dfe9` (`SandboxManager`
excluded), `7dc814bf` (`RelayTunnelManager` excluded), `5621ef11` (`RemoteAgentManager` excluded),
`217c8c7d` (`PrivacyFilterModelDownloader` absent — model-download subsystem), `8247f63a`
(`GitHubSkillService` excluded), `9124d696` (`ShareArtifactTool` excluded).
**DEFER:** `395fe51e` (allow manual provider models during connection tests — needs a `manualModelIds:`
param threaded through the excluded/mirrored `IntelStubConformers.testConnection` for a niche
Azure-deployment onboarding flow; ~zero value for Intel's cloud-DeepSeek path).

## Sync 0.20.0 → 0.20.3 (2026-06-14, Session 9)

21 commits in `24924e6f..7901ec42`. **Ported (7):**

| Upstream | Intel action |
|---|---|
| `8dd49a65` | Codex OAuth diagnostic context (`ProviderNetworkDiagnostics`) |
| `4569b76f` | OAuth → global proxy — adapted `GlobalProxySettings.sharedSession()` (unported) → `makeSession()` |
| `13bb8b47` | configurable Hugging Face cache path (down-leveled the new `onChange`) |
| `ef180dd8` | local access-key lifecycle — `AccessKeyLifecycleService`; ServerView adapted (`ServerController` excluded → server is loopback-only) |
| `7901ec42` | **partial** — ChatView static `ISO8601DateFormatter` cache (main-thread alloc); `PluginRepositoryService` part skipped (excluded) |
| `6c18cb91` | **partial** — `ToolConfigurationStore` only; the ToolsManagerView tools-section hang fix needs the **unported `37a2291b` `ToolAvailability`** + a card refactor that would lose the M16 blank-gap fix |
| `bd0e196d`+`54d650ba` | `Localizable.xcstrings` full-file from upstream |

**SKIP (excluded/divergent):** `b768bbcb` (RemoteProviderService — Intel uses CloudChatEngine),
`9e390950` (PluginHostAPI), `33c41661`/`8ff06de3` (host stdio MCP → excluded `SandboxStdioRunner`),
`dee498b8` (ToolIndexService/CapabilityTools), `e5419a3b` (MLX kv-cache), `5b3c2fa6` (paste-URL — a
*fix* to a feature Intel's divergent `RemoteProviderEditSheet` never had). **DEFER:** `e8bcba8a`
(onboarding model-selection — mixed with excluded RemoteProviderManager/ToolIndexService).
**IGNORE:** 3 appcasts, `44bc8ae6` (whats-new), `ae34ca6a` (legacy storage marker).

> **Versioning note:** the fork keeps its **own** version line (`1.0.x`) — we do
> NOT peg it to upstream's number (the fork amputates whole subsystems, so a
> pegged number would imply false parity). The upstream correspondence is shown
> as *metadata* in the About panel + release notes, sourced from a single
> constant: `IntelBuildInfo.upstreamBase` / `upstreamCommit`. Keep that constant
> in lockstep with the two values above.

## Sync 0.19.15 → 0.20.0 (2026-06-14, Session 6)

95 commits in `d132b728..24924e6f`. The exclude-list amputates MLX/memory/skills/
slash-registry/sandbox/p2p, so most were SKIP. **Ported (15 substantive):**

| Area | Upstream | Notes |
|---|---|---|
| tok/s accuracy | `26573b24` | new `RollingTokenRate` (shared) |
| image context tokens | `0da56927` | `Attachment` resolution-based estimate |
| theme button colors | `0c5b4bf0` | `ThemeEditorView` |
| raw JSON theme editor | `15df6096` | new `ThemeJSONEditorCodec` + editor; resolved union with the bg-decode hang fix |
| theme-editor + watcher hang | `76a07e24` | bg image decode off-main (`decodeThemeBackgroundImage`) |
| fatal crashes | `62191278` | only `ModelMediaCapabilities` applies — PrivacyFilter is DU (Intel lacks it); `osaurusApp` kept ours |
| quit/plugin-teardown crash | `0168ff40` | `ExternalPlugin`/`DebugLog`; `AppDelegate` kept ours (excluded teardown deps), `TelemetryService` DU |
| ClipboardService main-thread hang | `f1b069de` `374e3190` `1bb474c1` | pasteboard XPC moved off-main (recurring fix; `ModelDetailView`/`ManagementBadgeStore` kept ours) |
| tool-envelope hang | `69753ad8` | `ToolEnvelope` shared; `ToolRegistry` excluded (took theirs, dead code) |
| chat-jump-on-completion | `2c4d6089` | **merged** into our Intel `handlePostSnapshotScroll` — kept our `isNewTurn`/`wasPinnedToBottom` structure, added the `isStreaming` gate |
| sidebar rename | `24a5e3e9` | sidebar UI auto-merged; the view-model sync (`session.title`/`archived`) hand-ported into Intel `ChatContentView` callbacks (chat layout is extracted on Intel) |
| visual/interaction polish | `3a4edaae` | theme polish (CustomTheme/Theme/AgentInlineBlocks) only; `FloatingInputCard` budget-tint kept ours (needs excluded `ContextBudgetManager`), `ShimmerLabel` DU dropped |
| localization | `392954aa` … `e6894ce5` | full-file `Localizable.xcstrings` from upstream (both Intel strings present) |

**SKIP (bulk):** all vMLX pins + Gemma/DiffusionGemma/MLX runtime + memory/episodes +
skills/slash-registry + WindowManager/ModelManager hang fixes (excluded) + appcasts/CI.

**DEFER (revisit in a focused session):**
- `58aab452` **hosted inference** (0.20.0 marquee) — `ContentBlock`/`ChatTurn`/`OpenAIAPI`/
  `RemoteProviderManager` mirrored/excluded; conflicts with `CloudChatEngine`.
- `a39b2d89` **p2p e2e encryption** — isolated `Identity/*` pairing; not exposed on Intel.
- `7068b131` **sandbox-by-default** — `BuiltinSandboxTools`/`SandboxToolRegistrar` excluded.
- `2a58c239` + `ae4541d4` **model-picker UX** — Intel's `ModelPickerView` diverged
  (`cachedGroupedOptions`/`groupedBySource()` vs upstream's `rebuildTabs()` tabs); reconcile later.
- `c2231910` slash command (excluded registry), `4a9a23f0` system prompts (excluded composer),
  `37a2291b`/`be43da1a` tool/MCP diagnostics (excluded deps), `3a743373` external-model-mgmt
  (Intel-kept `ModelDetailView`/`AppDelegate`), `e6b78e36` onboarding polish, `fc1626c6` whats-new.

### Deferred-shelf deep dive (2026-06-14, Session 7)

Re-examined the deferral list for faithful portability. Outcome:

**✅ Ported faithfully:**
- `c2231910` **`/agent` slash command** — `SlashCommand` + picker UI (`SharedHeaderComponents`)
  applied verbatim; `chatToolbarOpenAgentPicker` was added only to `ChatWindowManager`'s
  `#if !OSAURUS_INTEL` branch, so it was **mirrored into `IntelDataConformers`** and the listener
  bridged into the Intel `IntelToolbarAgentView` (`openPickerTrigger` + `.onReceive`) so the command
  actually opens the picker. (3× two-param `onChange` down-leveled for Ventura.)
- `3a743373` **prune-deleted external models** — `ExternalModelLocator` +`pruneMissing()` call in
  `ModelPickerView`. The reveal-in-Finder **UI** lives in the divergent `ModelDetailView` → kept ours.

**🧱 Architecturally incompatible (NOT faithfully portable — rooted in amputated subsystems):**
- `a39b2d89` **p2p e2e** — crypto is self-contained but its transport (`BonjourBrowser`/
  `RelayTunnelManager`) is excluded; encrypting a channel Intel never opens = dead code. *(still blocked)*
- `be43da1a` **local MCP probe** — `MCPProviderProbeService` hard-needs excluded `SandboxStdioRunner`. *(still blocked)*

**🔧 Ported as Intel glue (Session 8, 2026-06-14 — `dfcc19cc`):**
- `58aab452` **hosted inference / "Osaurus Router"** — initially called incompatible, but
  `CloudChatEngine` already routes to any OpenAI-compatible provider via the stubbed
  `RemoteProviderManager`, so it WAS doable as a glue port. The "wallet" is the user's
  existing Osaurus identity (EIP-191 `deriveOsaurusId`→EVM address), not a separate wallet.
  Added `.osaurusRouter` provider type, the self-contained Router/credits files, a managed
  provider registration + signed catalog fetch in the stub, request signing in
  `CloudChatEngine` (stream+complete), and a `ManagementTab.credits` entry. Dropped the
  redundant `OpenAICompatibleStreamParser` (CloudChatEngine streams natively) and decoupled
  `StorageMutationGate`/`FeatureTelemetry`/insights cross-refs. **Compiles app-wide; live use
  needs a funded router account (untested).** Composer credits-chip deferred.
- `a39b2d89` **p2p e2e** — crypto is self-contained but its transport (`BonjourBrowser`/
  `RelayTunnelManager`) is excluded; encrypting a channel Intel never opens = dead code.
- `be43da1a` **local MCP probe** — `MCPProviderProbeService` hard-needs excluded `SandboxStdioRunner`.

**⏭ Skipped / needs-rewrite:** `2a58c239`+`ae4541d4` model-picker (Intel's grouping model would need
re-architecting to upstream's tabs — not a faithful diff), `7068b131` sandbox-default (enforcement in
excluded `BuiltinSandboxTools`), `fc1626c6` whats-new (keyed on excluded sandbox/pairing), `e6b78e36`
onboarding polish (low value).

## Sync workflow (monthly)

```bash
git fetch upstream
# Only NEW commits since last sync — never reparse old ones
git log d132b728..upstream/main --oneline
# Classify → PORT/SKIP/MIRROR → cherry-pick/ignore → update this ledger
# When done:
#   1. update the "Last synced upstream commit" hash + "Upstream version era" above
#   2. update IntelBuildInfo.swift (upstreamBase + upstreamCommit) to match
#      — that constant feeds the About panel and the release-notes footer.
```  

---

## Triage Rubric

```
For each upstream commit:
  git show --stat <commit>

  IF all files in Package.resolved + Package.swift
    → SKIP "vMLX version pin"

  IF all files in exclude: list AND no Intel mirror exists
    → SKIP "amputated subsystem"

  IF all files in test directories
    → IGNORE "test-only"

  IF any file in exclude: list WITH an Intel conformer mirror
    → MIRROR "re-implement in <conformer file>"

  IF all files in shared (non-excluded, non-test) code
    → PORT — cherry-pick

  IF mixed (some shared, some excluded)
    → EVALUATE — port shared subset, skip excluded
```

## Perpetual Conflict Files (always `--ours`)

- `Package.swift` — different dependencies, exclude list, OSAURUS_INTEL flag
- `Package.resolved` — different dependency graph

> **Deliberate pin divergence (2026-09-02): `swift-secp256k1` is `exact: "0.23.2"` here,
> while upstream stays on `exact: "0.21.1"`.** 0.21.1 does not compile under Swift 6.4:
> `UInt256` declares both `SIMDWordsInteger` and `UnsignedInteger`, both of which require
> `words`, and the newer compiler rejects `for word in words` as ambiguous
> (`P256K/UInt256.swift:215`) — even though the package already declares
> `swiftLanguageModes: [.v5]`. This breaks **every** commit including untouched baselines, in
> both architectures, so it is not sync damage. Upstream has not hit it because they are not on
> 6.4 yet. 0.23.2 builds clean with no source changes on our side. When upstream eventually
> bumps their pin, drop this divergence and follow them.
>
> **Knock-on effect — build-tool plugin validation.** 0.23.2 ships a
> `SharedSourcesPlugin` build-tool plugin that 0.21.1 did not. Xcode refuses to run an
> unvalidated package plugin from the command line, so `xcodebuild` dies at
> *"Validate plug-in SharedSourcesPlugin"* **before compiling a single file**, while
> `swift build` is unaffected — which makes it invisible to the usual Ventura build check.
> `scripts/build/build_rosy.sh` (the release path, called from `cut_intel_release.sh`) and
> `scripts/build/build_arm64.sh` therefore pass `-skipPackagePluginValidation
> -skipMacroValidation`. Without them the release ceremony fails with three lines of output
> and no obvious cause. Remove these flags if the secp256k1 pin is ever reverted.
- `RuntimePolicySourceTests.swift` — vMLX source-policy tests

---

## Sync Log

> **vMLX pins (~97 commits):** Batch-classified SKIP based on 30-commit sample analysis (63% ratio).  
> These touch only `Package.resolved` + `Package.swift` for vmlx-swift version bumps.  
> Intel uses `IntelStubs` — all harmless noise. Not individually listed; covered by the hash  
> range `d0782cbb..109e0306`. Individual hashes can be retrieved with:  
> `git log d0782cbb..109e0306 --oneline -- Packages/Package.resolved Packages/OsaurusCore/Package.swift`  
>  
> Commits below are the **substantive** upstream changes that required Intel action.

| # | Upstream Hash | Class | Intel Action | Files | Result |
|---|---|---|---|---|---|---|
| 1 | `61245f1a` | PORT | cherry-pick | IdentityView.swift | ✅ Clean — auto-merged |
| 2 | `5a9207c1` | PORT | deferred | RemoteProviderEditSheet.swift | ⚠️ Deferred — upstream file diverged too far; Intel version kept. URL-split feature to be manually ported later. |
| 3 | `4fc80157` | PORT | cherry-pick (skip xcstrings, keep test deleted) | AgentStarterTemplate.swift, AgentAvatarView.swift, OnboardingProgress.swift, +6 guarded files | ✅ Conflicts resolved; guards re-added |
| 4 | `95ad4ef3` | PORT | cherry-pick (skip ModelManager, OnboardingConsent, xcstrings) | +11 guarded onboarding files | ✅ Conflicts resolved; guards re-added |
| 5 | `a0ebae22` | PORT | cherry-pick (skip test file, keep guarded file) | ProviderPresets.swift, ProviderCredentialInstructions.swift, OnboardingConfigureAIView.swift | ✅ AtlasCloud provider preset — pre-req for Grok OAuth |
| 6 | `d9fd0db1` | PORT | cherry-pick (skip RemoteProviderService, xcstrings) | ProviderPresets.swift, ProviderCredentialInstructions.swift, +5 files | ✅ MiniMax provider preset — pre-req for Grok OAuth |
| 7 | `806de1a0` | PORT | created XAIOAuthService.swift + cherry-pick (discard excluded/guarded files) | ProviderPresets, RemoteProviderConfiguration, OAuthLoopbackServer, OAuthSignInCoordinator, ProviderCredentialInstructions, RemoteProviderEditSheet (reverted), XAIOAuthService | ✅ Core shared files ported; RemoteProviderEditSheet kept Intel version; RemoteProviderService/RemoteProviderManager changes discarded (excluded/irrelevant) |
| 8 | xcstrings sync | SYNC | `git checkout upstream/main` — full-file replacement | Localizable.xcstrings (38 commits worth of localization changes) | ✅ 2761 strings; both Intel strings already present upstream |
| 9 | `aa444a5a` | PORT | cherry-pick | MCPProviderManager.swift, ModelPickerItemCache.swift | ✅ Clean auto-merge — MCP hangs fix |
| 10 | `3ff495ef` | PORT | cherry-pick (manual conflict resolution) | ChatWindowManager.swift, NativeToolCallGroupView.swift, SystemPermissionService.swift | ✅ Resolved: VLMDetection excluded, SystemPermissionService took upstream, ChatWindowManager kept Intel, NativeToolCallGroupView manually patched |
| 11 | `c43cf17e` | PORT | cherry-pick | ChatSessionSidebar.swift | ✅ Clean auto-merge — chat rename guard |
| 12 | `9b79161b` | PORT | selective shared-file port (DIFF application, NOT whole-file replacement) | ChatToolChoicePolicy (NEW), FloatingInputCard, ToolsManagerView, ModelFamilyNames, ModelFamilyGuidance, ModelOptions, ModelOptionsStore, ModelMediaCapabilities, ModelMetadataParser, SystemPromptTemplates, ToolEnvelope, OsaurusPaths, FolderTools, StorageKeyManager, KeychainQueryHelpers, ToolSecretsKeychain, MCPProviderKeychain, RemoteProviderKeychain, DocumentChip (onInline param) | ✅ Partial — shared files only. HTTPHandler, Router, AppDelegate, CacheSection, ConcurrencySection, ChatView kept Intel versions (upstream too divergent). Intel conformers: added .required to ToolChoiceOption; Phase B ToolRegistry upgrades (folderToolNames, runtimeManagedToolNames, builtInSandboxToolNamesSnapshot, invalidToolArgumentsEnvelope).
| 13 | `1dbe7ed3` | PORT | selective diff (3 shared, 3 skipped) | OsaurusPaths, FloatingInputCard, SystemMonitorService | ✅ Free-space query swap, paste monitor crash fix, doc. AppDelegate/HTTPHandler/OsaurusServer skipped (MLX-specific). |
| 14 | `a213f3ce` | SKIP | MLX-only load policy | AppDelegate.swift | ⏭ Intel AppDelegate doesn't use ToolIndexService. |
| 15 | `f59a6cf0` | SKIP | MLX-only telemetry | HTTPHandler.swift | ⏭ Telemetry field in MLX orchestration path. |
| 16 | `c46c0682` | SKIP | MLX-only cold-tier pin | OsaurusServer.swift | ⏭ Intel OsaurusServer already minimal (no IdleStateHandler). |
| 17 | `8e1b42ba` | PORT | cherry-pick (resolved: re-added guard) | Localizable.xcstrings, 2 Onboarding views | ✅ OnboardingCreateAgentView + OnboardingWelcomeView guards re-added. |
| 18 | `a8d336ec` | PORT | cherry-pick (resolved: re-added guard) | xcstrings, 8 Onboarding files | ✅ Guards re-added; 2 excluded files kept deleted. |
| 19 | `edadc1f2` | PORT | cherry-pick (kept Intel ChatView/PluginsView) | xcstrings + 28 files | ✅ Chinese translations; Intel views preserved. |
| 20 | `396abe4f` | PORT | cherry-pick (gated new codex file) | PDFPPTXWorkflowService (NEW) | ✅ Gated behind #if !OSAURUS_INTEL. |
| 21 | `5145c37a` | PORT | cherry-pick (reverted FolderTools) | WorkspaceWriteSafety (NEW) | ✅ New file kept; FolderTools reverted (sandbox deps). |
| 22 | `8d94f864` | PORT | cherry-pick (reverted ProvidersView/RemoteProvidersView, gated diagnostics) | ProviderNetworkDiagnostics (NEW), ProviderDiagnosticsRowsView (NEW) | ✅ New files gated; Intel views preserved. |
| 23 | `d132b728` | PORT | cherry-pick (clean auto-merge) | ManagementBadgeStore, ServerView | ✅ Main thread hang fix — key gen off main actor. |
| 24 | `63bf3a3c` | PORT | cherry-pick (resolved: took upstream OAuth) | RelayTunnelManager, MCPOAuthService, XAIOAuthService, OpenAICodexOAuthService, NativeBlockViews, NSWorkspaceAsyncOpen (NEW) | ✅ Streaming/OAuth/relay hang fixes. |
| 25 | `dfca2325` | PORT | cherry-pick (gated WatcherManager, kept Intel ModelDownloadService) | WatcherManager, FloatingInputCard, DirectoryFingerprint, CustomTheme | ✅ Unresolved app hangs fix; Agent.rejectBuiltInForExternalSurface gated. |
| 26 | `bfa4aa01` | PORT | cherry-pick (clean auto-merge into AS branch) | PluginManager.swift | ✅ Keychain reads off main thread; Intel branch unaffected. |
| 27–36 | vMLX pins (4) + CI/appcast (6) | SKIP/IGNORE | — | Package.resolved, Package.swift, CI workflows, appcast XML | ⏭ Batch-skipped. |
| 37 | `0c494229` | PORT | cherry-pick -X ours + gating | 90 files, ChatView kept Intel | ✅ Capabilities refactor; 6 new files gated, 3 shared views reverted. |
| 38 | `6df10354` | PORT | cherry-pick (kept Intel ChatView) | 14 files | ✅ Capabilities persistence fix. |
| 39 | `5737790a` | PORT | cherry-pick (gated RemoteProviderReorderSheet) | RemoteProviderManager, RemoteProvidersView, RemoteProviderReorderSheet | ✅ Provider reorder; new sheet gated. |
| 40 | `f694bbaa` | PORT | cherry-pick (took ours for shared views, gated 3 files) | ExternalModelLocator, ModelCompatibilityDiagnostics, ExternalModelsSettingsView, ModelDetailView | ✅ Model diagnostics; 3 files gated, ModelDetailView reverted. |
| 41 | `522b8a69` | PORT | cherry-pick (removed App/AppIntents — no OSAURUS_INTEL in App target) | AppDelegate (ours), HTTPHandler (ours), ServerController, App/AppIntents | ✅ App Intents removed from Intel App target. |
| 42 | `2f7ff107` | PORT | cherry-pick (resolved test conflicts) | DocumentFormatRegistry, BusinessDocumentSummary (NEW) | ✅ Business document attachment summaries. |
| 43 | `e361e78b` | PORT | cherry-pick (kept Intel PluginsView, gated Claude files) | ClaudePlugin* (NEW, gated), PluginsView (ours) | ✅ Claude plugin marketplace; 7 files gated. |
| 44 | `62c66db5` | SKIP | MLX infrastructure | RuntimeProofValidation, tests | ⏭ ModelRuntime subsystem. |

### Intel-Specific Fixups (commit `8f86d6d5`)

| Fix | Reason |
|---|---|
| RemoteProviderEditSheet.swift reverted to Intel version | Upstream file depends on unported types (ProviderTextField, ProviderSecureField, OpenAICodexOAuthService, disableTimeout) |
| Package.swift: exclude RemoteReasoningPolicy.swift | Depends on excluded ThinkingConfig / RemoteProviderService |
| Stripped `public` from OAuthSignInCoordinator + ProviderCredentialInstructions | Intel module is internal; upstream uses library visibility |
| Re-added `#if !OSAURUS_INTEL` guards to 5 onboarding files | Lost during `--theirs` conflict resolution |
| Removed duplicate ProviderInputFields.swift | Intel defines ProviderTextField/ProviderSecureField inline in RemoteProviderEditSheet |

---

## Stats

- **Total upstream commits processed:** 44 substantive + ~97 vMLX pins + ~38 xcstrings
- **Sessions:** 5 (2026-06-07/2026-06-08) | **Fully caught up to upstream/main** ✅

---

## Deferred / watch-list

- **Chat "bubble" rendering for thoughts + tool-calls.** The Apple-Silicon
  Osaurus renders reasoning/tool-call blocks in a newer "bubble" style; Intel
  renders the 0.19.15 "card" style. The `Native*` chat views
  (`NativeThinkingView`, `NativeToolCallGroupView`, `NativeMessageCellView`,
  `NativeBlockViews` — ~5.3k lines of hand-tuned AppKit) are SHARED, not
  Intel-divergent, so this is **not** an Intel reimplementation — it's a newer
  upstream redesign. It is NOT in the 41 commits after `d132b728` (by subject).
  **Decision (Renée, 2026-06-11): do NOT reinvent it.** If a future upstream
  sync brings the redesign as a real commit, port it then. Otherwise leave the
  card style as-is.

---

## ⚠️ Intel-owned files & post-sync verification (GUARDRAIL)

The `9b79161b` / App-Intents syncs silently **reverted** Intel customizations by
taking "theirs" on cherry-picks (found + fixed in 1.0.15): the README was
replaced with upstream's, and `RemoteProviderKeychain` lost its Intel isolation.
These compile fine reverted, so they slip through. **After EVERY sync, verify
these Intel-owned customizations survived:**

| File | Must contain (Intel) | Not (upstream) |
|---|---|---|
| `README.md` | `🦕 Osaurus (Intel)` header, "Run a model locally" | `Own your AI`, `brew install --cask osaurus` |
| `Packages/OsaurusCore/Services/Provider/RemoteProviderKeychain.swift` | `ai.osaurus.remote.intel` (`#if OSAURUS_INTEL`) | bare `ai.osaurus.remote` only |
| `Packages/OsaurusCore/Services/MCP/MCPProviderKeychain.swift` | `ai.osaurus.mcp.intel` | bare `ai.osaurus.mcp` only |
| `App/osaurus/Info.plist` | `SUFeedURL` → `reneezmp/osaurus-intel`, `SUPublicEDKey` `bYYJJqFx…` (was `7Nh8jSxF…` until 1.0.36) | `osaurus-ai` / missing |
| `scripts/release/cut_intel_release.sh` | `REPO="reneezmp/osaurus-intel"` | upstream repo |
| `scripts/build/build_rosy.sh` | bakes `OsaurusCanonicalData` | — |
| `Packages/OsaurusCore/Identity/MasterKey.swift` (DO NOT isolate) | `com.osaurus.account`, synchronizable — **shared identity, leave as-is** | a `.intel` variant (would fracture identity) |

**Revert-detector** (run after each sync — lists Swift files that lost ALL their
Intel guards vs the last known-good tag):

```bash
comm -23 \
  <(git grep -l OSAURUS_INTEL <good-tag> -- '*.swift' | sed 's/^[^:]*://' | sort -u) \
  <(git grep -l OSAURUS_INTEL HEAD       -- '*.swift' | sed 's/^[^:]*://' | sort -u)
```

**Rule:** the README, the two provider/MCP keychain service names, the updater
config (Info.plist), and the release/build scripts are Intel-owned — on a
cherry-pick conflict, ALWAYS keep ours. The Master Key (`com.osaurus.account`)
is the opposite: shared + iCloud-synced identity, never give it an Intel variant.

---

## ⚠️ Ventura (macOS 13) backport maintenance (Phase B, 2026-06-12)

The deployment target is **macOS 13**, enforced by the compiler. After every
upstream sync, the build will fail on any new API that requires 14+. Recurring
categories to watch for:

| Pattern | Fix |
|---|---|
| `@Observable` macro | Convert to `ObservableObject` + `@Published` |
| `.onChange(of:){ _, v in }` | Down-level to `{ v in }` (bulk Perl regex available) |
| `.onChange(of:){ named, v in }` | Manual: `@State` prev-value var |
| `.symbolEffect` | Remove or `.contentTransition(.opacity)` |
| `.activateAllWindows` | Use `.activateIgnoringOtherApps` |
| new 14+ decorative APIs | Plain 13-compatible replacement (no `#available` gates) |

**Post-sync Ventura build check:**
```bash
cd Packages/OsaurusCore && swift build --arch x86_64
```
Fix every "only available in macOS 14/15" error, rebuild, repeat until clean.

---

## 2026-09-08 — Claude Code Intel hand-port and deferred-verdict correction

- Ported the useful core of upstream `eca456c3` without the excluded MLX service registry or MCP bridge: executable discovery, CLI-owned authentication, safe text-only streaming, Claude model aliases, settings setup/status, cancellation, and child-process teardown.
- The CLI receives prompts on stdin, runs statelessly, ignores user MCP servers, and has every built-in tool disabled in this first slice. Osaurus does not read or store Claude credentials.
- Verified current Anthropic requirements support macOS 13 and x64. The setup screen uses the current native installer and discovers its `~/.local/bin/claude` launcher.
- Re-audited all 73 historical `DEFER` rows. The authoritative correction is `docs/DEFER_FEASIBILITY_AUDIT_2026-09-08.md`: 58 are feasible Intel work (1 landed, 28 port-next, 29 roadmap); 15 are product/runtime skips. Difficulty and mixed-file scope are no longer accepted as incompatibility reasons.
- Validation at this checkpoint: package build passes; 730 tests / 108 suites pass, including 21 Claude configuration/streaming tests. x86_64 and workspace gates follow after commit-ready review.

## 2026-09-09 — Codex catalog and Responses Lite follow-up

Rosy acceptance exposed the exact failure fixed upstream by `7d7df287` and
`7bdb440f`: querying ChatGPT's generic model catalog admits unusable `*-wm`
experiments, while current GPT-5.6 Codex models may require the catalog-driven
Responses Lite contract. The Intel engine now carries both fixes without
un-excluding the Apple-Silicon service cone: Codex catalog URL/client identity,
CLI User-Agent, `use_responses_lite` capability tracking, UUIDv7 affinity,
required Lite headers, and the Lite input-item rewrite live in the Intel OAuth,
adapter, and cloud-engine files.

This checkpoint also restores upstream's provider-qualified model identity.
Bare ids remain a compatibility input only when one provider owns them; the
wire request always receives the owner's bare model id. Do not reintroduce
global bare-id deduplication in future sync conflict resolution—it hides Router
models and breaks persisted per-agent defaults.

## 2026-09-09 — Agent settings General and Abilities mirror

Ported the upstream 0.25.0 grouped Agent-detail navigation while preserving the
fork's working Intel managers. General now exposes Configure and Appearance;
Abilities exposes Overview, Tools, Subagents, and Sandbox. Keep the Intel
availability decisions during future conflict resolution: Tools, Knowledge,
Memory, schedules/watchers, custom avatars, per-agent themes, and Claude Code
folder permissions are live; native container sandbox, native subagents,
per-agent structured databases, and the Claude-to-Osaurus MCP bridge are shown
as unavailable until their real backends land.

Agent JSON now accepts upstream `toolsEnabled` / `memoryEnabled` keys and stores
per-agent `claudeCode` settings. Intel still writes its legacy
`disableTools` / `disableMemory` keys, so the custom decoder is the compatibility
boundary and positive upstream keys take precedence when both forms are
present. Preserve `bonjourEnabled`, `order`, and `claudeCode` whenever the
editor reconstructs an Agent value.


## 2026-09-09 — Remaining Agent settings groups and route compatibility

Connections now mirrors upstream with Network, Remote Connections, and Channels nested routes. Automation and conversational Memory keep their working Intel managers, while Database has the upstream nested route shape with dependency-aware content. Preserve `AgentDetailTabRoute.swift`: it converts legacy Home/Schema/Data/Views/Activity deep links into the consolidated Database sections.

The dependency contract is `docs/INTEL_AGENT_SETTINGS_BACKLOG.md`. Bonjour, schedules/watchers, history, pinned facts, and episodes are live. Relay/workspace sharing, peer grants, Channels/outbox, and private Agent Database remain backlog items until their full Intel backends are restored.

## 2026-09-10 — Native Web Search Intel hand-port

Upstream's free/custom Web Search stack was rebuilt through the Intel-compiled
registry and prompt composer: provider catalog and ordering, built-in
fallbacks, declarative providers, Keychain credentials, test search,
Readability extraction, Settings navigation, and per-agent opt-in gating. The
legacy `search-intel` dylib is retired to prevent duplicate tool registration.
The baseline schema also includes upstream's immutable-category fix so provider
changes cannot alter the prompt prefix. Osaurus Premium routing is deferred as
an explicit Credits/Router dependency. Automated and Rosy acceptance evidence
are tracked separately in `WEB_SEARCH_TEST_PLAN.md`.

## 2026-09-10 — Agent Settings Rosy acceptance correction

The first Rosy pass disproved the automated-only classification recorded by
the Agent Settings revamp. Existing-agent model migration, runtime capability
gating, custom avatars and themes, Bonjour state, schedule/watcher management,
and memory data projection all had material failures. Ventura also exposed an
app-wide native-control rendering regression: insertion carets, switch tint,
button content, menu content, and hover feedback could be absent until
interaction.

Future settings ports must keep the feature **Partial** until the exact Intel
build has passed Rosy acceptance. Codable round trips and route tests prove the
data shape and navigation only. They do not prove migration from Renée's live
store, the model/tool set sent by an existing chat, AppKit rendering on
Ventura, or manager actions reached through the rebuilt screen. Any sentence
that says manual acceptance is pending is incompatible with **Working and
tested** status.

Intel's compiled `CloudChatEngine` also bypassed upstream `ChatEngine`'s
Insights logging because the latter is excluded from the Intel target. The
replacement engine now records streamed Chat UI success, failure, response,
usage, and tool-call data in `InsightsService`. This remains Partial until the
new Rosy retest confirms the Insights list and detail panes render the records.
The per-message diagnostic controls seen in current upstream remain part of the
separately backlogged chat-interface revamp.

## 2026-09-12 — Intel Orchestrator Gate 5B approval boundary

Added the built-in-only `orchestrator_config` tool for the bounded Gate 5A JSON
domains. The model can inspect the schema, plan changed paths, and request apply;
it cannot export current private values or mint its own approval. Apply suspends
on a caller-independent in-chat queue and proceeds only after the visible exact
plan is accepted. Denial, timeout, cancellation, missing UI, stale plans, and
replay fail closed. Generic Always Allow prompts are bypassed for this dedicated
review, while an explicit tool-policy Deny still blocks execution.

Approval requests and mounted cards are keyed to the originating chat session.
This prevents one chat window from displaying or approving another window's
pending plan. The first implementation used SwiftUI's two-value `onChange`, which
is unavailable on the macOS 13 deployment target; the Ventura-safe implementation
remounts the approval surface when its session identity changes.

Validation must quote the executed test count. During this gate, `swift test`
first returned success with zero matching tests because the new test files were
wrapped in `#if OSAURUS_INTEL` while only the production target defines that flag.
This is now a permanent test-manual rule: a successful build is not evidence that
a filtered test ran.

## 2026-09-14 — Rosy post-QA repair batch

Direct Rosy Ventura testing, rather than commit review, exposed defects at four
boundaries: SwiftUI state looked correct while AppKit controls rendered blank;
stored ability choices looked correct while an open chat retained stale tools;
background requests carried a folder path while the created session did not
mount it; and Orchestrator code existed while its model never received the tools.

The repair follows each feature end to end. Native appearance and window chrome
are synchronized at the AppKit boundary; live dispatch rechecks the current
seeded allowlist; background execution mounts the request folder;
Router-qualified Memory models survive cold discovery and Qwen text parts decode;
and the built-in Orchestrator receives its fixed role, identity, configuration,
and bounded delegation tools. Source presence, persisted state, and a passing
build remain insufficient without runtime exposure and Rosy UI evidence.

Focused tests must run as named suites and report nonzero counts. The repair
checklist is [`ROSY_2026-09-14_FIX_RETEST.md`](ROSY_2026-09-14_FIX_RETEST.md).
Feature rows remain Partial until that candidate passes on Ventura. The owner
declined the complex optional section 14 field matrix; it remains future-user
coverage and must not silently reappear as a release blocker.

During validation, the first automation regression test itself violated the
storage contract and wrote 12 synthetic chats into the live sessions directory.
They were moved intact to a dated quarantine, the cross-runner isolation helper
was enabled for SwiftPM, and the focused rerun used a temporary root. This is a
failed validation incident even though the original focused assertions passed;
see `TEST_STORAGE_SAFETY.md`.

Final M4 validation ran serially with an isolated `OSAURUS_TEST_ROOT`: **982
tests in 149 suites passed**. The canonical Rosy build then completed with
`BUILD SUCCEEDED`; the app is a thin x86_64 Mach-O, declares macOS 13.0 minimum,
contains `OsaurusCanonicalData = true`, and is signed by `Osaurus Intel Code
Signing`. Its manual promotion gate is the focused checklist linked above.

## 2026-09-19 — Rosy disproved the first Ventura rendering repair

The `f38bfecf1` candidate restored chat chrome but did not repair Settings on
Ventura. Rosy showed that the standard close button still worked at its expected
coordinate while all three traffic-light images were invisible. Opening a modal
sheet made them reappear in grey. Settings text editors still hid insertion
carets and untouched native controls could remain white on white, while the chat
window rendered the same classes correctly. This is direct machine evidence that
the failure belongs to the manually-created Settings window's appearance and
full-size titlebar composition; it is not evidence that AppKit failed to install
the controls.

Do not treat a programmatic `standardWindowButton` presence check, clickable hit
region, or successful SwiftUI snapshot as visual acceptance. For manually-created
Ventura windows, test the actual non-modal window before and after focus, theme
changes, sheet presentation/dismissal, and full relaunch. Keep Settings native
controls independent of per-agent chat appearance unless the complete Settings
surface is intentionally themed to match.

The same pass found two parity gaps hidden by the earlier repair: the Intel Add
Knowledge sheet had retained a reduced three-field form despite upstream's local
form exposing labels, format help, and include/exclude globs; and completed-message
metrics could disappear when a restored turn retained token count without TTFT or
tok/s. Future ports must compare the whole user workflow and persisted/relaunched
shape, not merely the presence of a sheet or footer block.

The focused second-pass checklist is
[`ROSY_2026-09-19_VENTURA_RETEST.md`](ROSY_2026-09-19_VENTURA_RETEST.md).

## 2026-09-19 — Rosy second-pass evidence and Knowledge parity follow-up

Rosy's direct test of `944887838` confirmed that Settings now paints working
traffic lights, text fields show their carets, the complete Knowledge creation
form works with persisted include/exclude filters, and completed messages show
TTFT, throughput, and token count. Preserve the tester's annotations in
[`ROSY_2026-09-19_VENTURA_RETEST.md`](ROSY_2026-09-19_VENTURA_RETEST.md); they
are product evidence, not disposable working-tree changes.

The same run found two remaining gaps. Settings used a conspicuous dark native
titlebar strip, and the Ventura rendering bridge applied the active accent to
every `NSButton`, turning labels in switches, selectors, normal buttons, and
disabled controls white on the light Settings surface. The follow-up keeps a
real AppKit titlebar but makes it transparent over the Settings background, and
leaves text-bearing controls to Aqua plus their explicit SwiftUI styles.

Rosy also showed that Intel's Knowledge detail sheet and cards lagged upstream.
The follow-up ports the parts backed by Intel's real data: editable metadata and
globs, collection dates, document/chunk status, project usage, persisted custom
agent grants, and indexed documents with relative paths and categories. The
document list comes from the encrypted derived Knowledge index; it does not
invent an upstream-only service or expose a dead action.

Permanent lesson: native window hit regions, a successful M4 build, and an
AppKit control's post-click appearance are not evidence of its untouched
Ventura rendering. Check the actual Settings window before interaction, and
compare management surfaces against current upstream behavior while preserving
Intel's compiled dependency boundary.

The exact post-fix Rosy gate is
[`ROSY_2026-09-19_KNOWLEDGE_CONTROLS_RETEST.md`](ROSY_2026-09-19_KNOWLEDGE_CONTROLS_RETEST.md),
pinned to code commit `5419bf4cb`.

Rosy's result for that candidate is Partial. Themes and the previously broken
Ventura controls now render correctly. Settings has a readable light native
titlebar, although it does not yet use chat's integrated full-size chrome.
Knowledge details now expose the real location, dates, counts, agents, and
indexed documents, but clicking an Agents with Access switch does not update
the visible or global grant state. Collection cards also still lack upstream's
inline Edit action and categorized/uncategorized badge. These are release-known
gaps, not accepted parity.
M4 validation for that candidate ran **983 tests in 149 suites** against an
isolated filesystem root. The first attempted full run also disabled the test
Keychain and correctly broke OAuth-header tests; filesystem isolation is required,
but the suite's in-memory Keychain substitute must remain enabled.

## 2026-09-21 — Knowledge grant observability gate

The remaining Knowledge defect has a concrete Intel-side diagnosis. The
per-agent grant is intentionally kept in `AgentManager`'s private
`knowledgeGrants` sidecar and written atomically to
`OsaurusPaths.knowledgeAgentGrantsFile()` (`knowledge/agent-grants.json`).
`updateKnowledgeSettings` updates that dictionary, bumps the capability
revision, and posts `.agentUpdated`, but the `AgentManager` observed object was
not otherwise invalidated. `KnowledgeCollectionDetailSheet.accessSection` and
`KnowledgeCollectionCard` read grant state through SwiftUI bindings/body
derivations on `AgentManager.shared`; without an observed-object publication,
Rosy can show an unchanged switch/count even though the sidecar write and
runtime ledger have changed. Treat the observed-state repair and the runtime
boundary as separate gates.

The implementation lane now includes
`IntelAgentRuntimeLaneTests.knowledgeGrantPublishesPersistsAndRevokesRuntimeAccess`.
It proves observed-object publication, sidecar-file writes, capability revision
advancement, positive direct dispatch, and revocation denial. The existing
`IntelAgentRuntimeLaneTests.dispatchRejectsWebSearchAndKnowledgeWithoutTheirGrants`
continues to prove denial when an agent has no Knowledge grant. Neither test
yet proves persistence across a manager reload/relaunch boundary or access
from fresh and restored chats; those remain required before the Rosy checklist
is rerun. Any test that changes `OsaurusPaths.overrideRoot` or the storage key
must use `StoragePathsTestLock` across the entire critical section, as required
by [`TEST_STORAGE_SAFETY.md`](TEST_STORAGE_SAFETY.md).

This entry records source/test-contract evidence only. It does not promote
Knowledge beyond **Partial**, and the Rosy manual result remains pending.

The same repair ports the two card affordances identified in Rosy's partial
result without importing upstream-only services: inline Edit reuses Intel's
existing editor sheet, while the categorized/uncategorized badge reads the
derived Intel Knowledge document index and refreshes after indexing. Both are
implemented source state, not manual acceptance evidence.

Focused validation on 2026-09-21 passed **9 tests in 1 suite** for
`IntelAgentRuntimeLaneTests` under an isolated filesystem root. Because this
host's Swift test runner still identified its target as ARM under an
`arch -x86_64` wrapper, the separate explicit gate
`swift build --package-path Packages/OsaurusCore --arch x86_64` was run and
passed. Existing package warnings remain; no new compile error was accepted as
evidence.

The restored build host exposed Apple LibreSSL rather than OpenSSL 3. The
stable-signing bootstrap previously passed OpenSSL 3's `pkcs12 -legacy` flag
unconditionally, so identity creation stopped before Keychain import. The
script now detects LibreSSL (whose default PKCS#12 output is already compatible)
and reserves `-legacy` for OpenSSL implementations that support and require it.

The Rosy test candidate was then built successfully as version `1.0.37` build
`38`: a thin `x86_64` app with macOS 13.0 minimum deployment, canonical
`~/.osaurus` storage, and the stable self-signed `Osaurus Intel Code Signing`
identity. As expected for that sovereign identity, strict trust evaluation on
the M4 reports `CSSMERR_TP_NOT_TRUSTED`; first-open Gatekeeper behavior remains
a Rosy manual gate. The metadata-preserving transfer archive and focused test
steps are recorded in
[`ROSY_2026-09-21_KNOWLEDGE_PARITY_RETEST.md`](ROSY_2026-09-21_KNOWLEDGE_PARITY_RETEST.md).

Rosy's 2026-09-22 run passed installation, immediate grant visibility, and
grant persistence across relaunch, but disproved runtime access. In real agents
whose Tools page had already seeded `manualToolNames`, prompt composition first
recognized the Knowledge grant and then removed all three Knowledge schemas
because they were absent from that separate discretionary allowlist. Dispatch
could reject the same calls before reaching the Knowledge-specific grant gate.
The repair makes Knowledge assignment/project scope authoritative at both
boundaries: a live non-empty scope adds `list_knowledge`, `read_knowledge`, and
`search_knowledge` regardless of the seeded Tools list, while revocation removes
their schemas and execution permission. Focused coverage now composes the tool
list for a seeded manual agent before and after revocation instead of testing
registry execution alone.

Replacement Rosy candidate `1.0.38` build `39` was built as thin `x86_64`,
signed with the stable Intel identity, and packaged with metadata preservation
as `Osaurus-Intel-Knowledge-Runtime-2026-09-22.zip` (SHA-256
`a72a79cfdee9c376911fae419d85b420b1e5938527f59ac7f035446161186f14`).
The archive passed `unzip -t`; runtime acceptance remains pending on Rosy.

Rosy completed the replacement checklist: fresh and restored chats received
Knowledge tools, open-chat revocation removed access on the next turn, fresh
chats remained denied, re-grant restored access, and the new card affordances
worked. Runtime acceptance therefore passed on `1.0.38` build `39`.

The same run found three UI defects. The card rubbish-bin deletes immediately
because only the detail sheet owns a confirmation dialog; card and detail
deletion must converge on one confirmation path. When Settings resigns key to
another Osaurus window, its AppKit-backed controls enter an inactive rendering
state that washes buttons, toggles, and some labels toward white on the light
paper theme. Finally, Settings still uses a separate non-full-size native
titlebar, producing a white top band. Chat avoids that band with
`.fullSizeContentView` plus a real unified `NSToolbar`; merely restoring the
full-size style without the toolbar previously allowed SwiftUI content to paint
over Ventura's traffic-light images. Any Settings unification must port the
complete chat chrome lifecycle—toolbar attachment and post-attachment traffic-
light restoration—not only the style-mask flag.

The follow-up implements that complete contract for Settings: the window now
uses `.fullSizeContentView`, a real unified `NSToolbar`, transparent titlebar,
and post-attachment native traffic-light restoration. The Settings root forces
SwiftUI's control-active environment to remain active while another Osaurus
window is key, and Knowledge's Add Collection action uses explicit theme-owned
foreground/background rendering rather than AppKit's inactive bordered-button
palette. Both the card rubbish-bin and detail-sheet Delete now enter one themed
management-window confirmation; deletion occurs only from its destructive
action.

Focused validation passed **14 tests in 2 suites** for Intel Ventura rendering
and the agent runtime lane; the expanded rendering suite then passed **6 tests**
including unified chrome and deferred deletion. Rosy candidate `1.0.39` build
`40` is packaged as `Osaurus-Intel-Window-Safety-2026-09-22.zip` (SHA-256
`79a9e5423a9d4142465b1b59ff5b7f6dc614a9c1b01180b5c11867605fda9efe`).
Manual acceptance is tracked in
[`ROSY_2026-09-22_WINDOW_SAFETY_RETEST.md`](ROSY_2026-09-22_WINDOW_SAFETY_RETEST.md).

Rosy immediately disproved the first unified-chrome candidate: `1.0.39` removed
the white titlebar band and preserved active control colors, but the traffic
lights disappeared. The `NSToolbar` object existed, and the standard buttons
reported `isHidden == false`; that was insufficient evidence. With no retained
delegate and no default item, Ventura collapsed the toolbar's native chrome
region and painted those logically-present buttons outside the visible area.
The repair explicitly inserts a flexible-space item after attaching the toolbar,
and the focused contract now asserts materialized toolbar content. AppKit clears
the delegate for this standard-item-only toolbar, so delegate retention is not
used as a false proxy for visible chrome.

The corrected Rosy candidate is `1.0.40` build `41`, packaged as
`Osaurus-Intel-Traffic-Lights-2026-09-22.zip` with SHA-256
`f351769946f9414b8962f1f85ce9771a585f463a4165a8be508be06f57509f26`.
The focused materialized-toolbar contract passed and the archive passed
integrity validation; visible traffic lights remain a Rosy-only acceptance
observation.

Rosy disproved that repair too: `1.0.40` still had no visible traffic lights,
and its Core Model picker rendered an empty selected title. A standard flexible
space does not reproduce chat's actual toolbar contract. Settings now retains a
real `NSToolbarDelegate` for the window lifetime and that delegate supplies a
non-zero-height custom anchor item. The global forced-active control environment
was removed because it affected every AppKit-backed control, and Core Model now
uses a theme-owned menu with an explicit visible label for default, available,
and unavailable selections. The strengthened rendering suite passes 7 tests;
the combined rendering/runtime gate passes 16 tests. Rosy candidate `1.0.41`
build `42` is packaged as `Osaurus-Intel-Settings-Chrome-2026-09-22.zip`
(SHA-256 `518db96b34b6f1da4fe23c8de2f4cea5b662ce92f7b1ce6686f24ccdc224198d`).
The extracted archive remains a thin x86_64 app with macOS 13.0 minimum,
canonical `~/.osaurus`, and intact framework symlinks.

Rosy then showed that `1.0.41` build `42` still could not depend on Ventura's
standard button drawing underneath full-size SwiftUI content: Settings had no
traffic lights, and an inactive chat window hid its traffic lights rather than
showing the normal grey state. The Core Model text was fixed, but the borderless
custom `Menu` label lost its border and disclosure affordance. The shared Intel
window repair now deliberately hides AppKit's unreliable copies and installs
one topmost three-button strip into both Settings and chat content. It preserves
close/minimize/zoom actions, uses red/yellow/green while key, and muted grey
while inactive. Core Model now uses AppKit's standard button-menu style.
Candidate `1.0.42` build `43` is the next Rosy acceptance target.

The signed candidate is packaged as
`Osaurus-Intel-Shared-Traffic-Lights-2026-09-22.zip` (SHA-256
`b29a60c275b9964d888b73aef07a1114495f21904604546e2c884f3afe22cc79`).
The combined rendering/runtime gate passes 16 tests. Archive extraction
preserves all six framework symlinks and confirms thin x86_64, macOS 13.0
minimum, version `1.0.42` build `43`, and canonical `~/.osaurus`.

Rosy exposed a placement error in that candidate: `1.0.42` hid the standard
buttons, but its replacement strip was a child of the full-size content view.
Ventura's titlebar is a separate frame layer above that content, so both
Settings and chat showed no controls at all. The strip now uses a real
`NSTitlebarAccessoryViewController`. Focused coverage requires the accessory
controller and explicitly rejects the failed content-overlay arrangement.
Candidate `1.0.43` build `44` is the next Rosy target.

The signed candidate is packaged as
`Osaurus-Intel-Titlebar-Accessory-2026-09-22.zip` (SHA-256
`303b5aeaf7c7df8c668631dae4001799283d0b038ff230846db6be1bb870486f`).
The extracted archive confirms thin x86_64, macOS 13.0 minimum, canonical
`~/.osaurus`, version `1.0.43` build `44`, and all six framework symlinks.

Rosy showed `1.0.43`'s titlebar accessory in chat, proving the custom controls
and grey inactive state, but AppKit positioned it in toolbar flow rather than at
the traffic-light coordinates; Settings displayed no accessory. Its standard
button-style Core Model `Menu` also kept the box but lost the selected text.
The strip is now installed directly beside the hidden native close button in
that button's real titlebar superview, with its origin derived from the native
close frame. Core Model now avoids both failing native selection controls: a
plain themed SwiftUI button owns its text/border/chevron and opens a SwiftUI
popover. Candidate `1.0.44` build `45` is the next Rosy target.

The signed candidate is packaged as
`Osaurus-Intel-Native-Frame-Lights-2026-09-22.zip` (SHA-256
`b26cc8a5520b9f990a368b58e71775e2ac1a868f8b2fcbe43127b198fe8d8e23`).
Archive extraction confirms thin x86_64, version `1.0.44` build `45`, canonical
`~/.osaurus`, and all six framework symlinks.

Rosy narrowed `1.0.44` to a Settings-only lifecycle defect. The chat traffic
lights are now correctly positioned and switch between colored/key and
grey/inactive states, and the Core Model button/popover works. Settings still
shows no traffic lights. The shared renderer is therefore not the remaining
failure: Settings installs the strip into the native close button's private
superview before order-front/key finalization, has no retained `NSWindowDelegate`
to repair it afterwards, and does not repair on the existing-window reuse path.
Ventura may replace or retire that titlebar container after the installation.
The focused test currently checks only an off-screen window immediately after
configuration, so it cannot catch loss during the real window lifecycle. Keep
the working chat and picker unchanged; the next candidate must own a
Settings-specific post-key/post-layout repair lifecycle and test survival, not
merely initial strip installation.

Candidate `1.0.45` build `46` implements that Settings-specific lifecycle
owner. It repairs immediately after initial presentation, on `didBecomeKey`,
after resize and visibility changes, and whenever an existing Settings window
is brought forward. Each repair forces titlebar layout and logs a
`[SettingsChrome]` diagnostic containing the close-button parent identity,
frames, visibility, and strip attachment. Chat and Core Model rendering are
unchanged. The focused regression suite now deliberately removes the first
strip and requires the lifecycle owner to recreate it; 8 rendering tests and 9
agent-runtime tests pass.

The signed candidate is packaged as
`Osaurus-Intel-Settings-Lifecycle-2026-09-22.zip` (SHA-256
`e3cbb9c5e33d75302d9b75b73e111f2141d52523ab405ef506ccf0cd7f7db4be`).
Archive validation confirms thin x86_64, macOS 13.0 minimum, version `1.0.45`
build `46`, canonical `~/.osaurus`, six preserved framework symlinks, and no
compressed-data errors.

Rosy's `1.0.45` diagnostics disproved the stale-container hypothesis. Across
`did-become-key`, reuse, settled, and visibility callbacks, the window was key
and visible, the native parent identity remained stable and visible, and the
strip remained attached with canonical frames. Since no pixels appeared, the
native-button plane itself is below a later Settings composition/clipping layer.
The next implementation leaves chat untouched and installs only Settings'
strip in the persistent window frame root (`contentView.superview`), converting
the native close position through window coordinates and ordering the strip
above all frame children. Local diagnostics place it at `{{19, 615}, {52, 18}}`
for a 650-point test window, and all 8 focused rendering tests pass with explicit
frame-root ownership and forced-loss recovery coverage.

Candidate `1.0.46` build `47` is packaged as
`Osaurus-Intel-Settings-Frame-Root-2026-09-22.zip` (SHA-256
`0a4803abe815984b41121e9b533baf2c9d252a25566ef09c0a88a6eb1982958a`).
Archive validation confirms thin x86_64, macOS 13.0 minimum, canonical
`~/.osaurus`, six preserved framework symlinks, and no compressed-data errors.

**Rosy acceptance — 2026-09-22:** Renée confirmed that `1.0.46` build `47`
finally renders the Settings traffic lights correctly. The chat window remains
normal and its inactive controls remain grey; the Core Model picker remains
functional. This phase is complete with success. Preserve the deliberate split
between the two windows: chat installs in the native close-button parent, while
Settings installs in the persistent frame root and uses the native button only
to derive system coordinates. Reusing chat's native-parent installation for
Settings will recreate the invisible-but-attached Ventura failure.

### Agent General and Appearance acceptance start — 2026-09-22

The next main-acceptance slice is Agent Settings — General and Appearance. A
source audit confirmed that the accepted `1.0.46` build `47` already contains
the intended repairs: chat model selection is session-local, Claude Code and
Agent Data controls are directly discoverable, Delete Data preserves the agent
configuration while removing its chats and memory, and custom-avatar views
observe avatar revisions. No replacement build is required for this manual
pass by itself; the later Abilities/Tools repair below supersedes the candidate.

Focused automated evidence is green: `IntelAgentRuntimeLaneTests` passes 10/10
(including the new chat-local model isolation regression),
`IntelClaudeCodeTests` passes 10/10, and
`IntelAgentPresentationPersistenceTests` passes 1/1. The remaining gate is live
Rosy behavior across navigation and relaunch. Use
`ROSY_2026-09-22_AGENT_GENERAL_RETEST.md`; do not promote the feature from
Partial until its sections 1–4 pass.

### Abilities and Tools acceptance start — 2026-09-22

The cumulative Rosy checklist now continues with Agent Settings — Abilities
and Tools in section 6. The source audit confirmed live dispatch enforcement
for the Tools master switch, Auto and Manual allowlists, Web Search, Knowledge,
and Self-scheduling, plus truthful Intel-unavailable rows for Database,
Autonomous Execution, native subagents, and Sandbox.

The audit also found and repaired an offer/dispatch mismatch: Manual tool-
selection mode could retain `schedule_next_run`, `cancel_next_run`, and `notify`
in the composed schema while Self-scheduling was off, although dispatch would
deny every call. `SystemPromptComposer` now treats Self-scheduling as a master
ability gate in every selection mode and never lets capability loading override
an explicit denial. The new regression passes in `IntelAgentRuntimeLaneTests`,
which is green 11/11; `WebSearchToolTests` is green 11/11. Positive scheduler
schema restoration still requires the real registered runtime and remains an
explicit Rosy integration check.

Memory remains a separate later acceptance slice because its outstanding
distillation failures are independent. Unavailable Intel features pass this
slice only when their explanations are readable and non-actionable; this work
does not claim their missing backends exist.

Candidate `1.0.47` build `48` packages this repair as
`Osaurus-Intel-Abilities-Tools-2026-09-22.zip` (SHA-256
`1d7e80b40aec915fc66ed0ed1546bad6a535c9310f622bccf2606a6a765876d0`).
Archive and bundle validation confirm thin x86_64, macOS 13.0 minimum,
canonical `~/.osaurus`, six preserved framework symlinks, valid signing, and no
compressed-data errors. It supersedes `1.0.46` build `47` for the cumulative
Agent General/Appearance plus Abilities/Tools Rosy checklist.

### Automation acceptance start — 2026-09-23

The cumulative Rosy checklist now includes section 7 for conventional schedules
and watchers. Source audit confirms folder/bookmark propagation from both
managers through `BackgroundTaskManager` into fresh and reattached execution
contexts, plus Ventura-safe watcher responsiveness controls. Focused validation
passes 16/16 tests across `IntelAgentRuntimeLaneTests`,
`ScheduleExecutionAnchorTests`, and `ExecutionContextFolderActivationTests`.
Those tests use model/folder fakes and do not establish live FSEvents, provider
completion, CRUD persistence, or real file access; Automation remains Partial.

The per-agent Automation cards still used the original borderless ellipsis
menus despite the 2026-09-13 Ventura failure. They now expose four direct themed
buttons—Edit, Run Now, Pause/Resume, and Delete—with tooltips, accessibility
labels, running-state disablement, and destructive confirmation. Rosy must test
the complete schedule and watcher lifecycles before promotion.

The audit also corrected an overclaim in Abilities/Tools: the Intel registry
does not register `schedule_next_run`, `cancel_next_run`, or `notify`, and the
upstream scheduler implementations are excluded from the Intel target. The
off-state gate is real and tested; positive model-callable Self-scheduling is a
declared dependency blocker. Conventional schedules and watchers use separate
manager paths and remain testable in this Automation slice.

Candidate `1.0.48` build `49` packages the direct Automation actions as
`Osaurus-Intel-Automation-2026-09-23.zip` (SHA-256
`65cf38ec3cd1c9e6e8ddfde927272258ef4b92481b74f5f0d7960a51363435b1`).
Archive and bundle validation confirm thin x86_64, macOS 13.0 minimum,
canonical `~/.osaurus`, six preserved framework symlinks, valid signing, and no
compressed-data errors. It supersedes `1.0.47` build `48` for the cumulative
General/Appearance, Abilities/Tools, and Automation Rosy pass.

### Pre-Rosy release-candidate review — 2026-09-23

The mandatory accumulated-diff review placed `1.0.48` build `49` on **HOLD**.
Although the artifact validates, Intel exposes Self-scheduling as an enabled
ability without registering `schedule_next_run`, `cancel_next_run`, or `notify`;
the off-state policy test does not prove the missing positive runtime. The
review also flags unsafe implicit `1.0`/`1` defaults in `build_rosy.sh` and the
expected limitation that local Automation tests do not exercise Rosy's
x86_64/FSEvents/provider stack. Full findings and the replacement-build gate are
in `RC_CODE_REVIEW_2026-09-23.md`.

### Release-review resolution — 2026-09-23

Build `1.0.49` (`50`) resolves both code findings without expanding the release
into a scheduler-backend port. Self-scheduling is explicitly unavailable in
Abilities and General/Scheduling, exposes no mutating control, and resolves
false at runtime even for legacy enabled records; conventional schedules and
watchers remain supported. `build_rosy.sh` now requires and validates explicit
version/build metadata.

The replacement artifact is
`Osaurus-Intel-Reviewed-Automation-2026-09-23.zip` (SHA-256
`c052d760f7d92f3f7926192098fa44952ed3833229373639b74d262f6a1e2861`).
Validation passes 38/38 focused General/Abilities/Automation tests and 8/8
Ventura rendering tests. The bundle is thin x86_64, targets macOS 13.0, uses the
canonical data root, preserves six framework symlinks, has a valid signature,
and passes ZIP integrity. The code-review hold is lifted; manual Rosy gates
remain. Build `49` is superseded.

### Memory acceptance resumed — 2026-09-23

Memory is the next cumulative Rosy slice. Build `1.0.49` (`50`) already contains
the reviewed Qwen content-array and managed-Router cold-discovery repairs, so no
new archive was produced for this documentation-only phase. The exact Memory
gate adds 10/10 passing tests (five distillation regressions and five pinned-
identity override tests), bringing the cumulative focused evidence to 56/56.

The authoritative manual steps are section 8 of
`ROSY_2026-09-22_AGENT_GENERAL_RETEST.md`. They deliberately exercise explicit
distillation before ordinary chat warms discovery, then cover facts, episodes,
empty state, Memory off/on, paid-operation consent, retry preservation,
persistence, and scoped deletion. Keep the feature at **Partial** until those
checks pass on Rosy.

### Memory completion build — 2026-09-23

The implementation audit found and closed the missing Intel historical-chat
backfill path. Unlike upstream's SQLite chat-history adapter, Intel reads its
persisted JSON `ChatSessionsManager` records, but retains the same turn pairing,
idempotency, original-date, cancellation, progress, and pending-work recovery
contract. Intel additionally enforces its deliberate per-agent paid-cloud
distillation consent and project-only namespace exception.

The review resolved cancellation and failed-insert accounting findings, re-
enabled the Memory implementation/database/backfill tests, and passed 1,054/1,054
package tests plus the 74/74 enumerated Memory gate. Candidate `1.0.50` (`51`) is
`Osaurus-Intel-Memory-2026-09-23.zip`, SHA-256
`40609fb2cf505d6bd4b6e23c1cb1b93fd2f5a71e93840ad3f398a431e0fcc930`.
It is thin x86_64, macOS 13.0 minimum, canonical-root enabled, strictly signed,
ZIP-valid, and retains six framework symlinks. It supersedes build `50` for Rosy.

### Rosy cumulative findings and RC repair — 2026-09-24

The completed Rosy pass for build `51` is preserved in Renée's execution copy;
the repository's focused repair/retest is
`docs/ROSY_2026-09-24_RC_RETEST.md`. Durable findings: deleted Intel JSON chats
need process-local tombstones because an open chat can save after deletion;
custom-avatar replacements need revisioned filenames to invalidate live image
caches; Router non-streaming responses may still arrive as SSE; standalone
Automation cards need the same direct actions as per-agent cards; Memory's
native pickers are not reliable under the themed Ventura Settings host; and the
built-in Orchestrator needs a private admitted-target roster in its fixed prompt.

`search_memory` in that pass is owned by the personal `renee.rag` Obsidian-vault
plugin, not upstream Osaurus Memory. Its stale post-disable invocation is a
revocation/UI-completion regression and must remain rejected. Do not add the
excluded upstream `SearchMemoryTool` to make that test pass.

Candidate `1.0.51` (`52`) packages these cumulative repairs as
`Osaurus-Intel-RC-2026-09-24.zip`, SHA-256
`30b7e1f397faf70123f532d047908a17b3f11c42ab543a0791b2595cefdb791c`.
The final package gate passes 1,060 tests in 159 suites and `git diff --check`.
The archive round-trip is ZIP-valid, thin x86_64, macOS 13.0 minimum,
canonical-root enabled, strictly signed, and retains six framework symlinks.
The remaining manual scope is exactly `ROSY_2026-09-24_RC_RETEST.md`.

### DeepSeek refresh candidate — 2026-09-25

Candidate `1.0.52` (`53`) adds the selective upstream DeepSeek hosted-model
refresh described above and supersedes build `52`. The transfer archive is
`build/rosy-deploy/Osaurus-Intel-RC-DeepSeek-2026-09-25.zip`, SHA-256
`3fbb3fb456c76d6adf4a805780a9c372691fe7f2b8110c9dcfa6f37ba99cbc79`.

The DeepSeek delta passes 2/2 focused tests and explicit arm64 and x86_64
package builds; the preceding cumulative candidate passed 1,060 tests in 159
suites. ZIP integrity and round-trip extraction pass. The extracted app is thin
x86_64, targets macOS 13.0, uses canonical `~/.osaurus`, preserves six framework
symlinks, and carries the stable Intel certificate designated requirement. The
M4 host reports the expected `CSSMERR_TP_NOT_TRUSTED` because that sovereign
self-signed certificate is not installed as a system trust anchor here.

### Public release 1.0.55 — 2026-09-25

The accumulated RC work (candidates `1.0.37`–`1.0.54`, shipped to Rosy only as
transfer ZIPs) is being released through Sparkle as `1.0.55` build `56`. Two release-
path facts: `cut_intel_release.sh` must pass `VERSION`/`BUILD_NUMBER` to
`build_rosy.sh` (which now refuses implicit defaults), and Rosy candidates
consume build numbers the appcast never sees. Auto-incrementing from the
appcast (last public build `37`) would have produced build `38`, below Rosy's
installed candidate `55`, so Sparkle would never offer it. Set `BUILD_NUMBER`
past the newest installed candidate when cutting a release after a candidate
series. The Qwen 4,096-token distillation retest in
`ROSY_2026-09-24_RC_RETEST.md` remains an open manual check.

**Sparkle key loss (2026-09-25).** The EdDSA private key behind public key
`7Nh8jSxFmE2DGw3BGQ9YdIpM115AU743EXUuMA9fN3c=` (every release through `1.0.36`)
was destroyed when the release Mac was formatted; no backup exists. Sparkle only
allows key rotation for Apple Developer ID–signed apps, and the Intel fork uses a
self-signed identity, so installed copies can never accept an update signed by a
new key. Recovery: generate a new key (`generate_keys`), replace `SUPublicEDKey`
in `App/osaurus/Info.plist`, cut the release, and install that build **manually**
once on Rosy; Sparkle updates resume from it. New public key (from `1.0.55`):
`bYYJJqFxkzbL190wyzy+wAvnkvmJFyEwf1CUH5WRljg=`. The self-signed code-signing
identity was also recreated, so expect one more Keychain "Always Allow" prompt.

**Back up the key immediately after creating it:** `generate_keys -x <file>`
and store the file in a password manager, then delete the file. A formatted or
erased keychain erases the key (Sparkle warns about this). Restore on a new Mac
with `generate_keys -f <file>`, or pass it to `cut_intel_release.sh` via
`SPARKLE_PRIVATE_KEY`.

### Upstream quick correctness batch — 2026-09-25

Ported the audit's quick correctness batch (see
[`UPSTREAM_AUDIT_2026-09-25.md`](UPSTREAM_AUDIT_2026-09-25.md) row notes):
MCP 0/1 integer bridging, missing-`properties` schemas, non-container
argument validation, canonical MCP names with naming hints, theme hex/picker
fixes, attachment text types, off-main link opening, schedule consumed-slot
anchor and overlap guard, a Core Model breaker, write-only EventKit, and an
Intel chat-store stale-write fix. Gate: 1,108 tests in 164 suites, isolated
root, no live-data writes.

Durable lessons from this batch:

- **Check the exclude list before cherry-picking.** `OpenAIAPI.swift`,
  `RemoteProviderService.swift`, `RemoteToolDetection.swift`,
  `ToolRegistry.swift`, `ChatEngine.swift`, `CoreModelService.swift`,
  `HostAPIBridgeServer.swift` and `SandboxPluginTool.swift` are not compiled
  on Intel. Their Intel seams are `CloudChatEngine` (tool encoding and
  dispatch), `IntelStubConformers.ToolRegistry`, `IntelAgentConformers.JSONValue`,
  and `IntelMemoryService`. A clean cherry-pick into an excluded file is dead
  code. The abandoned raw cherry-pick of `ff92720ee`/`19c6786e7`/`ffbd07bf6`
  is kept as a git stash for reference only.
- **Intel's offered-tool check is the security boundary.** Any tool-name
  rewriting (e.g. canonical MCP names) must happen before it and resolve only
  to a tool offered in this turn, so approval and policy run on the real name.
- **macOS 13 target:** upstream's two-value `onChange(of:) { old, new in }`
  does not compile; use the single-value form and track the previous value.
  The compiler reports these, so build before trusting a clean apply.
- **No automatic paid retries** extends to fallbacks: only a failure that
  cannot have been billed (no endpoint, HTTP 404) may be retried immediately.
- **`Localizable.xcstrings` merges:** keep Intel's file and insert only the
  commit's new keys; preserve Xcode's key order and the missing final newline,
  or the diff rewrites the whole catalog.
