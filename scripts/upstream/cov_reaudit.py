#!/usr/bin/env python3
"""List upstream commits since the fork that no Intel doc has examined.

Usage (from the repo root):
    python3 scripts/upstream/cov_reaudit.py [upstream-ref]          # worklist
    python3 scripts/upstream/cov_reaudit.py [upstream-ref] --show H  # one commit
    python3 scripts/upstream/cov_reaudit.py [upstream-ref] --mentioned  # examined, but absent?

`W-cov-reaudit` (docs/COV_REAUDIT.md). The file classifiers only see files
Intel doesn't compile; a file Intel compiles (its own copy, or an upstream
file ported at some point) can still miss later upstream commits to it. This
walks every commit from the fork point to the ref that touches OsaurusCore
sources and keeps the ones no doc under docs/ mentions (by short hash or PR
number). It drops commits that only touch tests/resources, or only files
whose feature group is Incompatible, Deferred or dev tooling
(gap_features.py).

For each remaining commit it scores presence: of the lines the commit added
that still exist in upstream at the ref (so later rewrites don't count), how
many appear anywhere in Intel's OsaurusCore sources. A low score means the
change is probably not on Intel. Triage verdicts go in the table in
docs/COV_REAUDIT.md (its hash mention takes the commit off this list), so the
run ends with "UNTRIAGED 0" when everything has a verdict.

`--mentioned` scores the commits the docs DO mention instead, and lists the
ones whose code is mostly absent (presence < 50%). A doc mention means the
commit was examined, not that it was ported: the 0.24.3 triage marked #2388
and #2392 PORT, and neither reached Intel. A listed commit is fine when its
doc verdict was skip/defer/omit; a PORT verdict with absent code is a gap.
Any commit with a row in docs/COV_REAUDIT.md's tables has a verdict and is
left off this list.
"""
import collections, glob, os, re, subprocess, sys

PRE = "Packages/OsaurusCore/"
args = [a for a in sys.argv[1:] if not a.startswith("--")]
REF = args[0] if args else "upstream/main"
SHOW = sys.argv[sys.argv.index("--show") + 1] if "--show" in sys.argv else None
MENTIONED = "--mentioned" in sys.argv

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gap_features import F


def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True).stdout


FORK = git("merge-base", "HEAD", REF).strip()

pkg = open(PRE + "Package.swift").read()
excluded = set()
for block in re.findall(r"exclude:\s*\[(.*?)\]", pkg, re.S):
    excluded.update(re.findall(r'"([^"]+)"', block))


def compiled(f):
    return os.path.exists(PRE + f) and f not in excluded


def group(f):
    for fid, verdict, pat in F:
        if re.search(pat, f):
            return fid, verdict
    return None, None


def norm(line):
    return re.sub(r"\s+", " ", line.strip())


def meaningful(n):
    return len(n) >= 14 and not n.startswith("//") and n not in ("}", "{")


docs = "".join(open(p).read() for p in glob.glob("docs/*.md"))
# Every commit with a row in this audit's tables already has a verdict there.
audit_doc = open("docs/COV_REAUDIT.md").read() if os.path.exists("docs/COV_REAUDIT.md") else ""
rechecked = {h[:7] for h in re.findall(r"^\|[^|]*\| (?:re-checked )?`([0-9a-f]{7,12})`", audit_doc, re.M)}
doc_prs = set(re.findall(r"#(\d{3,5})\b", docs))
doc_hashes = {h[:7] for h in re.findall(r"\b[0-9a-f]{7,12}\b", docs)}

# For --mentioned: the ledger lines outside this audit's own table, and the
# words that record a decision not to port.
ledger_lines = [
    l for p in glob.glob("docs/*.md") if not p.endswith("COV_REAUDIT.md") for l in open(p)
]
DECLINED = re.compile(
    r"\b(SKIP|Skip|skip|skipped|DEFER|Defer|defer|deferred|Omit|omit|OMIT|IGNORE|Ignore|"
    r"Incompatible|incompatible|amputated|N/A|Not applicable|not applicable|MLX|vMLX|vmlx)\b"
    r"|\| I \||\| \*\*I\*\* \|"
)


def ledger_mentions(h, prs):
    pats = [re.compile(r"\b" + h[:7])] + [re.compile(rf"#{p}\b") for p in prs]
    return [l for l in ledger_lines if any(p.search(l) for p in pats)]

intel_lines = set()
for root, _, files in os.walk(PRE):
    rel = root[len(PRE):]
    if ".build" in root or rel.startswith("Tests"):
        continue
    for name in files:
        if name.endswith(".swift"):
            with open(os.path.join(root, name), errors="ignore") as fh:
                intel_lines.update(norm(l) for l in fh)

_up = {}


def upstream_lines(f):
    if f not in _up:
        _up[f] = {norm(l) for l in git("show", f"{REF}:{PRE}{f}").splitlines()}
    return _up[f]


def presence(h, src, keep_missing=False):
    diff = git("show", "--format=", "--unified=0", h, "--", *[PRE + f for f in src])
    cur, surv, pres, missing = None, 0, 0, []
    for line in diff.splitlines():
        if line.startswith("+++ "):
            cur = line[6 + len(PRE):] if line.startswith("+++ b/") else None
            continue
        if not line.startswith("+") or cur is None:
            continue
        n = norm(line[1:])
        if not meaningful(n) or n not in upstream_lines(cur):
            continue
        surv += 1
        if n in intel_lines:
            pres += 1
        elif keep_missing:
            missing.append((cur, n))
    return surv, pres, missing


log = git("log", "--format=@@%h|%s", "--name-only", f"{FORK}..{REF}", "--", "Packages/OsaurusCore")
commits = []
for chunk in log.split("@@")[1:]:
    lines = [l for l in chunk.splitlines() if l.strip()]
    h, subject = lines[0].split("|", 1)
    files = [l[len(PRE):] for l in lines[1:] if l.startswith(PRE)]
    commits.append((h, subject, files))

if SHOW:
    for h, subject, files in commits:
        if h.startswith(SHOW) or SHOW.startswith(h):
            src = [f for f in files if f.endswith(".swift") and not f.startswith("Tests/")]
            surv, pres, missing = presence(h, src, keep_missing=True)
            print(f"{h} {subject}\npresence {pres}/{surv}")
            for f in src:
                g, v = group(f)
                print(f"  {'compiled' if compiled(f) else (g or '?') + ':' + (v or '?'):28s} {f}")
            print("missing lines (sample):")
            for f, n in missing[:40]:
                print(f"  {f.split('/')[-1]}: {n[:150]}")
            break
    sys.exit(0)

skipped = collections.Counter()
rows = []
for h, subject, files in commits:
    prs = re.findall(r"\(#(\d+)\)", subject)
    mentioned = h[:7] in doc_hashes or any(p in doc_prs for p in prs)
    if mentioned != MENTIONED:
        skipped["mentioned in docs" if mentioned else "not mentioned in docs"] += 1
        continue
    if MENTIONED:
        if h[:7] in rechecked:
            skipped["re-checked"] += 1
            continue
        lines = ledger_mentions(h, prs)
        if not lines:
            skipped["only in this audit's table"] += 1
            continue
        if any(DECLINED.search(l) for l in lines):
            skipped["declined in the ledger (skip/defer/omit/MLX)"] += 1
            continue
    src = [f for f in files if f.endswith(".swift") and not f.startswith("Tests/")]
    if not src:
        skipped["tests/resources only"] += 1
        continue
    cats = set()
    for f in src:
        if compiled(f):
            cats.add("compiled")
        else:
            g, v = group(f)
            cats.add(f"{g}:{v}" if g else "gone")
    if all(c[-2:] in (":I", ":D", ":N") for c in cats):
        skipped["only I/D/N files"] += 1
        continue
    surv, pres, _ = presence(h, src)
    if MENTIONED and (not surv or pres / surv >= 0.5):
        skipped["mentioned, mostly present or superseded"] += 1
        continue
    rows.append((h, subject, surv, pres, sorted(cats)))

print(f"fork {FORK[:9]} .. {REF}: {len(commits)} commits touch OsaurusCore")
for k, n in skipped.items():
    print(f"  skipped {n:4d} {k}")
rows.sort(key=lambda r: (r[3] / r[2]) if r[2] else 2)
for h, subject, surv, pres, cats in rows:
    score = f"{pres:4d}/{surv:<4d}" if surv else "  superseded"
    print(f"{h} {score} {subject[:90]} | {','.join(c.split(':')[0] for c in cats)}")
print("ABSENT-UNCHECKED" if MENTIONED else "UNTRIAGED", len(rows))
