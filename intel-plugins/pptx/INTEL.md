# osaurus.pptx on Intel (Osaurus Intel fork)

Vendored from upstream `osaurus-ai/osaurus-pptx` (GitHub), commit
`399b57ee4eef0c96f500730e5b84b53bc15aab04` (2026-07-23, no release tag).
Licence: MIT. The upstream repo has no LICENSE file; its embedded manifest
declares MIT, and the SDK it depends on ships a real MIT `LICENSE` (kept in
`../swift-sdk/`).

Intel build target: x86_64, macOS 13.0 (Ventura):
`arch -x86_64 swift build -c release --arch x86_64 -Xswiftc -target -Xswiftc x86_64-apple-macosx13.0`.
The result is one dylib (`minos 13.0`) that links only `/System/Library` and
`/usr/lib/swift` system libraries. `intel-plugins/publish-signed.sh` builds,
zips and signs it (docs/INTEL_PLUGIN_PUBLISHING.md); `intel-plugins/build-all.sh`
installs it into the isolated dev Tools dir.

## Intel changes

- `Package.swift`: `platforms: [.macOS(.v15)]` -> `[.macOS(.v13)]`. It is only
  a declaration: no `#available`, `@available`, FoundationModels or other
  macOS 14/15 API appears in the sources (grep, plus the x86_64 macOS 13
  build). Without the change the dylib would get a 15.0 deployment target and
  could not load on Ventura.
- `Package.swift`: the SDK dependency (upstream `osaurus-plugin-sdk`, exact
  1.0.0, fetched from GitHub) -> `.package(path: "../swift-sdk")`, the vendored
  copy of that exact release; product references say `package: "swift-sdk"`
  (a path dependency's identity is its folder name). Reason: the Intel build
  must not fetch anything and the SDK version is pinned in this repo.
- `Sources/osaurus_pptx/Plugin.swift`: the embedded manifest says
  `"min_macos": "13.0"` instead of `"15.0"`. This is not cosmetic: the Intel
  host (`PluginManager`, the `min_macos` check) refuses a plugin whose manifest
  needs a newer macOS than the running one, so the upstream value would make
  the plugin unloadable on Ventura.
- `manifest.json` (new): the manifest string the dylib returns, saved as JSON
  for the publish script (plugin id, version) and Intel's installer. Regenerate
  it from the dylib's `get_manifest` whenever `Plugin.swift` changes (the
  publish script checks that version and `min_macos` agree with the dylib).

Nothing else changed: plugin id `osaurus.pptx`, version 1.1.0, tool ids and
schemas, all sources and tests are upstream's.

## Not vendored

`CLAUDE.md` (upstream's authoring guide), `.github/`, `.gitignore`, and the
sample deck `Q4_2025_Sales_Report.pptx` (no test uses it).

## Updating from upstream

Re-clone the upstream repo, diff against this folder, re-apply the changes
above, bump the SHA here, run `swift test` natively (the Xcode 27 test helper
is arm64 only, see docs/TEST_STORAGE_SAFETY.md) and the x86_64 build above.
