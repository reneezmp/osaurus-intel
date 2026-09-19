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

The consolidated end-of-roadmap Rosy pass lives in
[`ROSY_FINAL_ACCEPTANCE_CHECKLIST.md`](ROSY_FINAL_ACCEPTANCE_CHECKLIST.md). Add
new feature-specific acceptance work there when a roadmap slice lands so the
final Intel release is tested as one integrated product.

| Area | Product state | Evidence and remaining work |
|---|---|---|
| OpenAI ChatGPT/Codex OAuth | Working and tested | Login, catalog filtering, Responses Lite streaming, follow-up context, and cancellation passed Rosy acceptance. |
| Knowledge | Working and tested | Local collections, indexing, search, refresh, unavailable-folder reporting, and project attachment passed Rosy acceptance. |
| Projects and working folders | Working and tested | Instructions, Knowledge attachment, shared memory, default agent, per-chat folder ownership, persistence, and relaunch passed Rosy acceptance. |
| Claude Code | Working and tested | CLI auth, streaming, cancellation, progress, folder access, and opt-in file/shell execution passed Rosy acceptance. Osaurus MCP configuration remains dependency-blocked. |
| Agent Settings — General and Appearance | Partial | The 2026-09-13 Rosy defects now have code and focused regression fixes: chat-local model changes no longer rewrite agent defaults; Claude controls and Agent Data are discoverable; and the header observes custom-avatar revisions. Rosy Ventura retest is still required before promotion. |
| Agent Settings — Abilities Overview and Tools | Partial | Live dispatch now re-reads the seeded allowlist for Auto and Manual chats, so removed tools fail before execution; mounted-folder and built-in Orchestrator tools retain explicit admission. Self-scheduling now has a visible persisted toggle. Focused tests pass; Rosy must confirm open-chat revocation and the unavailable rows. |
| Agent Settings — Connections | Working and tested | Rosy retest on 2026-09-13 confirms Network, Remote Connections, and Agent Channels navigation; immediate and persistent Bonjour state; matching explanatory status; and `_osaurus._tcp` appearance/disappearance on a second device. Relay/workspace sharing, remote grants, and Channels remain accurately dependency-blocked with no dead actions; see `INTEL_AGENT_SETTINGS_BACKLOG.md`. |
| Agent Settings — Automation | Partial | Schedule/watcher cards now open their editors without a hidden nested menu, watcher actions use visible buttons, and fresh and reattached background dispatches mount the request folder on the generated chat. Focused lifecycle/folder tests pass; Rosy must confirm menu readability, completion, and the complete edit/pause/resume/run/delete flow. |
| Agent Settings — Memory | Partial | The Router-qualified model survives cold discovery and Qwen text content parts decode into distillation; malformed/non-text payloads still fail with bounded redacted diagnostics. Focused tests pass. Rosy must rerun distillation before pinned facts, episodes, empty state, and Memory off/on can be accepted. |
| Agent Settings — Subagents and Sandbox | Dependency-blocked | Native delegation and container execution require Intel-compatible runtime work. Do not call their current explanatory pages implementations. |
| Insights | Working and tested | Rosy retest on 2026-09-13 confirms ordinary and tool-using chat records, model, duration, request/output, token and completion data, offered/executed tools, useful provider failures, and non-empty list rendering. Newer per-message diagnostics remain deliberately assigned to the later chat-interface revamp. |
| Ventura native controls | Partial | Rosy's first repair retest disproved the `f38bfecf1` visual fix: Settings traffic-light hit regions existed but their images were invisible, its field-editor caret remained hidden, and untouched native controls could stay white on white. The next candidate gives Settings an ordinary AppKit titlebar, keeps its native controls in Aqua independently of agent chat themes, reapplies field-editor text/caret rendering, restores the full local-folder Knowledge form, and accepts persisted token-count-only message statistics. Focused contracts pass; only a new Rosy Ventura retest can promote this row. |
| Web Search | Working and tested | Rosy acceptance on 2026-09-13 covers default-off per-agent runtime gating, keyless built-ins, web/news/image categories, provider failure/fallback/cancellation, credential lifecycle and secrecy, ordering, category preferences, custom REST providers, bounded safe extraction, legacy-plugin suppression, and Premium consent boundaries. Image search returns structured image/thumbnail URLs; inline gallery rendering is outside the current tool contract. Funded Router accounting remains tracked under Credits and Router. |
| Credits and Router | Partial | Signed hosted inference, balance, Checkout, usage, activity, and metadata-only diagnostics compile on Intel. Gates C1-C3 add an explicit Router opt-out, bounded top-up parsing, credit-unit presentation, Credits-only code redemption, an account usage center, Premium Web Search consent, a separate wallet auto-pay switch, and safe billing status. Onboarding redemption, Insights correlation, and Rosy Ventura acceptance remain pending; commit coverage alone is not parity. |
| Orchestrator | Partial | The built-in agent now has the upstream green identity, an Intel-safe built-in role extended by the editable prompt, and built-in-only model-callable `orchestrator_config` and bounded delegation tools. Admission, exact-pair approval, denial, fresh tool-free child execution, output bounds, and fail-closed behavior have focused coverage. Rosy chat acceptance remains the promotion gate; see `ORCHESTRATOR_INTEL_PLAN.md`. |

## Prioritized roadmap

These are explicit product priorities, not promises that their current upstream
implementations compile unchanged on Intel.

1. **Orchestrator** — restore the built-in configuration/delegation agent in
   dependency order. Separate configuration features that can use current Intel
   managers from delegation features that require the subagent runtime.
   The dependency gates, cloud/custom-agent spike, unavailable target boundary,
   storage-safe test contract, and Rosy Ventura checklist are tracked in
   [`ORCHESTRATOR_INTEL_PLAN.md`](ORCHESTRATOR_INTEL_PLAN.md). Configuration and
   runtime routing (Gates 1–2), the internal Gate 3 probe, bounded Gate 4, and
   bounded declarative configuration Gates 5A–5B are implemented. Child tools, durable or
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
5. **Web Search — free/custom and Premium C3 implemented** — complete Rosy
   acceptance for provider ordering, hosted/native fallback, test search,
   custom REST providers, Keychain credentials, extraction, billing consent,
   and per-agent opt-in gating. Premium remains Partial until the real Router
   endpoints and funded/test-account paths pass on Rosy.
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
