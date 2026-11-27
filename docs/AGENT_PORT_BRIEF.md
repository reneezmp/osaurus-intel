# Brief for porting agents (Intel fork)

Shared instructions for Sonnet subagents porting upstream Osaurus Classic into the Intel fork. Kept in the repo since 2026-11-25 because the session scratchpad gets wiped. Reports go to the path named in each task.

You are porting a group of upstream commits into the **Osaurus Intel fork**. Read this whole brief first.

## Setup

- You work in an **isolated git worktree** of `/Users/renee/Developer/osaurus` (branch based on `intel-fork`). Work only inside your worktree (`git rev-parse --show-toplevel`). Never touch the main checkout at `/Users/renee/Developer/osaurus`.
- Upstream Classic (0.25.x) is fetched as `upstream/classic`; port from it, never from 1.x `upstream/main`. Read upstream with `git show <sha>` / `git show <sha>:<path>`.
- Intel targets **macOS 13 Ventura, x86_64**. Intel replaces many upstream files with its own code (`Intel*` files, `Models/Chat/IntelConformers/*`); `Packages/OsaurusCore/Package.swift`'s `exclude:` list names upstream files Intel doesn't compile, and `#if !OSAURUS_INTEL` code isn't compiled either.
- The draft verdicts are in `/Users/renee/Developer/osaurus/docs/UPSTREAM_AUDIT_2026-11-11.md` (rows by number). **They are unverified.** For each commit, first check Intel's code: if Intel already has the fix, record "Covered" with evidence and move on; if it needs a feature Intel lacks, record "Needs work (W-item)" and move on. Only port what really applies.

- **Check your base first** (2026-11-27: two worktrees started on an old upstream-era `main`): `git merge-base --is-ancestor intel-fork HEAD`; if it fails, `git reset --hard intel-fork` before any work.

## How to port

- Port the upstream change faithfully ("follow upstream by default"), adapting only what Intel's own files or Ventura force. Keep upstream's names and structure where Intel has the same file. Short comments citing the upstream PR (`#3266`) where Intel's code differs from upstream.
- **Ventura rules:** use the single-value `onChange(of:) { new in }` form; no macOS 14+ APIs without `if #available(macOS 14, *)` and a Ventura fallback; SF Symbols must exist on macOS 13; no `.segmented`/`.bordered` styles in new Intel UI (the `IntelVenturaControlGuardTests` enforce this).
- **Strings:** new UI strings go through `L("…")`, `Text(localized:)`, `Button(localized:)`, `Label(localized:systemImage:)`, `.localizedHelp`. Then run `python3 scripts/i18n/merge-upstream-keys.py <changed file names>` to copy upstream's catalog entries; for keys upstream lacks, write de / zh-Hans / ko / ru yourself (German informal "du"; Chinese 聊天, 智能体, 你; Korean polite style; Russian "вы", counts after a colon) and add them with `python3 scripts/i18n/add-translations.py file.json`. `bash scripts/i18n/check.sh` must pass.
- Port or adapt upstream's tests for the change where Intel compiles the code under test (`Packages/OsaurusCore/Tests/...`). The test target has no `OSAURUS_INTEL` flag.

## Build and test (mandatory, and safe)

- Build: `cd Packages/OsaurusCore && arch -x86_64 /usr/bin/swift build --arch x86_64` (add `--build-tests` before running tests). The first build in a fresh worktree takes several minutes.
- Tests: **only** through the safe gate script, never `swift test` directly:
  `REPO="$(git rev-parse --show-toplevel)" scripts/test/gate.sh <label> '<filter regex>'` (logs in `/tmp/osaurus-gate/test-<label>.log`)
  It uses a temporary data root, disables the keychain, checks that the live `~/.osaurus` wasn't touched, and prints "live hits" (must be empty) and "mdat unchanged". Always pass a filter covering the suites you touched plus `IntelVenturaControlGuard`. If "live hits" shows files or "MDAT CHANGED" appears, stop and report it.
- Never read or write `~/.osaurus`, the keychain, `NSPasteboard.general` in tests, or any secret.

## Commit

- Commit on your worktree's branch only, one commit per upstream PR or a few related ones, message `Port #NNNN: <what users get>` plus a line `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. **Never push**, never merge, never touch `intel-fork` directly.
- Don't edit `docs/` (the lead merges and documents). Instead, write your report to the output file named in your task.

## Report (output file, Markdown)

Per commit: `#NNNN` — Ported / Covered / Needs work (W-item) / Skipped (why) — one or two sentences: what changed for users and where on Intel; tests added; anything you adapted. Then: the build and test results (copy the gate's summary lines), your worktree path and branch name, and the list of your commits (`git log --oneline intel-fork..HEAD`).

Name in the report only tests that are in your commits: before writing it, `grep` each test name in your worktree (2026-11-27: a report listed two tests that were never committed).

## Shared-machine rules (2026-11-18)

- Other agents build and test on this Mac at the same time. Never run a global `pkill`/`killall` on `swift-test`, `swiftpm-testing-helper` or `swift-build`; kill only the PIDs of your own run (find them by your worktree path in `ps`).
- Use `scripts/test/gate_pty.sh` for the full run (falls back to the plain gate without a terminal). Skip a separate `swift build --build-tests` before the gate: `swift test` rebuilds anyway, so it only doubles the compile time.
- Live hits from the user's upstream app (now Osaurus 1.0.7) include 1.x-only paths such as `classic-resave/`, `sync-local/`, `.termination-forensics-active`, `last-exit-verdict.json`, `runtime/<uuid>/`; check `lsof` and timestamps against the test window.
- The gate now takes a machine-wide lock (`lockf /tmp/osaurus-test-gate.lock`): only one test run executes at a time; yours may print "waiting for gate lock" and wait for another agent's run. That is expected; don't kill it. Concurrent runs shared `swiftpm-testing-helper`'s UserDefaults and caches and hung (`BackgroundTaskAgentGroupCloseTests`) or failed (`EditableTextViewSpellCheckTests`, `FileDiffEngineTests.wordDocumentDiffsByParagraph`) each other.
- The gate has a stall watchdog: 300 silent seconds after "Test run started" kills only your repo's helper and retries once. `STALLED:` plus a passing second attempt is a pass (report it); exit 124 means both attempts stalled. Don't add your own kill loops. If 124 happens on `BackgroundTaskAgentGroupCloseTests`, run the full suite with filter `'^(?!.*BackgroundTaskAgentGroupClose).*$'` plus that suite alone, and report both (`TEST_STORAGE_SAFETY.md`, 2026-11-19).
- After every gate run, read the last lines of your own log yourself (`tail` the log): monitor patterns have missed finished runs.
- Usage budget is limited: work efficiently, don't loop on the same failing build more than a few times; if stuck, commit what is green, mark the rest WIP, and report where it stopped.
- Never revert or rewrite `docs/` files you weren't asked to edit. When a rebase or cherry-pick conflicts in `docs/`, take `intel-fork`'s version (`git checkout intel-fork -- <file>`) and re-apply only your allowed edit. Before your last commit, `git diff intel-fork --stat -- docs` must list only files your task allows (2026-11-25: a stage 3 commit had silently dropped three docs updates).
- The same applies to code: before your last commit, `git diff intel-fork --name-status` must show no deleted (`D`) file and no file outside your task's area, unless your task says so. After a cherry-pick of old work, check that it didn't undo newer changes in shared files (`git diff intel-fork -- <file>` and read the `-` lines).
- Write and port tests as Swift Testing (`import Testing`, `@Test`, `#expect`). The gate runs `--disable-xctest`, so upstream XCTest suites silently never run: convert them.
