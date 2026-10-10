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
//  AgentManager / ChatEngine / ToolRegistry / inference
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
import OsaurusSQLCipher  // sqlite3_* C API (same module the Intel DBs use)

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

// --- Per-plugin scoping: which plugin is currently calling a host callback? --
// Host trampolines are global (no plugin arg), so the active plugin id is
// stashed in thread-local storage around each `invoke` (callbacks run
// synchronously on that same thread). Used to scope config + the SQLite store.
let intelPluginThreadKey = "osr.intel.currentPluginId"
func intelCurrentPluginId() -> String {
    (Thread.current.threadDictionary[intelPluginThreadKey] as? String) ?? "_shared"
}

/// The agent of the chat that called the plugin, stashed the same way
/// (upstream `PluginHostAPI.activeAgentId()`). Nil outside a chat tool call
/// (config callbacks, catalog probes).
let intelPluginAgentThreadKey = "osr.intel.currentAgentId"
func intelCurrentPluginAgentId() -> UUID? {
    Thread.current.threadDictionary[intelPluginAgentThreadKey] as? UUID
}

// --- Per-plugin SQLite (db_exec / db_query). Plaintext file per plugin. ------
private let intelDbLock = NSLock()
private nonisolated(unsafe) var intelDbHandles: [String: OpaquePointer] = [:]
private let intelSqliteTransient = unsafeBitCast(
    OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

/// Open (once) and return the per-plugin DB handle at
/// `~/.osaurus-intel/Tools/<pluginId>/plugin.db`. Caller must NOT hold
/// `intelDbLock` (this takes it).
private func intelOpenPluginDB(_ pluginId: String) -> OpaquePointer? {
    intelDbLock.lock(); defer { intelDbLock.unlock() }
    if let h = intelDbHandles[pluginId] { return h }
    let dir = OsaurusPaths.root()
        .appendingPathComponent("Tools", isDirectory: true)
        .appendingPathComponent(pluginId, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("plugin.db").path
    var db: OpaquePointer?
    if sqlite3_open(path, &db) == SQLITE_OK, let db {
        intelDbHandles[pluginId] = db
        return db
    }
    if let db { sqlite3_close(db) }
    return nil
}

private func intelBindValue(_ stmt: OpaquePointer, _ idx: Int32, _ v: Any) {
    switch v {
    case is NSNull:
        sqlite3_bind_null(stmt, idx)
    case let s as String:
        sqlite3_bind_text(stmt, idx, s, -1, intelSqliteTransient)
    case let num as NSNumber:
        if CFNumberIsFloatType(num) { sqlite3_bind_double(stmt, idx, num.doubleValue) }
        else { sqlite3_bind_int64(stmt, idx, num.int64Value) }
    default:
        sqlite3_bind_text(stmt, idx, "\(v)", -1, intelSqliteTransient)
    }
}

/// Bind `params_json` (a JSON array for positional `?`, or an object for named
/// `:name` / `@name` / `$name` placeholders) onto a prepared statement.
private func intelBindParams(_ stmt: OpaquePointer, _ paramsJSON: String?) {
    guard let paramsJSON, !paramsJSON.isEmpty,
          let data = paramsJSON.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) else { return }
    if let arr = obj as? [Any] {
        for (i, v) in arr.enumerated() { intelBindValue(stmt, Int32(i + 1), v) }
    } else if let dict = obj as? [String: Any] {
        for (k, v) in dict {
            for name in [":\(k)", "@\(k)", "$\(k)"] {
                let idx = sqlite3_bind_parameter_index(stmt, name)
                if idx > 0 { intelBindValue(stmt, idx, v); break }
            }
        }
    }
}

private func intelDbExec(pluginId: String, sql: String, paramsJSON: String?) -> String {
    guard let db = intelOpenPluginDB(pluginId) else {
        return jsonStringSafe(["error": "db_open_failed", "message": "could not open plugin database"])
    }
    intelDbLock.lock(); defer { intelDbLock.unlock() }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
        return jsonStringSafe(["error": "sql_error", "message": String(cString: sqlite3_errmsg(db))])
    }
    defer { sqlite3_finalize(stmt) }
    intelBindParams(stmt, paramsJSON)
    let rc = sqlite3_step(stmt)
    guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
        return jsonStringSafe(["error": "sql_error", "message": String(cString: sqlite3_errmsg(db))])
    }
    return jsonStringSafe([
        "ok": true,
        "rows_affected": Int(sqlite3_changes(db)),
        "last_insert_rowid": Int(sqlite3_last_insert_rowid(db)),
    ])
}

private func intelDbQuery(pluginId: String, sql: String, paramsJSON: String?) -> String {
    guard let db = intelOpenPluginDB(pluginId) else {
        return jsonStringSafe(["error": "db_open_failed", "message": "could not open plugin database"])
    }
    intelDbLock.lock(); defer { intelDbLock.unlock() }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
        return jsonStringSafe(["error": "sql_error", "message": String(cString: sqlite3_errmsg(db))])
    }
    defer { sqlite3_finalize(stmt) }
    intelBindParams(stmt, paramsJSON)
    let colCount = sqlite3_column_count(stmt)
    var rows: [[String: Any]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        var row: [String: Any] = [:]
        for c in 0..<colCount {
            let name = sqlite3_column_name(stmt, c).map { String(cString: $0) } ?? "col\(c)"
            switch sqlite3_column_type(stmt, c) {
            case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, c))
            case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, c)
            case SQLITE_NULL: row[name] = NSNull()
            default: row[name] = sqlite3_column_text(stmt, c).map { String(cString: $0) } ?? ""
            }
        }
        rows.append(row)
        if rows.count >= 1000 { break }  // safety cap
    }
    return jsonStringSafe(["ok": true, "rows": rows])
}

// --- Config: the plugin's per-agent Keychain namespace (upstream). ----------
// Config values are credentials (manifest `secrets`), so they live in
// `ToolSecretsKeychain` like upstream's `PluginHostAPI`, scoped per agent:
// plugin calls read the calling chat's agent with the Default agent as the
// global fallback (`resolvedSecret`, upstream #2061); the Plugins tab writes
// the Default agent's namespace. Until 2026-10-10 Intel kept them in a
// plaintext, agent-less JSON file (`Tools/.intel-plugin-config.json`) that
// upstream's secrets sheet and the plugin cards never read;
// `IntelPluginConfigMigration` moves that file into the Keychain once.

/// Upstream `PluginHostAPI.configValueMaxBytes`: the Keychain is for
/// credentials and small state, not blobs (plugins use `db_exec`).
let intelPluginConfigValueMaxBytes = 1 * 1024 * 1024  // 1 MiB

private let intelConfigWarnLock = NSLock()
private nonisolated(unsafe) var intelConfigWarned: Set<String> = []

/// Warn once per plugin + operation (upstream `warnNoAgentContextOnce` /
/// `warnConfigValueTooLargeOnce`), so a misbehaving plugin can't flood the log.
private func intelWarnConfigOnce(pluginId: String, op: String, _ message: String) {
    intelConfigWarnLock.lock()
    let first = intelConfigWarned.insert("\(pluginId)|\(op)").inserted
    intelConfigWarnLock.unlock()
    if first { intelPluginLog.warning("plugin \(pluginId, privacy: .public): \(message, privacy: .public)") }
}

enum IntelPluginConfigMigration {
    static let separator = "\u{1}"

    static func legacyFileURL() -> URL {
        OsaurusPaths.root()
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent(".intel-plugin-config.json")
    }

    /// Move every `pluginId<U+0001>key` value from the legacy plaintext file
    /// into the Default agent's Keychain namespace (where the Plugins tab
    /// writes). The file is deleted only after every value reads back from
    /// the Keychain, so an interrupted or refused write never loses one;
    /// it stays for the next launch otherwise. Returns how many moved.
    @discardableResult
    static func runIfNeeded() -> Int {
        let url = legacyFileURL()
        guard let data = try? Data(contentsOf: url) else { return 0 }
        guard let stored = try? JSONDecoder().decode([String: String].self, from: data) else {
            intelPluginLog.error("plugin config file unreadable; left in place")
            return 0
        }
        var moved = 0
        var allMoved = true
        for (scopedKey, value) in stored {
            let parts = scopedKey.components(separatedBy: separator)
            // `_shared` held values set outside any plugin call: no owner.
            guard parts.count == 2, !parts[0].isEmpty, parts[0] != "_shared", !parts[1].isEmpty else { continue }
            let (pluginId, key) = (parts[0], parts[1])
            if ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: Agent.defaultId) == value {
                moved += 1
                continue
            }
            ToolSecretsKeychain.saveSecret(value, id: key, for: pluginId, agentId: Agent.defaultId)
            if ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: Agent.defaultId) == value {
                moved += 1
            } else {
                allMoved = false
            }
        }
        if allMoved {
            try? FileManager.default.removeItem(at: url)
        } else {
            intelPluginLog.error("plugin config: some values could not be stored in the Keychain; file kept")
        }
        return moved
    }
}

// --- Blocking bridge: run async / MainActor work from a sync C trampoline. ---
// Safe because plugin callbacks run on a background thread (IntelPluginTool
// invokes off the main actor), so the main actor stays free to finish the work.
private final class IntelBox<T>: @unchecked Sendable { var value: T? }
private func intelBlockingAsync<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = IntelBox<T>()
    Task.detached { box.value = await body(); sem.signal() }
    sem.wait()
    return box.value!
}

// --- dispatch / task_status → the Intel BackgroundTaskManager. ----------------
private func intelDispatch(pluginId: String, requestJSON: String) -> String {
    guard let data = requestJSON.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let prompt = json["prompt"] as? String, !prompt.isEmpty
    else {
        return jsonStringSafe(["error": "invalid_request", "message": "Missing required field 'prompt'"])
    }
    let title = json["title"] as? String
    let folderPath = json["folder_path"] as? String
    let sessionId = json["session_id"] as? String
    // Agent scope is host-enforced (upstream `PluginHostAPI.planDispatch`):
    // the plugin runs work as the agent of the chat that called it, never a
    // caller-supplied id, and never the built-in Default agent, which is
    // reachable only from the in-app chat.
    let activeAgent = intelCurrentPluginAgentId()
    if let rejection = Agent.rejectBuiltInForExternalSurface(activeAgent, source: "plugin/planDispatch") {
        return jsonStringSafe(["error": rejection.code, "message": rejection.message])
    }
    guard let resolvedAgent = activeAgent else {
        return jsonStringSafe([
            "error": "missing_agent_context",
            "message": "Plugin dispatch requires an active chat agent context.",
        ])
    }
    return intelBlockingAsync {
        let request = DispatchRequest(
            prompt: prompt,
            agentId: resolvedAgent,
            title: title,
            folderPath: folderPath,
            showToast: true,
            sourcePluginId: pluginId,
            source: .plugin,
            externalSessionKey: sessionId
        )
        guard let handle = await TaskDispatcher.shared.dispatch(request) else {
            return jsonStringSafe(["error": "dispatch_rejected",
                                   "message": "Dispatch rejected (task limit reached or unavailable)"])
        }
        // Release the events held during the dispatch (BackgroundTaskManager
        // buffers them from registerTask because sourcePluginId != nil). Without
        // this they'd accumulate forever — on Intel nothing consumes them, so
        // this just clears the buffer.
        await MainActor.run { BackgroundTaskManager.shared.releaseEventsForDispatch(taskId: handle.id) }
        return jsonStringSafe(["id": handle.id.uuidString, "status": "running"])
    }
}

private func intelStatusString(_ status: BackgroundTaskStatus) -> String {
    switch status {
    case .running: return "running"
    case .awaitingClarification: return "awaiting_clarification"
    case .completed(let success, _): return success ? "completed" : "failed"
    case .cancelled: return "cancelled"
    }
}

private func intelTaskStatus(pluginId: String, taskIdString: String) -> String {
    guard let uuid = UUID(uuidString: taskIdString) else {
        return jsonStringSafe(["error": "invalid_task_id", "message": "Invalid UUID format"])
    }
    return intelBlockingAsync {
        await MainActor.run { () -> String in
            guard let state = BackgroundTaskManager.shared.taskState(for: uuid),
                  state.sourcePluginId == pluginId
            else {
                return jsonStringSafe(["error": "not_found", "message": "Task not found"])
            }
            var dict: [String: Any] = [
                "id": uuid.uuidString,
                "status": intelStatusString(state.status),
                "title": state.taskTitle,
            ]
            if let step = state.currentStep { dict["step"] = step }
            if case .completed(_, let summary) = state.status { dict["summary"] = summary }
            return jsonStringSafe(dict)
        }
    }
}

// --- complete → the Intel cloud chat engine (DeepSeek / remote). -------------
private func intelComplete(requestJSON: String) -> String {
    guard let data = requestJSON.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawMessages = json["messages"] as? [[String: Any]], !rawMessages.isEmpty
    else {
        return jsonStringSafe(["error": "invalid_request", "message": "Missing required field 'messages'"])
    }
    let messages: [ChatMessage] = rawMessages.map { m in
        ChatMessage(role: (m["role"] as? String) ?? "user", content: m["content"] as? String)
    }
    let model = json["model"] as? String
    let temperature = json["temperature"] as? Double
    let maxTokens = json["max_tokens"] as? Int
    return intelBlockingAsync {
        let engine = ChatEngine(model: model ?? "deepseek-v4-pro")
        let req = ChatCompletionRequest(
            model: model ?? "deepseek-v4-pro", messages: messages, temperature: temperature, max_tokens: maxTokens)
        do {
            let resp = try await engine.completeChat(request: req)
            let content = resp.choices.first?.message?.content ?? ""
            return jsonStringSafe(["ok": true, "content": content])
        } catch {
            return jsonStringSafe(["error": "completion_failed", "message": "\(error)"])
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

// Explicit-plugin config access (the settings UI / PluginManager — not the
// thread-local trampoline path): the Plugins tab's global defaults, i.e. the
// Default agent's namespace, the same place upstream's secrets sheet writes.
func intelPluginConfigGet(pluginId: String, key: String) -> String? {
    ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: Agent.defaultId)
}

func intelPluginConfigSet(pluginId: String, key: String, value: String) {
    if value.isEmpty {
        ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: Agent.defaultId)
    } else {
        ToolSecretsKeychain.saveSecret(value, id: key, for: pluginId, agentId: Agent.defaultId)
    }
}

// Upstream `PluginHostAPI.configGet/configSet/configDelete`. Anonymous calls
// (no chat-bound agent, e.g. inside `on_config_changed`) must not fall back
// to the Default agent's namespace: reads return nil, writes are dropped,
// each with a one-time warning.
func intelHostConfigGetValue(pluginId: String, agentId: UUID?, key: String) -> String? {
    guard let agentId else {
        intelWarnConfigOnce(pluginId: pluginId, op: "config_get", "config_get without an agent context")
        return nil
    }
    return ToolSecretsKeychain.resolvedSecret(id: key, for: pluginId, agentId: agentId)
}

func intelHostConfigSetValue(pluginId: String, agentId: UUID?, key: String, value: String) {
    if value.utf8.count > intelPluginConfigValueMaxBytes {
        intelWarnConfigOnce(pluginId: pluginId, op: "config_set_size", "config_set value for '\(key)' over 1 MiB ignored")
        return
    }
    guard let agentId else {
        intelWarnConfigOnce(pluginId: pluginId, op: "config_set", "config_set without an agent context")
        return
    }
    ToolSecretsKeychain.saveSecret(value, id: key, for: pluginId, agentId: agentId)
}

func intelHostConfigDeleteValue(pluginId: String, agentId: UUID?, key: String) {
    guard let agentId else {
        intelWarnConfigOnce(pluginId: pluginId, op: "config_delete", "config_delete without an agent context")
        return
    }
    ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: agentId)
}

private let intelHostConfigGet: osr_config_get_t = { keyPtr in
    guard let keyPtr else { return nil }
    guard let value = intelHostConfigGetValue(
        pluginId: intelCurrentPluginId(), agentId: intelCurrentPluginAgentId(), key: String(cString: keyPtr))
    else { return nil }
    return dupCString(value)
}

private let intelHostConfigSet: osr_config_set_t = { keyPtr, valuePtr in
    guard let keyPtr else { return }
    intelHostConfigSetValue(
        pluginId: intelCurrentPluginId(), agentId: intelCurrentPluginAgentId(),
        key: String(cString: keyPtr), value: valuePtr.map { String(cString: $0) } ?? "")
}

private let intelHostConfigDelete: osr_config_delete_t = { keyPtr in
    guard let keyPtr else { return }
    intelHostConfigDeleteValue(
        pluginId: intelCurrentPluginId(), agentId: intelCurrentPluginAgentId(), key: String(cString: keyPtr))
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
    let resultBox = IntelBox<String>()
    let started = Date()
    let task = URLSession.shared.dataTask(with: request) { respData, response, error in
        defer { semaphore.signal() }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        if let error {
            resultBox.value = jsonStringSafe(["error": "request_failed", "message": error.localizedDescription, "elapsed_ms": elapsed])
            return
        }
        guard let http = response as? HTTPURLResponse else {
            resultBox.value = jsonStringSafe(["error": "invalid_response", "message": "Non-HTTP response", "elapsed_ms": elapsed])
            return
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, let vs = v as? String { headers[ks] = vs }
        }
        let bodyStr = respData.flatMap { String(data: $0, encoding: .utf8) }
            ?? respData?.base64EncodedString() ?? ""
        resultBox.value = jsonStringSafe([
            "status": http.statusCode,
            "body": bodyStr,
            "headers": headers,
            "elapsed_ms": elapsed,
        ])
    }
    task.resume()
    semaphore.wait()
    return dupCString(resultBox.value ?? #"{"error":"unknown"}"#)
}

/// JSON-encode a `[String: Any]`; never throws (best-effort for trampolines).
private func jsonStringSafe(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let s = String(data: data, encoding: .utf8)
    else { return #"{"error":"encode_failed"}"# }
    return s
}

// --- Amputated subsystems: honest `not_supported`, never null. --------------
private let intelHostDbExec: osr_db_exec_t = { sqlPtr, paramsPtr in
    let pid = intelCurrentPluginId()
    let sql = sqlPtr.map { String(cString: $0) } ?? ""
    let params = paramsPtr.map { String(cString: $0) }
    return dupCString(intelDbExec(pluginId: pid, sql: sql, paramsJSON: params))
}
private let intelHostDbQuery: osr_db_query_t = { sqlPtr, paramsPtr in
    let pid = intelCurrentPluginId()
    let sql = sqlPtr.map { String(cString: $0) } ?? ""
    let params = paramsPtr.map { String(cString: $0) }
    return dupCString(intelDbQuery(pluginId: pid, sql: sql, paramsJSON: params))
}
private let intelHostDispatch: osr_dispatch_t = { reqPtr in
    let pid = intelCurrentPluginId()
    let req = reqPtr.map { String(cString: $0) } ?? "{}"
    return dupCString(intelDispatch(pluginId: pid, requestJSON: req))
}
private let intelHostTaskStatus: osr_task_status_t = { idPtr in
    let pid = intelCurrentPluginId()
    let idStr = idPtr.map { String(cString: $0) } ?? ""
    return dupCString(intelTaskStatus(pluginId: pid, taskIdString: idStr))
}
private let intelHostComplete: osr_complete_t = { reqPtr in
    let req = reqPtr.map { String(cString: $0) } ?? "{}"
    return dupCString(intelComplete(requestJSON: req))
}
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
struct IntelPluginToolSpec: Sendable, Identifiable {
    let id: String
    let description: String
    let parameters: JSONValue?
}

/// A user-settable config field, parsed from the manifest `secrets[]` (the
/// natural home for API keys / per-plugin settings). Rendered by the Intel
/// plugin config sheet; persisted via the scoped config store; `on_config_changed`
/// notifies the plugin.
public struct IntelPluginConfigField: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let detail: String?
    public let required: Bool
    public let url: String?
    public let isSecret: Bool
}

final class IntelLoadedPlugin: @unchecked Sendable {
    let pluginId: String
    let displayName: String
    let toolSpecs: [IntelPluginToolSpec]
    let manifestJSON: String
    /// Top-level manifest `instructions`, appended to the system prompt when
    /// any of this plugin's tools are active in a chat (see PluginManager).
    let instructions: String?
    /// User-settable config fields (from manifest `secrets[]`).
    let configFields: [IntelPluginConfigField]

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
        displayName: String,
        toolSpecs: [IntelPluginToolSpec],
        instructions: String?,
        configFields: [IntelPluginConfigField],
        manifestJSON: String,
        handle: UnsafeMutableRawPointer,
        api: osr_plugin_api,
        ctx: osr_plugin_ctx_t,
        hostAPIPtr: UnsafeMutablePointer<osr_host_api>
    ) {
        self.pluginId = pluginId
        self.displayName = displayName
        self.toolSpecs = toolSpecs
        self.instructions = instructions
        self.configFields = configFields
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
    func invoke(type: String, id: String, payload: String, agentId: UUID? = nil) throws -> String {
        try queue.sync {
            guard !isShutDown else {
                throw NSError(domain: "IntelLoadedPlugin", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Plugin has been shut down"])
            }
            guard let invokeFn = api.invoke else {
                throw NSError(domain: "IntelLoadedPlugin", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Plugin does not implement invoke"])
            }
            // Scope host callbacks (config, db, dispatch…) to this plugin. The
            // callbacks run synchronously on this thread inside invokeFn, so a
            // thread-local id is the cheapest correct scope.
            Thread.current.threadDictionary[intelPluginThreadKey] = pluginId
            if let agentId { Thread.current.threadDictionary[intelPluginAgentThreadKey] = agentId }
            defer {
                Thread.current.threadDictionary.removeObject(forKey: intelPluginThreadKey)
                Thread.current.threadDictionary.removeObject(forKey: intelPluginAgentThreadKey)
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

    /// Notify the plugin that the user changed one of its config values
    /// (host UI → plugin). No-op if the plugin doesn't implement the callback.
    func notifyConfigChanged(key: String, value: String) {
        queue.sync {
            guard !isShutDown, let cb = api.on_config_changed else { return }
            Thread.current.threadDictionary[intelPluginThreadKey] = pluginId
            defer { Thread.current.threadDictionary.removeObject(forKey: intelPluginThreadKey) }
            key.withCString { k in value.withCString { v in cb(ctx, k, v) } }
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

        // Reject incomplete ABI tables BEFORE calling init (upstream #2061): a
        // nil `free_string` leaks every returned string, a nil `destroy`
        // makes teardown impossible, a nil `invoke` yields tools that can
        // never run.
        if let abiError = abiTableValidationFailure(api) {
            hostAPIPtr.deinitialize(count: 1); hostAPIPtr.deallocate()
            dlclose(handle)
            return .failure(IntelPluginLoadError(message: abiError))
        }

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

        // Upstream #2061: the manifest's `plugin_id` must be the id it is
        // installed (and its secrets stored) under, and tool ids must be
        // non-empty and unique (duplicates silently overwrite each other).
        if let manifestError = manifestValidationFailure(manifestJSON: manifestJSON, directoryId: pluginId) {
            api.destroy?(ctx)
            hostAPIPtr.deinitialize(count: 1); hostAPIPtr.deallocate()
            dlclose(handle)
            return .failure(IntelPluginLoadError(message: manifestError))
        }

        let toolSpecs = Self.parseToolSpecs(fromManifestJSON: manifestJSON)
        let instructions = Self.parseInstructions(fromManifestJSON: manifestJSON)
        let displayName = Self.parseName(fromManifestJSON: manifestJSON) ?? pluginId
        let configFields = Self.parseConfigFields(fromManifestJSON: manifestJSON)

        let loaded = IntelLoadedPlugin(
            pluginId: pluginId,
            displayName: displayName,
            toolSpecs: toolSpecs,
            instructions: instructions,
            configFields: configFields,
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

    /// Decodable shapes for pulling tool specs + instructions + config out of
    /// the manifest.
    /// Upstream `PluginManager.abiTableValidationFailure`.
    static func abiTableValidationFailure(_ api: osr_plugin_api) -> String? {
        var missing: [String] = []
        if api.free_string == nil { missing.append("free_string") }
        if api.`init` == nil { missing.append("init") }
        if api.destroy == nil { missing.append("destroy") }
        if api.get_manifest == nil { missing.append("get_manifest") }
        if api.invoke == nil { missing.append("invoke") }
        guard !missing.isEmpty else { return nil }
        return "Plugin ABI table is missing required function(s): \(missing.joined(separator: ", "))"
    }

    /// Upstream `manifestIdentityValidationFailure` +
    /// `manifestCapabilityValidationFailure` (tools; Intel serves no routes).
    /// A manifest without `plugin_id` is accepted, as before: the id then
    /// comes from the install directory.
    static func manifestValidationFailure(manifestJSON: String, directoryId: String) -> String? {
        guard let data = manifestJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ManifestTools.self, from: data)
        else { return nil }
        if let declared = decoded.plugin_id, declared != directoryId {
            return "Plugin manifest declares plugin_id '\(declared)' but is installed as '\(directoryId)'. "
                + "Reinstall the plugin under its canonical ID."
        }
        var seen = Set<String>()
        for tool in decoded.capabilities?.tools ?? [] {
            let id = tool.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty { return "Plugin \(directoryId) declares a tool with an empty id" }
            if !seen.insert(id).inserted { return "Plugin \(directoryId) declares duplicate tool id '\(id)'" }
        }
        return nil
    }

    private struct ManifestTools: Decodable {
        struct Caps: Decodable { let tools: [ToolDef]? }
        struct ToolDef: Decodable {
            let id: String
            let description: String?
            let parameters: JSONValue?
        }
        struct Secret: Decodable {
            let id: String
            let label: String?
            let description: String?
            let required: Bool?
            let url: String?
            let secret: Bool?
        }
        let plugin_id: String?
        let capabilities: Caps?
        let instructions: String?
        let name: String?
        let secrets: [Secret]?
    }

    static func parseName(fromManifestJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ManifestTools.self, from: data)
        else { return nil }
        return decoded.name
    }

    static func parseConfigFields(fromManifestJSON json: String) -> [IntelPluginConfigField] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ManifestTools.self, from: data),
              let secrets = decoded.secrets
        else { return [] }
        return secrets.map {
            IntelPluginConfigField(
                id: $0.id,
                label: $0.label ?? $0.id,
                detail: $0.description,
                required: $0.required ?? true,
                url: $0.url,
                isSecret: $0.secret ?? true
            )
        }
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

    private static func parseInstructions(fromManifestJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ManifestTools.self, from: data),
              let instr = decoded.instructions,
              !instr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return instr
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
        // Task-locals don't cross the GCD hop: capture the calling chat's
        // agent here so a plugin `dispatch` runs as it (upstream).
        let agentId = ChatExecutionContext.currentAgentId
        let payload = Self.injectFolderContext(
            into: Self.injectSecrets(
                into: argumentsJSON.isEmpty ? "{}" : argumentsJSON, pluginId: pid, agentId: agentId),
            folderRoot: ChatExecutionContext.currentFolderRoot)
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try handle.invoke(type: "tool", id: tid, payload: payload, agentId: agentId))
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

    /// Upstream `ExternalTool.injectSecrets`: the plugin's secrets (calling
    /// agent's, over the Default agent's globals) under `_secrets`. No agent,
    /// or the Default agent itself, means an anonymous call: the payload is
    /// left unchanged rather than leaking the built-in agent's namespace
    /// (such plugins read keys through `config_get`).
    static func injectSecrets(into payload: String, pluginId: String, agentId: UUID?) -> String {
        guard let agentId, agentId != Agent.defaultId else { return payload }
        let secrets = ToolSecretsKeychain.resolvedSecretsWithDefaults(pluginId: pluginId, agentId: agentId)
        guard !secrets.isEmpty else { return payload }
        return merging(["_secrets": secrets], into: payload)
    }

    /// Upstream `ExternalTool.injectFolderContext`: the executing chat's
    /// working folder under `_context.working_directory`.
    static func injectFolderContext(into payload: String, folderRoot: URL?) -> String {
        guard let folderRoot else { return payload }
        return merging(["_context": ["working_directory": folderRoot.path]], into: payload)
    }

    /// Adds `fields` to a JSON-object payload; any other payload is returned as is.
    private static func merging(_ fields: [String: Any], into payload: String) -> String {
        guard let data = payload.data(using: .utf8),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return payload }
        for (key, value) in fields { dict[key] = value }
        guard let out = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: out, encoding: .utf8)
        else { return payload }
        return string
    }
}

#endif
