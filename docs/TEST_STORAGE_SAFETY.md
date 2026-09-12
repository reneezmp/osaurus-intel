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
   OSAURUS_TEST_ROOT="$TEST_STORAGE_ROOT" arch -x86_64 /usr/bin/swift test \
     --package-path Packages/OsaurusCore \
     --no-parallel \
     --disable-xctest
   ```

   `--disable-xctest` also avoids the unrelated empty XCTest runner attempting
   to load the wrong architecture. This package currently uses Swift Testing.
8. **Check for residue after stateful tests.** Confirm the live configuration
   checksum is unchanged, no test-named agent remains under `~/.osaurus/agents`,
   and no test fixture appeared in another live store.
9. **Prove the filter matched real tests.** SwiftPM can finish successfully with
   `No matching test cases were run`. Read the final executed test count and fail
   the validation if it is zero. The Intel define belongs to the production
   target; do not wrap Intel test files in `#if OSAURUS_INTEL` unless the test
   target also defines it, because that silently compiles the tests out.

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
