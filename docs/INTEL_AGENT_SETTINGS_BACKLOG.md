# Intel Agent Settings Dependency Backlog

This backlog is subordinate to the product states in
[`FEATURE_PARITY.md`](FEATURE_PARITY.md). Routes and dependency cards do not
make their underlying features implemented.

The Agent editor mirrors upstream 0.25.0 navigation even where an Intel backend is not yet compiled. These routes are intentional contracts: future ports attach to them instead of redesigning the editor again.

## Stable routes

- `connections/network` — Bonjour is live; Relay and Shared With remain dependency states.
- `connections/connections` — host-side peer grants and revocation.
- `connections/channels` — incoming reply assignments and proactive destinations.
- `memory/memory` — chat history, pinned facts, and episode summaries are live.
- `memory/database` — nested `overview`, `tables`, `savedViews`, and `history` routes.
- Legacy database deep links (`home`, `schema`, `data`, `views`, `activity`) resolve into the matching nested Database route through `AgentDetailTabRoute`.

## B1 — Relay and workspace sharing

**Current UI:** Network shows working Bonjour discovery plus dependency-aware Relay and Shared With cards.

**Required backend:** restore the excluded relay tunnel, pairing/invite coordinators, shared-agent identity, workspace sharing host, and their credential lifecycle. Preserve Intel Keychain isolation where it already applies.

**Connection point:** replace the dependency cards in `AgentDetailView.networkTabContent`; keep the `network` raw route stable.

## B2 — Remote Connections

**Current UI:** the nested Remote Connections page and canonical `connections` deep-link exist.

**Required backend:** port host-side access-key grants, redeemed invites, peer liveness/usage, and immediate revocation. This depends on B1 identity and pairing.

**Connection point:** populate `remoteConnectionsTabContent` from the host grant store; do not add a second route.

## B3 — Channels and outbox policy

**Current UI:** Replies and Messages It Can Start have stable empty states under the canonical `channels` route.

**Required backend:** add the global Channels management tab, channel credential/security stores, transport runtime, reply assignment summaries, proactive destination editor, and outbox approval policy.

**2026-09-25 upstream audit:** n8n channel support (`a609acdb5`,
`94af9d41a`, `338425936`, `ef26b55b7`) is a feasible B3 transport, not an
Intel exclusion. Stage its webhook authentication, trigger/reply routing,
connection testing, error reporting, and secret migration behind the shared
channel identity/credential/outbox contract. iMessage helper hardening
(`92fb38a15`) follows the same transport boundary. Do not show n8n as
connected merely because upstream has a Settings card.

**Connection point:** replace the two dependency states in `channelsTabContent` and add links to the global `.channels` management destination once that destination exists. Do not expose Add Destination before the editor and policy store are live.

## B4 — Private Agent Database

**Plan (2026-09-25):** [`AGENT_DATABASE_INTEL_PLAN.md`](AGENT_DATABASE_INTEL_PLAN.md) — staged in three releases, covers B5 too.

**Current UI:** Database exposes Overview, Tables, Saved Views, and History without pretending storage exists. Historical deep links already migrate to these sections.

**Required backend:** restore `AgentDatabase`, `AgentDatabaseStore`, schema/database tools, saved-view persistence, write audit history, encrypted bundle import/export, and delete/reset behavior. Define and test Intel migration from any legacy `dbEnabled` records before enabling writes.

**Connection point:** replace `intelDatabaseTabContent` with the upstream workspace while retaining `AgentDetailTabRoute` and `AgentDatabaseSection`. Only then re-enable the Database ability toggle.

## B5 — Database automation history

**Current UI:** Automation remains Partial after the 2026-09-23 repair audit.
Per-agent schedule and watcher cards expose direct Edit, Run Now, Pause/Resume,
and Delete buttons instead of the Ventura-unreliable nested menus. Watcher
responsiveness uses plain themed buttons. Background dispatch carries and mounts
the selected folder for fresh and reattached chats, with focused fake-engine
completion coverage. Rosy must still confirm live FSEvents, real provider
completion, folder access, persistence, and the full action lifecycle. Database
History accurately explains that no database audit trail is present.

**Required backend:** after B4, connect schedule/watcher run records and database mutations to the Database History section. This is separate from conversational Memory history, which already works.

## B6 — Native Apple app tools

**Current UI/runtime:** Intel has no compiled AppleApps tool family. This is
**Absent**, not impossible or intentionally omitted. Upstream `348bc70cb`
adds a large Calendar, Reminders, Contacts, Notes, Mail, Maps, Messages,
Music, and Shortcuts integration family; the full commit verdict is in
[`UPSTREAM_AUDIT_2026-09-25.md`](UPSTREAM_AUDIT_2026-09-25.md).

**Required backend and policy:** inventory each app's available macOS API and
TCC behavior on Rosy's Ventura first. Upstream EventKit's Calendar/Reminders
`fullAccess` authorization is macOS 14+, so Intel needs a macOS 13-compatible
request/check path or a truthful unavailable state for individual operations.
Add per-agent opt-in, action-level approval for writes/sends, bounded results,
redaction, cancellation, and plugin-tool migration so a newly native name
cannot silently bypass an existing grant. Port by app family with tests and
Rosy permission-denied/relaunch acceptance; do not gate the entire family on
the first unsupported API.

## B7 — Workspace agents and team billing

**Current UI/runtime:** B1/B2 are dependency explanations; Intel has no
Workspace sharing backend. Upstream `940d86a31` plus its follow-up fixes are
**Stage**, not No: the shared-agent and billing behavior is feasible once the
remote trust boundary exists.

**Required backend:** B1 identity, pairing and relay, B2 host access grants
and immediate revocation, workspace membership/shared-agent persistence,
admitted-model routing and usage attribution, and Router workspace schema
0041/billing endpoints. Only after these may the Workspace roster, shared
agent dispatch, invite UI, and team billing be presented as live. Tests must
cover cross-device grant loss, model changes, account mismatch, relaunch, and
refusal to charge a personal wallet for team work without explicit policy.

## Acceptance rule

A dependency leaves this backlog only when its store, runtime action, editor, persistence, and focused tests all work on the Intel target. A visible switch or button without that complete path is not considered shipped.
