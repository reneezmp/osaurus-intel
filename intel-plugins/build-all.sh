#!/bin/bash
# Dev-only; M4 isolation. Rosy users install plugins via the plugin repo
# (github.com/reneezmp/osaurus-intel-plugins).
#
# Build every single-file C plugin under intel-plugins/ as a native x86_64
# dylib and install it into the Intel fork's isolated Tools dir
# (~/.osaurus-intel/Tools/<plugin_id>/). Re-run after editing any plugin.
#
# A plugin dir qualifies if it has a manifest.json + exactly one *.c file.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ABI_INCLUDE="$HERE/../Packages/OsaurusCore/Tools/PluginABI"

for dir in "$HERE"/*/; do
    name="$(basename "$dir")"
    manifest="$dir/manifest.json"
    [ -f "$manifest" ] || continue

    # shellcheck disable=SC2086
    src=$(ls "$dir"*.c 2>/dev/null || true)
    [ -n "$src" ] || continue

    plugin_id="$(/usr/bin/python3 -c "import json;print(json.load(open('$manifest'))['plugin_id'])")"
    install_dir="$HOME/.osaurus-intel/Tools/$plugin_id"

    echo "→ $name → $plugin_id"
    clang -arch x86_64 -dynamiclib -O2 -I "$ABI_INCLUDE" -o "$dir/plugin.dylib" $src
    codesign -s - -f "$dir/plugin.dylib"
    mkdir -p "$install_dir"
    cp "$dir/plugin.dylib" "$install_dir/plugin.dylib"
    cp "$manifest" "$install_dir/manifest.json"
    echo "   ✅ $(file "$install_dir/plugin.dylib" | sed 's/.*: //')"
done

echo "Done. Launch with OSAURUS_INTEL_PLUGIN_SELFTEST=1 to verify, or open the Plugins tab."
