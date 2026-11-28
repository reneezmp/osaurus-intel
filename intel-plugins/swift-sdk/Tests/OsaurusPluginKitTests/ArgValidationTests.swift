//
//  ArgValidationTests.swift
//

import XCTest

@testable import OsaurusPluginKit

final class ArgValidationTests: XCTestCase {

    private func expectInvalidArgs(
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let failure = error as? EnvelopeFailure else {
                return XCTFail("expected EnvelopeFailure, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(failure.kind, .invalidArgs, file: file, line: line)
        }
    }

    // MARK: - parseObject

    func testParseValidObject() throws {
        let args = try ArgValidation.parseObject(#"{"q":"hello","limit":5}"#)
        XCTAssertEqual(args["q"] as? String, "hello")
        XCTAssertEqual(args["limit"] as? Int, 5)
    }

    func testParseMalformedJSONIsInvalidArgs() {
        expectInvalidArgs { _ = try ArgValidation.parseObject(#"{"q": unquoted}"#) }
        expectInvalidArgs { _ = try ArgValidation.parseObject("not json at all") }
    }

    func testParseNonObjectRootIsInvalidArgs() {
        expectInvalidArgs { _ = try ArgValidation.parseObject("[1,2,3]") }
        expectInvalidArgs { _ = try ArgValidation.parseObject("\"string\"") }
    }

    func testParseNilOrEmptyPayloadIsInvalidArgs() {
        expectInvalidArgs { _ = try ArgValidation.parseObject(nil) }
        expectInvalidArgs { _ = try ArgValidation.parseObject("") }
        expectInvalidArgs { _ = try ArgValidation.parseObject("   \n") }
    }

    // MARK: - String accessors

    func testRequireString() throws {
        let args: [String: Any] = ["name": "value", "blank": "  ", "num": 3]
        XCTAssertEqual(try ArgValidation.requireString(args, "name"), "value")
        expectInvalidArgs { _ = try ArgValidation.requireString(args, "missing") }
        expectInvalidArgs { _ = try ArgValidation.requireString(args, "blank") }
        expectInvalidArgs { _ = try ArgValidation.requireString(args, "num") }
    }

    func testOptionalString() throws {
        let args: [String: Any] = ["name": "value", "null": NSNull(), "num": 3]
        XCTAssertEqual(try ArgValidation.optionalString(args, "name"), "value")
        XCTAssertNil(try ArgValidation.optionalString(args, "missing"))
        XCTAssertNil(try ArgValidation.optionalString(args, "null"))
        expectInvalidArgs { _ = try ArgValidation.optionalString(args, "num") }
    }

    // MARK: - resolveLimit

    func testResolveLimitDefaultsWhenAbsent() throws {
        XCTAssertEqual(
            try ArgValidation.resolveLimit(nil, field: "limit", defaultValue: 10, maximum: 100), 10)
        XCTAssertEqual(
            try ArgValidation.resolveLimit(
                NSNull(), field: "limit", defaultValue: 10, maximum: 100), 10)
    }

    func testResolveLimitAcceptsValidValues() throws {
        XCTAssertEqual(
            try ArgValidation.resolveLimit(5, field: "limit", defaultValue: 10, maximum: 100), 5)
        // JSON numbers may arrive as whole Doubles.
        XCTAssertEqual(
            try ArgValidation.resolveLimit(7.0, field: "limit", defaultValue: 10, maximum: 100), 7)
    }

    func testResolveLimitRejectsZeroAndNegative() {
        expectInvalidArgs {
            _ = try ArgValidation.resolveLimit(0, field: "limit", defaultValue: 10, maximum: 100)
        }
        expectInvalidArgs {
            _ = try ArgValidation.resolveLimit(-3, field: "limit", defaultValue: 10, maximum: 100)
        }
    }

    func testResolveLimitClampsToMaximum() throws {
        XCTAssertEqual(
            try ArgValidation.resolveLimit(9999, field: "limit", defaultValue: 10, maximum: 100),
            100)
    }

    func testResolveLimitRejectsNonIntegers() {
        expectInvalidArgs {
            _ = try ArgValidation.resolveLimit(2.5, field: "limit", defaultValue: 10, maximum: 100)
        }
        expectInvalidArgs {
            _ = try ArgValidation.resolveLimit("5", field: "limit", defaultValue: 10, maximum: 100)
        }
        expectInvalidArgs {
            _ = try ArgValidation.resolveLimit(true, field: "limit", defaultValue: 10, maximum: 100)
        }
    }

    // MARK: - isoDate

    func testIsoDateAcceptsInternetDateTime() throws {
        let date = try ArgValidation.isoDate("2026-07-17T12:00:00Z", field: "since")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 7)
        XCTAssertEqual(parts.day, 17)
        XCTAssertEqual(parts.hour, 12)
    }

    func testIsoDateAcceptsFractionalSecondsAndOffsets() throws {
        _ = try ArgValidation.isoDate("2026-07-17T12:00:00.123Z", field: "since")
        _ = try ArgValidation.isoDate("2026-07-17T12:00:00+02:00", field: "since")
    }

    func testIsoDateAcceptsDateOnly() throws {
        _ = try ArgValidation.isoDate("2026-07-17", field: "since")
    }

    func testIsoDateRejectsInvalidValues() {
        for bad in ["yesterday", "17/07/2026", "2026-13-45", "2026-07-17T99:00:00Z", ""] {
            expectInvalidArgs { _ = try ArgValidation.isoDate(bad, field: "since") }
        }
    }

    // MARK: - enumValue

    func testEnumValueAcceptsAllowed() throws {
        XCTAssertEqual(
            try ArgValidation.enumValue("asc", field: "order", allowed: ["asc", "desc"]), "asc")
    }

    func testEnumValueRejectsUnknownAndWrongCase() {
        expectInvalidArgs {
            _ = try ArgValidation.enumValue("sideways", field: "order", allowed: ["asc", "desc"])
        }
        expectInvalidArgs {
            _ = try ArgValidation.enumValue("ASC", field: "order", allowed: ["asc", "desc"])
        }
    }
}
