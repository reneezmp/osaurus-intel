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

## Part 2 — tickets, git sync, clickable paths, type inference (next)

Upstream pieces not yet ported: `flag_knowledge_stale` /
`list_knowledge_tickets` / `update_knowledge_ticket` + the tickets table and
Knowledge-tab ticket list, `KnowledgeGitSyncService` (clone from a remote,
fast-forward sync, commit/push writes), `KnowledgeLinkResolver` (clickable
knowledge paths in chat), and index use of `KnowledgeTypeInference`
(`inferred_type`; the helper is compiled and tested, the index does not use it
yet).
