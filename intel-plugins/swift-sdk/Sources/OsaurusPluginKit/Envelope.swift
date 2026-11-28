//
//  Envelope.swift
//  OsaurusPluginKit
//
//  Canonical tool-result envelopes, consolidated from the per-plugin
//  variants audited in July 2026.
//
//  Failure (canonical, use everywhere):
//      {"ok":false,"kind":"<kind>","message":"...","retryable":<bool>,"data":{...}?}
//
//  Success (flexible): plugins with legacy `{ok, data}` / `{ok, result}`
//  shapes can keep their success shape and adopt only the failure side —
//  the builders below cover the common cases.
//

import Foundation

public enum Envelope {

    // MARK: - Failure kinds

    public enum Kind: String, CaseIterable, Sendable {
        case invalidArgs = "invalid_args"
        case notFound = "not_found"
        case permissionDenied = "permission_denied"
        case timeout = "timeout"
        case executionError = "execution_error"

        /// Canonical retryable policy: bad input / missing target /
        /// denied permission won't improve on retry; timeouts and
        /// execution errors may be transient.
        public var defaultRetryable: Bool {
            switch self {
            case .invalidArgs, .notFound, .permissionDenied: return false
            case .timeout, .executionError: return true
            }
        }
    }

    // MARK: - Failure builders

    /// Canonical failure envelope. `retryable` overrides the kind's
    /// default when non-nil. `dataJSON`, when provided, must be a valid
    /// JSON value and is embedded verbatim under `"data"`.
    public static func failure(
        _ kind: Kind,
        _ message: String,
        retryable: Bool? = nil,
        dataJSON: String? = nil
    ) -> String {
        let retry = retryable ?? kind.defaultRetryable
        var json =
            "{\"ok\":false,\"kind\":\"\(kind.rawValue)\",\"message\":\"\(escape(message))\",\"retryable\":\(retry)"
        if let dataJSON {
            json += ",\"data\":\(dataJSON)"
        }
        json += "}"
        return json
    }

    /// Failure with a structured `data` dictionary (serialized via
    /// JSONSerialization; non-serializable payloads are dropped rather
    /// than corrupting the envelope).
    public static func failure(
        _ kind: Kind,
        _ message: String,
        retryable: Bool? = nil,
        data: [String: Any]
    ) -> String {
        failure(kind, message, retryable: retryable, dataJSON: serialize(data))
    }

    // MARK: - Success builders

    /// Minimal success envelope: `{"ok":true}`.
    public static func success() -> String {
        "{\"ok\":true}"
    }

    /// Success wrapping a raw JSON payload under `key` (default
    /// `"result"`, the shape most audited plugins already emit):
    /// `{"ok":true,"result":<raw>}`.
    public static func success(raw: String, key: String = "result") -> String {
        "{\"ok\":true,\"\(escape(key))\":\(raw)}"
    }

    /// Success with `fields` merged at the top level next to `ok`:
    /// `{"ok":true, ...fields}`. An `"ok"` key inside `fields` is
    /// ignored — the envelope owns it.
    public static func success(fields: [String: Any]) -> String {
        var merged = fields
        merged["ok"] = true
        return serialize(merged) ?? "{\"ok\":true}"
    }

    // MARK: - JSON string escaping

    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 2)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if let a = ch.asciiValue, a < 0x20 {
                    out += String(format: "\\u%04x", a)
                } else {
                    out.append(ch)
                }
            }
        }
        return out
    }

    private static func serialize(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Typed error carrying an envelope kind, so service-layer code can
/// `throw` and the host-facing `invoke` renders one canonical failure at
/// the boundary:
///
///     catch let failure as EnvelopeFailure { return failure.render() }
///
public struct EnvelopeFailure: Error {
    public let kind: Envelope.Kind
    public let message: String
    /// Overrides the kind's default retryable policy when non-nil.
    public let retryable: Bool?
    /// Raw JSON embedded under `"data"` when non-nil.
    public let dataJSON: String?

    public init(
        _ kind: Envelope.Kind,
        _ message: String,
        retryable: Bool? = nil,
        dataJSON: String? = nil
    ) {
        self.kind = kind
        self.message = message
        self.retryable = retryable
        self.dataJSON = dataJSON
    }

    /// Renders the canonical failure envelope JSON.
    public func render() -> String {
        Envelope.failure(kind, message, retryable: retryable, dataJSON: dataJSON)
    }
}
