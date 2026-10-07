#!/usr/bin/env python3
"""Add hand-written catalog entries (Intel strings upstream doesn't ship).

Reads a JSON object from the file argument (or stdin):
    {"English key": {"de": "…", "zh-Hans": "…"}, …}
Each new key is inserted beside its sorted neighbours, as
`merge-upstream-keys.py` does; existing keys are left alone. Conventions:
German uses informal "du"; Chinese uses 聊天, 智能体 and 你.

Usage: scripts/i18n/add-translations.py strings.json
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

CATALOG = Path(__file__).resolve().parents[2] / "Packages/OsaurusCore/Resources/Localizable.xcstrings"


def main() -> int:
    source = open(sys.argv[1], encoding="utf-8") if len(sys.argv) > 1 else sys.stdin
    new = json.load(source)
    text = CATALOG.read_text(encoding="utf-8")
    catalog = json.loads(text)
    strings = catalog["strings"]

    def entry(values: dict) -> dict:
        return {
            "localizations": {
                locale: {"stringUnit": {"state": "translated", "value": value}}
                for locale, value in values.items()
            }
        }

    pending = sorted(k for k in new if k not in strings)
    merged = {}
    for key, value in strings.items():
        while pending and pending[0] < key:
            merged[pending[0]] = entry(new[pending[0]])
            pending.pop(0)
        merged[key] = value
    for key in pending:
        merged[key] = entry(new[key])
    added = len(merged) - len(strings)
    catalog["strings"] = merged
    out = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "))
    CATALOG.write_text(out + ("\n" if text.endswith("\n") else ""), encoding="utf-8")
    print(f"added {added}, skipped {len(new) - added} already present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
