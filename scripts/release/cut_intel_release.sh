#!/usr/bin/env bash
#
# cut_intel_release.sh — one-command release for Osaurus (Intel).
#
# Builds the Intel app, stamps the version, ad-hoc signs it, signs the zip with
# Sparkle (EdDSA), prepends an entry to docs/appcast.xml, creates the GitHub
# release with the zip asset, and pushes the appcast — so installed copies
# auto-update.
#
# Usage:
#   scripts/release/cut_intel_release.sh <shortVersion> ["release notes"]
#   scripts/release/cut_intel_release.sh 1.0.2 "Fixes the global hotkey + budget popover."
#
# The CFBundleVersion (Sparkle's comparison key) is auto-incremented from the
# highest <sparkle:version> already in the appcast, so it always moves forward.
#
# Signing key: read from the macOS Keychain by default (the key created by
# `generate_keys`). To use an exported key instead, set SPARKLE_PRIVATE_KEY.
#
set -euo pipefail

SHORT_VERSION="${1:-}"
if [[ -z "$SHORT_VERSION" ]]; then
  echo "usage: $0 <shortVersion> [\"release notes\"]" >&2
  exit 2
fi
NOTES="${2:-Maintenance release.}"

REPO="reneezmp/osaurus-intel"
BRANCH="intel-fork"
# Minimum macOS the build supports (Sparkle won't offer the update below this).
# Keep in lockstep with the deployment target in the Package.swift files +
# project.pbxproj. macOS 14 (Sonoma) as of the Ventura-compat work; → 13.0 once
# Phase B lands.
MIN_SYS="13.0"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Stamp the upstream-sync era into the release notes. Single source of truth:
# IntelBuildInfo.swift (the same constant the About panel shows) — so the
# in-app metadata and the release notes can never drift.
UPSTREAM_BASE="$(grep -oE 'upstreamBase = "[^"]+"' \
  Packages/OsaurusCore/Models/Chat/IntelConformers/IntelBuildInfo.swift 2>/dev/null \
  | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
if [ -n "$UPSTREAM_BASE" ]; then
  NOTES="${NOTES}

_Intel fork · synced to upstream Osaurus ${UPSTREAM_BASE} — see UPSTREAM_SYNC.md._"
fi

APP="build/rosy-deploy/Build/Products/Debug/osaurus.app"
APPCAST="docs/appcast.xml"
ZIP="$HOME/Desktop/Osaurus-Intel-${SHORT_VERSION}.zip"

# Locate Sparkle's sign_update (it lives in the SPM artifacts after a build).
SIGN_UPDATE="$(find . -path '*sparkle/Sparkle/bin/sign_update' 2>/dev/null | head -1)"
[[ -n "$SIGN_UPDATE" ]] || { echo "✗ sign_update not found — build once first."; exit 1; }

# Guards.
command -v gh >/dev/null || { echo "✗ gh CLI not found"; exit 1; }
if gh release view "$SHORT_VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "✗ release $SHORT_VERSION already exists on $REPO. Pick a new version." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "✗ working tree not clean — commit or stash first." >&2
  exit 1
fi

# 1) Next build number = (highest sparkle:version in appcast) + 1.
LAST_BUILD="$(grep -oE '<sparkle:version>[0-9]+' "$APPCAST" | grep -oE '[0-9]+' | sort -n | tail -1 || true)"
LAST_BUILD="${LAST_BUILD:-1}"
BUILD=$(( LAST_BUILD + 1 ))
echo "→ Releasing Osaurus (Intel) ${SHORT_VERSION}  (build ${BUILD})"

# 2) Build the Intel app (canonical ~/.osaurus, ad-hoc signed).
echo "→ Building…"
CONFIG=Debug scripts/build/build_rosy.sh >/dev/null
[[ -d "$APP" ]] || { echo "✗ build product missing at $APP"; exit 1; }

# 3) Stamp the version and re-sign (editing Info.plist invalidates the signature).
#    Sign with the STABLE self-signed identity, not ad-hoc — this is what makes
#    macOS Keychain keep "Always Allow" across updates instead of re-prompting
#    for every keychain item on every install (ad-hoc's designated requirement is
#    the per-build cdhash, which changes every time). Create the identity once
#    with scripts/build/make_signing_identity.sh. Override via OSAURUS_SIGN_IDENTITY.
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${SHORT_VERSION}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" "$PLIST"
SIGN_IDENTITY="${OSAURUS_SIGN_IDENTITY:-Osaurus Intel Code Signing}"
if ! security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "✗ Signing identity '$SIGN_IDENTITY' not found in keychain."
  echo "  Run scripts/build/make_signing_identity.sh once to create it"
  echo "  (or set OSAURUS_SIGN_IDENTITY). Refusing to fall back to ad-hoc —"
  echo "  that would make every install re-prompt for all keychain items."
  exit 1
fi
echo "→ Signing with '$SIGN_IDENTITY'…"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"

# 4) Package as a ditto zip (NEVER move a raw .app through iCloud — breaks symlinks).
echo "→ Packaging…"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
LENGTH="$(stat -f%z "$ZIP")"

# 5) Sign the zip with Sparkle (EdDSA).
echo "→ Signing…"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  KEYFILE="$(mktemp)"; printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEYFILE"; chmod 600 "$KEYFILE"
  SIG_LINE="$("$SIGN_UPDATE" --ed-key-file "$KEYFILE" "$ZIP")"
  rm -f "$KEYFILE"
else
  SIG_LINE="$("$SIGN_UPDATE" "$ZIP")"   # reads private key from the Keychain
fi
EDSIG="$(printf '%s' "$SIG_LINE" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
[[ -n "$EDSIG" ]] || { echo "✗ failed to derive edSignature from: $SIG_LINE"; exit 1; }

# 6) Create the GitHub release with the asset.
echo "→ Publishing GitHub release…"
gh release create "$SHORT_VERSION" "$ZIP" \
  --repo "$REPO" --target "$BRANCH" \
  --title "Osaurus (Intel) ${SHORT_VERSION}" \
  --notes "$NOTES"

DL_URL="https://github.com/${REPO}/releases/download/${SHORT_VERSION}/Osaurus-Intel-${SHORT_VERSION}.zip"
PUB_DATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"

# 7) Prepend the new <item> to the appcast (newest first), then push.
echo "→ Updating appcast…"
ITEM=$(cat <<EOF
    <item>
      <title>${SHORT_VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:channel>release</sparkle:channel>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_SYS}</sparkle:minimumSystemVersion>
      <enclosure url="${DL_URL}" length="${LENGTH}" type="application/octet-stream" sparkle:edSignature="${EDSIG}"/>
      <description sparkle:format="markdown"><![CDATA[
## Osaurus (Intel) ${SHORT_VERSION}

${NOTES}
]]></description>
    </item>
EOF
)

ITEM="$ITEM" APPCAST="$APPCAST" python3 - <<'PY'
import os
path = os.environ["APPCAST"]
item = os.environ["ITEM"]
s = open(path).read()
anchor = "<language>en</language>\n"
if anchor not in s:
    raise SystemExit("✗ appcast anchor '<language>en</language>' not found")
s = s.replace(anchor, anchor + item + "\n", 1)
open(path, "w").write(s)
print("   appcast item inserted")
PY

git add "$APPCAST"
git commit -q -m "release: Osaurus (Intel) ${SHORT_VERSION} (build ${BUILD})"
git push origin "$BRANCH"

echo ""
echo "✅ Released Osaurus (Intel) ${SHORT_VERSION} (build ${BUILD})"
echo "   asset : ${DL_URL}  (${LENGTH} bytes)"
echo "   feed  : pushed to ${BRANCH} → installed copies will see it on the next check."
