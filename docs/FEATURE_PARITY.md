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

## Current checkpoint — 2026-09-10

| Area | Product state | Evidence and remaining work |
|---|---|---|
| OpenAI ChatGPT/Codex OAuth | Working and tested | Login, catalog filtering, Responses Lite streaming, follow-up context, and cancellation passed Rosy acceptance. |
| Knowledge | Working and tested | Local collections, indexing, search, refresh, unavailable-folder reporting, and project attachment passed Rosy acceptance. |
| Projects and working folders | Working and tested | Instructions, Knowledge attachment, shared memory, default agent, per-chat folder ownership, persistence, and relaunch passed Rosy acceptance. |
| Claude Code | Working and tested | CLI auth, streaming, cancellation, progress, folder access, and opt-in file/shell execution passed Rosy acceptance. Osaurus MCP configuration remains dependency-blocked. |
| Agent Settings — General and Appearance | Partial | Rosy acceptance on 2026-09-10 found incorrect migrated model display/runtime selection, missing reset/Claude controls/Delete Data, broken custom-avatar selection, unapplied agent themes, and app-wide control rendering defects. Persistence-only tests did not prove this surface. Repair and repeat Rosy acceptance before promotion. |
| Agent Settings — Abilities Overview and Tools | Partial | Rosy acceptance on 2026-09-10 found that Tools, Memory, Knowledge, Web Search, and scheduling state was not consistently enforced in the chat runtime, especially for existing sessions. Tool assignment UI persists, but runtime invalidation and capability tests are required before promotion. |
| Agent Settings — Connections | Partial | Rosy acceptance found the Network page did not expose Bonjour's persisted value as an operable toggle. Relay/workspace sharing, remote grants, and Channels remain dependency-blocked; see `INTEL_AGENT_SETTINGS_BACKLOG.md`. |
| Agent Settings — Automation | Partial | Schedule/watcher creation and persistence work, but Rosy acceptance found missing edit/pause/resume/run/delete actions, an unreadable watcher dropdown, and watcher runs that did not inherit the selected folder. |
| Agent Settings — Memory | Partial | Chat history opens, but Rosy acceptance found pinned facts and episode summaries missing for agents that have data. Private Agent Database remains dependency-blocked, and its Ability card must not expose working-looking controls. |
| Agent Settings — Subagents and Sandbox | Dependency-blocked | Native delegation and container execution require Intel-compatible runtime work. Do not call their current explanatory pages implementations. |
| Insights | Partial | Intel's replacement chat engine now records Chat UI requests, responses, timings, token estimates/provider usage, tool calls, and failures in the existing Insights ring buffer. Automated x86_64 compilation passes; Rosy must confirm entries and detail rendering before promotion. The newer per-message diagnostics belong to the deliberately later chat-interface revamp. |
| Web Search | Partial | Native provider ordering, built-in fallbacks, category routing, custom REST providers, Keychain credentials, test search, extraction, and opt-in per-agent tool gating are implemented and covered by focused tests. Rosy x86_64 UI/network acceptance is pending. Osaurus Premium routing remains dependency-blocked on Credits/Router. |
| Orchestrator | Partial | Intel Gates 1–4 are implemented. The manual Gate 4 sheet admits only explicitly selected custom agents and remote cloud models, scopes Ask/Deny/Always Allow to the exact launcher/target pair, runs one fresh child for one turn with no tools, enforces input/token/output/timeout and one-child limits, and returns bounded inline text. M4 automated validation covers the runtime and x86_64 build; Rosy Ventura QA is pending. Durable child sessions, background/model-owned spawning, and child tools remain dependency-blocked because Intel cloud tool-loop limits are not request-scoped. See `ORCHESTRATOR_INTEL_PLAN.md`. |

## Prioritized roadmap

These are explicit product priorities, not promises that their current upstream
implementations compile unchanged on Intel.

1. **Orchestrator** — restore the built-in configuration/delegation agent in
   dependency order. Separate configuration features that can use current Intel
   managers from delegation features that require the subagent runtime.
   The dependency gates, cloud/custom-agent spike, unavailable target boundary,
   storage-safe test contract, and Rosy Ventura checklist are tracked in
   [`ORCHESTRATOR_INTEL_PLAN.md`](ORCHESTRATOR_INTEL_PLAN.md). Configuration and
   runtime routing (Gates 1–2) and the internal Gate 3 probe are implemented and
   tested; the bounded Gate 4 surface is implemented. Child tools, durable or
   background execution, and model-owned autonomous delegation remain later
   dependency work.
2. **Revamped Credits** — audit wallet, activity, redemption, premium-search,
   Router, and diagnostics paths. Never expose balance-changing controls without
   the real remote service and error handling.
3. **Channels** — Discord, Slack, Telegram, iMessage, WhatsApp, incoming-agent
   assignment, outbox, activity, allowlists, credentials, and send approvals.
   The Agent Settings attachment points are tracked in
   `INTEL_AGENT_SETTINGS_BACKLOG.md` B3.
4. **Browser Use and Computer Use** — run a capability spike before porting.
   Record an Intel/macOS support matrix for Ventura and newer releases,
   Accessibility and Screen Recording behavior, browser-engine availability,
   model requirements, and approval/cancellation semantics. Do not assume these
   are Apple-Silicon-only or universally Intel-compatible.
5. **Web Search — free/custom slice implemented** — complete Rosy acceptance
   for provider ordering, test search, built-in fallbacks, custom REST
   providers, Keychain credentials, extraction, and per-agent opt-in gating.
   Osaurus Premium remains dependency-blocked on the Credits/Router roadmap;
   do not add a premium switch before that service path is real.
6. **Media, cloud models only** — implement remote image/video model discovery,
   defaults, permissions, quoting, job recovery, and results. Exclude local MLX
   generation/editing from the Intel scope unless a separate compatible runtime
   is proven.
7. **Privacy** — audit telemetry controls and implement cloud-bound PII
   redaction/review, provider/model policy, placeholder lifecycle, storage, and
   “forget redactions” behavior against the Intel cloud engine.

## Deliberately later

- The revamped chat interface added upstream on 2026-09-09, including the
  current message action rows, per-message diagnostics affordances, and stats.
- The revamped Workspaces tab added upstream on 2026-09-09.

- Orchestrator child tools and model-owned autonomous delegation. Intel cloud
  tool-loop limits are not request-scoped, so these require a later request-scoped
  budget and lifecycle contract.

They still receive commit classifications and feature-ledger rows during the
next review; “later” means scheduled later, not silently skipped.
