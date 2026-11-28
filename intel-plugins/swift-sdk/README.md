# osaurus-plugin-sdk

Versioned shared SDK for Osaurus plugins, created out of the July 2026
reliability audit. Consolidates the ABI mirror, host bridge, and utility
code (envelopes, subprocess running, path safety, argument validation)
that was previously copy-pasted — and had drifted — across the plugin
repositories.

The single source of truth for the C ABI is
`Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h` in the Osaurus
host repository. When in doubt, the header wins. This SDK mirrors the
**v6** surface and pins the frozen layout with tests.

## Products

All three products are **static** libraries. This is deliberate and
load-bearing: a plugin release build must produce **exactly one dylib**
(the plugin itself) — the host enforces this. Never change these to
`.dynamic`.

| Product | Use from | Contents |
|---|---|---|
| `OsaurusPluginABI` | plugin target | `OsrHostAPI` (v6 mirror), `OsrPluginAPI` / `OsrPluginAPIv1Prefix`, `HostBridge`, `PluginEntry`, C typealiases, `osrMakeCString` |
| `OsaurusPluginKit` | plugin target | `Envelope` / `EnvelopeFailure`, `ProcessRunner`, `PathSafety`, `ArgValidation` |
| `OsaurusPluginTestSupport` | test target only | `ManifestConformance`, `assertCanonicalFailure`, `ABIConformance` |

## Adoption

Pin the SDK **exactly**. The ABI mirror must move in lockstep with the
host; a floating minor could silently change struct layout expectations
under a plugin binary that was reviewed against another one.

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/osaurus-ai/osaurus-plugin-sdk.git", .exact("1.0.0"))
],
targets: [
    .target(
        name: "my_plugin",
        dependencies: [
            .product(name: "OsaurusPluginABI", package: "osaurus-plugin-sdk"),
            .product(name: "OsaurusPluginKit", package: "osaurus-plugin-sdk"),
        ]
    ),
    .testTarget(
        name: "my_pluginTests",
        dependencies: [
            "my_plugin",
            .product(name: "OsaurusPluginTestSupport", package: "osaurus-plugin-sdk"),
        ]
    ),
]
```

Your plugin's own library product stays `.dynamic` — that's the one
dylib the host loads.

## Entry points

```swift
import OsaurusPluginABI

// Stable storage for the API table (the host keeps the pointer).
nonisolated(unsafe) var pluginAPI = PluginEntry.makeAPI(
    version: OsrABIVersion.v2,
    init: { Unmanaged.passRetained(PluginContext()).toOpaque() },
    destroy: { ctx in ctx.map { Unmanaged<PluginContext>.fromOpaque($0).release() } },
    getManifest: { _ in osrMakeCString(manifestJSON) },
    invoke: { ctx, type, id, payload in
        // dispatch to your tools; return osrMakeCString(envelopeJSON)
        osrMakeCString(Envelope.success())
    }
)

@_cdecl("osaurus_plugin_entry_v2")
public func osaurus_plugin_entry_v2(_ host: UnsafeRawPointer?) -> UnsafeRawPointer? {
    PluginEntry.enterV2(host, api: &pluginAPI)  // installs HostBridge.shared
}

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
    PluginEntry.enterV1(api: &pluginAPI)
}
```

After `enterV2`, host callbacks are available anywhere via the bridge —
every accessor performs the documented `host.version >= N && slot != nil`
check and no-ops safely in unit tests where no host is installed:

```swift
let bridge = HostBridge.shared
bridge.log(OsrLogLevel.info, "plugin ready")
bridge.logStructured(OsrLogLevel.info, "webhook_registered", payload: #"{"status":200}"#)  // v5+, falls back to log
let agent = bridge.activeAgentId()      // v4+, nil outside a per-agent frame
let token = bridge.configGet("token")   // returned string freed for you via hostFree
bridge.configSet("cursor", "42")
```

`HostBridge.hostFree(_:)` releases host-returned C strings through
`host->free_string` on v6+ hosts and falls back to `libc free()` on
older ones. Never pass a host-returned pointer to the plugin's own
`free_string` — that callback is for the reverse direction.

## Migrating a v1 plugin (adding entry_v2)

1. Keep your existing `osaurus_plugin_entry` export — v1 hosts and old
   Osaurus builds still call it.
2. Replace your hand-rolled `osr_plugin_api` struct/globals with
   `PluginEntry.makeAPI(...)` and set `version: OsrABIVersion.v2`.
3. Add the `osaurus_plugin_entry_v2` export shown above. The host tries
   it first and falls back to the v1 symbol.
4. Delete any local `osr_host_api` mirror and use `HostBridge` instead.
   Hand-maintained mirrors are the #1 audited crash source: skipping one
   appended slot (classically `log_structured`, v5) shifts every later
   slot and ends in `pointer being freed was not allocated`. This SDK
   pins the layout (offsets 0 / 176 / 184 / 192, stride 200) in
   `HostAPILayoutTests` so drift fails CI instead of crashing hosts.
5. Opt into `handleRoute:` / `onConfigChanged:` / `onTaskEvent:` in
   `makeAPI` if your manifest declares those capabilities.
6. In your tests, add the conformance checks:

```swift
import OsaurusPluginTestSupport

try ManifestConformance.assertConformant(manifestJSON)
try ABIConformance.assertEntryConformance(osaurus_plugin_entry_v2(nil), manifestJSON: manifestJSON)
try assertCanonicalFailure(myFailureJSON, kind: .invalidArgs)
```

## Envelopes

Canonical failure shape (use for every error):

```json
{"ok": false, "kind": "not_found", "message": "…", "retryable": false, "data": {"…": "…"}}
```

Kinds and default retryable policy: `invalid_args`, `not_found`,
`permission_denied` are non-retryable; `timeout` and `execution_error`
are retryable by default. Override per-call with `retryable:`.

```swift
Envelope.failure(.notFound, "no such mailbox")
Envelope.failure(.executionError, "osascript crashed", retryable: false)
throw EnvelopeFailure(.invalidArgs, "limit must be positive")   // render() at the invoke boundary
```

Success shapes are flexible — plugins with legacy `{ok, data}` /
`{ok, result}` shapes keep them:

```swift
Envelope.success()                              // {"ok":true}
Envelope.success(raw: itemsJSON)                // {"ok":true,"result":…}
Envelope.success(raw: itemsJSON, key: "data")   // {"ok":true,"data":…}
Envelope.success(fields: ["count": 3])          // {"ok":true,"count":3}
```

## Utilities

```swift
// Subprocess with timeout (default 30 s), concurrent stdout/stderr
// draining, 5 MB per-stream cap, SIGTERM → SIGKILL after 2 s grace.
let out = try ProcessRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", script])
if out.timedOut { return Envelope.failure(.timeout, "osascript timed out") }

// Component-aware containment (symlinks resolved on the deepest
// existing ancestor, so not-yet-created paths work too).
guard PathSafety.isContained(target, in: workingDirectory) else {
    throw EnvelopeFailure(.invalidArgs, "path outside working directory")
}
try PathSafety.atomicWrite(data: bytes, to: target)   // temp file + rename

// Strict argument parsing — every failure throws EnvelopeFailure(.invalidArgs).
let args = try ArgValidation.parseObject(payload)
let query = try ArgValidation.requireString(args, "query")
let limit = try ArgValidation.resolveLimit(args["limit"], field: "limit", defaultValue: 5, maximum: 50)
let since = try ArgValidation.isoDate(try ArgValidation.requireString(args, "since"), field: "since")
try ArgValidation.enumValue(order, field: "order", allowed: ["asc", "desc"])
```

## License

MIT — see [LICENSE](LICENSE).
