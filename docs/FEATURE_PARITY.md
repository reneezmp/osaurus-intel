# Intel Feature Parity Ledger

This is the authoritative product-level companion to `UPSTREAM_SYNC.md`.
The commit ledger answers which upstream commits were examined. **It does not
prove that the Intel app has the resulting feature.** A sync may be current at
the commit level while feature parity remains incomplete.

## Status vocabulary

Use exactly these product states:

- **Working and tested** — the user-facing surface, runtime action, persistence,
  and focused tests work on Intel. Record what was actually tested.
- **Partial** — useful behavior works, but named upstream behavior is missing.
- **Dependency-blocked** — the intended route or explanatory state may exist,
  but the required Intel backend does not. This is not implementation.
- **Absent** — neither a usable feature nor an intentional dependency state is
  present.
- **Intentionally omitted** — the behavior has no place in the Intel product;
  record the product reason. Difficulty, conflict size, an absent file, or an
  `exclude:` entry is never sufficient.

The words **synced**, **current**, **reviewed**, and **ported** must always be
qualified. Prefer “commit coverage current through `<sha>`” or “the Intel slice
of `<feature>` is working and tested.” Never use commit coverage as shorthand
for feature parity.

## Mandatory upstream-review workflow

Every future upstream range review must do all of the following before calling
the work complete:

1. Read this file, `UPSTREAM_SYNC.md`, the current `Package.swift` exclusion
   list, and the latest feasibility/backlog documents.
2. Inventory user-visible upstream features in the range, including commits
   that touch only new, absent, or excluded files.
3. Give every affected feature one product state from the vocabulary above.
4. For **Partial** and **Dependency-blocked**, name the missing behavior and the
   exact dependency cluster. Add or update a dependency-ordered backlog entry.
5. Revisit prior SKIP and DEFER decisions when a feature adopts a replacement
   Intel backend. Exclusion is a routing signal for a hand port, not a verdict.
6. Verify both layers separately:
   - commit coverage: every commit classified with evidence;
   - feature coverage: every user-visible feature represented in this ledger.
7. Test behavior, persistence, relaunch, failure states, and Intel architecture.
   A green suite covering only compiled files does not prove upstream parity;
   list excluded or unavailable test families explicitly. Record automated and
   Rosy manual evidence separately; never imply one from the other.
8. Report the result using separate headings: **Working**, **Partial**,
   **Dependency-blocked**, **Absent**, and **Intentionally omitted**.

No visible control counts as shipped until its store, runtime action,
persistence, and focused tests work. An explanatory dependency card is useful
UI, but its feature state remains **Dependency-blocked**.

## Current checkpoint — Rosy acceptance and build 53

The consolidated end-of-roadmap Rosy pass lives in
[`ROSY_FINAL_ACCEPTANCE_CHECKLIST.md`](ROSY_FINAL_ACCEPTANCE_CHECKLIST.md). Add
new feature-specific acceptance work there when a roadmap slice lands so the
final Intel release is tested as one integrated product.

| Area | Product state | Evidence and remaining work |
|---|---|---|
| OpenAI ChatGPT/Codex OAuth | Working and tested | Login, catalog filtering, Responses Lite streaming, follow-up context, and cancellation passed Rosy acceptance. |
| Knowledge | Working and tested | Local collections, indexing, search, refresh, unavailable-folder reporting, project attachment, richer details, indexed document/category rows, observable/persistent custom-agent grants, and live runtime enforcement passed on Rosy with replacement `1.0.38` build `39`, including fresh/restored chats, open-chat revocation, new-chat denial, and re-grant. Inline Edit, categorized/uncategorized badges, and the shared card/detail deletion confirmation also passed in the completed 2026-09-22 window-safety phase. |
| Projects and working folders | Working and tested | Instructions, Knowledge attachment, shared memory, default agent, per-chat folder ownership, persistence, and relaunch passed Rosy acceptance. |
| Claude Code | Working and tested | CLI auth, streaming, cancellation, progress, folder access, and opt-in file/shell execution passed Rosy acceptance. Osaurus MCP configuration remains dependency-blocked. |
| Agent Settings — General and Appearance | Working and tested | Rosy's 2026-09-25 build 53 retest passed deleted-chat non-resurrection across relaunch and live custom-avatar replacement/clear across Settings, Agents, header, and sidebar, in addition to the earlier model isolation and Agent Data checks. |
| Agent Settings — Abilities Overview and Tools | Partial | `renee.rag` `search_memory` worked while enabled; after disable, the agent correctly used the still-offered `search_knowledge` and acknowledged `search_memory` was unavailable. Build 54's no-tools folder prompt correction passed Rosy's retest. A real stale structured-call rejection remains a separate test. `search_memory` is the personal Obsidian plugin tool, not upstream semantic Memory. |
| Agent Settings — Connections | Working and tested | Rosy retest on 2026-09-13 confirms Network, Remote Connections, and Agent Channels navigation; immediate and persistent Bonjour state; matching explanatory status; and `_osaurus._tcp` appearance/disappearance on a second device. Relay/workspace sharing, remote grants, and Channels remain accurately dependency-blocked with no dead actions; see `INTEL_AGENT_SETTINGS_BACKLOG.md`. |
| Agent Settings — Automation | Working and tested | Rosy passed conventional schedule/watcher creation, execution, folder inheritance, persistence, cleanup, and the visible standalone Edit, Run Now, Pause/Resume, and Delete actions with confirmation on build 53. Model-callable Self-scheduling remains a separate unavailable backend, not included in this promotion. |
| Agent Settings — Memory | Working and tested | DeepSeek distillation, cold routing, empty state, Memory off/on, paid consent, backfill, persistence, scoped cleanup, and the Ventura filters/720×500 inspector passed. Build 54's privacy-safe live shape proved the Qwen failure is a textless `finish_reason=length` at the 1,024-token output cap, not a missing SSE decoder field. The next candidate gives only Router `qwen-3-8-max` a bounded 4,096-token distillation allowance; Rosy acceptance remains pending. Rosy acceptance on public build `1.0.55` (`56`), 2026-09-25, passed the Qwen retest; Memory is accepted. |
| Agent Settings — Subagents and Sandbox | Dependency-blocked | Native delegation and container execution require Intel-compatible runtime work. Do not call their current explanatory pages implementations. |
| Insights | Working and tested | Rosy retest on 2026-09-13 confirms ordinary and tool-using chat records, model, duration, request/output, token and completion data, offered/executed tools, useful provider failures, and non-empty list rendering. Newer per-message diagnostics remain deliberately assigned to the later chat-interface revamp. |
| Ventura native controls | Working and tested | Themes, carets, readable controls, Knowledge forms, and message statistics passed earlier Rosy acceptance. `1.0.46` build `47` removed the Settings white band and passed Rosy acceptance with visible/clickable active and inactive traffic lights. Preserve the deliberate compatibility split: chat installs its replacement strip beside the native close button; Settings installs in the persistent frame root and uses the native button only as its coordinate source. |
| Web Search | Working and tested | Rosy acceptance on 2026-09-13 covers default-off per-agent runtime gating, keyless built-ins, web/news/image categories, provider failure/fallback/cancellation, credential lifecycle and secrecy, ordering, category preferences, custom REST providers, bounded safe extraction, legacy-plugin suppression, and Premium consent boundaries. Image search returns structured image/thumbnail URLs; inline gallery rendering is outside the current tool contract. Funded Router accounting remains tracked under Credits and Router. |
| Credits and Router | Working and tested | Signed hosted inference, balance, Checkout, usage, activity, and metadata-only diagnostics compile on Intel. Gates C1-C3 add an explicit Router opt-out, bounded top-up parsing, credit-unit presentation, Credits-only code redemption, an account usage center, Premium Web Search consent, a separate wallet auto-pay switch, and safe billing status. Onboarding redemption, Insights correlation, and Rosy Ventura acceptance remain pending; commit coverage alone is not parity. **Owner field acceptance, 2026-09-25:** Renée confirmed Credits and Router working on Rosy with build `1.0.55`; this closes the owner-deferred Credits/Router field test. |
| Orchestrator | Partial | Build 53's built-in chat reported an empty admitted roster despite both toggles being on. Build 54 shares admission logic across Settings/manual launcher/chat, reports blocked reasons, adds a built-in-only live `orchestrator_targets` query, and surfaces failed saves. The configured mascot replaces the hardcoded grey built-in avatar. Rosy reports that the build 54 focused checks passed; record a separate detailed approval/revocation trace before promoting the bounded delegation backend beyond partial. |
| DeepSeek hosted API models | Working and tested | Rosy build 53 passed hosted `deepseek-flash` and `deepseek-v4-pro` discovery and replies, direct versus reasoning-rail separation, and historical/local V4 compatibility. This is only the DeepSeek slice of upstream `a0aaa945d`; its Astra/Codex and other provider updates remain Partial below. |

## 2026-09-25 upstream range audit — product impact

The [complete 171-commit feasibility audit](UPSTREAM_AUDIT_2026-09-25.md)
classifies `7e109ade6..a4daf94c4`. This section is a **state and work map**, not
an implementation or Rosy-test claim. `7e109ade` remains the last synced
upstream checkpoint. The existing build 53 acceptance gates above remain open.

### Working and tested

- No newly audited feature was promoted by this assessment. Intel already has
  persistent Memory consolidation and launch catch-up equivalent to
  `888d8a55a`, and its bounded top-up conversion covers `8de938f91`; their
  existing Rosy and backend gates still apply.

### Partial

| Area | Missing behavior exposed by upstream | Next Intel gate |
|---|---|---|
| MCP and tool calls | `ff92720ee` fixes Foundation `NSNumber` 0/1 becoming booleans; `19c6786e7`, `fb2efe4db`, and `ffbd07bf6` cover no-arg schemas, canonical names, and null/primitive calls. | Hand-port to compiled MCP/provider and chat loop, preserving request scope and live allowlists; focused tests with actual encoded arguments. |
| Chat persistence | `979d53b40` and `219640c82` address single chat ownership and history-schema repair. | Adapt migrations to Intel's compiled stores, then verify old Rosy chats and tombstones through relaunch. |
| Automation | `7666cc6ba` fixes an early-wake/double-fire pattern still present in Intel `ScheduleManager`. | Anchor the consumed due slot, catch up per schedule, guard overlapping runs; test clock edges and background execution. |
| Core Model and Memory | `93513e8d6` adds configured-primary first-token timeout/circuit-breaker fallback; Intel currently falls back only for unavailable primaries. | Port to `CoreModelService`; distinguish timeout, cancellation, and intentionally resident/no-fallback configurations. |
| Themes and chat UX | `11f26f9a8` fixes an alpha-order round-trip still present in Intel; `5c6b998ec` and `210685eb9` improve attachment types and small-screen sizing. | Port with Ventura visual and save/reload tests; do not disturb the accepted traffic-light compatibility split. |
| Hosted model catalog and accounting | Only the DeepSeek slug slice of `a0aaa945d` is present. Astra/Codex OAuth discovery and fallback, context/reasoning profiles, `9b3336d68` prompt-cache fields, and `2ac423378` compaction remain. | Hand-port by provider, with authentication, stream, usage, and billing tests; compaction needs an Intel service and consent/state design. |
| Credits, Orchestrator, and folder tools | `9631a3b41` local read-only Credits API, `09844d5d6`/`c9021e91c` agent description UX, and `65ff7cc4e` richer file formats can attach to current Intel seams. | Separate endpoint authorization, existing-agent migration, and folder format/import limits; bounded Orchestrator is not native subagent parity. |

### Dependency-blocked

| Area | Dependency before implementation/promotion |
|---|---|
| Workspaces and remote sharing | `940d86a31` and follow-ups need B1/B2 identity, pairing, relay, host grants, workspace Router schema/billing, and revocation. |
| Channels and n8n | `a609acdb5` and follow-ups need B3 transport, credential isolation, reply assignment, outbox/approval policy, and diagnostics. |
| Native subagents and sandbox tools | Request-scoped child budgets, lifecycle, model/folder permission boundaries, and compatible sandbox runtime must precede child writes or multi-turn execution. |
| Rich sandbox-backed file routes | The sandbox `/workspace` import path in `65ff7cc4e` needs sandbox and database restoration; Intel can separately port safe rich reading to existing folder tools. |

### Absent

- Native Apple app tools (`348bc70cb`) are not in Intel. They are feasible,
  not rejected: upstream Calendar/Reminders uses macOS 14 full-access APIs,
  while Rosy requires a macOS 13 EventKit path plus TCC, per-agent grants,
  tool approvals, and plugin migration. See B6 in the Agent Settings backlog.
- Upstream Privacy filtering, Browser Use/Computer Use, and rich document
  generation remain absent. Each needs a separate Intel capability and
  authorization design; the upstream audit records their commit slices.

### Intentionally omitted

- MLX/vMLX pins, local model downloads/residency and bundle-specific fixes
  have no compiled Intel inference path today. Upstream arm64 appcasts and
  release scripts do not replace the Intel x86_64 release flow. Raptor
  campaign UI and new install-cohort telemetry are not Intel product features.
  This does **not** omit generic fixes contained in mixed commits; their
  Intel slices are marked Split or Port in the full audit.

## Prioritized roadmap

These are explicit product priorities, not promises that their current upstream
implementations compile unchanged on Intel.

1. **Completed 2026-09-22 — Rosy acceptance repairs** — Knowledge grants,
   card parity/deletion safety, inactive controls, Core Model rendering, and
   integrated Settings chrome passed on Rosy. Preserve the Settings frame-root
   traffic-light compatibility rule documented in `UPSTREAM_SYNC.md`.
2. **Complete the remaining main acceptance pass** — rerun the still-open Agent
   General/Appearance, Abilities/Tools, Automation, Memory, Orchestrator, and
   declarative-configuration gates in `ROSY_FINAL_ACCEPTANCE_CHECKLIST.md`.
3. **Orchestrator** — restore the built-in configuration/delegation agent in
   dependency order. Separate configuration features that can use current Intel
   managers from delegation features that require the subagent runtime.
   The dependency gates, cloud/custom-agent spike, unavailable target boundary,
   storage-safe test contract, and Rosy Ventura checklist are tracked in
   [`ORCHESTRATOR_INTEL_PLAN.md`](ORCHESTRATOR_INTEL_PLAN.md). Configuration and
   runtime routing (Gates 1–2), the internal Gate 3 probe, bounded Gate 4, and
   bounded declarative configuration Gates 5A–5B are implemented. Child tools, durable or
   background execution, and model-owned autonomous delegation remain later
   dependency work.
4. **Revamped Credits** — audit wallet, activity, redemption, premium-search,
   Router, and diagnostics paths. Never expose balance-changing controls without
   the real remote service and error handling.
5. **Channels** — Discord, Slack, Telegram, iMessage, WhatsApp, incoming-agent
   assignment, outbox, activity, allowlists, credentials, and send approvals.
   The Agent Settings attachment points are tracked in
   `INTEL_AGENT_SETTINGS_BACKLOG.md` B3.
6. **Browser Use and Computer Use** — run a capability spike before porting.
   Record an Intel/macOS support matrix for Ventura and newer releases,
   Accessibility and Screen Recording behavior, browser-engine availability,
   model requirements, and approval/cancellation semantics. Do not assume these
   are Apple-Silicon-only or universally Intel-compatible.
7. **Web Search — free/custom and Premium C3 implemented** — complete Rosy
   acceptance for provider ordering, hosted/native fallback, test search,
   custom REST providers, Keychain credentials, extraction, billing consent,
   and per-agent opt-in gating. Premium remains Partial until the real Router
   endpoints and funded/test-account paths pass on Rosy.
8. **Media, cloud models only** — implement remote image/video model discovery,
   defaults, permissions, quoting, job recovery, and results. Exclude local MLX
   generation/editing from the Intel scope unless a separate compatible runtime
   is proven.
9. **Privacy** — audit telemetry controls and implement cloud-bound PII
   redaction/review, provider/model policy, placeholder lifecycle, storage, and
   “forget redactions” behavior against the Intel cloud engine.

### New audit-derived implementation queue (after current Rosy acceptance)

1. **Correctness/safety:** MCP number and argument conversion, no-arg schemas,
   canonical provider names, null/primitive calls, chat-owner/schema repair.
2. **Reliability:** schedule due-slot accounting and Core Model timeout/fallback.
3. **Small scoped ports:** theme alpha, file attachment types, window sizing,
   hosted model catalog/profiles and prompt-cache accounting.
4. **Staged feature clusters:** rich folder formats, Apple app tools (B6),
   Channels/n8n (B3), Workspaces (B1/B2/B7), and native subagent/computer-use
   capability spikes. Each cluster is a feasible backlog, not a rejection.

## Deliberately later

- The revamped chat interface added upstream on 2026-09-09, including the
  current message action rows, per-message diagnostics affordances, and stats.
- The revamped Workspaces tab added upstream on 2026-09-09.

- Orchestrator child tools and model-owned autonomous delegation. Intel cloud
  tool-loop limits are not request-scoped, so these require a later request-scoped
  budget and lifecycle contract.

They still receive commit classifications and feature-ledger rows during the
next review; “later” means scheduled later, not silently skipped.
