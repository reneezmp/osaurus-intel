# Private Agent Database (B4) + Database History (B5) — Intel plan

**Status (2026-09-25):** approved by Renée; implementation starts with Phase 0.
Update the phase status lines below as work lands.

## Context

The Agent editor already has a Database tab (Overview / Tables / Saved Views /
History) and a Database ability row, but on Intel they are placeholders: the
whole upstream subsystem (`AgentDatabase`, `AgentDatabaseStore`,
`LocalAgentBridge`, `DatabaseTools`, the `Views/Agent/Database/` workspace) is
excluded or stubbed. Backlog items B4 (private per-agent database) and B5
(automation/run history in Database › History) are the next target
(`docs/INTEL_AGENT_SETTINGS_BACKLOG.md`). Goal: a real, encrypted, per-agent
SQLite database the agent can build and query through tools, with a working
Database tab and a History view that shows scheduled/watcher/manual runs and
exactly what each run changed.

**Decisions made (Renée, 2026-09-25):**
- **Staged delivery.** Release 1 = database + tools + Database tab + History.
  Release 2 = CSV/TSV/JSON/JSONL file import/export. Release 3 = xlsx and
  encrypted `.osaurus-agent` bundle export/import.
- **Legacy `dbEnabled` flags reset to off** once; nobody gets database tools
  until they switch the ability on themselves.
- **Approvals:** read/insert/update/upsert/soft-delete/restore/views run
  automatically (all logged, soft deletes restorable); `db_execute` (raw SQL
  scripts) and `db_migrate` default to **Ask**. Per-tool overrides still work.

## Key research findings (drive the design)

- **Port from `upstream/main`, not the on-disk copies.** The excluded files
  on disk are ~3.4k lines behind (they predate #1640, #1869, #2052, #2255).
- **Intel already has most infrastructure:** vendored SQLCipher,
  `EncryptedSQLiteOpener`, `StorageKeyManager`, `PreparedStatementCache`,
  `OsaurusPaths.agentDatabaseFile/agentDirectory/...`, `AgentDetailTabRoute`
  + `AgentDatabaseSection`, `AgentMutationActivity`, `MigrationGenerator`,
  `ChatExecutionContext.currentAgentId/currentRunId/currentRunActor`, and a
  compiled `SchedulerDatabase` with `agent_runs`, `runs(agentId:)`,
  `deleteAllForAgent`. `StorageMigrator` already discovers
  `agents/<UUID>/db.sqlite` for rekey/export.
- **`BackgroundTaskManager` already writes `agent_runs` rows + run traces**
  when `effectiveDBEnabled` is true — so legacy-flag agents write hidden
  history today (fixed by the flag reset).
- **Intel agent deletion is incomplete:** `AgentManager.delete`
  (`IntelManagerConformers.swift:243`) removes only the JSON + knowledge grant;
  it leaves `agents/<id>/`, `agent_runs` rows, and never calls the (stub)
  `AgentDatabaseStore.deleteOnDisk`.
- **Upstream gap to fix in the port:** `db_query` is not verified read-only
  (only rolled back). Add a `sqlite3_stmt_readonly` check.
- **History = two sources:** runs from `SchedulerDatabase.agent_runs`; per-run
  detail from the agent DB's append-only `_changelog` joined on `run_id`.
  Exclude `trigger_kind = 'schedule'` (self-scheduled wakes; unsupported on Intel).
- **Stubs that will collide** and must be removed:
  `IntelAgentConformers.swift` `AgentDatabaseStore` (~:301), `LocalAgentBridge`
  (~:350); Release 3 also `AgentBundleService`/`AgentBundleManifest`
  (~:190–254). Un-exclude the real files in `Package.swift`.

## Phase 0 — Groundwork and safety fixes (small, ships with Release 1)

1. **One-time legacy flag reset.** In Intel `AgentManager` load path
   (`IntelManagerConformers.swift`), set `settings.dbEnabled = false` for every
   agent once, recorded by a marker (e.g. `UserDefaults` key
   `intelAgentDatabaseFlagReset.v1`, or a field in the knowledge-grant style
   sidecar). Persist through the normal `update()` so the capability revision
   bumps. Test: legacy JSON with `dbEnabled: true` → off after migration, and a
   later explicit enable survives relaunch.
2. **Complete agent deletion.** Extend `AgentManager.delete` to mirror upstream
   `AgentStore.delete`: `AgentDatabaseStore.deleteOnDisk` (removes
   `agents/<id>/`), `SchedulerDatabase.deleteAllForAgent`,
   `LocalAgentBridge.forget`. (Schedules/watchers/chats owned by a deleted
   agent: record current behaviour in the doc; not changed here.)
3. Declare `Notification.Name.agentStorageWarn` on Intel.
4. Add `dbEnabled` coverage to `Tests/Agent/AgentCodableMigrationTests.swift`.

## Phase 1 — Release 1: database, tools, Database tab, History

### 1a. Storage (port from upstream/main)
Un-exclude / replace: `Storage/AgentDatabase.swift`,
`Storage/AgentDatabaseStore.swift`, `Services/AgentBridge/LocalAgentBridge.swift`,
`AgentRuntimeBridge.swift` (result types), `SchemaDumper.swift`,
`SchemaSnapshot.swift`. Intel adaptations:
- Open with `StorageKeyManager.shared.currentKey()` +
  `EncryptedSQLiteOpener.open` (always encrypted, same as `SchedulerDatabase`),
  replacing upstream `OsaurusStorageOpener`/`StorageEncryptionPolicy`.
- Replace `StorageMutationGate` with Intel
  `StorageMigrationCoordinator.blockingAwaitReady()`.
- **Never quarantine/rebuild on open failure** (unlike `KnowledgeDatabase`):
  user-authored data → surface an error and leave the file untouched.
- Keep upstream schema v1 (`_tables_meta`, `_changelog`, `_views`), table
  conventions, soft delete, saved-view temp mirrors, quota via
  `AgentLimitsSettings`, per-agent serial queues.
- Register handles with `OsaurusDatabaseHandle` like other Intel DBs; verify
  `StorageMigrator` rekey includes the new files.
- Add `sqlite3_stmt_readonly` enforcement to `query()` / `db_query`.

### 1b. Tools
Port `Tools/Database/DatabaseTools.swift` minus `db_import`, `db_export` and
`db_execute`'s `path:` form (those need Release 2's resolver): `db_schema`,
`db_create_table`, `db_alter_table`, `db_migrate`, `db_insert`, `db_upsert`,
`db_update`, `db_delete`, `db_restore`, `db_query`, `db_execute` (sql only),
`db_define_view`, `db_run_view`, `db_drop_view`, `db_list_views`.
- `db_execute` and `db_migrate` conform to `PermissionedTool` with
  `defaultPermissionPolicy = .ask`; the rest default `.auto`.
- **Registration** in Intel `ToolRegistry.init` via `registerDatabaseTools()`
  + `static let databaseToolNames` (pattern: `registerKnowledgeTools`,
  `IntelStubConformers.swift:1194`).
- **Runtime gate** in `runtimeCapabilityDenial` (`IntelStubConformers.swift:1367`):
  database tools require `AgentManager.effectiveDBEnabled(agentId)`
  (web-search-style branch), return `.unavailable` otherwise. Database tools
  bypass the Tools-tab seeded allowlist like Knowledge tools (the ability
  toggle is the grant).
- **Prompt/tool composition** in `SystemPromptComposer.composeChatContext`
  (`IntelDataConformers.swift:1785–2010`): read `effectiveDBEnabled` with the
  other flags; filter database tools out when off, union into `allowed` when
  on; add the `OnboardingPrompt.block` section (update to upstream's latest
  version, minus import/export/bundle text until those ship) and the
  `SchemaSnapshot` section (use the non-blocking/`IfOpen` variant).
- `ChatExecutionContext.currentAgentId` is already bound around tool execution
  in `ChatView`/`CloudChatEngine`; background runs bind `currentRunId` +
  `currentRunActor` in `BackgroundTaskManager`, so `_changelog.run_id` links
  to `agent_runs` automatically.

### 1c. Database tab UI
Port `Views/Agent/Database/` from upstream/main: `DatabaseWorkspaceView`,
`DatabaseOverviewView`, `DatabaseTablesView` (+ `AgentDataBrowserModel`,
`AgentDataGridView`), `DatabaseSavedViewsView`, `DatabaseHistoryView`,
`DatabaseSharedUI`. Adaptations:
- Replace `intelDatabaseTabContent` (`AgentsView.swift:3030`) with
  `DatabaseWorkspaceView`, keeping `AgentDetailTabRoute`/`AgentDatabaseSection`
  deep links (handler at `AgentsView.swift:1387`).
- Hide Import/Export buttons and drag-and-drop in Tables until Release 2;
  hide bundle actions until Release 3.
- Replace the unavailable rows (`abilityUnavailableRow` at `:2442` and
  `databaseFeatureRow` at `:3447`) with a real toggle bound to `dbEnabled`
  (upstream `toolBackedSaveBinding`), plus a clear **privacy note**: on Intel
  every model is remote, so schema and query results are sent to the chat
  provider. Reuse `isUsingRemoteProvider` (`:3456`).
- Wire **Delete Data** (`deleteAgentDatabaseData`, `:3721`, currently dead) to
  a confirm alert; call throwing `deleteOnDisk` with error handling.
- Remove dead `showDeleteDBConfirmation` if unused after wiring.
- macOS 13 audit of every ported view: two-value `onChange`, `@Observable`,
  newer `Table`/`ContentUnavailableView` APIs etc. (the compiler catches them).
- Merge only the needed catalog keys (script used in the upstream batches:
  insert new keys, preserve order and missing trailing newline); de + zh-Hans.

### 1d. History (B5)
`DatabaseHistoryView`: list `SchedulerDatabase.runs(agentId:limit:200)`
(filter out `trigger_kind == "schedule"`), detail = header (status, duration,
error, tokens, cost) + `_changelog WHERE run_id = ?` rows. Chat-initiated
(user) turns in the foreground: confirm whether `currentRunId` is bound in the
interactive chat path; if not, their changes appear under an "Interactive
changes" group keyed by `run_id IS NULL` (decide during implementation, keep
honest labelling). No new write points needed for schedules/watchers.

### 1e. Tests (isolated per `docs/TEST_STORAGE_SAFETY.md`)
Port and adapt upstream `Tests/Storage/AgentDatabaseTests.swift`,
`DatabaseToolsTests.swift`, `AgentDataBrowserModelTests.swift`; add Intel tests:
- flag reset migration; deletion removes `agents/<id>/` + `agent_runs`;
- runtime denial when ability off, offered when on, Default agent never;
- compose: tools + onboarding + schema sections present only when on;
- `db_query` rejects writes/PRAGMAs; forbidden SQL list; soft delete/restore;
- `_changelog` rows carry `run_id` from a simulated background run;
- History source filters `schedule` trigger kind;
- encrypted-at-rest check (file not readable as plaintext SQLite);
- approval defaults: `db_execute`/`db_migrate` `.ask`.
Use `StoragePathsTestLock` + `OsaurusPaths.overrideRoot` + `_setKeyForTesting`
(template: `Tests/Helpers/ChatHistoryTestStorage.swift`).

## Phase 2 — Release 2: file import/export (CSV/TSV/JSON/JSONL)

Port `DatabaseImport`, `DatabaseExport`, `AgentImportRunner`,
`DatabaseFilePathResolver` from upstream/main with xlsx paths compiled out,
and the resolver reduced to the **host working-folder root**
(`ChatExecutionContext.currentFolderRoot` + `FolderToolHelpers.resolvePath`;
drop the sandbox branch). Enable `db_import`, `db_export`, `db_execute path:`;
turn on Tables Import/Export + drag-and-drop. Tests: parse/infer, 64 MiB caps,
path escape refusal, round-trip.

## Phase 3 — Release 3: xlsx + encrypted agent bundles

- xlsx: backport `XLSXAdapter.workbook(from:filename:)`,
  `XLSXEmitter.packageBytes(for:)`, `FileWriteDocumentRouting.maxRowsPerSheet`
  (relates to deferred #91 rich formats — do together if #91 is scheduled).
- `AgentBundleService`: PBKDF2 (600k) + AES-GCM sealed bundle key, tar via
  `/usr/bin/tar`; replace `StorageFormatConverter`/`StorageEncryptionPolicy`
  with `EncryptedSQLiteOpener.rekey` on a copied file; `AgentStore.save` →
  `AgentManager.add/update`; address collision → Intel `assignAddress`.
  Two-step import (review → activate). Remove the Intel bundle stubs.

## Documentation (same change as each release, per AGENTS.md)

- `docs/FEATURE_PARITY.md`: Database row states per release.
- `docs/INTEL_AGENT_SETTINGS_BACKLOG.md`: B4/B5 status; what stays staged.
- `docs/UPSTREAM_SYNC.md`: port log (source commits, Intel adaptations,
  readonly fix, never-quarantine rule).
- New `docs/AGENT_DB.md` Intel section (or extend existing `docs/AGENT_DB.md`):
  storage location, encryption, tools, approval defaults, privacy note.
- New Rosy checklist `docs/ROSY_<date>_AGENT_DATABASE_RETEST.md` per release.

## Verification (each release)

1. Focused suites, then the full suite:
   `TEST_STORAGE_ROOT="$(mktemp -d /tmp/osaurus-tests.XXXXXX)" OSAURUS_TEST_ROOT="$TEST_STORAGE_ROOT" arch -x86_64 /usr/bin/swift test --package-path Packages/OsaurusCore --no-parallel --disable-xctest`
   — confirm non-zero executed count and no files under `~/.osaurus` changed.
2. `swift build --package-path Packages/OsaurusCore --arch x86_64`.
3. `scripts/i18n/check.sh`: no new missing keys vs baseline.
4. Rosy manual pass (checklist): enable ability on a test agent → ask it to
   create a table, insert, query, define a view → Tables/Overview/Saved Views
   show it → run a watcher/schedule that writes → History shows the run and
   its changes → `db_execute` prompts for approval → Delete Data wipes and
   recreates lazily → delete agent removes its folder → relaunch persistence →
   Ventura rendering of the workspace.
5. Candidate build via `scripts/build/build_rosy.sh` with explicit
   `VERSION`/`BUILD_NUMBER` > current Rosy build.

## Critical files

- `Packages/OsaurusCore/Package.swift` (un-exclude DB files)
- `Models/Chat/IntelConformers/IntelAgentConformers.swift` (remove stubs)
- `Models/Chat/IntelConformers/IntelStubConformers.swift` (ToolRegistry)
- `Models/Chat/IntelConformers/IntelDataConformers.swift` (composeChatContext)
- `Models/Chat/IntelConformers/IntelManagerConformers.swift` (flag reset, delete)
- `Views/Agent/AgentsView.swift` (tab content, toggle, Delete Data)
- New: `Storage/AgentDatabase*.swift`, `Services/AgentBridge/*`,
  `Tools/Database/DatabaseTools.swift`, `Views/Agent/Database/*`
