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

Per plugin (`time`, `hello`, `fetch`, `memo` by default; `PLUGINS="..."` to
choose) the script:

1. builds the dylib from `intel-plugins/<name>/` for **x86_64 with a macOS
   13.0 minimum**, checks both, and ad-hoc signs it;
2. zips it as `dist/<name>/<plugin_id>-<version>.zip`;
3. signs the zip with minisign (legacy Ed25519, which is what Osaurus
   verifies; it asks for the key's password once per plugin) and verifies
   the signature with the public key;
4. writes `plugins/<name>.json`: `public_keys.minisign` and the version's
   single x86_64 artifact (zip URL, SHA-256, size, `min_macos`, signature);
5. refreshes `dist/<name>/plugin.dylib` + `manifest.json` and their SHA-256
   and size in `plugins.json`, the raw index that Intel builds up to 1.0.62
   still install from.

Then review (`git -C <repo> diff`), commit and push the plugin repo.

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
