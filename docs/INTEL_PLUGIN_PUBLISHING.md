# Publishing the Intel plugins (signed)

How the Intel plugins get from `intel-plugins/` (sources, this repo) to the
plugin repo `reneezmp/osaurus-intel-plugins` that Osaurus Intel installs
from. Since `W-plugin-reliability` stage 2g (2026-11-06) this follows
upstream's registry format: every plugin version is a zip signed with
minisign, listed in `plugins/<name>.json` with the publisher's public key.
Osaurus pins that key at first install and refuses an update signed with a
different one (upstream's TOFU rule).

Renée owns the signing key and the plugin repo. Sessions write scripts and
app code; they never create, read or move the secret key, and never push to
the plugin repo.

## Release order

Since stage 2g-3 the app installs only signed plugins from the spec files.
Publish with the script **before** shipping a build that has 2g-3: until
then the specs list unsigned raw dylibs and the new installer refuses them.
Builds up to 1.0.62 keep installing from `plugins.json`.

## One-time setup

1. Install minisign: `brew install minisign`.
2. Create the key pair (minisign asks for a password; use a strong one and
   keep it in your password manager):

   ```sh
   mkdir -p ~/.minisign
   minisign -G -p ~/.minisign/osaurus-intel-plugins.pub -s ~/.minisign/osaurus-intel-plugins.key
   ```

3. Back up `~/.minisign/osaurus-intel-plugins.key` somewhere safe (with its
   password). If it is lost, a new key means every installed plugin refuses
   the next update until it is uninstalled and installed again. The `.pub`
   file is public and goes into every spec.

## Publishing

```sh
intel-plugins/publish-signed.sh ~/path/to/osaurus-intel-plugins
```

Per plugin (`time`, `hello`, `fetch`, `memo`, `xlsx`, `pptx` by default;
`PLUGINS="..."` to choose) the script:

1. builds the dylib from `intel-plugins/<name>/` for **x86_64 with a macOS
   13.0 minimum**, checks both, and ad-hoc signs it (C plugins with clang,
   `xlsx` and `pptx` with SwiftPM, see below);
2. zips it as `dist/<name>/<plugin_id>-<version>.zip` (with `README.md`,
   `CHANGELOG.md` and `SKILL.md` when the folder has them; the host loads a
   plugin's `SKILL.md` from its install folder);
3. signs the zip with minisign (legacy Ed25519, which is what Osaurus
   verifies; it asks for the key's password once per plugin) and verifies
   the signature with the public key;
4. writes `plugins/<name>.json`: `public_keys.minisign` and the version's
   single x86_64 artifact (zip URL, SHA-256, size, `min_macos`, signature);
5. refreshes `dist/<name>/plugin.dylib` + `manifest.json` and their SHA-256
   and size in `plugins.json`, the raw index that Intel builds up to 1.0.62
   still install from.

Then review (`git -C <repo> diff`), commit and push the plugin repo.

A plugin published for the first time (`xlsx`, `pptx`) has no
`plugins/<name>.json` yet: the script writes one from the plugin's
`manifest.json` (id, name, description, licence, tool summaries) and then adds
the signed version entry as usual. It does not add them to `plugins.json`
(the raw index only serves builds up to 1.0.62, which never knew these
plugins).

### Build only (dry run)

`BUILD_ONLY=1 PLUGINS="xlsx pptx" intel-plugins/publish-signed.sh` builds,
runs the arch / minos / dependency checks and leaves unsigned zips in
`$OUT_DIR` (default `$TMPDIR/osaurus-intel-plugins-dryrun`). It needs no key
and no plugin repo, and it touches nothing outside the scratch build dir.

- **Don't run the plugin repo's `generate-index.sh` any more.** It rebuilds
  `plugins.json` from the spec's artifact URL, which is now the zip, and
  would point older builds at a file they can't load.
- **To release a new plugin version:** bump `version` in
  `intel-plugins/<name>/manifest.json`, run the script (it adds the new
  version entry at the top of the spec), push.
- The retired `search-intel` isn't published (native Web Search replaced
  it); its old spec entry stays unsigned, so the new installer refuses it.
- Options: `MINISIGN_KEY`, `MINISIGN_PUB`, `RAW_BASE`, `PLUGINS`,
  `MIN_MACOS` (see the script header).

## The document plugins `osaurus.xlsx` and `osaurus.pptx` (2026-11-28)

Upstream's built-in Document Builder skill (and `FolderPluginHints`) send the
model to these two first-party plugins, so Intel publishes them. They are
Swift packages, vendored (not rewritten) from upstream:

| Folder | Upstream | Commit |
|---|---|---|
| `intel-plugins/xlsx/` | `osaurus-ai/osaurus-xlsx` | `f69c93410ac3fa286cf35b1b04c1f859b9202323` |
| `intel-plugins/pptx/` | `osaurus-ai/osaurus-pptx` | `399b57ee4eef0c96f500730e5b84b53bc15aab04` |
| `intel-plugins/swift-sdk/` | `osaurus-ai/osaurus-plugin-sdk` 1.0.0 | `f5fac88621aa174531c0aac3c1d1dbbbd8142522` |

Each folder's `INTEL.md` lists every Intel change. Short version: the package
platform `.macOS(.v15)` -> `.v13` (a declaration only; no macOS 14/15 API is
used), the SDK dependency becomes the vendored path package, and the embedded
manifest's `min_macos` `15.0` -> `13.0`. The last one matters: the Intel host
refuses a plugin whose manifest needs a newer macOS than the running one, so
an unmodified upstream build would show a load error on Ventura even if the
dylib itself loaded. Why they work on Intel: the SDK's C ABI is the same
version 6 `osaurus_plugin.h` the Intel host ships, both entry symbols are
exported, and the dylib links only `/usr/lib/swift` and system frameworks
(no back-deploy libraries to ship; the one weak reference to
`swift_coroFrameAlloc` is guarded by a null check that falls back to `malloc`).

How the script builds them: `arch -x86_64 /usr/bin/swift build -c release
--arch x86_64 -Xswiftc -target -Xswiftc x86_64-apple-macosx13.0` in a scratch
dir, then checks `lipo` = x86_64, `vtool` minos = 13.0, that exactly one
`lib*.dylib` exists, that it links only `/usr/lib/` and `/System/Library/`
libraries, and that `manifest.json`'s version and `min_macos` appear in the
manifest string compiled into the dylib. Checked 2026-11-28 on the build Mac
(Xcode 27.2): both build, `file` says x86_64, `minos 13.0`, and the x86_64
dylibs loaded under Rosetta through a small C driver that calls
`osaurus_plugin_entry_v2` / `osaurus_plugin_entry`, `get_manifest` and `invoke`
(`create_xlsx`, `list_sheets`, `xlsx_to_csv`, `create_presentation` returned
correct JSON). Package tests (xlsx 101, pptx 82, SDK 24) pass natively on the
build Mac; the Xcode 27 test helper is arm64 only
(`docs/TEST_STORAGE_SAFETY.md`), so they do not run as x86_64. Not yet tested:
an install on Rosy (Ventura). Do that after publishing: install `XLSX` and
`PPTX` from the Plugins tab, ask for a spreadsheet and a deck, and confirm the
files open.

What Renée must do: run the publish script with the default list (or
`PLUGINS="xlsx pptx"`), review `git diff` in the plugin repo (two new
`plugins/*.json` and `dist/*` folders), commit and push. Later releases: bump
`version` in `intel-plugins/<name>/manifest.json` **and** in the manifest
string in `Sources/osaurus_<name>/Plugin.swift` (the script refuses a
mismatch).

## Why the rebuild matters now (found 2026-11-06)

Every dylib published in June 2026 was built with no deployment target on a
macOS 26 SDK: `vtool -show-build` reports `minos 26.0`. macOS refuses to load
a library built for a newer system, so on Rosy (Ventura 13) the published
`time`, `hello`, `fetch` and `memo` cannot load; since 2e-1 the Plugins tab
shows that load error. The plugin repo's own `build.sh` has the same gap
(no `-mmacosx-version-min`). Publishing with this script fixes the raw
dylibs for current builds too: reinstall each plugin after the push.

## How it was checked (2026-11-06)

On a scratch copy of the plugin repo, with a stand-in `minisign` (CryptoKit,
same file formats) and a throwaway key: the script built all four plugins
(`minos 13.0`, x86_64), zipped, signed and verified them, and updated the
specs and `plugins.json`. A temporary test then ran upstream's installer
code on the output: spec decoding, x86_64 resolution on macOS 13.7.8, the
SHA-256 and size, `MinisignVerifier` (and rejection of a changed byte),
`BoundedArchiveExtractor` with the plugin policy, and
`installVerifiedArtifact` into `Tools/<id>/1.0.0/` with a receipt pinning
the key and the `current` link. The first run with the real `minisign` is
Renée's.
