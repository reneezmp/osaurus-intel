#!/usr/bin/env bash
# Amputation-drift tripwire for the Intel fork.
#
# WHAT THIS IS FOR
# ----------------
# The fork's divergence is mostly *deletion*: amputated-subsystem call sites were
# removed rather than guarded. Measured on 2026-09-02:
#
#   ChatView.swift            +997  / -2718   (6 OSAURUS_INTEL guards)
#   FloatingInputCard.swift   +176  / -697    (0 guards)
#   HTTPHandler.swift         +503  / -10014  (0 guards)
#   NativeMessageCellView     +72   / -507    (0 guards)
#
# The revert-detector in docs/UPSTREAM_SYNC.md only finds files that lost ALL their
# OSAURUS_INTEL guards, so it is structurally blind to the zero-guard files above.
#
# WHAT THIS IS *NOT*
# ------------------
# An earlier design grepped for amputated type names. That does not work: the fork
# provides Intel *conformer mirrors* for many excluded types (MemorySearchService,
# AgentManager, ServerController ...), so referencing them is correct and expected.
# And a symbol with no mirror at all simply fails to compile —
# `swift build --arch x86_64` already is that check. Do not re-add a symbol grep.
#
# The risk the compiler CANNOT see is re-imported upstream code that compiles fine
# but calls into an IntelStubs no-op. The reliable signal for that is *size*: these
# files should not grow during a sync. This script reports their drift against a
# baseline ref so a human reviews any growth.
#
# Usage:
#   scripts/sync/tripwire.sh [<baseline-ref>] [<growth-threshold-lines>]
#     baseline-ref   default: pre-sync-0.24.3  (fall back to any tag/sha you set in Stage 0)
#     threshold      default: 40 lines of net growth before a file is flagged
#
# Exit: 0 = no file grew past the threshold, 1 = review needed, 2 = setup problem

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

BASE="${1:-pre-sync-0.24.3}"
THRESHOLD="${2:-40}"

if ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
  echo "tripwire: baseline ref '$BASE' not found." >&2
  echo "  Create it before a sync:  git tag pre-sync-0.24.3 intel-fork" >&2
  echo "  Or pass one:              scripts/sync/tripwire.sh <ref>" >&2
  exit 2
fi

# Amputation-scarred files: large deletions relative to upstream, and/or zero guards.
# Add to this list whenever a sync reveals another heavily-amputated file.
WATCH=(
  "Packages/OsaurusCore/Views/Chat/ChatView.swift"
  "Packages/OsaurusCore/Views/Chat/FloatingInputCard.swift"
  "Packages/OsaurusCore/Views/Chat/NativeMessageCellView.swift"
  "Packages/OsaurusCore/Networking/HTTPHandler.swift"
  "Packages/OsaurusCore/AppDelegate.swift"
  "Packages/OsaurusCore/Services/Chat/SystemPromptTemplates.swift"
)

printf '%-52s %8s %8s %8s\n' "FILE" "BASE" "NOW" "DRIFT"
printf '%.0s-' {1..80}; echo

flagged=0
for f in "${WATCH[@]}"; do
  if ! git cat-file -e "$BASE:$f" 2>/dev/null; then
    printf '%-52s %8s %8s %8s\n' "$(basename "$f")" "-" "-" "absent@base"
    continue
  fi
  base_n=$(git show "$BASE:$f" | wc -l | tr -d ' ')
  now_n=$(git show "HEAD:$f" 2>/dev/null | wc -l | tr -d ' ')
  [[ -z "$now_n" ]] && now_n=0
  drift=$(( now_n - base_n ))

  mark=""
  if (( drift > THRESHOLD )); then mark=" ⚠️"; flagged=1; fi
  printf '%-52s %8s %8s %+8d%s\n' "$(basename "$f")" "$base_n" "$now_n" "$drift" "$mark"
done

echo
# Guard-count check: a zero-guard file staying zero-guard is expected; a guarded file
# dropping to zero is the classic silent revert.
echo "OSAURUS_INTEL guard counts (base -> now):"
for f in "${WATCH[@]}"; do
  git cat-file -e "$BASE:$f" 2>/dev/null || continue
  gb=$(git show "$BASE:$f" | grep -c OSAURUS_INTEL)
  gn=$(git show "HEAD:$f" 2>/dev/null | grep -c OSAURUS_INTEL)
  if (( gb > 0 && gn == 0 )); then
    echo "  ❌ $(basename "$f"): $gb -> 0  (LOST ALL GUARDS — silent revert)"
    flagged=1
  else
    echo "  ok $(basename "$f"): $gb -> $gn"
  fi
done

echo
if (( flagged )); then
  cat <<'EOF'
❌ Review needed.

Net growth in an amputation-scarred file usually means upstream code was re-imported
by a cherry-pick conflict resolution. Read the diff for each flagged file:

    git diff <baseline> HEAD -- <path>

Confirm every added block is a deliberate hand-port, not a resolved conflict that
dragged amputated call sites back in. Growth can be legitimate (a ported feature) —
this is a prompt to look, not a verdict.
EOF
  exit 1
fi

echo "✅ No amputation drift past ${THRESHOLD} lines; no guard losses."
