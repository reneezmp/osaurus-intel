#!/usr/bin/env python3
"""Deterministic first-pass triage of an upstream commit range for the Intel fork.

Eliminates commits that cannot possibly apply, by intersecting each commit's touched
files with the `exclude:` list in Packages/OsaurusCore/Package.swift. No judgment —
only the commits it cannot rule out come back as REVIEW.

On the 0.20.3 -> 0.24.3 sync this removed 307 of 783 commits (39%) before a human
looked at anything.

Usage:
    scripts/sync/triage.py <since> [<until>]        # e.g. 9124d696 upstream/main
    scripts/sync/triage.py 9124d696 --json out.json
"""

import argparse
import collections
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CORE = "Packages/OsaurusCore/"
PACKAGE_SWIFT = os.path.join(REPO, CORE, "Package.swift")

# Files that only ever describe the dependency graph. The fork keeps its own.
INFRA_EXACT = {
    "Packages/OsaurusCore/Package.swift",
    "Packages/OsaurusCore/Package.resolved",
    "Package.swift",
    "Package.resolved",
    "Makefile",
    ".gitignore",
}
INFRA_SUBSTR = ("xcworkspace", "xcodeproj", "Packages/IntelStubs")


def git(*args):
    return subprocess.run(
        ["git"] + list(args), capture_output=True, text=True, cwd=REPO
    ).stdout


def excluded_paths():
    """Parse the main target's exclude: list out of Package.swift."""
    src = open(PACKAGE_SWIFT).read()
    start = src.index("exclude: [")
    end = src.index("]", start)
    return sorted(set(re.findall(r'"([^"]+)"', src[start:end])))


def make_classifier(excl, fork_files):
    excl_files = {CORE + e for e in excl}
    # entries without a file extension are directories
    excl_dirs = tuple(CORE + e + "/" for e in excl if "." not in e.split("/")[-1])

    def classify(f):
        if f in excl_files or f.startswith(excl_dirs):
            return "excluded"
        if f.startswith("docs/") or f.endswith(".md"):
            return "docs"
        if f.startswith(".github/"):
            return "ci"
        if "appcast" in f.lower() or f.endswith(".html"):
            return "appcast"
        if f.startswith("Tests/") or "/Tests/" in f:
            return "tests"
        if f.endswith(".xcstrings") or "/i18n/" in f:
            return "i18n"
        return "live" if f in fork_files else "absent"

    return classify


def is_infra(f):
    return f in INFRA_EXACT or any(s in f for s in INFRA_SUBSTR)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("since", help="last synced upstream commit, e.g. 9124d696")
    ap.add_argument("until", nargs="?", default="upstream/main")
    ap.add_argument("--json", help="write full result to this path")
    args = ap.parse_args()

    fork_files = set(git("ls-tree", "-r", "--name-only", "HEAD").splitlines())
    classify = make_classifier(excluded_paths(), fork_files)

    rows = []
    log = git(
        "log", "--reverse", "--no-merges", "--pretty=format:%H\x01%s",
        f"{args.since}..{args.until}",
    ).splitlines()

    for line in log:
        if "\x01" not in line:
            continue
        sha, subject = line.split("\x01", 1)
        files = [f for f in git("show", "--pretty=format:", "--name-only", sha).split() if f]
        cats = collections.Counter(classify(f) for f in files)
        live = sorted(f for f in files if classify(f) == "live" and not is_infra(f))

        if live:
            verdict = "REVIEW"
        elif cats.get("live"):
            verdict = "INFRA-ONLY"
        elif cats.get("absent"):
            verdict = "NEW-SUBSYSTEM"
        elif set(cats) <= {"docs", "ci", "appcast", "tests", "i18n"}:
            verdict = "IGNORE"
        else:
            verdict = "SKIP"

        rows.append(
            {"sha": sha[:8], "subj": subject, "verdict": verdict,
             "n": len(files), "live": live}
        )

    counts = collections.Counter(r["verdict"] for r in rows)
    print(f"{len(rows)} commits in {args.since}..{args.until}", file=sys.stderr)
    for verdict, n in counts.most_common():
        print(f"  {verdict:14s} {n:5d}", file=sys.stderr)

    if args.json:
        json.dump(rows, open(args.json, "w"), indent=0)
        print(f"\nwrote {args.json}", file=sys.stderr)
    else:
        for r in rows:
            if r["verdict"] == "REVIEW":
                print(f"{r['sha']}  {r['subj']}")


if __name__ == "__main__":
    main()
