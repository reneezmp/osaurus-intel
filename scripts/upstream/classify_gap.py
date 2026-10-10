#!/usr/bin/env python3
"""Classify every upstream OsaurusCore source file that Intel does not compile.

Usage (from the repo root):  python3 scripts/upstream/classify_gap.py [upstream-ref]

Lists files that exist on the upstream ref but are absent from the Intel tree
or excluded in Packages/OsaurusCore/Package.swift, assigns each to a feature
(first matching pattern wins) and prints totals plus any UNASSIGNED files.
An unassigned file is a feature nobody has classified yet: add a pattern and a
row in docs/INTEL_MISSING_FEATURES_BACKLOG.md. Verdicts: I = incompatible
(Apple Silicon only / upstream-only artifact), C = covered by Intel's own
implementation, W = needs work, N = not a user feature (dev tooling).
See the verdict rule in docs/UPSTREAM_SYNC.md.
"""
import collections, os, re, subprocess, sys

REF = sys.argv[1] if len(sys.argv) > 1 else "upstream/main"
PRE = "Packages/OsaurusCore/"

pkg = open(PRE + "Package.swift").read()
excluded = set()
for block in re.findall(r"exclude:\s*\[(.*?)\]", pkg, re.S):
    excluded.update(re.findall(r'"([^"]+)"', block))

def is_excluded(f):
    return any(f == e or (not e.endswith(".swift") and f.startswith(e.rstrip("/") + "/")) for e in excluded)

listing = subprocess.run(["git", "ls-tree", "-r", "--name-only", REF, PRE], capture_output=True, text=True, check=True).stdout.split()
rows = []
for full in listing:
    f = full[len(PRE):]
    if not f.endswith(".swift") or f.startswith("Tests/"):
        continue
    if not os.path.exists(PRE + f):
        kind = "absent"
    elif is_excluded(f):
        kind = "excluded"
    else:
        continue
    text = subprocess.run(["git", "show", f"{REF}:{full}"], capture_output=True, text=True).stdout
    rows.append((kind, f, text.count("\n")))

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gap_features import F

assign = collections.defaultdict(list)
unassigned = []
for kind, f, n in rows:
    for fid, verdict, pat in F:
        if re.search(pat, f):
            assign[fid].append((f, n, kind))
            break
    else:
        unassigned.append((f, n))

print(f"{len(rows)} upstream source files not compiled on Intel ({REF})")
for fid, verdict, _ in F:
    items = assign[fid]
    print(f"{fid:32s} {verdict} {len(items):4d} files {sum(n for _, n, _ in items):7d} lines")
print("UNASSIGNED", len(unassigned))
for f, n in unassigned:
    print("  ", n, f)
sys.exit(1 if unassigned else 0)
