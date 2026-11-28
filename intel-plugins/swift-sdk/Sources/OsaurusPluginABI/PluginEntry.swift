//
//  PluginEntry.swift
//  OsaurusPluginABI
//
//  Helpers so a plugin's `osaurus_plugin_entry` / `osaurus_plugin_entry_v2`
//  exports are each ~5 lines:
//
//      nonisolated(unsafe) var pluginAPI = PluginEntry.makeAPI(
//          version: OsrABIVersion.v2,
//          init: { ... }, destroy: { ... },
//          getManifest: { _ in osrMakeCString(manifestJSON) },
//          invoke: { ctx, type, id, payload in ... }
//      )
//
//      @_cdecl("osaurus_plugin_entry_v2")
//      public func osaurus_plugin_entry_v2(_ host: UnsafeRawPointer?) -> UnsafeRawPointer? {
//          PluginEntry.enterV2(host, api: &pluginAPI)
//      }
//
//      @_cdecl("osaurus_plugin_entry")
//      public func osaurus_plugin_entry() -> UnsafeRawPointer? {
//          PluginEntry.enterV1(api: &pluginAPI)
//      }
//

import Foundation

public enum PluginEntry {

    /// Standard `free_string` for plugin-returned strings: plain
    /// `libc free()`, pairing with the `strdup` inside `osrMakeCString`.
    /// Keep it plain — a `free_string` that does anything else corrupts
    /// the heap if a host ever misroutes a pointer into it.
    public static let defaultFreeString: OsrFreeStringFn = { ptr in
        guard let ptr else { return }
        free(UnsafeMutableRawPointer(mutating: ptr))
    }

    /// Assembles a fully-populated plugin API table. All callbacks are
    /// `@convention(c)` — they cannot capture Swift state; recover your
    /// context from the `OsrPluginCtx` pointer instead.
    public static func makeAPI(
        version: UInt32 = OsrABIVersion.v2,
        freeString: OsrFreeStringFn? = nil,
        init initFn: OsrInitFn?,
        destroy: OsrDestroyFn?,
        getManifest: OsrGetManifestFn?,
        invoke: OsrInvokeFn?,
        handleRoute: OsrHandleRouteFn? = nil,
        onConfigChanged: OsrOnConfigChangedFn? = nil,
        onTaskEvent: OsrOnTaskEventFn? = nil
    ) -> OsrPluginAPI {
        OsrPluginAPI(
            free_string: freeString ?? defaultFreeString,
            init: initFn,
            destroy: destroy,
            get_manifest: getManifest,
            invoke: invoke,
            version: version,
            handle_route: handleRoute,
            on_config_changed: onConfigChanged,
            on_task_event: onTaskEvent
        )
    }

    /// Body of `osaurus_plugin_entry_v2`: captures the injected host API
    /// into `HostBridge.shared` and returns the plugin's API table. `api`
    /// must point at stable storage (a file-scope `var`), not a local.
    @discardableResult
    public static func enterV2(
        _ host: UnsafeRawPointer?,
        api: UnsafeMutablePointer<OsrPluginAPI>
    ) -> UnsafeRawPointer? {
        HostBridge.shared.install(host?.assumingMemoryBound(to: OsrHostAPI.self))
        return UnsafeRawPointer(api)
    }

    /// Body of the legacy `osaurus_plugin_entry` (v1 — no host API).
    /// `api` must point at stable storage (a file-scope `var`).
    public static func enterV1(
        api: UnsafeMutablePointer<OsrPluginAPI>
    ) -> UnsafeRawPointer? {
        UnsafeRawPointer(api)
    }
}
