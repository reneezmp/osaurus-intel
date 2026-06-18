#!/usr/bin/env bash
set -euo pipefail

# Build a Rosy-ready Osaurus.app — the Intel fork, x86_64, ad-hoc signed for
# local install on Rosy (2017 Intel MacBook Air, macOS Sequoia via OCLP).
#
# The key difference from a dev build: this app carries
# `OsaurusCanonicalData = true` in its Info.plist, so it owns the canonical
# `~/.osaurus` instead of the dev-isolated `~/.osaurus-intel`. On Rosy the fork
# is the ONLY Osaurus, so there's no production install to protect.
#
# Usage:   scripts/build/build_rosy.sh            # Debug (matches what we tested)
#          CONFIG=Release scripts/build/build_rosy.sh

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-Debug}"
DERIVED="build/rosy-deploy"

echo "→ Building osaurus.app (Intel x86_64, $CONFIG)…"
xcodebuild \
  -workspace osaurus.xcworkspace \
  -scheme osaurus \
  -configuration "$CONFIG" \
  -arch x86_64 \
  -derivedDataPath "$DERIVED" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build | tail -3

APP="$DERIVED/Build/Products/$CONFIG/osaurus.app"
[ -d "$APP" ] || { echo "✗ build product not found at $APP"; exit 1; }
PLIST="$APP/Contents/Info.plist"

echo "→ Baking OsaurusCanonicalData = true (use ~/.osaurus on Rosy)…"
/usr/libexec/PlistBuddy -c "Set :OsaurusCanonicalData true" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :OsaurusCanonicalData bool true" "$PLIST"

# Re-sign with the stable self-signed identity (editing Info.plist invalidated
# the signature). A STABLE identity — not ad-hoc — is what makes macOS Keychain
# remember "Always Allow" across app updates: the keychain ACL pins to the
# signature's designated requirement, which for ad-hoc is the per-build cdhash
# (changes every build → re-prompts forever), but for this cert is a constant
# `identifier "com.dinoki.osaurus" and certificate leaf = H"<cert>"`.
# Create once with: scripts/build/make_signing_identity.sh
SIGN_IDENTITY="${OSAURUS_SIGN_IDENTITY:-Osaurus Intel Code Signing}"
echo "→ Re-signing with '$SIGN_IDENTITY'…"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"

echo ""
echo "✅ Rosy deploy build ready:"
echo "   $APP"
echo "   arch:      $(file "$APP/Contents/MacOS/osaurus" | sed 's/.*: //')"
echo "   canonical: $(/usr/libexec/PlistBuddy -c 'Print :OsaurusCanonicalData' "$PLIST")"
echo ""
echo "Next: copy osaurus.app to Rosy's /Applications and launch it."
echo "On first run it will create + own ~/.osaurus (look for the log line:"
echo "  '[Osaurus] data root: isIntel=true canonical=true → ~/.osaurus')."
echo "If Gatekeeper blocks it: right-click → Open, or 'xattr -dr com.apple.quarantine osaurus.app'."
