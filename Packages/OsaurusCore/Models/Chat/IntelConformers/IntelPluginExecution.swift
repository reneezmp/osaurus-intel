//
//  IntelPluginExecution.swift
//  OsaurusCore — Intel fork (M9 Phase C)
//
//  A SLIM, self-contained plugin execution host for the Intel fork.
//
//  Why this exists
//  ---------------
//  The production execution stack (PluginHostAPI 3,516 lines + the real
//  PluginManager + repo/resolver/db) was written against the *real*
//  AgentManager / ChatEngine / MCPServerManager / ToolRegistry / inference
//  subsystems — all of which are amputated-and-mirrored on Intel. A full
//  restore drags in ~41 amputated touchpoints, most of which (embed → MLX,
//  complete → inference, sandbox provisioning) are physically dead on Intel
//  anyway. So instead of un-excluding that whole web, this file provides a
//  minimal, honest host:
//
//    • Real callbacks (pure Foundation, no amputated deps):
//        log, log_structured, free_string, config_get/set/delete,
//        file_read, http_request
//    • Honest `not_supported` envelopes for the dead ones:
//        db_exec/query, dispatch*, complete*, embed, list_models,
//        list_active_tasks, get_active_agent_id
//    • No-op void trampolines for the fire-and-forget dead ones.
//
//  This is enough to dlopen a natively-built x86_64 plugin, complete the v2
//  ABI handshake, and invoke its tools. No official arm64 plugin can ever
//  run here (Rosetta is one-way x86→ARM), but a hand-built x86_64 plugin —
//  the whole point of Phase C — loads and runs.
//
//  ABI mirror note
//  ---------------
//  The canonical Swift mirror of `Tools/PluginABI/osaurus_plugin.h` lives in
//  `ExternalPlugin.swift`, which is compiled out on Intel (`#if !OSAURUS_INTEL`).
//  So the `osr_*` type names below are unique to the Intel build — no
//  collision. The struct layout MUST stay byte-identical to the v6 header or
//  a plugin will dispatch `host->free_string` to the wrong slot and abort.
//

#if OSAURUS_INTEL

import Foundation
import os

// MARK: - C ABI Mirror (Intel-only; mirrors osaurus_plugin.h v6)

typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

// Plugin-side functions (every v2 plugin exports these via osr_plugin_api).
typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
typealias osr_invoke_t =
    @convention(c) (
        osr_plugin_ctx_t?,  // ctx
        UnsafePointer<CChar>?,  // type
        UnsafePointer<CChar>?,  // id
        UnsafePointer<CChar>?  // payload
    ) -> UnsafePointer<CChar>?
typealias osr_handle_route_t =
    @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_on_config_changed_t =
    @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_on_task_event_t =
    @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Void

// Host-side callback types (host → plugin, injected via osr_host_api at v2 entry).
typealias osr_config_get_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_config_set_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_config_delete_t = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_db_exec_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_db_query_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_log_t = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_task_status_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_dispatch_cancel_t = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_clarify_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_complete_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_on_chunk_t = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
typealias osr_complete_stream_t =
    @convention(c) (UnsafePointer<CChar>?, osr_on_chunk_t?, UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?
typealias osr_embed_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_list_models_t = @convention(c) () -> UnsafePointer<CChar>?
typealias osr_http_request_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_file_read_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_list_active_tasks_t = @convention(c) () -> UnsafePointer<CChar>?
typealias osr_send_draft_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_interrupt_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_add_issue_t =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_complete_cancel_t = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_get_active_agent_id_t = @convention(c) () -> UnsafePointer<CChar>?
typealias osr_log_structured_t =
    @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_host_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void

/// Frozen v6 layout — field order/types MUST match `osaurus_plugin.h`.
struct osr_host_api {
    var version: UInt32

    // Config + Storage + Logging
    var config_get: osr_config_get_t?
    var config_set: osr_config_set_t?
    var config_delete: osr_config_delete_t?
    var db_exec: osr_db_exec_t?
    var db_query: osr_db_query_t?
    var log: osr_log_t?

    // Agent Dispatch
    var dispatch: osr_dispatch_t?
    var task_status: osr_task_status_t?
    var dispatch_cancel: osr_dispatch_cancel_t?
    var dispatch_clarify: osr_dispatch_clarify_t?

    // Inference
    var complete: osr_complete_t?
    var complete_stream: osr_complete_stream_t?
    var embed: osr_embed_t?
    var list_models: osr_list_models_t?

    // HTTP Client
    var http_request: osr_http_request_t?

    // File I/O
    var file_read: osr_file_read_t?

    // Extended Agent Dispatch
    var list_active_tasks: osr_list_active_tasks_t?
    var send_draft: osr_send_draft_t?
    var dispatch_interrupt: osr_dispatch_interrupt_t?
    var dispatch_add_issue: osr_dispatch_add_issue_t?

    // Streaming control
    var complete_cancel: osr_complete_cancel_t?

    // Agent context introspection (v4)
    var get_active_agent_id: osr_get_active_agent_id_t?

    // Structured logging (v5)
    var log_structured: osr_log_structured_t?

    // Host-side string free (v6)
    var free_string: osr_host_free_string_t?
}

struct osr_plugin_api {
    var free_string: osr_free_string_t?
    var `init`: osr_init_t?
    var destroy: osr_destroy_t?
    var get_manifest: osr_get_manifest_t?
    var invoke: osr_invoke_t?
    var version: UInt32
    var handle_route: osr_handle_route_t?
    var on_config_changed: osr_on_config_changed_t?
    var on_task_event: osr_on_task_event_t?
}

typealias osr_plugin_entry_t = @convention(c) () -> UnsafeRawPointer?
typealias osr_plugin_entry_v2_t = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?

// MARK: - Host callback support (global; @convention(c) cannot capture state)

private let intelPluginLog = Logger(subsystem: "com.osaurus.intel", category: "plugin-host")

/// Allocate a malloc'd copy of `s` for return across the C ABI. The plugin
/// frees it via `host->free_string` (→ `intelHostFreeString` → `free`).
private func dupCString(_ s: String) -> UnsafePointer<CChar>? {
    return s.withCString { UnsafePointer(strdup($0)) }
}

private func notSupportedEnvelope(_ name: String) -> String {
    #"{"error":"not_supported","message":"\#(name) is unavailable on the Osaurus Intel fork (amputated subsystem)."}"#
}

// --- Config: a lock-guarded, file-backed key/value store. -------------------
private let intelConfigLock = NSLock()
private nonisolated(unsafe) var intelConfigStore: [String: String] = IntelPluginConfigStore.load()

private enum IntelPluginConfigStore {
    static func fileURL() -> URL {
        OsaurusPaths.root()
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent(".intel-plugin-config.json")
    }

    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL()),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    /// Caller must hold `intelConfigLock`.
    static func persistLocked() {
        let url = fileURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(intelConfigStore) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Trampolines (global @convention(c) closures)

private let intelHostFreeString: osr_host_free_string_t = { ptr in
    if let ptr { free(UnsafeMutableRawPointer(mutating: ptr)) }
}

private let intelHostLog: osr_log_t = { level, msgPtr in
    let msg = msgPtr.map { String(cString: $0) } ?? ""
    switch level {
    case 0: intelPluginLog.debug("\(msg, privacy: .public)")
    case 1: intelPluginLog.info("\(msg, privacy: .public)")
    case 2: intelPluginLog.warning("\(msg, privacy: .public)")
    default: intelPluginLog.error("\(msg, privacy: .public)")
    }
}

private let intelHostLogStructured: osr_log_structured_t = { level, msgPtr, fieldsPtr in
    let msg = msgPtr.map { String(cString: $0) } ?? ""
    let fields = fieldsPtr.map { String(cString: $0) } ?? "{}"
    intelPluginLog.log(level: level >= 3 ? .error : .info, "\(msg, privacy: .public) \(fields, privacy: .public)")
}

private let intelHostConfigGet: osr_config_get_t = { keyPtr in
    guard let keyPtr else { return nil }
    let key = String(cString: keyPtr)
    intelConfigLock.lock(); defer { intelConfigLock.unlock() }
    guard let value = intelConfigStore[key] else { return nil }
    return dupCString(value)
}

private let intelHostConfigSet: osr_config_set_t = { keyPtr, valuePtr in
    guard let keyPtr else { return }
    let key = String(cString: keyPtr)
    let value = valuePtr.map { String(cString: $0) } ?? ""
    intelConfigLock.lock(); defer { intelConfigLock.unlock() }
    intelConfigStore[key] = value
    IntelPluginConfigStore.persistLocked()
}

private let intelHostConfigDelete: osr_config_delete_t = { keyPtr in
    guard let keyPtr else { return }
    let key = String(cString: keyPtr)
    intelConfigLock.lock(); defer { intelConfigLock.unlock() }
    intelConfigStore[key] = nil
    IntelPluginConfigStore.persistLocked()
}

private let intelHostFileRead: osr_file_read_t = { pathPtr in
    guard let pathPtr else { return dupCString(#"{"error":"invalid_request","message":"null path"}"#) }
    let path = String(cString: pathPtr)
    guard let data = FileManager.default.contents(atPath: path) else {
        return dupCString(#"{"error":"not_found","message":"file unreadable"}"#)
    }
    // Return base64 to stay binary-safe across the C string boundary.
    let payload: [String: Any] = ["base64": data.base64EncodedString(), "size": data.count]
    let json = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) }
    return dupCString(json ?? #"{"error":"encode_failed"}"#)
}

/// Synchronous HTTP for plugins. Matches the production request contract
/// (`{method,url,headers,body,body_encoding,timeout_ms}`) and returns
/// `{status,body,headers,elapsed_ms}`. No SSRF/rate-limit gates — this is
/// Renée's own device running her own hand-built plugins (sovereignty).
private let intelHostHttpRequest: osr_http_request_t = { reqPtr in
    guard let reqPtr else { return dupCString(#"{"error":"invalid_request"}"#) }
    let reqJSON = String(cString: reqPtr)
    guard let data = reqJSON.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = json["method"] as? String,
          let urlStr = json["url"] as? String,
          let url = URL(string: urlStr)
    else {
        return dupCString(#"{"error":"invalid_request","message":"Missing required fields: method, url"}"#)
    }

    var request = URLRequest(url: url)
    request.httpMethod = method.uppercased()
    let timeoutMs = json["timeout_ms"] as? Int ?? 30000
    request.timeoutInterval = TimeInterval(min(timeoutMs, 300000)) / 1000.0
    if let headers = json["headers"] as? [String: String] {
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    }
    if let body = json["body"] as? String {
        if (json["body_encoding"] as? String) == "base64" {
            request.httpBody = Data(base64Encoded: body)
        } else {
            request.httpBody = Data(body.utf8)
        }
    }

    let semaphore = DispatchSemaphore(value: 0)
    var resultJSON = #"{"error":"unknown"}"#
    let started = Date()
    let task = URLSession.shared.dataTask(with: request) { respData, response, error in
        defer { semaphore.signal() }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        if let error {
            resultJSON = jsonStringSafe(["error": "request_failed", "message": error.localizedDescription, "elapsed_ms": elapsed])
            return
        }
        guard let http = response as? HTTPURLResponse else {
            resultJSON = jsonStringSafe(["error": "invalid_response", "message": "Non-HTTP response", "elapsed_ms": elapsed])
            return
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, let vs = v as? String { headers[ks] = vs }
        }
        let bodyStr = respData.flatMap { String(data: $0, encoding: .utf8) }
            ?? respData?.base64EncodedString() ?? ""
        resultJSON = jsonStringSafe([
            "status": http.statusCode,
            "body": bodyStr,
            "headers": headers,
            "elapsed_ms": elapsed,
        ])
    }
    task.resume()
    semaphore.wait()
    return dupCString(resultJSON)
}

/// JSON-encode a `[String: Any]`; never throws (best-effort for trampolines).
private func jsonStringSafe(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let s = String(data: data, encoding: .utf8)
    else { return #"{"error":"encode_failed"}"# }
    return s
}

// --- Amputated subsystems: honest `not_supported`, never null. --------------
private let intelHostDbExec: osr_db_exec_t = { _, _ in dupCString(notSupportedEnvelope("db_exec")) }
private let intelHostDbQuery: osr_db_query_t = { _, _ in dupCString(notSupportedEnvelope("db_query")) }
private let intelHostDispatch: osr_dispatch_t = { _ in dupCString(notSupportedEnvelope("dispatch")) }
private let intelHostTaskStatus: osr_task_status_t = { _ in dupCString(notSupportedEnvelope("task_status")) }
private let intelHostComplete: osr_complete_t = { _ in dupCString(notSupportedEnvelope("complete")) }
private let intelHostCompleteStream: osr_complete_stream_t = { _, _, _ in dupCString(notSupportedEnvelope("complete_stream")) }
private let intelHostEmbed: osr_embed_t = { _ in dupCString(notSupportedEnvelope("embed")) }
private let intelHostListModels: osr_list_models_t = { dupCString(#"{"models":[]}"#) }
private let intelHostListActiveTasks: osr_list_active_tasks_t = { dupCString(#"{"tasks":[]}"#) }
private let intelHostDispatchAddIssue: osr_dispatch_add_issue_t = { _, _ in dupCString(notSupportedEnvelope("dispatch_add_issue")) }
private let intelHostGetActiveAgentId: osr_get_active_agent_id_t = { nil }

// --- Void trampolines: safe no-ops. ----------------------------------------
private let intelHostDispatchCancel: osr_dispatch_cancel_t = { _ in }
private let intelHostDispatchClarify: osr_dispatch_clarify_t = { _, _ in }
private let intelHostSendDraft: osr_send_draft_t = { _, _ in }
private let intelHostDispatchInterrupt: osr_dispatch_interrupt_t = { _, _ in }
private let intelHostCompleteCancel: osr_complete_cancel_t = { _ in }

/// Build the slim host-API struct passed to a plugin's v2 entry point.
/// The returned pointer must outlive the plugin (it holds the callback
/// table the plugin keeps calling), so the loader owns it and frees it
/// only in `teardown()`.
private func buildIntelHostAPI() -> UnsafeMutablePointer<osr_host_api> {
    let ptr = UnsafeMutablePointer<osr_host_api>.allocate(capacity: 1)
    ptr.initialize(to: osr_host_api(
        version: 6,
        config_get: intelHostConfigGet,
        config_set: intelHostConfigSet,
        config_delete: intelHostConfigDelete,
        db_exec: intelHostDbExec,
        db_query: intelHostDbQuery,
        log: intelHostLog,
        dispatch: intelHostDispatch,
        task_status: intelHostTaskStatus,
        dispatch_cancel: intelHostDispatchCancel,
        dispatch_clarify: intelHostDispatchClarify,
        complete: intelHostComplete,
        complete_stream: intelHostCompleteStream,
        embed: intelHostEmbed,
        list_models: intelHostListModels,
        http_request: intelHostHttpRequest,
        file_read: intelHostFileRead,
        list_active_tasks: intelHostListActiveTasks,
        send_draft: intelHostSendDraft,
        dispatch_interrupt: intelHostDispatchInterrupt,
        dispatch_add_issue: intelHostDispatchAddIssue,
        complete_cancel: intelHostCompleteCancel,
        get_active_agent_id: intelHostGetActiveAgentId,
        log_structured: intelHostLogStructured,
        free_string: intelHostFreeString
    ))
    return ptr
}

// MARK: - Loaded native plugin handle

/// A live, dlopen'd x86_64 plugin. Owns the dylib handle, the plugin's
/// init'd context, and the host-API table. Invocation is serialized on a
/// dedicated queue (the C plugin is not assumed thread-safe).
/// A tool a plugin exposes, parsed from its manifest `capabilities.tools[]`.
/// `parameters` is the OpenAI/JSON-Schema object the model reads to call the
/// tool with the right argument shape.
struct IntelPluginToolSpec: Sendable {
    let id: String
    let description: String
    let parameters: JSONValue?
}

final class IntelLoadedPlugin: @unchecked Sendable {
    let pluginId: String
    let toolSpecs: [IntelPluginToolSpec]
    let manifestJSON: String

    /// Tool ids (the names registered into ToolRegistry / logged in self-test).
    var toolIds: [String] { toolSpecs.map(\.id) }

    private let handle: UnsafeMutableRawPointer
    private let api: osr_plugin_api
    private let ctx: osr_plugin_ctx_t
    private let hostAPIPtr: UnsafeMutablePointer<osr_host_api>
    private let queue: DispatchQueue
    private var isShutDown = false

    init(
        pluginId: String,
        toolSpecs: [IntelPluginToolSpec],
        manifestJSON: String,
        handle: UnsafeMutableRawPointer,
        api: osr_plugin_api,
        ctx: osr_plugin_ctx_t,
        hostAPIPtr: UnsafeMutablePointer<osr_host_api>
    ) {
        self.pluginId = pluginId
        self.toolSpecs = toolSpecs
        self.manifestJSON = manifestJSON
        self.handle = handle
        self.api = api
        self.ctx = ctx
        self.hostAPIPtr = hostAPIPtr
        self.queue = DispatchQueue(label: "com.osaurus.intel.plugin.\(pluginId)")
    }

    /// Invoke a plugin tool. `type` is the invocation kind ("tool"), `id` is
    /// the tool id, `payload` is the tool's JSON arguments. Returns the
    /// plugin's JSON result string.
    func invoke(type: String, id: String, payload: String) throws -> String {
        try queue.sync {
            guard !isShutDown else {
                throw NSError(domain: "IntelLoadedPlugin", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Plugin has been shut down"])
            }
            guard let invokeFn = api.invoke else {
                throw NSError(domain: "IntelLoadedPlugin", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Plugin does not implement invoke"])
            }
            let resPtr: UnsafePointer<CChar>? = type.withCString { t in
                id.withCString { i in
                    payload.withCString { p in
                        invokeFn(ctx, t, i, p)
                    }
                }
            }
            guard let resPtr else {
                throw NSError(domain: "IntelLoadedPlugin", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Plugin returned NULL response"])
            }
            let result = String(cString: resPtr)
            api.free_string?(resPtr)
            return result
        }
    }

    func teardown() {
        queue.sync {
            guard !isShutDown else { return }
            isShutDown = true
            api.destroy?(ctx)
            hostAPIPtr.deinitialize(count: 1)
            hostAPIPtr.deallocate()
            dlclose(handle)
        }
    }
}

// MARK: - Loader

/// Human-readable plugin load failure (Result's Failure must be an Error).
struct IntelPluginLoadError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum IntelPluginLoader {
    /// dlopen + v2 ABI handshake. Returns a live handle or a human-readable
    /// failure message. Only the v2 entry point is supported (v1 plugins
    /// cannot call host callbacks, so they're not useful on Intel).
    static func load(dylibURL: URL, pluginId: String) -> Result<IntelLoadedPlugin, IntelPluginLoadError> {
        let flags = RTLD_NOW | RTLD_LOCAL
        guard let handle = dlopen(dylibURL.path, Int32(flags)) else {
            let err = dlerror().map { String(cString: $0) } ?? "unknown error"
            return .failure(IntelPluginLoadError(message: "dlopen failed: \(err)"))
        }

        guard let v2sym = dlsym(handle, "osaurus_plugin_entry_v2") else {
            dlclose(handle)
            return .failure(IntelPluginLoadError(message: "missing entry point (expected osaurus_plugin_entry_v2)"))
        }

        let hostAPIPtr = buildIntelHostAPI()
        let entryFn = unsafeBitCast(v2sym, to: osr_plugin_entry_v2_t.self)
        guard let apiRaw = entryFn(UnsafeRawPointer(hostAPIPtr)) else {
            hostAPIPtr.deinitialize(count: 1); hostAPIPtr.deallocate()
            dlclose(handle)
            return .failure(IntelPluginLoadError(message: "plugin v2 entry returned null API"))
        }

        let api = apiRaw.assumingMemoryBound(to: osr_plugin_api.self).pointee

        guard let initFn = api.`init`, let ctx = initFn() else {
            hostAPIPtr.deinitialize(count: 1); hostAPIPtr.deallocate()
            dlclose(handle)
            return .failure(IntelPluginLoadError(message: "plugin init failed"))
        }

        guard let getManifest = api.get_manifest, let jsonPtr = getManifest(ctx) else {
            api.destroy?(ctx)
            hostAPIPtr.deinitialize(count: 1); hostAPIPtr.deallocate()
            dlclose(handle)
            return .failure(IntelPluginLoadError(message: "plugin returned no manifest"))
        }
        let manifestJSON = String(cString: jsonPtr)
        api.free_string?(jsonPtr)

        let toolSpecs = Self.parseToolSpecs(fromManifestJSON: manifestJSON)

        let loaded = IntelLoadedPlugin(
            pluginId: pluginId,
            toolSpecs: toolSpecs,
            manifestJSON: manifestJSON,
            handle: handle,
            api: api,
            ctx: ctx,
            hostAPIPtr: hostAPIPtr
        )
        return .success(loaded)
    }

    /// Locate the dylib inside a plugin directory. Prefers `plugin.dylib`,
    /// then any `*.dylib` (top level, then one level down for the official
    /// `<id>/<version>/plugin.dylib` layout).
    static func findDylib(in pluginDir: URL) -> URL? {
        let fm = FileManager.default
        let direct = pluginDir.appendingPathComponent("plugin.dylib")
        if fm.fileExists(atPath: direct.path) { return direct }

        guard let entries = try? fm.contentsOfDirectory(
            at: pluginDir, includingPropertiesForKeys: [.isDirectoryKey])
        else { return nil }

        if let topDylib = entries.first(where: { $0.pathExtension == "dylib" }) {
            return topDylib
        }
        // One level down (version subdir).
        for sub in entries {
            let isDir = (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let nested = sub.appendingPathComponent("plugin.dylib")
            if fm.fileExists(atPath: nested.path) { return nested }
            if let nestedEntries = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil),
               let anyDylib = nestedEntries.first(where: { $0.pathExtension == "dylib" }) {
                return anyDylib
            }
        }
        return nil
    }

    /// Decodable shapes for pulling tool specs out of the manifest JSON.
    private struct ManifestTools: Decodable {
        struct Caps: Decodable { let tools: [ToolDef]? }
        struct ToolDef: Decodable {
            let id: String
            let description: String?
            let parameters: JSONValue?
        }
        let capabilities: Caps?
    }

    private static func parseToolSpecs(fromManifestJSON json: String) -> [IntelPluginToolSpec] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ManifestTools.self, from: data),
              let tools = decoded.capabilities?.tools
        else { return [] }
        return tools.map {
            IntelPluginToolSpec(
                id: $0.id,
                description: $0.description ?? $0.id,
                parameters: $0.parameters
            )
        }
    }
}

// MARK: - Agent tool bridge

/// Bridges a native plugin tool into the agent tool-loop. Registered into the
/// Intel `ToolRegistry`, so `openAISpecs()` advertises it to the model and
/// `execute()` routes a tool call straight to the plugin's `invoke`. The
/// invoke is a blocking C call, so it runs off the main actor (on the plugin's
/// own serial queue inside `IntelLoadedPlugin.invoke`) to keep the UI live.
struct IntelPluginTool: OsaurusTool {
    let pluginId: String
    let toolId: String
    let name: String
    let description: String
    let parameters: JSONValue?

    init(pluginId: String, spec: IntelPluginToolSpec) {
        self.pluginId = pluginId
        self.toolId = spec.id
        self.name = spec.id
        self.description = spec.description
        self.parameters = spec.parameters
    }

    func execute(argumentsJSON: String) async throws -> String {
        let pid = pluginId
        let tid = toolId
        let toolName = name
        guard let handle = await PluginManager.shared.nativeHandle(for: pid) else {
            return ToolEnvelope.failure(
                kind: .toolNotFound,
                message: "Plugin '\(pid)' is not loaded.",
                tool: toolName
            )
        }
        let payload = argumentsJSON.isEmpty ? "{}" : argumentsJSON
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try handle.invoke(type: "tool", id: tid, payload: payload))
                } catch {
                    cont.resume(returning: ToolEnvelope.failure(
                        kind: .executionError,
                        message: "Plugin '\(pid)' tool '\(tid)' failed: \(error.localizedDescription)",
                        tool: toolName
                    ))
                }
            }
        }
    }
}

#endif
