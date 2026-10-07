#!/usr/bin/env python3
"""Copy upstream catalog entries for Swift keys the Intel catalog is missing.

Ported upstream code brings its strings with it, but the Intel catalog only
gets them when they are merged. This finds the keys
`check-swift-catalog-keys.py` would report, limited to Swift files whose path
contains one of the given substrings, and copies each matching entry
(de + zh-Hans included) from `upstream/main`'s catalog. Interpolated keys
(`L("…\\(x)…")`) match upstream's printf-style key the same way the checker
does. Keys upstream doesn't have are listed so they can be translated by hand.

The catalog is rewritten in Xcode's layout (2-space indent, " : "), keeping
existing key order and the file's missing trailing newline.

Usage: scripts/i18n/merge-upstream-keys.py Views/Chat/Foo.swift Services/Bar
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Packages/OsaurusCore/Resources/Localizable.xcstrings"
SWIFT_ROOT = ROOT / "Packages/OsaurusCore"
UPSTREAM_REF = "upstream/main:Packages/OsaurusCore/Resources/Localizable.xcstrings"


def load_checker():
    spec = importlib.util.spec_from_file_location(
        "check_keys", ROOT / "scripts/i18n/check-swift-catalog-keys.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    filters = sys.argv[1:]
    if not filters:
        print(__doc__)
        return 2
    checker = load_checker()
    text = CATALOG.read_text(encoding="utf-8")
    catalog = json.loads(text)
    strings = catalog["strings"]
    upstream = json.loads(
        subprocess.run(["git", "show", UPSTREAM_REF], cwd=ROOT, capture_output=True, check=True).stdout
    )["strings"]

    refs = checker.referenced_keys(SWIFT_ROOT)
    added, unmatched = [], []
    for key in sorted(refs):
        if not any(f in ref for ref in refs[key] for f in filters):
            continue
        if key in strings:
            continue
        if "\\(" in key:
            pattern = checker.canonical_pattern(key)
            if any(pattern.match(k) for k in strings):
                continue
            match = next((k for k in upstream if pattern.match(k)), None)
        else:
            match = key if key in upstream else None
        if match is None:
            unmatched.append((key, refs[key][0]))
            continue
        strings[match] = upstream[match]
        added.append(match)

    # SwiftUI literals (`Text("…", bundle: .module)`, settings titles) aren't
    # in the checker's markers: also take any plain string literal in the
    # named files that upstream's catalog has as a key.
    import re
    literal = re.compile(r'"((?:[^"\\]|\\.)+)"')
    for path in sorted(SWIFT_ROOT.rglob("*.swift")):
        rel = str(path)
        if ".build" in path.parts or not any(f in rel for f in filters):
            continue
        # Per line: a stray quote in a comment must not shift the pairing for
        # the rest of the file.
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
        for raw in (r for line in lines if not line.lstrip().startswith("//") for r in literal.findall(line)):
            if "\\(" in raw:
                continue
            key = checker.unescape_swift_string(raw)
            if key in strings or key not in upstream or not key.strip():
                continue
            strings[key] = upstream[key]
            added.append(key)

    if added:
        # The catalog isn't strictly sorted; put each new key before the
        # first existing key that sorts after it, leaving the rest in place.
        existing = [(k, v) for k, v in strings.items() if k not in added]
        pending = sorted(added)
        merged = {}
        for k, v in existing:
            while pending and pending[0] < k:
                merged[pending[0]] = strings[pending[0]]
                pending.pop(0)
            merged[k] = v
        for k in pending:
            merged[k] = strings[k]
        catalog["strings"] = merged
        out = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "))
        if text.endswith("\n"):
            out += "\n"
        CATALOG.write_text(out, encoding="utf-8")
    for key in added:
        print(f"added: {key}")
    for key, ref in unmatched:
        print(f"NOT IN UPSTREAM: {key} ({ref})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
