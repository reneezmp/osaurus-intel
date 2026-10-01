# Per-chat file history on Intel (`W-file-history`)

Upstream #2907 part A (`74e83c6c5`), ported 2026-10-01 after Renée chose it
ahead of cross-block selection, in two stages the same day. Stage 1: the
journal, revert, the File Changes inspector pane, `file_undo` /
`file_operation_history`, the sidebar badge, the transcript links and the
retention setting. Stage 2: upstream's inline diff cards
(`NativeFileDiffView`, the `.fileDiff` transcript block; #1683 plus
#2907's undo hooks).

## What the user gets

- **File Changes** in the chat window's right panel (lens bar: File Changes
  | History). One entry per tool call that touched files: **Timeline** (every
  change in order, grouped under the user message that led to it, each
  expandable to its files and diffs) and **Files** (where each file stands
  compared to before the chat). Revert one change, roll back to a point,
  revert one file, or Revert All. Multi-file reverts and conflicts ask
  first with a per-file list; every revert ends with an Undo toast,
  because a revert is itself recorded.
- **Conflicts:** a file edited outside the chat after the agent touched it
  is "edited since". Revert skips it unless you choose Overwrite, and an
  overwrite is still captured first, so nothing is lost.
- The toolbar's right-panel button shows the number of changed files while
  the panel is closed. History rows show a small `±N` badge; clicking it
  opens that chat with File Changes.
- Under a reply: "N files changed · View changes". On a collapsed tool row
  that changed files (shell commands, copies): "N files changed".
- **Diff cards:** every `file_write` / `file_edit` row gets a collapsed card
  below it: file name, +/− counts, copy, expand to the syntax-highlighted
  diff, and Revert / Undo / View change (File Changes on that write). While
  the model is still writing the call, the card grows live with the
  content ("…" badge); a failed write keeps its streamed content as a
  "preview" card.
- `dry_run: true` now previews text writes and edits too (before, Intel
  honoured it only for documents and **wrote text files anyway**).
- The agent gets `file_operation_history` (what this chat changed, newest
  first) and `file_undo` (undo the last change, one `operation_id`, or one
  `path` back to before the chat). Every mutating folder tool result now
  carries `operation_id`.
- Settings ▸ General ▸ Advanced ▸ Data & Storage ▸ **File History**: keep history until the
  chat is deleted (default), for 90 or 30 days, and an optional size limit
  (1/5/20 GB). Deleting a chat always deletes its history.

## How it works (upstream design, unchanged)

- `FileChangeJournal` (actor) wraps every mutating call in a capture. Tools
  that name their targets (`file_write`, `file_edit`, `file_copy`) get a
  **precise** snapshot of just those paths (plus missing parent folders).
  Opaque tools (`shell_run`) get a **shadow** capture: a cheap manifest of
  the folder before and after, with pre-images from an APFS-cloned shadow
  copy of the folder that is kept in sync between calls.
- Bytes go into `FileObjectStore`, a content-addressed store
  (`file-history/objects/`, sha256 keys, written to a temp file, hashed,
  fsynced, then renamed). A blob is checked against its hash before it is
  swapped back in.
- When a folder can't be snapshotted (over 50,000 entries for a shadow, or
  a huge tree on a volume that can't clone), the user is asked before the
  call runs (`ToolPermissionPromptService` with `perCallApprovalOnly`), and
  an approved call is recorded as **Not tracked**.
- Crash safety: a capture's pre-state is written to `file-history/pending/`
  before the tool runs; leftovers are finalized on the next launch.
- `ToolRegistry.execute` (Intel version in `IntelStubConformers.swift`) is
  the single capture point: any tool with `mutatesHostFolder` called with a
  chat session id bound. Chat, scheduled and watcher runs all go through it.

## Intel differences (keep on re-sync)

| Upstream | Intel | Why |
|---|---|---|
| Rows in the SQLite chat-history database (schema v20) | `Storage/FileHistoryDatabase.swift`, its own encrypted file `file-history/history.sqlite` (storage key + `EncryptedSQLiteOpener`), same tables and query API; listed in `StorageMigrator.databaseTargets` for key rotation | Intel stores chats as JSON and never compiled `ChatHistoryDatabase` |
| Database opened at launch by the chat store | The shared journal opens it on first use (`openSharedDatabaseIfNeeded`, also from `purgeSession`) | Nothing else on Intel needs it |
| Imports pre-journal `sandbox_changes` rows | No-op stubs on `FileHistoryDatabase`; the two legacy-import tests are not ported | Intel never shipped the sandbox |
| Replaced `FileOperationLog` | `FileOperationLog` / `FileOperation` removed too | Intel's log was in-memory and never surfaced in UI |
| Sandbox / bridge roots, background jobs, ownership repair (`chown` in the VM) | Host folder only; `ownershipRepairEnabled = false`, `repairOwnership` body removed | No sandbox on Intel |
| Untracked prompt: headless lanes `autoApproveToolPrompts` / `denyUnapprovedToolPrompts` | Intel's approval card; a test process refuses unless `FileChangeCapture.untrackedApprovalForTesting` is bound | Intel has no headless approval lanes |
| `refreshFileChanges()` called at every switch site | Also driven by the active session and its `$sessionId` (`observeActiveSessionFileChanges`), plus explicit calls where a blank tab resets in place | Intel's tab code differs; one observer covers every switch |
| `ChatConfiguration.fileHistoryRetention` (Codable struct) | Field on Intel's class plus its `chat.json` snapshot | Intel's configuration is a class |
| `file_write` / `file_edit` results (upstream folder tools) | Intel's tools gain upstream's diff payload (`WorkspaceWriteSafety.preview`) and text `dry_run`, but keep Intel's result `text` (its line count, its edit summary) and schema; no `mode: append`, batch `edits`, `file_reference`, content hashes or verification notes | Those belong to upstream's folder-tool hardening, a separate port |
| `WorkspaceWriteSafety` (upstream) | Took only `overwritesExistingFile` (no overwrite warning on edits) and the empty-side diff fix (a new file is `+N −0`) | Rest of upstream's version is the same separate port |
| Blocks from `ContentBlock.generateBlocks` | Emitted by Intel's own `BlockMemoizer` (`IntelDataConformers.swift`): calls split into groups around each card; the first group keeps `toolgroup-<turn>`, later ones get `-1`, `-2`…; cards are `filediff-<callId>` / `filediff-pending-<turn>` as upstream | Intel's transcript builder is its own |
| `highlightCode` with a highlighter lock | Same function in Intel's `CodeBlockView.swift`, no lock | Intel's shared Highlightr is main-thread only |
| `themedAlert(accessory:width:)` | Added to Intel's `ThemedAlertDialog` (the card already supported both) | Needed by the revert confirmation |

Ventura: single-value `onChange` in `FileChangesPanel` (marked "Intel:").
`clonefile` and APFS clones work on macOS 13.

Privacy note (same as upstream): blobs and shadow copies are plain copies of
the user's own files (as plain as the originals), in `0700` folders under
the data directory; the database that indexes them is encrypted.

## Files

- From upstream, verbatim: `Services/FileHistory/FileChangeModels.swift`,
  `FileObjectStore.swift`, `FileChangeSummaryStore.swift`,
  `FileDiffEngine.swift` (now the full file, journal-backed diff included),
  `Services/Sandbox/SandboxWorkspaceChange.swift` (root kinds and entry
  types), `Folder/ShellMutationPlanner.swift`,
  `Views/Settings/FileHistoryRetentionSection.swift` (one "Intel:" `let`).
- From upstream, Intel edits marked: `FileChangeJournal.swift`,
  `FileChangeJournal+Revert.swift`, `FileChangeCapture.swift`,
  `Views/Chat/FileChangesPanel.swift`.
- New Intel file: `Storage/FileHistoryDatabase.swift`.
- Changed: `Tools/OsaurusTool.swift` (the four capture hooks),
  `Folder/ChatExecutionContext.swift` (`currentChangeSetId`),
  `Folder/FolderTools.swift` (flags, targets, `operation_id`, the two new
  tools), `Folder/FileCopyTool.swift`, `Folder/WorkspaceWriteSafety.swift`,
  `IntelStubConformers.swift` (`ToolRegistry.execute`),
  `IntelManagerConformers.swift` (retention field, purge on chat delete),
  `ChatWindowState.swift`, `ChatInspectorPanel.swift` (now identical to
  upstream), `ChatContentView.swift` (`userPromptExcerpt`),
  `ChatSessionSidebar.swift` (badge), `NativeToolCallGroupView.swift` and
  `NativeMessageCellView.swift` (links; Intel's rows carry an argument
  preview / hug their last button, so the link swaps constraints),
  `StorageMaintenance.swift`, `StorageSettingsView.swift`,
  `SettingsSearchIndex.swift`, `ConfigurationView.swift`,
  `ThemedAlertDialog.swift`, `ToolPermissionPromptService.swift`,
  `OsaurusPaths.swift`, `StorageMigrator.swift`.

## Tests

- Upstream, adapted: `Tests/FileHistory/FileChangeJournalTests.swift`
  (Intel: retention round trip through `chat.json`, untracked gate through
  the test seam, `operation_id` instead of the diff payload, no legacy
  import), `FileDiffEngineTests.swift`, `FileHistoryTestEnv.swift`,
  `Tests/Folder/ShellMutationPlannerTests.swift` (minus `AgentTaskState`),
  `Tests/Chat/ChatWindowStateInspectorTests.swift` (File Changes cases back).
- Intel: `Tests/FileHistory/IntelFileHistoryTests.swift` (upstream's
  `file_undo` cases from suites Intel doesn't compile, `shell_run` rename
  capture, folder tool declarations, window count/deep link/pending
  request, purge on chat delete). The old `FileOperationLog` undo checks in
  `IntelFileCopyTests`, `IntelDocumentEditingTests` and
  `IntelRichFolderFormatsTests` now undo through the journal.
- Test storage: the shared journal and database live under
  `OsaurusPaths.root()`, so the test gate's `OSAURUS_TEST_ROOT` (or a
  suite's `overrideRoot`) keeps them off the live data directory.

## Stage 2: inline diff cards (shipped 2026-10-01)

- `Views/Chat/NativeFileDiffView.swift` is upstream's file, verbatim.
- `ContentBlockKind.fileDiff` and the emission live in
  `IntelDataConformers.swift` (`BlockMemoizer.fileDiff(for:…)`,
  `knownFileContents`); `NativeMessageCellView` gained
  `configureAsFileDiff`, the kind tag and the height estimate (upstream).
- `ChatTurn.pendingToolArgFull` (Intel's turn in `IntelDataConformers`)
  buffers a file-writing call's full arguments (cap 256 KB) for the live
  card, as upstream.
- Tests: upstream `Tests/Chat/FileDiffStreamingPreviewTests.swift`
  (verbatim); Intel `Tests/Chat/IntelFileDiffCardTests.swift` (diff
  payload, text `dry_run`, block emission for completed, failed, running
  and streaming writes). The journal test reads `operation_id` through
  `FileDiff.from(toolResult:)` again, as upstream.
- Rendering checked offscreen in light and dark (2026-10-01): header,
  counts, highlighting and add/remove tints draw correctly.

Manual QA: [`ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`](ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md#per-chat-file-history-w-file-history).
