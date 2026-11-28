# Osaurus plugin SDK, vendored for the Intel plugins

Vendored from upstream `osaurus-ai/osaurus-plugin-sdk` (GitHub), tag `1.0.0` =
commit `f5fac88621aa174531c0aac3c1d1dbbbd8142522` (2026-07-17). Licence: MIT
(`LICENSE`, kept as shipped). Used by `intel-plugins/xlsx` and
`intel-plugins/pptx` through `.package(path: "../swift-sdk")`.

## Intel changes

None. Sources, tests, `Package.swift` and `LICENSE` are upstream's. The package
already declares `.macOS(.v13)`, and its three products are explicitly static,
so a plugin that links them still produces exactly one dylib.

## ABI check (2026-11-28)

`Sources/OsaurusPluginABI` mirrors `osaurus_plugin.h` at ABI version 6. The
Intel host header (`Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h`) is
the same version 6 with the same `osr_plugin_api` layout, the same
`osaurus_plugin_entry_v2(host)` and legacy `osaurus_plugin_entry()` symbols, and
the same `free_string` contract (plain `free`, paired with `strdup`). Intel's
loader (`PluginManager.loadPlugin`) looks up `osaurus_plugin_entry_v2` first,
then `osaurus_plugin_entry`; both are exported by the plugins. The struct
layout is LP64 on arm64 and x86_64 alike, so the SDK's layout tests hold on
Intel.

## Tests

`swift test` runs natively on the build Mac (arm64): 24 XCTest cases; none
touch `~/.osaurus`, the keychain or the network (`PathSafetyTests` only reads
`NSHomeDirectory()` to canonicalize a path). The Xcode 27 test helper is arm64
only, so an x86_64 test bundle cannot run (docs/TEST_STORAGE_SAFETY.md).
