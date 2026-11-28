//
//  PluginAPI.swift
//  OsaurusPluginABI
//
//  Field-for-field Swift mirrors of `osr_plugin_api` from
//  `osaurus_plugin.h` — the table the plugin hands back to the host from
//  its entry point.
//

import Foundation

/// Full current `osr_plugin_api` mirror (v2+ surface).
///
/// Layout per the header: five required function pointers, then the
/// `uint32_t version` field, then the three optional v2 callbacks.
/// On arm64 Darwin: offsets 0/8/16/24/32, version at 40 (padded to 48),
/// then 48/56/64 — stride 72. Asserted by `PluginAPILayoutTests`.
public struct OsrPluginAPI {
    // ── Required (every plugin) ──
    public var free_string: OsrFreeStringFn?
    public var `init`: OsrInitFn?
    public var destroy: OsrDestroyFn?
    public var get_manifest: OsrGetManifestFn?
    public var invoke: OsrInvokeFn?

    // ── Optional (zero / NULL when unused) ──

    /// ABI version the plugin was compiled against.
    /// 0 (or absent) for v1 plugins, 2+ for v2+ plugins.
    public var version: UInt32

    public var handle_route: OsrHandleRouteFn?
    public var on_config_changed: OsrOnConfigChangedFn?
    public var on_task_event: OsrOnTaskEventFn?

    public init(
        free_string: OsrFreeStringFn? = nil,
        init initFn: OsrInitFn? = nil,
        destroy: OsrDestroyFn? = nil,
        get_manifest: OsrGetManifestFn? = nil,
        invoke: OsrInvokeFn? = nil,
        version: UInt32 = 0,
        handle_route: OsrHandleRouteFn? = nil,
        on_config_changed: OsrOnConfigChangedFn? = nil,
        on_task_event: OsrOnTaskEventFn? = nil
    ) {
        self.free_string = free_string
        self.`init` = initFn
        self.destroy = destroy
        self.get_manifest = get_manifest
        self.invoke = invoke
        self.version = version
        self.handle_route = handle_route
        self.on_config_changed = on_config_changed
        self.on_task_event = on_task_event
    }
}

/// The REQUIRED prefix of `osr_plugin_api` only — the five callbacks every
/// plugin (v1 included) must provide. A v1 host reads exactly this much of
/// the table. Stride 40 on arm64 Darwin (five pointers, no padding).
public struct OsrPluginAPIv1Prefix {
    public var free_string: OsrFreeStringFn?
    public var `init`: OsrInitFn?
    public var destroy: OsrDestroyFn?
    public var get_manifest: OsrGetManifestFn?
    public var invoke: OsrInvokeFn?

    public init(
        free_string: OsrFreeStringFn? = nil,
        init initFn: OsrInitFn? = nil,
        destroy: OsrDestroyFn? = nil,
        get_manifest: OsrGetManifestFn? = nil,
        invoke: OsrInvokeFn? = nil
    ) {
        self.free_string = free_string
        self.`init` = initFn
        self.destroy = destroy
        self.get_manifest = get_manifest
        self.invoke = invoke
    }
}
