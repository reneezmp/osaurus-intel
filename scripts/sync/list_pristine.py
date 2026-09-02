#!/usr/bin/env python3
"""Split the fork's live files into PRISTINE (safe to fast-forward) and TOUCHED.

A file is PRISTINE when the fork's copy is byte-identical to upstream at the last
synced commit — meaning the fork never customized it, so upstream's newer version
can be taken wholesale:

    git checkout upstream/main -- <path>

A TOUCHED file has Intel divergence and must be hand-reconciled. On the fork that
divergence is usually *deletion* (amputated subsystem call sites removed), which is
why upstream's version can never simply replace it.

Usage:
    scripts/sync/list_pristine.py <since>                    # all live files
    scripts/sync/list_pristine.py <since> --triage out.json  # only files that
                                                             # reviewed commits touch
"""

import argparse
import json
import os
import subprocess

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Never fast-forward these — see UPSTREAM_SYNC.md "Intel-owned files".
INTEL_OWNED = (
    "README.md",
    "RemoteProviderKeychain.swift",
    "MCPProviderKeychain.swift",
    "App/osaurus/Info.plist",
    "scripts/release/cut_intel_release.sh",
    "scripts/build/build_rosy.sh",
)


def git(*args):
    return subprocess.run(
        ["git"] + list(args), capture_output=True, text=True, cwd=REPO
    )


def blob(rev, path):
    p = git("rev-parse", f"{rev}:{path}")
    return p.stdout.strip() if p.returncode == 0 else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("since", help="last synced upstream commit, e.g. 9124d696")
    ap.add_argument("--triage", help="triage.py --json output; restrict to REVIEW files")
    args = ap.parse_args()

    if args.triage:
        rows = json.load(open(args.triage))
        candidates = set()
        for r in rows:
            if r["verdict"] == "REVIEW":
                candidates.update(r.get("live", []))
    else:
        candidates = set(git("ls-tree", "-r", "--name-only", "HEAD").stdout.splitlines())

    pristine, touched, owned = [], [], []
    for f in sorted(candidates):
        if any(f.endswith(o) or f == o for o in INTEL_OWNED):
            owned.append(f)
            continue
        here, base = blob("HEAD", f), blob(args.since, f)
        if here is None or base is None:
            touched.append(f)
        elif here == base:
            pristine.append(f)
        else:
            touched.append(f)

    print(f"# candidates: {len(candidates)}")
    print(f"# PRISTINE (fast-forwardable): {len(pristine)}")
    print(f"# TOUCHED   (hand-reconcile):  {len(touched)}")
    print(f"# INTEL-OWNED (never FF):      {len(owned)}")
    print()
    for f in pristine:
        print(f)


if __name__ == "__main__":
    main()
