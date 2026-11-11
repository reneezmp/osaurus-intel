#!/usr/bin/env python3
"""Bring upstream's translations into the Intel catalogs for keys both have.

W-cov-reaudit stage 4 (2026-11-11). The Intel catalogs were snapshots of
upstream's, then grew by `merge-upstream-keys.py` and hand translations, so
keys both catalogs share can lag upstream: languages upstream added later
(ko, ru, zh-Hant) are missing, and older zh-Hans wording (代理, 您) was never
refreshed by upstream's glossary pass.

For every key in both catalogs, per language upstream has:

- Intel lacks the language: copy upstream's localization.
- Both have it and they differ, take upstream's only when it is better:
  - upstream's units are all `translated` (its `needs_review` entries are
    mostly untranslated English placeholders);
  - the format specifiers match Intel's (count and types, ignoring `n$`);
  - Intel's plural variations are never replaced by a plain string;
  - `en` and `de` keep Intel's own `translated` text (Intel's German is hand
    written with its own glossary; `en` overrides describe Intel behaviour);
  - zh-Hans keeps Intel's text when upstream's would bring back 您 or 代理
    where Intel says 你 or 智能体.

Only `localizations` change; key order, comments and the file's trailing
newline (or lack of one) are kept, in Xcode's layout.

Usage:
  scripts/i18n/fill-upstream-translations.py [--dry-run] [catalog ...]
Catalogs default to both Intel catalogs, compared with `upstream/main`.
"""

from __future__ import annotations

import collections
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CATALOGS = [
    "Packages/OsaurusCore/Resources/Localizable.xcstrings",
    "App/osaurus/InfoPlist.xcstrings",
]
UPSTREAM = "upstream/main"
KEEP_INTEL_TRANSLATED = {"en", "de"}
SPEC = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?([@dDuUxXoOfeEgGcCsSpaAi%])")


def units(loc: dict) -> list[dict]:
    if "stringUnit" in loc:
        return [loc["stringUnit"]]
    return [
        form["stringUnit"]
        for form in loc.get("variations", {}).get("plural", {}).values()
        if "stringUnit" in form
    ]


def specs(loc: dict) -> collections.Counter:
    """Format specifiers of the localization's widest form."""
    best = collections.Counter()
    for unit in units(loc):
        found = collections.Counter(s for s in SPEC.findall(unit.get("value", "")) if s != "%")
        if sum(found.values()) > sum(best.values()):
            best = found
    return best


def all_translated(loc: dict) -> bool:
    us = units(loc)
    return bool(us) and all(u.get("state") == "translated" and u.get("value", "").strip() for u in us)


def text(loc: dict) -> str:
    return " ".join(u.get("value", "") for u in units(loc))


def prefer_upstream(lang: str, mine: dict, theirs: dict) -> bool:
    if not all_translated(theirs):
        return False
    if "variations" in mine and "variations" not in theirs:
        return False
    if specs(mine) and specs(mine) != specs(theirs):
        return False
    if lang in KEEP_INTEL_TRANSLATED and all_translated(mine):
        return False
    if lang == "zh-Hans":
        a, b = text(mine), text(theirs)
        if ("您" in b and "您" not in a) or ("代理" in b and "代理" not in a):
            return False
    return True


def fill(path: Path, dry_run: bool) -> collections.Counter:
    raw = path.read_text(encoding="utf-8")
    catalog = json.loads(raw)
    rel = path.relative_to(ROOT).as_posix()
    upstream = json.loads(
        subprocess.run(
            ["git", "show", f"{UPSTREAM}:{rel}"], cwd=ROOT, capture_output=True, check=True
        ).stdout
    )["strings"]
    stats = collections.Counter()
    for key, entry in catalog["strings"].items():
        theirs_all = upstream.get(key, {}).get("localizations", {})
        if not theirs_all:
            continue
        mine_all = entry.setdefault("localizations", {})
        for lang, theirs in theirs_all.items():
            mine = mine_all.get(lang)
            if mine is None:
                mine_all[lang] = theirs
                stats[f"added {lang}"] += 1
            elif mine != theirs and prefer_upstream(lang, mine, theirs):
                mine_all[lang] = theirs
                stats[f"updated {lang}"] += 1
        if not mine_all:
            del entry["localizations"]
        elif list(mine_all) != sorted(mine_all):
            entry["localizations"] = dict(sorted(mine_all.items()))
    if not dry_run and stats:
        out = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "))
        if raw.endswith("\n"):
            out += "\n"
        path.write_text(out, encoding="utf-8")
    return stats


def main() -> int:
    args = sys.argv[1:]
    dry_run = "--dry-run" in args
    paths = [a for a in args if a != "--dry-run"] or DEFAULT_CATALOGS
    for p in paths:
        stats = fill(ROOT / p, dry_run)
        print(p)
        for name, count in sorted(stats.items()):
            print(f"  {name}: {count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
