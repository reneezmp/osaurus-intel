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

## Current checkpoint — 2026-09-09

| Area | Product state | Evidence and remaining work |
|---|---|---|
| OpenAI ChatGPT/Codex OAuth | Working and tested | Login, catalog filtering, Responses Lite streaming, follow-up context, and cancellation passed Rosy acceptance. |
| Knowledge | Working and tested | Local collections, indexing, search, refresh, unavailable-folder reporting, and project attachment passed Rosy acceptance. |
| Projects and working folders | Working and tested | Instructions, Knowledge attachment, shared memory, default agent, per-chat folder ownership, persistence, and relaunch passed Rosy acceptance. |
| Claude Code | Working and tested | CLI auth, streaming, cancellation, progress, folder access, and opt-in file/shell execution passed Rosy acceptance. Osaurus MCP configuration remains dependency-blocked. |
| Agent Settings — General and Appearance | Working and tested | Identity, model choice, generation overrides, avatar, empty state, action bar, themes, and Claude Code configuration use Intel stores/runtime paths. Automated validation passed; Rosy UI acceptance remains pending. |
| Agent Settings — Abilities Overview and Tools | Working and tested | Existing Intel tool, Knowledge, Memory, web-search, and scheduling controls remain connected to their live implementations. Automated validation passed; Rosy UI acceptance remains pending. |
| Agent Settings — Connections | Partial | Bonjour is live. Relay/workspace sharing, remote grants, and Channels are dependency-blocked; see `INTEL_AGENT_SETTINGS_BACKLOG.md`. |
| Agent Settings — Automation | Working and tested | Schedules and watchers retain their Intel managers and creation flows. Automated validation passed; this revised layout still needs Rosy UI acceptance. |
| Agent Settings — Memory | Partial | Conversational history, pinned facts, and episodes are live. Private Agent Database is dependency-blocked. |
| Agent Settings — Subagents and Sandbox | Dependency-blocked | Native delegation and container execution require Intel-compatible runtime work. Do not call their current explanatory pages implementations. |

## Prioritized roadmap

These are explicit product priorities, not promises that their current upstream
implementations compile unchanged on Intel.

1. **Orchestrator** — restore the built-in configuration/delegation agent in
   dependency order. Separate configuration features that can use current Intel
   managers from delegation features that require the subagent runtime.
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
5. **Web Search** — mirror provider ordering, test search, built-in fallbacks,
   category preferences, custom REST providers, credential storage, and agent
   capability gating. Paid/premium routing must stay explicit and opt-in.
6. **Media, cloud models only** — implement remote image/video model discovery,
   defaults, permissions, quoting, job recovery, and results. Exclude local MLX
   generation/editing from the Intel scope unless a separate compatible runtime
   is proven.
7. **Privacy** — audit telemetry controls and implement cloud-bound PII
   redaction/review, provider/model policy, placeholder lifecycle, storage, and
   “forget redactions” behavior against the Intel cloud engine.

## Deliberately later

- The revamped chat interface added upstream on 2026-09-09.
- The revamped Workspaces tab added upstream on 2026-09-09.

They still receive commit classifications and feature-ledger rows during the
next review; “later” means scheduled later, not silently skipped.
