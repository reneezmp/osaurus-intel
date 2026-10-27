#!/usr/bin/env python3
# Usage: python3 scripts/upstream/guide_check.py Packages/OsaurusCore Packages/OsaurusCore/Resources/Guide $(ls Packages/OsaurusCore/Resources/Guide)
# See docs/GUIDE_INTEL.md.
"""Report bold UI labels and `code` names in guide topics that don't appear
in the Swift sources Intel compiles (Package.swift excludes honoured,
#if !OSAURUS_INTEL whole-file gates skipped)."""
import os, re, sys, json
pkg = sys.argv[1]; guide_dir = sys.argv[2]; files = sys.argv[3:]
src_root = pkg
pkg_swift = open(os.path.join(pkg, 'Package.swift')).read()
# target exclude list: everything inside the first 'exclude: [' of the main target
excl = set(re.findall(r'"([^"]+\.swift)"', pkg_swift))
corpus = []
for d, _, fs in os.walk(src_root):
    if '/.build' in d or '/Tests' in d: continue
    for f in fs:
        if not f.endswith('.swift'): continue
        p = os.path.join(d, f); rel = os.path.relpath(p, src_root)
        if rel in excl: continue
        t = open(p, encoding='utf-8', errors='ignore').read()
        if t.lstrip().startswith('#if !OSAURUS_INTEL') and '#else' not in t: continue
        corpus.append(t)
loc = os.path.join(pkg, 'Resources', 'Localizable.xcstrings')
if os.path.exists(loc): corpus.append(open(loc).read())
blob = '\n'.join(corpus).lower()
for f in files:
    text = open(os.path.join(guide_dir, f)).read()
    bold = set(re.findall(r'\*\*([^*]{2,60})\*\*', text))
    code = set(re.findall(r'`([a-z_][a-z0-9_]{3,40})`', text))
    miss_b = sorted(b for b in bold if b.lower().strip(' .…') not in blob)
    miss_c = sorted(c for c in code if c.lower() not in blob)
    print(f'== {f}: bold missing {len(miss_b)}/{len(bold)}, code missing {len(miss_c)}/{len(code)}')
    if miss_b: print('   bold:', miss_b)
    if miss_c: print('   code:', miss_c)
