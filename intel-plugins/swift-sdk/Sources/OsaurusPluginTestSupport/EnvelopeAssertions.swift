//
//  EnvelopeAssertions.swift
//  OsaurusPluginTestSupport
//

import Foundation
import OsaurusPluginKit

/// Asserts `json` is a canonical failure envelope:
/// `{"ok":false,"kind":"<kind>","message":<non-empty>,"retryable":<bool>}`.
///
/// When `retryable` is nil, the kind's default policy is expected.
/// Throws a descriptive `ConformanceError` on any mismatch — throwing
/// fails the test in both XCTest and swift-testing.
public func assertCanonicalFailure(
    _ json: String,
    kind: Envelope.Kind,
    retryable: Bool? = nil
) throws {
    guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
        let envelope = object as? [String: Any]
    else {
        throw ConformanceError("failure envelope is not a JSON object: \(json)")
    }

    guard let ok = envelope["ok"] as? Bool, ok == false else {
        throw ConformanceError("failure envelope must carry ok:false — got: \(json)")
    }
    guard let actualKind = envelope["kind"] as? String else {
        throw ConformanceError("failure envelope is missing 'kind': \(json)")
    }
    guard actualKind == kind.rawValue else {
        throw ConformanceError(
            "expected kind '\(kind.rawValue)' but found '\(actualKind)': \(json)")
    }
    guard let message = envelope["message"] as? String, !message.isEmpty else {
        throw ConformanceError("failure envelope is missing a non-empty 'message': \(json)")
    }
    guard let actualRetryable = envelope["retryable"] as? Bool else {
        throw ConformanceError("failure envelope is missing boolean 'retryable': \(json)")
    }
    let expectedRetryable = retryable ?? kind.defaultRetryable
    guard actualRetryable == expectedRetryable else {
        throw ConformanceError(
            "expected retryable \(expectedRetryable) for kind '\(kind.rawValue)' "
                + "but found \(actualRetryable): \(json)")
    }
}
