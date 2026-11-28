//
//  HostBridge.swift
//  OsaurusPluginABI
//
//  Safe Swift-side access to the `osr_host_api` the host injects at
//  `osaurus_plugin_entry_v2`. Every accessor performs the documented
//  defensive check (`host.version >= N && slot != nil`) so a plugin
//  compiled against this SDK degrades gracefully on older hosts and in
//  unit tests where no host is installed.
//

import Foundation

/// Thread-safe wrapper around the injected host API.
///
/// Usage: `HostBridge.shared` is populated by `PluginEntry.enterV2` (or an
/// explicit `HostBridge.shared.install(...)` from a hand-written entry
/// point). Tests can also build standalone instances against a mock
/// `OsrHostAPI` pointer.
public final class HostBridge: @unchecked Sendable {

    /// Process-wide bridge, populated at `osaurus_plugin_entry_v2`.
    public static let shared = HostBridge()

    private let lock = NSLock()
    /// Value copy of the host table. The header freezes the layout and the
    /// host never mutates the struct after entry, so a copy is safe and
    /// avoids holding a raw pointer.
    private var host: OsrHostAPI?

    public init() {}

    public convenience init(host: UnsafePointer<OsrHostAPI>?) {
        self.init()
        install(host)
    }

    /// Captures the host API. Call once from the v2 entry point. Passing
    /// nil uninstalls (useful in tests).
    public func install(_ hostPointer: UnsafePointer<OsrHostAPI>?) {
        lock.lock()
        host = hostPointer?.pointee
        lock.unlock()
    }

    /// True when a v2+ host has been installed. Unit tests and v1-only
    /// loads see `false`; all accessors then behave as safe no-ops.
    public var isInstalled: Bool {
        snapshot() != nil
    }

    /// The `version` the host advertised, or 0 when no host is installed.
    public var hostVersion: UInt32 {
        snapshot()?.version ?? 0
    }

    private func snapshot() -> OsrHostAPI? {
        lock.lock()
        defer { lock.unlock() }
        return host
    }

    // MARK: - Config (v2+)

    /// Returns the config value for `key` scoped to the active agent, or
    /// nil when the key is missing (or no host is installed). The empty
    /// string is a real value, distinct from "deleted" — it is returned
    /// as-is per the header contract.
    public func configGet(_ key: String) -> String? {
        guard let host = snapshot(), let fn = host.config_get else { return nil }
        return key.withCString { keyPtr -> String? in
            guard let ptr = fn(keyPtr) else { return nil }
            let value = String(cString: ptr)
            hostFree(ptr)
            return value
        }
    }

    /// Stores `value` under `key` for the active agent. No-op when no host
    /// is installed.
    public func configSet(_ key: String, _ value: String) {
        guard let host = snapshot(), let fn = host.config_set else { return }
        key.withCString { keyPtr in
            value.withCString { valuePtr in
                fn(keyPtr, valuePtr)
            }
        }
    }

    /// Removes `key` entirely for the active agent. No-op when no host is
    /// installed.
    public func configDelete(_ key: String) {
        guard let host = snapshot(), let fn = host.config_delete else { return }
        key.withCString { keyPtr in fn(keyPtr) }
    }

    // MARK: - Logging

    /// Plain log line. Levels per `OsrLogLevel` (0=trace ... 4=error).
    public func log(_ level: Int32, _ message: String) {
        guard let host = snapshot(), let fn = host.log else { return }
        message.withCString { msgPtr in fn(level, msgPtr) }
    }

    /// Structured log (v5+). `payload` is a JSON object string surfaced as
    /// searchable fields in Insights; nil logs the message with no fields.
    /// On pre-v5 hosts this degrades to a plain `log` call with the
    /// payload appended, per the documented fallback.
    public func logStructured(_ level: Int32, _ message: String, payload: String?) {
        guard let host = snapshot() else { return }
        if host.version >= OsrABIVersion.v5, let fn = host.log_structured {
            message.withCString { msgPtr in
                if let payload {
                    payload.withCString { payloadPtr in fn(level, msgPtr, payloadPtr) }
                } else {
                    fn(level, msgPtr, nil)
                }
            }
        } else {
            let fallback = payload.map { "\(message) \($0)" } ?? message
            log(level, fallback)
        }
    }

    // MARK: - Agent context (v4+)

    /// UUID of the agent that invoked the current callback frame, or nil
    /// outside any per-agent frame, on pre-v4 hosts, or when no host is
    /// installed. Always re-call per frame — never cache across callbacks.
    public func activeAgentId() -> String? {
        guard let host = snapshot(),
            host.version >= OsrABIVersion.v4,
            let fn = host.get_active_agent_id
        else { return nil }
        guard let ptr = fn() else { return nil }
        let value = String(cString: ptr)
        hostFree(ptr)
        return value
    }

    // MARK: - Memory (v6+ with libc fallback)

    /// Releases a `const char*` the HOST returned (config_get, dispatch,
    /// get_active_agent_id, ...). Uses `host->free_string` on v6+ hosts
    /// and falls back to `libc free()` on older hosts, exactly as the
    /// header prescribes. Never routes through the plugin's own
    /// `free_string` — that callback is for the reverse direction.
    /// nil is a no-op.
    public func hostFree(_ ptr: UnsafePointer<CChar>?) {
        guard let ptr else { return }
        if let host = snapshot(), host.version >= OsrABIVersion.v6, let fn = host.free_string {
            fn(ptr)
        } else {
            free(UnsafeMutableRawPointer(mutating: ptr))
        }
    }
}
