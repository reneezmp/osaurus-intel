# Knowledge writing on Intel

Backlog id: `W-knowledge-write` in [`INTEL_MISSING_FEATURES_BACKLOG.md`](INTEL_MISSING_FEATURES_BACKLOG.md).
Rosy checklist: [`ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`](ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md#knowledge-writing).

Until 2026-09-30 Intel Knowledge was read-only (`search_knowledge`,
`read_knowledge`, `list_knowledge`). Upstream's current design lets agents
write, with consent at call time and every change revertable. This is being
ported in two parts.

## Part 1 — writing, approval, history, folder watcher (shipped 2026-09-30)

### What agents can do

| Tool | Policy | What it does |
|---|---|---|
| `write_knowledge` | Ask (Always Allow possible) | Create or replace whole markdown documents; `documents` is an array, so one call = one approval. |
| `edit_knowledge` | Ask (Always Allow possible) | Find/replace edits inside a document (unique match required, or `all`). Upstream added it because restating a long document truncates it. |
| `delete_knowledge` | **Ask every call** (`PerCallApprovalTool`) | Remove documents. |

- **Who:** any agent with a grant to the collection — the grant is the
  boundary, exactly like the read tools (upstream dropped the separate curator
  role; #2439). The built-in agent has no Knowledge.
- **Only markdown** (`.md`, `.markdown`, `.mdx`) can be written; binary sources
  are never overwritten. Paths are confined to the collection folder
  (re-checked in `KnowledgeWriteService`).
- **Approval card:** the engine asks the tool for a `KnowledgeWritePreview`
  (`ToolRegistry.knowledgeWritePreview`) and `ToolPermissionView` shows paths,
  create/replace/delete and a diff per document instead of JSON (the card
  widens to 560 pt). Warnings flag dropped frontmatter and unfenced keys.
- **Write log + revert:** every change records what it replaced in
  `~/.osaurus*/knowledge/write_log.sqlite` **before** touching the file.
  Knowledge → **History** (appears once anything was written) lists runs;
  revert a run or a single document. A revert refuses to discard a later
  human edit (hash check).
- Writes re-index the collection immediately.

### Folder watcher

`KnowledgeFolderWatcher` (upstream) now runs from launch: edits made to a
collection folder outside Osaurus re-index within ~5 s (FSEvents, debounced).
Stopped on quit.

### Intel adaptations

- The write log opens with the storage key + `EncryptedSQLiteOpener` behind
  `StorageMigrationCoordinator` (upstream: `OsaurusStorageOpener` +
  `StorageMutationGate`). It is **primary data** — an open failure is reported,
  never answered by quarantining/rebuilding (unlike the derived knowledge
  index). It is in `StorageMigrator.databaseTargets()` so it follows a key
  rotation.
- Upstream coerces arguments with `SchemaValidator` before execution; Intel
  tools get raw arguments. `KnowledgeWriteArguments.coerce` (stringified
  `documents`/`paths`/`edits` arrays) is applied by both the tools and the
  preview (when the schema is passed), so the card and the write agree.
- `WorkspaceWriteSafety.unifiedDiffText` and
  `KnowledgeIndexService.isMarkdown` were added (upstream helpers).
- **External surfaces:** upstream lists the write tools in
  `externallyDeniedToolNames`. On Intel no external surface runs registry
  tools (the MCP server serves fixed demo tools; the HTTP API runs none), so
  there is nothing to deny; revisit if an external surface ever executes
  registry tools. There is also no unattended auto-approval list: a scheduled
  run that writes shows the card and waits, as upstream.

### Tests

Upstream: `WriteKnowledgeToolTests`, `EditKnowledgeToolTests`,
`KnowledgeWriteLogTests`, `KnowledgeWritePreviewTests`,
`KnowledgeWriteServiceRoundTripTests`, `KnowledgeTypeInferenceTests` (106
tests; list checks for concepts Intel lacks are replaced by Intel equivalents,
see the comments). Intel: `IntelKnowledgeWriteTests` (grant-based offering,
preview hook, per-call delete, registry write + revert, rotation coverage).

## Part 2 — tickets, git sync, clickable paths, inferred types (shipped 2026-09-30)

### Stale-document tickets

| Tool | What it does |
|---|---|
| `flag_knowledge_stale` | File a ticket against a document (annotation only; one open ticket per document). |
| `list_knowledge_tickets` | Browse tickets in the agent's granted collections. |
| `update_knowledge_ticket` | Claim (`in_progress`) or release (`open`) a ticket. |

- All three follow the collection grant, like the other Knowledge tools.
- **Deliberate divergence:** upstream removed the Curator switch and offers
  `update_knowledge_ticket` with the ordinary grant, but its body still
  requires the retired `knowledgeCuratorEnabled` flag, so it refuses nearly
  everyone upstream. Intel drops that leftover check (grant = boundary) and
  rewords the description (no more "proposal approval").
- The Knowledge page shows open tickets under **Curation** with **Fix in a
  chat** (opens a chat with a granted agent, briefing pre-filled; the fix goes
  through the write tools and their approval card) and **Dismiss**.
- Tickets live in the derived knowledge index (as upstream); deleting a
  collection deletes its tickets. Upstream's proposal queue and its
  `proposals` table are not ported (Intel never had proposals).
- `KnowledgeCurationService` on Intel holds only `dismissTicket` /
  `resolveTicket`.

### Index schema

Intel numbers its own index schema (its v1 differs from upstream's):
**v2** adds `tickets`, **v3** adds `inferred_type`. The v3 migration fills
`inferred_type` for existing documents (it depends only on the path), because
the hash check would otherwise skip them. Readers use the explicit frontmatter
`type` when present, else the inferred one (search hits, `list_knowledge`,
`getDocument`); the Knowledge detail's "uncategorized" check still reports
missing *frontmatter* types. `KnowledgeDatabase` gained an internal `init()` and
`openInMemory()` for tests, as upstream.

### Git sync

As upstream ships it: the "clone from a git URL" option stays **hidden**
(upstream commented it out), but a collection whose folder is already a git
repo shows a **git** badge and a **Sync** button (fast-forward pull, then push,
using the user's own git credentials; divergence is reported, never merged).
`KnowledgeCollection.gitRemoteURL` records the detected `origin`. Deleting a
collection removes a managed clone folder (never a user folder) and its write
history.

### Clickable paths

`KnowledgeLinkResolver` + `SelectableTextView`: a knowledge path mentioned in a
reply (code span or prose, e.g. `Recipes/soup.md`) becomes a link when it
resolves to a real file in a registered collection. Click opens it;
right-click gives Open, Open With, Show in Finder, Copy Path. A link to a
document that has since gone shows a "Document Not Found" toast.

### Tests (part 2)

Upstream: `KnowledgeCurationTests` and `KnowledgeSyncAndDiffTests` (proposal
and external-list cases removed), `KnowledgeGitSyncTests` (real `git` in temp
repos). Intel: `IntelKnowledgeWriteTests` adds the v1 → v3 upgrade on an
encrypted Intel v1 file, ticket flag + claim without a curator flag, link
resolution and git detection.
