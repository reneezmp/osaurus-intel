#!/bin/zsh
# Safe test gate (docs/TEST_STORAGE_SAFETY.md): temp root, keychain off, serial,
# one run at a time machine-wide (lockf), stall watchdog with one retry,
# live-folder + identity mdat checks, temp root removed.
# Usage: [REPO=<worktree>] scripts/test/gate.sh <label> [filter]
# Logs: $GATE_LOG_DIR (default /tmp/osaurus-gate)/test-<label>.log
# Rules and history: docs/TEST_STORAGE_SAFETY.md.
label="$1"; filter="$2"
cd "${REPO:-/Users/renee/Developer/osaurus}" || exit 1
S="${GATE_LOG_DIR:-/tmp/osaurus-gate}"; mkdir -p "$S"
log="$S/test-$label.log"
marker="$S/marker-$label"; touch "$marker"
stallflag="$S/stalled-$label"; rm -f "$stallflag"
STALL_SECONDS=300
mdat_before="$(security find-generic-password -s com.osaurus.account -a master-key 2>/dev/null | grep mdat)"
args=(--package-path Packages/OsaurusCore --no-parallel --disable-xctest)
[[ -n "$filter" ]] && args+=(--filter "$filter")
echo "waiting for gate lock if another run holds it"
rc=1
for attempt in 1 2; do
  TEST_STORAGE_ROOT="$(mktemp -d /tmp/osaurus-tests.XXXXXX)"
  if [[ -z "$TEST_STORAGE_ROOT" || ! -d "$TEST_STORAGE_ROOT" ]]; then echo "no temp root"; exit 1; fi
  echo "start $(date +%T) attempt=$attempt repo=$PWD root=$TEST_STORAGE_ROOT"
  OSAURUS_TEST_ROOT="$TEST_STORAGE_ROOT" OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
    /usr/bin/lockf -k /tmp/osaurus-test-gate.lock ${=RUNNER} arch -x86_64 /usr/bin/swift test "${args[@]}" < /dev/null > "$log" 2>&1 &
  runpid=$!
  # Watchdog: tests started, log silent for STALL_SECONDS => kill THIS repo's helper only.
  ( while kill -0 $runpid 2>/dev/null; do
      sleep 20
      grep -aq "Test run started" "$log" 2>/dev/null || continue
      idle=$(( $(date +%s) - $(stat -f %m "$log") ))
      if (( idle >= STALL_SECONDS )); then
        touch "$stallflag"
        pkill -f "swiftpm-testing-helper.* $PWD/Packages"
        break
      fi
    done ) &
  dogpid=$!
  wait $runpid; rc=$?
  kill $dogpid 2>/dev/null
  rm -rf "$TEST_STORAGE_ROOT"
  echo "end $(date +%T) rc=$rc"
  if [[ -f "$stallflag" ]]; then
    rm -f "$stallflag"
    echo "STALLED: log silent ${STALL_SECONDS}s, last test: $(grep -a 'started\.' "$log" | tail -1 | cut -c1-120)"
    cp "$log" "$log.stalled$attempt"
    rc=124
    continue
  fi
  break
done
grep -aE "Test run (started|with)|✘|error:" "$log" | grep -v "^.*warning" | tail -25
mdat_after="$(security find-generic-password -s com.osaurus.account -a master-key 2>/dev/null | grep mdat)"
[[ "$mdat_before" == "$mdat_after" ]] && echo "mdat unchanged: $mdat_after" || echo "MDAT CHANGED: $mdat_before -> $mdat_after"
echo "live hits:"; find ~/.osaurus ~/.osaurus-intel -newer "$marker" -type f -exec stat -f '%Sm %N' {} \; 2>/dev/null | head -20
rm -f "$marker"
exit $rc
