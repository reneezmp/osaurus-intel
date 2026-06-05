#!/bin/bash
# Build the hello-intel test plugin as a native x86_64 dylib and install it
# into the Intel fork's isolated Tools dir (~/.osaurus-intel/Tools/hello-intel).
#
# Works from any host arch: clang cross-compiles to x86_64, and the x86_64
# osaurus app (native on Rosy, Rosetta on Apple Silicon) dlopens it.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ABI_INCLUDE="$HERE/../../Packages/OsaurusCore/Tools/PluginABI"
INSTALL_DIR="$HOME/.osaurus-intel/Tools/hello-intel"

echo "→ Compiling hello.c for x86_64…"
clang -arch x86_64 \
      -dynamiclib \
      -O2 \
      -I "$ABI_INCLUDE" \
      -o "$HERE/plugin.dylib" \
      "$HERE/hello.c"

echo "→ Ad-hoc codesigning…"
codesign -s - -f "$HERE/plugin.dylib"

echo "→ Installing to $INSTALL_DIR…"
mkdir -p "$INSTALL_DIR"
cp "$HERE/plugin.dylib" "$INSTALL_DIR/plugin.dylib"
cp "$HERE/manifest.json" "$INSTALL_DIR/manifest.json"

echo "✅ Installed hello-intel."
echo "   Verify arch: $(file "$INSTALL_DIR/plugin.dylib" | sed 's/.*: //')"
