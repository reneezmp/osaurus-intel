#!/usr/bin/env python3
"""Set verdicts in docs/COV_REAUDIT.md's tables.

Usage: python3 scripts/upstream/set_verdict.py <tsv>   # hash<TAB>verdict<TAB>note
Rewrites the Verdict cell and the last (note) cell of the row whose commit
cell holds the hash (either table).
"""
import sys

p = "docs/COV_REAUDIT.md"
lines = open(p).read().split("\n")
todo = {}
for l in open(sys.argv[1]):
    l = l.rstrip("\n")
    if l:
        h, v, n = l.split("\t", 2)
        todo[h] = (v, n)
seen = set()
for i, l in enumerate(lines):
    if not l.startswith("| "):
        continue
    cells = l.split(" | ")
    for h, (v, n) in todo.items():
        if len(cells) > 2 and f"`{h}`" in cells[1]:
            cells[0] = "| " + v
            cells[-1] = n.replace("|", "/") + " |"
            lines[i] = " | ".join(cells)
            seen.add(h)
missing = set(todo) - seen
if missing:
    raise SystemExit(f"rows not found: {sorted(missing)}")
open(p, "w").write("\n".join(lines))
print(f"updated {len(seen)} rows")
