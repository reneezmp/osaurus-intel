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
//    • Intel's own: log, log_structured, free_string,
//        config_get/set/delete (per-agent Keychain).
//    • Upstream's, on `PluginHostContext`: http_request / file_read
//        (stage 2a), db_exec / db_query (2b), dispatch, task_status,
//        dispatch_cancel / _interrupt / _clarify / _add_issue, send_draft,
//        list_active_tasks, get_active_agent_id (2c), complete,
//        complete_stream, complete_cancel, embed, list_models (2d, on
//        Intel's engines: `IntelPluginInference.swift`). Task events reach
//        the plugin's on_task_event (`IntelLoadedPlugin.notifyTaskEvent`).
//
//  `W-plugin-reliability` stage 2 (docs/UPSTREAM_SYNC.md) moves the rest
//  onto upstream's code a stage at a time.
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

// --- Per-plugin scoping: which plugin is currently calling a host callback? --
// Host trampolines are global (no plugin arg), so the active plugin id is
// stashed in thread-local storage around each `invoke` (callbacks run
// synchronously on that same thread). Used to scope config + the SQLite store.
// The keys are upstream's (`PluginHostContext.tlsKey` / `agentTlsKey`), so
// `PluginHostContext`'s trampolines and these read the same scope.
let intelPluginThreadKey = "ai.osaurus.plugin.active"
func intelCurrentPluginId() -> String {
    (Thread.current.threadDictionary[intelPluginThreadKey] as? String) ?? "_shared"
}

/// The agent of the chat that called the plugin, stashed the same way
/// (upstream `PluginHostAPI.activeAgentId()`). Nil outside a chat tool call
/// (config callbacks, catalog probes).
let intelPluginAgentThreadKey = "ai.osaurus.plugin.agent"
func intelCurrentPluginAgentId() -> UUID? {
    Thread.current.threadDictionary[intelPluginAgentThreadKey] as? UUID
}

// --- db_exec / db_query: upstream's (`PluginHostContext.dbExec` / `dbQuery`
// over `PluginDatabase`, stage 2b): encrypted `Tools/<id>/data/data.db`, SQL
// guard, 100 MiB cap. Intel's old plaintext `Tools/<id>/plugin.db` moves in
// on first open (`IntelPluginDatabaseMigration`).

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

// --- dispatch, task_status, cancel, interrupt, draft, list_active_tasks and
// get_active_agent_id are upstream's (`PluginHostContext`, stage 2c);
// complete, complete_stream, complete_cancel, embed and list_models too
// (stage 2d, `IntelPluginInference.swift`).

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

// file_read and http_request are upstream's (`PluginHostContext`,
// `IntelPluginHostContext.swift`): SSRF checks, rate limits, size caps, and
// reads limited to the artifacts folder. Until stage 2a Intel's own versions
// read any path and fetched any address.

/// Build the host-API struct passed to a plugin's v2 entry point. Called
/// through `PluginHostContext.buildHostAPI()`, which owns the pointer and
/// frees it when the context goes away (after the plugin is destroyed).
func buildIntelHostAPI() -> UnsafeMutablePointer<osr_host_api> {
    let ptr = UnsafeMutablePointer<osr_host_api>.allocate(capacity: 1)
    ptr.initialize(to: osr_host_api(
        version: 6,
        config_get: intelHostConfigGet,
        config_set: intelHostConfigSet,
        config_delete: intelHostConfigDelete,
        db_exec: PluginHostContext.trampolineDbExec,
        db_query: PluginHostContext.trampolineDbQuery,
        log: intelHostLog,
        dispatch: PluginHostContext.trampolineDispatch,
        task_status: PluginHostContext.trampolineTaskStatus,
        dispatch_cancel: PluginHostContext.trampolineDispatchCancel,
        dispatch_clarify: PluginHostContext.trampolineDispatchClarify,
        complete: PluginHostContext.trampolineComplete,
        complete_stream: PluginHostContext.trampolineCompleteStream,
        embed: PluginHostContext.trampolineEmbed,
        list_models: PluginHostContext.trampolineListModels,
        http_request: PluginHostContext.trampolineHttpRequest,
        file_read: PluginHostContext.trampolineFileRead,
        list_active_tasks: PluginHostContext.trampolineListActiveTasks,
        send_draft: PluginHostContext.trampolineSendDraft,
        dispatch_interrupt: PluginHostContext.trampolineDispatchInterrupt,
        dispatch_add_issue: PluginHostContext.trampolineDispatchAddIssue,
        complete_cancel: PluginHostContext.trampolineCompleteCancel,
        get_active_agent_id: PluginHostContext.trampolineGetActiveAgentId,
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
    /// Upstream's per-plugin host state: rate limits, the database, the
    /// registry entry, and the host-API table the plugin holds.
    let hostContext: PluginHostContext
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
        hostContext: PluginHostContext
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
        self.hostContext = hostContext
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
            // Scope host callbacks (config, db, dispatch…) to this plugin and
            // the calling agent. The callbacks run synchronously on this
            // thread inside invokeFn, so thread-local storage is the scope
            // (upstream `withTLSScope`).
            let resPtr: UnsafePointer<CChar>? = PluginHostContext.withTLSScope(
                pluginId: pluginId, agentId: agentId
            ) {
                type.withCString { t in
                    id.withCString { i in
                        payload.withCString { p in
                            invokeFn(ctx, t, i, p)
                        }
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
            hostContext.teardown()
            dlclose(handle)
        }
    }

    /// Upstream `ExternalPlugin.hasTaskEventHandler` (every Intel plugin is
    /// v2, the only ABI the loader accepts).
    var hasTaskEventHandler: Bool { api.on_task_event != nil }

    /// Deliver a task lifecycle event to the plugin's `on_task_event`
    /// (upstream `ExternalPlugin.notifyTaskEvent`). Upstream gives each task
    /// its own serial queue, concurrent with `invoke`; Intel's host never
    /// runs a plugin's code concurrently, so events go through the plugin's
    /// one serial queue, after any tool call in progress. Order within a
    /// task is kept either way. Async, so a plugin that dispatched from
    /// inside `invoke` gets its events once that call has returned.
    func notifyTaskEvent(taskId: String, eventType: TaskEventType, eventJSON: String, agentId: UUID? = nil) {
        guard let eventFn = api.on_task_event else { return }
        let rawType = eventType.rawValue
        queue.async { [self] in
            guard !isShutDown else { return }
            PluginHostContext.withTLSScope(pluginId: pluginId, agentId: agentId) {
                taskId.withCString { taskIdPtr in
                    eventJSON.withCString { jsonPtr in
                        eventFn(ctx, taskIdPtr, rawType, jsonPtr)
                    }
                }
            }
        }
    }

    /// Notify the plugin that the user changed one of its config values
    /// (host UI → plugin). No-op if the plugin doesn't implement the callback.
    func notifyConfigChanged(key: String, value: String) {
        queue.sync {
            guard !isShutDown, let cb = api.on_config_changed else { return }
            PluginHostContext.withTLSScope(pluginId: pluginId, agentId: nil) {
                key.withCString { k in value.withCString { v in cb(ctx, k, v) } }
            }
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

        // Upstream: host calls made inside the entry point, `init` or
        // `get_manifest` resolve through `currentContext`; the context is
        // registered under the plugin id only once the load succeeds.
        guard let hostContext = try? PluginHostContext(pluginId: pluginId) else {
            dlclose(handle)
            return .failure(IntelPluginLoadError(message: "could not create the plugin host context"))
        }
        PluginHostContext.currentContext = hostContext
        defer { PluginHostContext.currentContext = nil }

        let hostAPIPtr = hostContext.buildHostAPI()
        let entryFn = unsafeBitCast(v2sym, to: osr_plugin_entry_v2_t.self)
        guard let apiRaw = entryFn(UnsafeRawPointer(hostAPIPtr)) else {
            dlclose(handle)
            return .failure(IntelPluginLoadError(message: "plugin v2 entry returned null API"))
        }

        let api = apiRaw.assumingMemoryBound(to: osr_plugin_api.self).pointee

        // Reject incomplete ABI tables BEFORE calling init (upstream #2061): a
        // nil `free_string` leaks every returned string, a nil `destroy`
        // makes teardown impossible, a nil `invoke` yields tools that can
        // never run.
        if let abiError = abiTableValidationFailure(api) {
            dlclose(handle)
            return .failure(IntelPluginLoadError(message: abiError))
        }

        guard let initFn = api.`init`, let ctx = initFn() else {
            dlclose(handle)
            return .failure(IntelPluginLoadError(message: "plugin init failed"))
        }

        guard let getManifest = api.get_manifest, let jsonPtr = getManifest(ctx) else {
            api.destroy?(ctx)
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
            hostContext: hostContext
        )
        PluginHostContext.setContext(hostContext, for: pluginId)
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
    /// Upstream `PluginManager.abiTableValidationFailure` (with #3079's
    /// loaded-image check).
    ///
    /// Returns a message when the plugin's ABI table is missing any of the
    /// five required function pointers, or when any populated slot does not
    /// point at code in a loaded image. Every plugin — v1 or v2+ — must
    /// provide the full required prefix; optional v2 callbacks stay optional.
    ///
    /// The second check is what stops a struct-layout mismatch from
    /// crashing the host. Sentry APPLE-MACOS-337: a plugin's table passed
    /// the nil checks, `init` and `get_manifest` ran, and the host then
    /// called `free_string` on the 997-byte manifest it had just copied —
    /// with `free_string == 0x1` (next launch `0x2`). The register dump has
    /// `pc == x28 == 0x1`, i.e. a `blr` through a slot that held a small
    /// integer, not a function. A field that is really an int or a bool in
    /// the plugin's own struct lands in a function-pointer slot of ours when
    /// the two layouts disagree; it is non-nil, so the nil checks cannot see
    /// it. `dladdr` can: a C function pointer handed to us by a dylib we
    /// just `dlopen`ed must live inside *some* loaded image (the plugin, a
    /// system library such as `free`, or a dependency it links). Anything
    /// else is not callable and is rejected here, before the first call.
    static func abiTableValidationFailure(_ api: osr_plugin_api) -> String? {
        var missing: [String] = []
        if api.free_string == nil { missing.append("free_string") }
        if api.`init` == nil { missing.append("init") }
        if api.destroy == nil { missing.append("destroy") }
        if api.get_manifest == nil { missing.append("get_manifest") }
        if api.invoke == nil { missing.append("invoke") }
        if !missing.isEmpty {
            return "Plugin ABI table is missing required function(s): \(missing.joined(separator: ", "))"
        }

        var invalid: [String] = []
        func check<F>(_ fn: F?, _ name: String) {
            guard let fn else { return }
            let raw = unsafeBitCast(fn, to: UnsafeRawPointer.self)
            if !isCodePointerInLoadedImage(raw) {
                invalid.append("\(name)=0x\(String(UInt(bitPattern: raw), radix: 16))")
            }
        }
        check(api.free_string, "free_string")
        check(api.`init`, "init")
        check(api.destroy, "destroy")
        check(api.get_manifest, "get_manifest")
        check(api.invoke, "invoke")
        check(api.handle_route, "handle_route")
        check(api.on_config_changed, "on_config_changed")
        check(api.on_task_event, "on_task_event")
        guard !invalid.isEmpty else { return nil }
        return
            "Plugin ABI table slot(s) do not point at code in any loaded image: "
            + invalid.joined(separator: ", ")
            + ". The plugin's osr_plugin_api layout does not match osaurus_plugin.h; rebuild it against the current header."
    }

    /// True when `pointer` falls inside a Mach-O image currently mapped in
    /// this process. `dladdr` returns non-zero exactly in that case; it does
    /// not require a symbol to cover the address, so stripped plugin code
    /// still passes while `0x1`, stack garbage, or a freed heap address do
    /// not.
    nonisolated static func isCodePointerInLoadedImage(_ pointer: UnsafeRawPointer) -> Bool {
        var info = Dl_info()
        return dladdr(pointer, &info) != 0
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
