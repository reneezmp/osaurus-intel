#!/usr/bin/env python3
"""Copy string-catalog entries from upstream into Intel's Localizable.xcstrings.

Usage: python3 scripts/upstream/copy_strings.py <upstream-ref> "<key>" ["<key>" ...]

Follows the merge rule in docs/UPSTREAM_SYNC.md ("Localizable.xcstrings
merges"): Intel's file is kept and only the named keys are inserted (or
replaced), in Xcode's format (`"key" : {`, two-space indent), in sorted key
order, preserving the missing final newline. A key upstream doesn't have is
reported and skipped.
"""
import json, subprocess, sys

PATH = "Packages/OsaurusCore/Resources/Localizable.xcstrings"
ref, keys = sys.argv[1], sys.argv[2:]
up = json.loads(subprocess.run(["git", "show", f"{ref}:{PATH}"], capture_output=True, text=True, check=True).stdout)
raw = open(PATH, encoding="utf-8").read()
ours = json.loads(raw)  # only for the "already present" check
for k in keys:
    if k not in up["strings"]:
        print("not upstream:", k)
        continue
    ours["strings"][k] = up["strings"][k]
    print("copied:", k)


def dump(obj, indent=0):
    pad = "  " * indent
    if isinstance(obj, dict):
        if not obj:
            return "{\n\n" + pad + "}"
        items = [f'{pad}  {json.dumps(k, ensure_ascii=False)} : {dump(v, indent + 1)}' for k, v in obj.items()]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(obj, list):
        return "[\n" + ",\n".join(pad + "  " + dump(v, indent + 1) for v in obj) + "\n" + pad + "]"
    return json.dumps(obj, ensure_ascii=False)


# Insert-only, at the text level, so the rest of the file is untouched: a new
# key goes before the first top-level key that sorts after it (file order).
import re
lines = raw.split("\n")
key_re = re.compile(r'^    ("(?:[^"\\]|\\.)*") : \{$')
tops = [(n, json.loads(m.group(1))) for n, l in enumerate(lines) if (m := key_re.match(l))]
for k in keys:
    if k not in up["strings"]:
        continue
    entry = ("    " + json.dumps(k, ensure_ascii=False) + " : " + dump(up["strings"][k], 2)).split("\n")
    existing = [n for n, name in tops if name == k]
    if existing:
        start = existing[0]
        end = start
        while lines[end] not in ("    },", "    }"):
            end += 1
        tail = "," if lines[end].endswith(",") else ""
        entry[-1] += tail
        lines[start : end + 1] = entry
    else:
        after = next((n for n, name in tops if name > k), None)
        if after is None:
            raise SystemExit("no insertion point for " + k)
        entry[-1] += ","
        lines[after:after] = entry
    tops = [(n, json.loads(m.group(1))) for n, l in enumerate(lines) if (m := key_re.match(l))]
out = "\n".join(lines)
json.loads(out)
open(PATH, "w", encoding="utf-8").write(out)
