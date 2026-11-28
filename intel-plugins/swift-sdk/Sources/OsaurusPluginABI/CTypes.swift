//
//  CTypes.swift
//  OsaurusPluginABI
//
//  Swift mirrors of the C function-pointer typedefs in
//  `Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h`. The header is
//  the single source of truth — when in doubt, the header wins.
//

import Foundation

// MARK: - ABI version constants (OSR_ABI_VERSION_*)

public enum OsrABIVersion {
    public static let v1: UInt32 = 1
    public static let v2: UInt32 = 2
    public static let v3: UInt32 = 3
    public static let v4: UInt32 = 4
    public static let v5: UInt32 = 5
    public static let v6: UInt32 = 6

    /// Highest ABI surface this SDK mirrors.
    public static let current: UInt32 = v6
}

// MARK: - Log levels (per osaurus_plugin.h: 0=trace ... 4=error)

public enum OsrLogLevel {
    public static let trace: Int32 = 0
    public static let debug: Int32 = 1
    public static let info: Int32 = 2
    public static let warn: Int32 = 3
    public static let error: Int32 = 4
}

// MARK: - Task lifecycle event types (OSR_TASK_EVENT_*)

public enum OsrTaskEvent {
    public static let started: Int32 = 0
    public static let activity: Int32 = 1
    public static let progress: Int32 = 2
    public static let clarification: Int32 = 3
    public static let completed: Int32 = 4
    public static let failed: Int32 = 5
    public static let cancelled: Int32 = 6
    public static let output: Int32 = 7
    public static let draft: Int32 = 8
}

// MARK: - Opaque plugin context

public typealias OsrPluginCtx = UnsafeMutableRawPointer

// MARK: - Host callback typedefs (plugin → host)

// Config + Storage + Logging
public typealias OsrConfigGetFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrConfigSetFn =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
public typealias OsrConfigDeleteFn = @convention(c) (UnsafePointer<CChar>?) -> Void
public typealias OsrDbExecFn =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrDbQueryFn =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrLogFn = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void

// Agent Dispatch
public typealias OsrDispatchFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrTaskStatusFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrDispatchCancelFn = @convention(c) (UnsafePointer<CChar>?) -> Void
public typealias OsrDispatchClarifyFn =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void

// Inference
public typealias OsrCompleteFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrOnChunkFn = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
public typealias OsrCompleteStreamFn =
    @convention(c) (
        UnsafePointer<CChar>?,
        OsrOnChunkFn?,
        UnsafeMutableRawPointer?
    ) -> UnsafePointer<CChar>?
public typealias OsrEmbedFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrListModelsFn = @convention(c) () -> UnsafePointer<CChar>?

// HTTP Client
public typealias OsrHttpRequestFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

// File I/O
public typealias OsrFileReadFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

// Extended Agent Dispatch (added in v2)
public typealias OsrListActiveTasksFn = @convention(c) () -> UnsafePointer<CChar>?
public typealias OsrSendDraftFn =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
public typealias OsrDispatchInterruptFn =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
public typealias OsrDispatchAddIssueFn =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

// Streaming control (added in v3)
public typealias OsrCompleteCancelFn = @convention(c) (UnsafePointer<CChar>?) -> Void

// Agent context introspection (added in v4)
public typealias OsrGetActiveAgentIdFn = @convention(c) () -> UnsafePointer<CChar>?

// Structured logging (added in v5)
public typealias OsrLogStructuredFn =
    @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void

// Host-side free for host-returned strings (added in v6)
public typealias OsrHostFreeStringFn = @convention(c) (UnsafePointer<CChar>?) -> Void

// MARK: - Plugin callback typedefs (host → plugin)

public typealias OsrFreeStringFn = @convention(c) (UnsafePointer<CChar>?) -> Void
public typealias OsrInitFn = @convention(c) () -> OsrPluginCtx?
public typealias OsrDestroyFn = @convention(c) (OsrPluginCtx?) -> Void
public typealias OsrGetManifestFn = @convention(c) (OsrPluginCtx?) -> UnsafePointer<CChar>?
public typealias OsrInvokeFn =
    @convention(c) (
        OsrPluginCtx?,
        UnsafePointer<CChar>?,  // type
        UnsafePointer<CChar>?,  // id
        UnsafePointer<CChar>?   // payload
    ) -> UnsafePointer<CChar>?
public typealias OsrHandleRouteFn =
    @convention(c) (OsrPluginCtx?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrOnConfigChangedFn =
    @convention(c) (OsrPluginCtx?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
public typealias OsrOnTaskEventFn =
    @convention(c) (OsrPluginCtx?, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Void

// MARK: - C string helpers

/// Heap-allocates `s` as a NUL-terminated C string.
///
/// Use for strings the plugin returns to the host (the host releases them
/// through the plugin's `free_string`, which pairs with this `strdup`).
///
/// Deliberately goes through `withCString` instead of the implicit
/// `String -> UnsafePointer<CChar>!` bridge; the implicit bridge produced a
/// heap-corruption abort in production plugins.
public func osrMakeCString(_ s: String) -> UnsafePointer<CChar>? {
    s.withCString { cStr -> UnsafePointer<CChar>? in
        guard let copy = strdup(cStr) else { return nil }
        return UnsafePointer(copy)
    }
}
