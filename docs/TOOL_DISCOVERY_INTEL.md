# Automatic tool discovery on Intel

Status: **shipped 2026-09-30**, awaiting Rosy (checklist:
[`ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`](ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md#automatic-tool-discovery)).
Backlog id: `W-tool-discovery` in [`INTEL_MISSING_FEATURES_BACKLOG.md`](INTEL_MISSING_FEATURES_BACKLOG.md).

## What it is

An agent's capability picker has an **Auto-discover relevant capabilities**
switch (Agents → an agent → Tools). Its text always promised upstream's
behaviour — "the model starts with a small set and loads more from your
enabled capabilities on demand" — but on Intel Auto mode sent every enabled
tool on every turn. It now works as upstream's current design ("Design C"):

- **Auto (custom agents):** the request carries the agent's built-ins (agent
  loop, abilities, Apple apps, Knowledge, Database, folder tools, …) and one
  gateway tool, `capabilities`. **Plugin and MCP tools** the agent may use are
  listed in an **Enabled capabilities** section of the prompt and loaded on
  demand:
  - `capabilities({"ids": ["tool/<name>"]})` — one tool
  - `capabilities({"ids": ["plugin/<id>"]})` — a whole plugin/MCP provider group
  - `capabilities({"ids": ["skill/<name>"]})` — a skill (its instructions
    come back in the result)
  - `capabilities({"query": "…"})` — search the enabled set
  - `capabilities({})` — list the enabled ids (paginated)
- **Manual:** unchanged — the enabled set is sent every turn, no gateway.
- **Built-in agent (Orchestrator):** unchanged — fixed surface, no discovery
  (upstream does the same).

Loaded tools stay loaded for the rest of the chat (per-session
`SessionToolStateStore`, passed back as `additionalToolNames`). Changing the
agent's settings resets them (the session fingerprint includes the capability
revision).

## Security

- The load is **authorised against the agent's live catalog**: registered
  plugin/MCP tools that are not switched off in the Tools tab **and** are on
  the agent's allowlist (`effectiveEnabledToolNames`; nil = a never-opened
  picker = all). An id outside that set is refused ("No enabled capability
  matches …"), including via `plugin/<id>`.
- `CloudChatEngine` adds a loaded tool to the request's tool list for the
  next round, so the existing **offered-tool check** admits it; the tool still
  goes through `runtimeCapabilityDenial` (allowlist re-check) and its
  permission policy at dispatch.
- `capabilities` itself is refused for the built-in agent and in Manual mode.
- The composer re-filters `additionalToolNames` through the live catalog, so a
  tool removed from the allowlist can't come back from session state.

## Intel adaptations (vs upstream)

| Upstream | Intel |
|---|---|
| Persisted hybrid index: SQLite FTS BM25 (`ToolDatabase`, `ToolIndexService`) + VecturaKit embeddings (Apple Silicon) | Catalog built live from the registry; `CapabilitySearch` ranks in memory: BM25 over names/groups/descriptions fused (reciprocal rank) with the **local static embedder** Memory uses, only when its model is already on disk. Never a cloud embedder, never a download. |
| Loaded schema delivered inside the tool result; folded into `<tools>` at the next compose (paged-KV reasons) | The engine owns the tool loop: it drains `CapabilityLoadBuffer` after each call and adds the tools to the request for the next round. |
| `capabilities_discover` / `capabilities_load` kept for non-chat callers | Only the `capabilities` gateway (its schema/description verbatim). |
| Manifest frozen per session, compact tier for small models | Rendered per compose (verbose form, 70 tools / 30 skills cap); the catalog only changes when settings change, which resets the session anyway. |
| Methods in search results | None (methods are retired upstream; see `W-methods`). |

Upstream files not compiled, now classified `COV-tool-discovery` in
`scripts/upstream/classify_gap.py`: `ToolIndexService`, `ToolSearchService`,
`SkillSearchService`, `ToolDatabase`, `CapabilitySearchHealth`,
`CapabilitySearchEvaluator`, `CapabilityQueryIntent`, upstream
`SessionToolStateStore` (Intel keeps its own).

## Skills fixed along the way

Skills never reached the model on Intel: `SkillManager.skill(for:)` and
`buildFullInstructions` were stubs returning nil, and the `/` popup did not
list skills. Now:

- `skill(for:)` / `skill(named:)` read the real list; `buildFullInstructions`
  and `loadReferenceContents` are upstream's.
- The `/` popup lists every installed skill (upstream `allCommands` order);
  picking one applies it to the next message.
- `SkillManager.refresh()` runs refreshes one after another (the launch
  refresh could finish after a later one and put back a stale list).
- Skills are loadable through `capabilities` (`skill/<name>`), filtered by the
  agent's enabled skills.
- Note: `SkillStore` may re-case a skill name on reload (a name ending
  `F28E` comes back `F28e`); compare skills by id.

## Where things live

- `Tools/CapabilityTools.swift` — `CapabilityLoadBuffer`, `CapabilityCatalog`,
  `CapabilitySearch`, `CapabilityManifest`, `CapabilitiesTool`.
- `ToolRegistry` (Intel, `IntelStubConformers.swift`) —
  `isLoadableDynamicTool`, `openAISpecs(named:)`, `capabilities` registration
  and runtime gate.
- `SystemPromptComposer.composeChatContext` (Intel, `IntelDataConformers.swift`)
  — the Auto-mode filter, gateway and manifest section ("Enabled
  Capabilities" in the prompt budget).
- `CloudChatEngine` — per-run buffer, `adoptingLoadedTools`.

## Tests

`Tests/Tool/IntelToolDiscoveryTests.swift`: search ranking, Auto vs Manual
composition, the gateway (allowlist, groups, search, list, session record),
gating, skills (lookup, `/` popup, load), and an HTTP-fixture engine run where
round 1 loads a plugin tool and round 2 is offered it and runs it.
