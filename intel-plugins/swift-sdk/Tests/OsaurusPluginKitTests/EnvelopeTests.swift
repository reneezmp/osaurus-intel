//
//  EnvelopeTests.swift
//

import XCTest

@testable import OsaurusPluginKit

final class EnvelopeTests: XCTestCase {

    private func parse(_ json: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - Retryable policy matrix

    func testDefaultRetryablePolicyMatrix() {
        XCTAssertFalse(Envelope.Kind.invalidArgs.defaultRetryable)
        XCTAssertFalse(Envelope.Kind.notFound.defaultRetryable)
        XCTAssertFalse(Envelope.Kind.permissionDenied.defaultRetryable)
        XCTAssertTrue(Envelope.Kind.timeout.defaultRetryable)
        XCTAssertTrue(Envelope.Kind.executionError.defaultRetryable)
    }

    func testFailureEnvelopeAppliesDefaultPolicyForEveryKind() throws {
        for kind in Envelope.Kind.allCases {
            let dict = try parse(Envelope.failure(kind, "boom"))
            XCTAssertEqual(dict["ok"] as? Bool, false, "kind \(kind.rawValue)")
            XCTAssertEqual(dict["kind"] as? String, kind.rawValue)
            XCTAssertEqual(dict["message"] as? String, "boom")
            XCTAssertEqual(dict["retryable"] as? Bool, kind.defaultRetryable)
            XCTAssertNil(dict["data"])
        }
    }

    func testRetryableOverrideWinsInBothDirections() throws {
        let forcedRetryable = try parse(
            Envelope.failure(.invalidArgs, "transient parse", retryable: true))
        XCTAssertEqual(forcedRetryable["retryable"] as? Bool, true)

        let forcedFatal = try parse(
            Envelope.failure(.timeout, "permanent deadline", retryable: false))
        XCTAssertEqual(forcedFatal["retryable"] as? Bool, false)
    }

    // MARK: - Failure payloads

    func testFailureWithRawDataJSON() throws {
        let dict = try parse(
            Envelope.failure(.executionError, "boom", dataJSON: "{\"exit_code\":3}"))
        let data = try XCTUnwrap(dict["data"] as? [String: Any])
        XCTAssertEqual(data["exit_code"] as? Int, 3)
    }

    func testFailureWithDictionaryData() throws {
        let dict = try parse(
            Envelope.failure(.notFound, "no such file", data: ["path": "/tmp/x", "attempts": 2]))
        let data = try XCTUnwrap(dict["data"] as? [String: Any])
        XCTAssertEqual(data["path"] as? String, "/tmp/x")
        XCTAssertEqual(data["attempts"] as? Int, 2)
    }

    func testMessageEscaping() throws {
        let nasty = "quote:\" backslash:\\ newline:\n tab:\t bell:\u{07}"
        let dict = try parse(Envelope.failure(.invalidArgs, nasty))
        XCTAssertEqual(dict["message"] as? String, nasty)
    }

    // MARK: - Success builders

    func testSuccessMinimal() throws {
        let dict = try parse(Envelope.success())
        XCTAssertEqual(dict["ok"] as? Bool, true)
        XCTAssertEqual(dict.count, 1)
    }

    func testSuccessRawPayloadDefaultKey() throws {
        let dict = try parse(Envelope.success(raw: "[1,2,3]"))
        XCTAssertEqual(dict["ok"] as? Bool, true)
        XCTAssertEqual(dict["result"] as? [Int], [1, 2, 3])
    }

    func testSuccessRawPayloadLegacyKey() throws {
        // Legacy plugins that emit {ok, data} keep their shape.
        let dict = try parse(Envelope.success(raw: "{\"count\":5}", key: "data"))
        let data = try XCTUnwrap(dict["data"] as? [String: Any])
        XCTAssertEqual(data["count"] as? Int, 5)
    }

    func testSuccessFieldsMergedAtTopLevel() throws {
        let dict = try parse(Envelope.success(fields: ["count": 2, "items": ["a", "b"]]))
        XCTAssertEqual(dict["ok"] as? Bool, true)
        XCTAssertEqual(dict["count"] as? Int, 2)
        XCTAssertEqual(dict["items"] as? [String], ["a", "b"])
    }

    func testSuccessFieldsCannotOverrideOk() throws {
        let dict = try parse(Envelope.success(fields: ["ok": false, "x": 1]))
        XCTAssertEqual(dict["ok"] as? Bool, true)
    }

    // MARK: - EnvelopeFailure error type

    func testEnvelopeFailureRendersCanonicalEnvelope() throws {
        let failure = EnvelopeFailure(.permissionDenied, "denied", dataJSON: "{\"scope\":\"mail\"}")
        let dict = try parse(failure.render())
        XCTAssertEqual(dict["ok"] as? Bool, false)
        XCTAssertEqual(dict["kind"] as? String, "permission_denied")
        XCTAssertEqual(dict["retryable"] as? Bool, false)
        XCTAssertEqual((dict["data"] as? [String: Any])?["scope"] as? String, "mail")
    }

    func testEnvelopeFailureRetryableOverride() throws {
        let dict = try parse(EnvelopeFailure(.executionError, "fatal", retryable: false).render())
        XCTAssertEqual(dict["retryable"] as? Bool, false)
    }

    func testKindRawValuesAreCanonical() {
        XCTAssertEqual(
            Envelope.Kind.allCases.map(\.rawValue),
            ["invalid_args", "not_found", "permission_denied", "timeout", "execution_error"])
    }
}
