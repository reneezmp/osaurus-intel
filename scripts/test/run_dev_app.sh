#!/bin/zsh
# Launch an Intel dev build on the dev Mac without touching the live
# ~/.osaurus, its preferences, caches or keychain (docs/TEST_STORAGE_SAFETY.md,
# "Dev-Mac rule"). Build first with PRODUCT_BUNDLE_IDENTIFIER=com.dinoki.osaurus.intel-dev
# (see the comment at the end). Usage: scripts/test/run_dev_app.sh [path/to/osaurus.app]
# Quit the app normally; the script then runs the postflight checks and cleans up.
set -u
DEV_ID="com.dinoki.osaurus.intel-dev"
APP="${1:-build/intel-dev/Build/Products/Debug/osaurus.app}"
cd "$(dirname "$0")/../.." || exit 1
[[ -x "$APP/Contents/MacOS/osaurus" ]] || { echo "no app at $APP"; exit 1; }
id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$id" == "$DEV_ID" ]] || { echo "refusing: bundle id is '$id', not $DEV_ID"; exit 1; }

INTEL_RUN_ROOT="$(mktemp -d /tmp/osaurus-intel-run.XXXXXX)"
if [[ -z "$INTEL_RUN_ROOT" || ! -d "$INTEL_RUN_ROOT" ]]; then echo "no temp root"; exit 1; fi
marker="$INTEL_RUN_ROOT/.marker"; touch "$marker"
mdat_before="$(security find-generic-password -s com.osaurus.account -a master-key 2>/dev/null | grep mdat)"

# Sparkle off for the dev domain: the dev build must never update itself.
defaults write "$DEV_ID" SUEnableAutomaticChecks -bool false
defaults write "$DEV_ID" SUAutomaticallyUpdate -bool false

echo "data root: $INTEL_RUN_ROOT  (keychain off, Sparkle off)"
echo "Quit the app (Cmd-Q) when done; cleanup runs after."
OSAURUS_TEST_ROOT="$INTEL_RUN_ROOT" OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
  "$APP/Contents/MacOS/osaurus" > "$INTEL_RUN_ROOT/../osaurus-intel-run.log" 2>&1
echo "app exited ($?)"

mdat_after="$(security find-generic-password -s com.osaurus.account -a master-key 2>/dev/null | grep mdat)"
[[ "$mdat_before" == "$mdat_after" ]] && echo "mdat unchanged" || echo "MDAT CHANGED: $mdat_before -> $mdat_after"
echo "files changed under ~/.osaurus while it ran (expect only the upstream app's own writes):"
find ~/.osaurus -newer "$marker" -type f -exec stat -f '%Sm %N' {} \; 2>/dev/null | head -20
rm -rf "$INTEL_RUN_ROOT"
defaults delete "$DEV_ID" >/dev/null 2>&1
rm -rf "$HOME/Library/Caches/$DEV_ID"
echo "cleaned up: temp root, $DEV_ID defaults and caches"

# Build command used (2026-11-26):
# xcodebuild -workspace osaurus.xcworkspace -scheme osaurus -configuration Debug \
#   -arch x86_64 -skipPackagePluginValidation -skipMacroValidation \
#   -derivedDataPath build/intel-dev ONLY_ACTIVE_ARCH=NO \
#   PRODUCT_BUNDLE_IDENTIFIER=com.dinoki.osaurus.intel-dev \
#   CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
