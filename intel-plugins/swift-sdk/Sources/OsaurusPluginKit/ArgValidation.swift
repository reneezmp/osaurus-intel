//
//  ArgValidation.swift
//  OsaurusPluginKit
//
//  Strict parsing and validation for tool-call arguments. Every failure
//  throws an `EnvelopeFailure` (kind `invalid_args`) so `invoke` can
//  render the canonical failure envelope at the boundary.
//

import Foundation

public enum ArgValidation {

    // MARK: - JSON parsing

    /// Strictly parses a JSON object from the raw `payload` the host
    /// passed to `invoke`. Malformed JSON, non-object roots, and nil/empty
    /// payloads all throw `invalid_args`.
    public static func parseObject(_ json: String?) throws -> [String: Any] {
        guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EnvelopeFailure(.invalidArgs, "Missing arguments payload")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        } catch {
            throw EnvelopeFailure(.invalidArgs, "Arguments are not valid JSON")
        }
        guard let dict = object as? [String: Any] else {
            throw EnvelopeFailure(.invalidArgs, "Arguments must be a JSON object")
        }
        return dict
    }

    // MARK: - Typed accessors

    /// Required non-empty string argument.
    public static func requireString(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = try optionalString(args, key),
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw EnvelopeFailure(.invalidArgs, "Missing or empty required argument: \(key)")
        }
        return value
    }

    /// Optional string argument; present-but-wrong-type is an error.
    public static func optionalString(_ args: [String: Any], _ key: String) throws -> String? {
        guard let raw = args[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? String else {
            throw EnvelopeFailure(.invalidArgs, "Argument '\(key)' must be a string")
        }
        return value
    }

    // MARK: - Integer limits

    /// Resolves an integer limit argument: nil falls back to
    /// `defaultValue`, zero/negative values are rejected, values above
    /// `maximum` are clamped to it. Non-integer values (bools, fractions,
    /// strings) are rejected.
    public static func resolveLimit(
        _ value: Any?,
        field: String,
        defaultValue: Int,
        maximum: Int
    ) throws -> Int {
        guard let value, !(value is NSNull) else { return defaultValue }
        if value is Bool {
            throw EnvelopeFailure(.invalidArgs, "\(field) must be an integer")
        }
        let resolved: Int
        if let intValue = value as? Int {
            resolved = intValue
        } else if let doubleValue = value as? Double,
            doubleValue.truncatingRemainder(dividingBy: 1) == 0,
            let exact = Int(exactly: doubleValue)
        {
            resolved = exact
        } else {
            throw EnvelopeFailure(.invalidArgs, "\(field) must be an integer")
        }
        guard resolved > 0 else {
            throw EnvelopeFailure(.invalidArgs, "\(field) must be a positive integer")
        }
        return min(resolved, maximum)
    }

    // MARK: - ISO dates

    /// Validates an ISO 8601 date string. Accepts full internet
    /// date-times (`2026-07-17T12:00:00Z`, with or without fractional
    /// seconds) and date-only values (`2026-07-17`).
    public static func isoDate(_ value: String, field: String) throws -> Date {
        let dateTime = ISO8601DateFormatter()
        dateTime.formatOptions = [.withInternetDateTime]
        if let date = dateTime.date(from: value) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let dayOnly = DateFormatter()
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = TimeZone(identifier: "UTC")
        dayOnly.dateFormat = "yyyy-MM-dd"
        if let date = dayOnly.date(from: value) { return date }

        throw EnvelopeFailure(
            .invalidArgs,
            "\(field) must be an ISO 8601 date (e.g. 2026-07-17 or 2026-07-17T12:00:00Z)")
    }

    // MARK: - Enum strings

    /// Validates that `value` is one of `allowed` (case-sensitive).
    @discardableResult
    public static func enumValue(
        _ value: String,
        field: String,
        allowed: [String]
    ) throws -> String {
        guard allowed.contains(value) else {
            throw EnvelopeFailure(
                .invalidArgs,
                "\(field) must be one of: \(allowed.joined(separator: ", "))")
        }
        return value
    }
}
