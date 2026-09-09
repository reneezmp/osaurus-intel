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

**Connection point:** replace the two dependency states in `channelsTabContent` and add links to the global `.channels` management destination once that destination exists. Do not expose Add Destination before the editor and policy store are live.

## B4 — Private Agent Database

**Current UI:** Database exposes Overview, Tables, Saved Views, and History without pretending storage exists. Historical deep links already migrate to these sections.

**Required backend:** restore `AgentDatabase`, `AgentDatabaseStore`, schema/database tools, saved-view persistence, write audit history, encrypted bundle import/export, and delete/reset behavior. Define and test Intel migration from any legacy `dbEnabled` records before enabling writes.

**Connection point:** replace `intelDatabaseTabContent` with the upstream workspace while retaining `AgentDetailTabRoute` and `AgentDatabaseSection`. Only then re-enable the Database ability toggle.

## B5 — Database automation history

**Current UI:** Automation remains fully functional through the Intel Schedule and Watcher managers. Database History explains that no database audit trail is present.

**Required backend:** after B4, connect schedule/watcher run records and database mutations to the Database History section. This is separate from conversational Memory history, which already works.

## Acceptance rule

A dependency leaves this backlog only when its store, runtime action, editor, persistence, and focused tests all work on the Intel target. A visible switch or button without that complete path is not considered shipped.
