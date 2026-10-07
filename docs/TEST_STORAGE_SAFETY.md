# Test Storage Safety

This repository contains tests for stores that normally read and write
`~/.osaurus`. A test must never be allowed to discover that live location by
accident. Passing tests are not sufficient evidence: the test process must also
leave the user's data byte-for-byte unchanged.

## 2026-09-10 incident

During the Agent Settings repair, early runtime tests changed and saved the
shared `ChatConfigurationStore`. At the same time, other Swift Testing suites
temporarily changed the process-wide `OsaurusPaths.overrideRoot` and later
removed their temporary directories. Swift Testing ran those suites
concurrently.

The operations interleaved as follows:

1. A storage test redirected `OsaurusPaths.overrideRoot` to its temporary root.
2. A runtime test loaded or saved the shared chat configuration while that
   override was active.
3. The storage test restored the global root and removed its temporary folder.
4. Runtime-test cleanup saved its sparse fixture after the root had returned to
   the default, writing the fixture into the live `~/.osaurus/config/chat.json`.

The pre-incident log showed the live configuration using
`deepseek/deepseek-v4-flash` with `maxToolAttempts = 40`. The damaged file was
missing those fields and contained only the small set written by the test
fixture. An interrupted test also left one clearly test-named agent JSON file in
the live agents directory.

Recovery restored only values supported by the earlier log, removed the
test-only agent after inspecting it, and verified that no other test agents
remained. The runtime permission tests now use disposable custom agents instead
of saving the global chat configuration. Search-provider persistence tests use
the shared storage-path lock.

## Mandatory test rules

1. **Never use the default storage root for a test that can write.** Start the
   test process with an isolated `OSAURUS_TEST_ROOT`, or set
   `OsaurusPaths.overrideRoot` inside the shared lock before constructing any
   path-backed store.
2. **Use `StoragePathsTestLock` for the whole critical section.** This applies to
   tests that mutate `OsaurusPaths.overrideRoot` or `StorageKeyManager`, and also
   to tests that read or write path-backed stores while another suite could
   mutate those globals.
3. **Resolve paths after acquiring the lock.** Do not cache a destination URL
   before the root is stable, then write it later.
4. **Prefer local fixtures over shared singletons.** Exercise pure configuration
   values, disposable agents, or stores constructed with an explicit temporary
   URL. Do not call `ChatConfigurationStore.shared.save()` merely to arrange a
   test condition.
5. **If a live-format file must be tested, preserve its exact bytes.** Snapshot
   the original file, restore those bytes in guaranteed cleanup, and verify the
   parent directory still exists. Reconstructing a partial model is not an
   acceptable restore operation.
6. **Do not rely on `@Suite(.serialized)` for process-global safety.** It only
   orders tests inside that suite. Unrelated suites may still execute at the
   same time.
7. **Run the full stateful suite explicitly without concurrency.** SwiftPM's
   displayed defaults have been misleading across toolchain versions, so use
   the flag rather than assuming serial execution:

   ```sh
   TEST_STORAGE_ROOT="$(mktemp -d /tmp/osaurus-tests.XXXXXX)"
   OSAURUS_TEST_ROOT="$TEST_STORAGE_ROOT" OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
     arch -x86_64 /usr/bin/swift test \
     --package-path Packages/OsaurusCore \
     --no-parallel \
     --disable-xctest
   ```

   **Never write `export TEST_STORAGE_ROOT=… OSAURUS_TEST_ROOT="$TEST_STORAGE_ROOT"`
   on one line.** The shell expands `$TEST_STORAGE_ROOT` before `export`
   assigns it, so `OSAURUS_TEST_ROOT` is empty and `OsaurusPaths.root()`
   falls back to the live `~/.osaurus` (2026-10-07 incident below). Assign
   `TEST_STORAGE_ROOT` first (its own statement), then pass
   `OSAURUS_TEST_ROOT` as a command prefix as shown. Verify with
   `echo "$OSAURUS_TEST_ROOT"` when in doubt.

   `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1` turns the keychain wrappers into
   no-ops so tests never write the real keychain (added 2026-10-07; before
   that, `CodexOAuthHeadersTests` wrote and deleted fake Codex tokens in the
   real keychain on every run and now uses an in-memory read override).

   `--disable-xctest` also avoids the unrelated empty XCTest runner attempting
   to load the wrong architecture. This package currently uses Swift Testing.
   In the Codex workspace sandbox, SwiftPM's nested macOS sandbox can fail
   before manifest compilation with `sandbox_apply: Operation not permitted`
   (or a denied Clang module cache). Run the same isolated command with
   approved unsandboxed execution; do not remove `OSAURUS_TEST_ROOT` or the
   serial-test flags to work around that failure.
8. **Check for residue after stateful tests.** Confirm the live configuration
   checksum is unchanged, no test-named agent remains under `~/.osaurus/agents`,
   and no test fixture appeared in another live store.
9. **Prove the filter matched real tests.** SwiftPM can finish successfully with
   `No matching test cases were run`. Read the final executed test count and fail
   the validation if it is zero. The Intel define belongs to the production
   target; do not wrap Intel test files in `#if OSAURUS_INTEL` unless the test
   target also defines it, because that silently compiles the tests out.
10. **Never write the system pasteboard.** `NSPasteboard.general` is the
   user's real clipboard; a test that calls a view's `copy(_:)` or
   `ChatCrossSelection.copyIfActive` replaces it (happened once on
   2026-10-01 while porting cross-block selection). Assert on the string
   that would be copied, or on menu validation, instead.

## Preflight and postflight

Before a full or stateful test run:

- Record the current commit and test command.
- Point the process at a fresh temporary test root.
- Hash live configuration files and inventory the live agents directory.
- Confirm the test root is not `~/.osaurus` and is not a parent of it.

After the run:

- Compare the live hashes and agent inventory with the preflight record.
- Search live storage for fixture names such as `test`, `fixture`, or the
  current test UUID.
- Treat any live-data difference as a failed test run even when every assertion
  passed.
- Rebuild only after the storage checks pass, so the delivered app and the test
  evidence refer to the same commit.

**Known non-test writer (2026-09-30):** on the dev Mac the installed
`/Applications/osaurus.app` is upstream's arm64 build, which owns `~/.osaurus`
and, while it runs, re-downloads its plugin catalog into
`~/.osaurus/PluginSpecs/` every 4 hours (upstream `PluginRepositoryService`),
plus writes `.storage-maintenance.json`. A `find ~/.osaurus -newer <marker>`
hit on those paths is that app, not a test: confirm with `ps -o lstart= -p
$(pgrep -f /Applications/osaurus.app)` and the test log (no PluginSpecs
mention). Intel code under test writes only to the test root; outside tests
its live root is `~/.osaurus-intel`. Any other hit is still a failed run.

**Also from that app (2026-10-06):** upstream 0.25.x keeps its activity log
and memory database open, so `~/.osaurus/activity/{activity.sqlite,
activity.sqlite-wal,activity.head}` and `~/.osaurus/memory/memory.sqlite-wal`
change every few seconds while it runs. Verified by watching
`activity.head` change again after the test run had ended (21:15:50, test
log finished 21:15:06), with the app running since 3 October. To rule a hit
in or out, re-check the same paths a minute after the run, or quit the app
before testing.

When that app works in a folder it also writes upstream's file history:
`~/.osaurus/file-history/{objects,pending,tmp,shadows}` plus
`~/.osaurus/chat-history/history.sqlite-wal` (upstream keeps file-history
rows in its SQLite chat history, which Intel doesn't have). Telling it apart
from an Intel leak: Intel's journal would also create
`file-history/history.sqlite` (Intel's own database, absent from upstream's
layout), and in tests the journal's root comes from `OsaurusPaths.root()`,
which `OSAURUS_TEST_ROOT` overrides for the whole process. Seen 2026-10-06:
an `.xlsx` object at 21:55:57 during a test run, with `shadows/` already
touched at 21:43 and no `history.sqlite`.

## 2026-09-14 automation-test residue

The first `ExecutionContextFolderActivationTests` implementation constructed a
real `ChatSession` without `ChatHistoryTestStorage`. Focused runs passed while
silently writing 12 synthetic schedule/watcher chats to the live sessions
directory; a concurrent Xcode run then timed out waiting for one response. The
files were identified by exact test-only prompts/responses and moved intact to
`~/.osaurus/quarantine/2026-09-14-automation-test-fixtures/` rather than deleted.

The test now runs inside `ChatHistoryTestStorage`, and that helper is compiled by
the Intel SwiftPM test target. SwiftPM omits the unavailable upstream
`ChatSessionStore` reset while retaining isolated paths, keys, locking, refresh,
and cleanup. A passing stateful test is invalid if its log says it loaded live
sessions or if a fixture appears under `~/.osaurus/sessions` afterward.

## 2026-10-07 live-data incident (unsafe `export` gate)

**What happened.** Nine test runs between 09:58:47 and 12:06 (upstream audit
2026-10-07 session) used
`export TEST_STORAGE_ROOT="$(mktemp …)" OSAURUS_TEST_ROOT="$TEST_STORAGE_ROOT"`.
In zsh and bash the second assignment expands before the first is made, so
`OSAURUS_TEST_ROOT` was empty and the tests ran against the live
`~/.osaurus`, which the upstream app (`com.dinoki.osaurus` 0.25.19) was
using at the time. Found by the postflight `find -newer` check.

**Damage found (read-only inspection, values not printed):**

- `agents/44A80015….json`, `agents/93CFB693….json`, `agents/B9EB2F03….json`
  (three of the four upstream agents) were rewritten at 10:02:42 by Intel's
  one-time `.intel-agent-database-flag-reset-v1` migration
  (`IntelManagerConformers.resetLegacyDatabaseFlagsIfNeeded`): `dbEnabled`
  forced off, and Intel's `Agent` encoder dropped the upstream-only keys it
  doesn't model: about 20 under `settings` (Apple Script, browser and computer
  use, knowledge, follow-up, image/video, chart, screen context, memory
  search, spawn/subagent budgets, permissions and overrides) and
  `autonomousExec.backgroundProcessEnabled` / `sandboxNetworkEnabled`.
  (Top-level keys such as `avatar`, `chatGreeting` or `themeId` were absent
  too, but Intel models those and omits them only when unset, so those
  agents most likely never had them.) Renée re-saved the three agents from
  the still-running upstream app, which still held the full records. The
  marker file was written too. No backup: Time Machine was not mounted, there are no
  local APFS snapshots, and no other copy exists on disk.
- Test residue: four empty `agents/<uuid>/` folders, a
  `sessions/1C8E9DCD….json` ("Scheduled folder task"), and test content in
  `config/tool-policies.json` (probe tool names), `providers/search.json`,
  `knowledge/agent-grants.json` and `config/activity-log.json`. Whether the
  last four replaced existing user files cannot be told from timestamps
  (atomic writes reset the birth time).
- `memory/memory.sqlite` was modified at 10:12:39, during a run; whether by
  a test or the upstream app's checkpoint is unknown.

**Recovery and cleanup (2026-10-07):** Renée re-saved the three agents
from the running upstream app; all three are back to the full 25 settings
keys with `dbEnabled` restored. Checked against upstream's code first:
`config/tool-policies.json` and `knowledge/agent-grants.json` are Intel-only
(upstream never reads them) and `config/activity-log.json` matched
upstream's default, so those three were deleted along with the marker, the
test chat and the four empty test agent folders. `providers/search.json` was
kept: it is Renée's real upstream search setup (Kagi disabled, premium
search on), loaded and saved back by a test process without losing a field
(same stored properties as upstream). `providers/search-definitions/` is
empty; whether it held custom definitions before is unknown.

**Rules added:** the gate above (no one-line `export`), and the keychain
flag. **Code guards (2026-10-07):** `OsaurusPaths.root()` now stops a test
process (`fatalError`) that has no `overrideRoot` and an empty
`OSAURUS_TEST_ROOT` instead of returning the live root; and Intel's
`AgentManager.persist` keeps every key of an existing agent file that
Intel's model can't round-trip (`preservingUnknownFields`,
`IntelAgentUnknownFieldsTests`), so any Intel save of an upstream agent,
test or real, no longer strips upstream settings.
