//
//  HostAPI.swift
//  OsaurusPluginABI
//
//  Field-for-field Swift mirror of `osr_host_api` (v6 layout) from
//  `osaurus_plugin.h`. The struct layout is FROZEN — the host appends new
//  callbacks at the end on every version bump. A mirror that drops or
//  reorders a single slot dispatches every later callback into the wrong
//  host function and typically crashes inside `libc free()` on a
//  non-malloc pointer.
//
//  Pinned offsets (arm64 Darwin, LP64 — asserted by
//  `HostAPILayoutTests` in this package and by the host's own
//  `PluginHostAPIStructLayoutTests`):
//
//      version              0
//      get_active_agent_id  176
//      log_structured       184
//      free_string          192
//      (struct stride)      200
//

import Foundation

/// Swift mirror of `osr_host_api`. Field names match the C header exactly
/// so audits against `osaurus_plugin.h` are a line-by-line diff.
public struct OsrHostAPI {
    public var version: UInt32

    // Config + Storage + Logging
    public var config_get: OsrConfigGetFn?
    public var config_set: OsrConfigSetFn?
    public var config_delete: OsrConfigDeleteFn?
    public var db_exec: OsrDbExecFn?
    public var db_query: OsrDbQueryFn?
    public var log: OsrLogFn?

    // Agent Dispatch
    public var dispatch: OsrDispatchFn?
    public var task_status: OsrTaskStatusFn?
    public var dispatch_cancel: OsrDispatchCancelFn?
    public var dispatch_clarify: OsrDispatchClarifyFn?  // RESERVED

    // Inference
    public var complete: OsrCompleteFn?
    public var complete_stream: OsrCompleteStreamFn?
    public var embed: OsrEmbedFn?
    public var list_models: OsrListModelsFn?

    // HTTP Client
    public var http_request: OsrHttpRequestFn?

    // File I/O
    public var file_read: OsrFileReadFn?

    // Extended Agent Dispatch (added in v2)
    public var list_active_tasks: OsrListActiveTasksFn?
    public var send_draft: OsrSendDraftFn?
    public var dispatch_interrupt: OsrDispatchInterruptFn?
    public var dispatch_add_issue: OsrDispatchAddIssueFn?  // RESERVED

    // Streaming control (added in v3). NULL on v2 hosts.
    public var complete_cancel: OsrCompleteCancelFn?

    // Agent context introspection (added in v4). NULL on v3 and earlier.
    public var get_active_agent_id: OsrGetActiveAgentIdFn?

    // Structured logging (added in v5). NULL on v4 and earlier. The slot's
    // presence is what makes `free_string` (v6) land at offset 192 — it
    // MUST stay here even in plugins that never call it.
    public var log_structured: OsrLogStructuredFn?

    // Host-side free for host-returned strings (added in v6). NULL on v5
    // and earlier hosts — fall back to `libc free()`.
    public var free_string: OsrHostFreeStringFn?

    /// Memberwise init with nil defaults so mocks and tests can populate
    /// only the slots they exercise. Trailing slots default to nil, which
    /// is exactly how an older host presents to a newer plugin.
    public init(
        version: UInt32 = OsrABIVersion.current,
        config_get: OsrConfigGetFn? = nil,
        config_set: OsrConfigSetFn? = nil,
        config_delete: OsrConfigDeleteFn? = nil,
        db_exec: OsrDbExecFn? = nil,
        db_query: OsrDbQueryFn? = nil,
        log: OsrLogFn? = nil,
        dispatch: OsrDispatchFn? = nil,
        task_status: OsrTaskStatusFn? = nil,
        dispatch_cancel: OsrDispatchCancelFn? = nil,
        dispatch_clarify: OsrDispatchClarifyFn? = nil,
        complete: OsrCompleteFn? = nil,
        complete_stream: OsrCompleteStreamFn? = nil,
        embed: OsrEmbedFn? = nil,
        list_models: OsrListModelsFn? = nil,
        http_request: OsrHttpRequestFn? = nil,
        file_read: OsrFileReadFn? = nil,
        list_active_tasks: OsrListActiveTasksFn? = nil,
        send_draft: OsrSendDraftFn? = nil,
        dispatch_interrupt: OsrDispatchInterruptFn? = nil,
        dispatch_add_issue: OsrDispatchAddIssueFn? = nil,
        complete_cancel: OsrCompleteCancelFn? = nil,
        get_active_agent_id: OsrGetActiveAgentIdFn? = nil,
        log_structured: OsrLogStructuredFn? = nil,
        free_string: OsrHostFreeStringFn? = nil
    ) {
        self.version = version
        self.config_get = config_get
        self.config_set = config_set
        self.config_delete = config_delete
        self.db_exec = db_exec
        self.db_query = db_query
        self.log = log
        self.dispatch = dispatch
        self.task_status = task_status
        self.dispatch_cancel = dispatch_cancel
        self.dispatch_clarify = dispatch_clarify
        self.complete = complete
        self.complete_stream = complete_stream
        self.embed = embed
        self.list_models = list_models
        self.http_request = http_request
        self.file_read = file_read
        self.list_active_tasks = list_active_tasks
        self.send_draft = send_draft
        self.dispatch_interrupt = dispatch_interrupt
        self.dispatch_add_issue = dispatch_add_issue
        self.complete_cancel = complete_cancel
        self.get_active_agent_id = get_active_agent_id
        self.log_structured = log_structured
        self.free_string = free_string
    }
}
