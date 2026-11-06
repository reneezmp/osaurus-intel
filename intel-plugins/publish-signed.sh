#!/bin/bash
# Build, zip, minisign-sign and list the Intel plugins in upstream's registry
# format (`W-plugin-reliability` stage 2g-2; docs/INTEL_PLUGIN_PUBLISHING.md).
#
# Run it against YOUR checkout of the plugin repo, then review and push that
# checkout yourself:
#
#   intel-plugins/publish-signed.sh ~/Developer/osaurus-intel-plugins
#
# For each plugin (default: time hello fetch memo) it:
#   1. builds the dylib from this repo's intel-plugins/<name>/ sources for
#      x86_64 with a macOS 13.0 minimum (Rosy runs Ventura) and ad-hoc signs it;
#   2. zips it as dist/<name>/<plugin_id>-<version>.zip (upstream's artifact);
#   3. signs the zip with minisign (legacy Ed25519, the format Osaurus checks;
#      minisign asks for your key's password) and verifies the signature;
#   4. writes plugins/<name>.json: your public key under `public_keys.minisign`
#      and the version's x86_64 artifact (zip URL, SHA-256, size, signature);
#   5. refreshes dist/<name>/plugin.dylib + manifest.json and their SHA-256 /
#      size in plugins.json, the raw index older Intel builds (up to 1.0.62)
#      install from.
#
# Do NOT run the plugin repo's generate-index.sh afterwards: it rebuilds
# plugins.json from the spec artifact URL, which is now the zip, and would
# point older builds at a zip they can't load.
#
# Environment (all optional):
#   MINISIGN_KEY   secret key   (default ~/.minisign/osaurus-intel-plugins.key)
#   MINISIGN_PUB   public key   (default ~/.minisign/osaurus-intel-plugins.pub)
#   RAW_BASE       download base (default https://raw.githubusercontent.com/reneezmp/osaurus-intel-plugins/main)
#   PLUGINS        plugin folders to publish (default "time hello fetch memo")
#   MIN_MACOS      deployment target (default 13.0)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ABI_INCLUDE="$HERE/../Packages/OsaurusCore/Tools/PluginABI"
REPO="${1:?Usage: $0 <path to your osaurus-intel-plugins checkout>}"
REPO="$(cd "$REPO" && pwd)"
MINISIGN_KEY="${MINISIGN_KEY:-$HOME/.minisign/osaurus-intel-plugins.key}"
MINISIGN_PUB="${MINISIGN_PUB:-$HOME/.minisign/osaurus-intel-plugins.pub}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/reneezmp/osaurus-intel-plugins/main}"
PLUGINS="${PLUGINS:-time hello fetch memo}"
MIN_MACOS="${MIN_MACOS:-13.0}"

fail() { echo "✗ $*" >&2; exit 1; }

[ -d "$REPO/plugins" ] && [ -d "$REPO/dist" ] && [ -f "$REPO/plugins.json" ] \
  || fail "$REPO doesn't look like the plugin repo (needs plugins/, dist/, plugins.json)."
for tool in clang codesign zip vtool lipo shasum minisign; do
  command -v "$tool" >/dev/null || fail "'$tool' not found. (minisign: brew install minisign)"
done
[ -f "$MINISIGN_KEY" ] || fail "secret key not found at $MINISIGN_KEY (see docs/INTEL_PLUGIN_PUBLISHING.md)."
[ -f "$MINISIGN_PUB" ] || fail "public key not found at $MINISIGN_PUB."
PUBKEY="$(sed -n 2p "$MINISIGN_PUB" | tr -d '[:space:]')"
[ -n "$PUBKEY" ] || fail "no key on line 2 of $MINISIGN_PUB."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "→ Publishing to $REPO (minimum macOS $MIN_MACOS)"
for name in $PLUGINS; do
  src_dir="$HERE/$name"
  manifest="$src_dir/manifest.json"
  [ -f "$manifest" ] || fail "$name: no manifest.json in $src_dir"
  plugin_id="$(/usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['plugin_id'])" "$manifest")"
  version="$(/usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$manifest")"
  spec="$REPO/plugins/$name.json"
  [ -f "$spec" ] || fail "$name: no spec at $spec"
  dist="$REPO/dist/$name"
  mkdir -p "$dist"
  stage="$WORK/$name"
  mkdir -p "$stage"
  echo "• $name → $plugin_id $version"

  # 1. Build for Intel Macs on Ventura and later.
  # shellcheck disable=SC2046
  clang -arch x86_64 -mmacosx-version-min="$MIN_MACOS" -dynamiclib -O2 \
    -I "$ABI_INCLUDE" -I "$HERE/common" \
    -o "$stage/plugin.dylib" $(ls "$src_dir"/*.c)
  [ "$(lipo -archs "$stage/plugin.dylib")" = "x86_64" ] || fail "$name: not an x86_64-only dylib"
  minos="$(vtool -show-build "$stage/plugin.dylib" | awk '/minos/ {print $2; exit}')"
  [ "$minos" = "$MIN_MACOS" ] || fail "$name: built for macOS $minos, expected $MIN_MACOS"
  codesign -s - -f "$stage/plugin.dylib" >/dev/null 2>&1

  # 2. Upstream's artifact: a flat zip with the dylib (and docs if any).
  zipname="$plugin_id-$version.zip"
  for doc in README.md CHANGELOG.md; do
    [ -f "$src_dir/$doc" ] && cp "$src_dir/$doc" "$stage/"
  done
  (cd "$stage" && zip -X -q "$WORK/$zipname" ./*)

  # 3. Sign (legacy, non-prehashed: Osaurus verifies Ed25519 over the bytes).
  minisign -S -l -s "$MINISIGN_KEY" -m "$WORK/$zipname" -x "$WORK/$zipname.minisig" \
    -t "$plugin_id $version"
  algo="$(sed -n 2p "$WORK/$zipname.minisig" | base64 -D 2>/dev/null | head -c 2)"
  [ "$algo" = "Ed" ] || fail "$name: signature is prehashed ('$algo'); Osaurus needs legacy 'Ed'. Update minisign."
  minisign -V -q -p "$MINISIGN_PUB" -m "$WORK/$zipname" -x "$WORK/$zipname.minisig" \
    || fail "$name: signature didn't verify with $MINISIGN_PUB"

  # 4 + 5. Publish files and rewrite the spec / raw index.
  cp "$WORK/$zipname" "$dist/$zipname"
  cp "$stage/plugin.dylib" "$dist/plugin.dylib"
  cp "$manifest" "$dist/manifest.json"
  /usr/bin/python3 - "$spec" "$REPO/plugins.json" "$dist/$zipname" "$WORK/$zipname.minisig" \
    "$dist/plugin.dylib" "$PUBKEY" "$RAW_BASE/dist/$name/$zipname" "$plugin_id" "$version" "$MIN_MACOS" <<'PY'
import hashlib, json, os, sys
spec_path, index_path, zip_path, sig_path, dylib_path, pubkey, url, pid, version, min_macos = sys.argv[1:]

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()

with open(spec_path) as f:
    spec = json.load(f)
if spec.get("plugin_id") != pid:
    sys.exit(f"spec {spec_path} is for {spec.get('plugin_id')}, not {pid}")
spec.setdefault("public_keys", {})["minisign"] = pubkey
artifact = {
    "os": "macos",
    "arch": "x86_64",
    "min_macos": min_macos,
    "url": url,
    "sha256": sha256(zip_path),
    "size": os.path.getsize(zip_path),
    "minisign": {"signature": open(sig_path).read()},
}
versions = spec.setdefault("versions", [])
entry = next((v for v in versions if v.get("version") == version), None)
if entry is None:
    entry = {"version": version}
    versions.insert(0, entry)
entry["artifacts"] = [artifact]
with open(spec_path, "w") as f:
    json.dump(spec, f, indent=2)
    f.write("\n")

with open(index_path) as f:
    index = json.load(f)
for p in index.get("plugins", []):
    if p.get("id") == pid:
        p["sha256"] = sha256(dylib_path)
        p["size"] = os.path.getsize(dylib_path)
with open(index_path, "w") as f:
    json.dump(index, f, indent=2)
    f.write("\n")
PY
  echo "  ✓ signed, $(stat -f%z "$dist/$zipname") bytes"
done

echo ""
echo "✅ Done. Review the changes in $REPO (git -C \"$REPO\" status), then commit and push them yourself."
echo "   Don't run generate-index.sh: it would point older Intel builds at the zips."
