//
//  EnvelopeAssertionTests.swift
//

import XCTest
import OsaurusPluginKit

@testable import OsaurusPluginTestSupport

final class EnvelopeAssertionTests: XCTestCase {

    func testPassesOnCanonicalFailureFromKit() throws {
        try assertCanonicalFailure(
            Envelope.failure(.notFound, "no such contact"), kind: .notFound)
        try assertCanonicalFailure(
            Envelope.failure(.timeout, "deadline"), kind: .timeout, retryable: true)
        try assertCanonicalFailure(
            Envelope.failure(.executionError, "fatal", retryable: false),
            kind: .executionError, retryable: false)
    }

    func testDefaultsExpectedRetryableToKindPolicy() throws {
        // No explicit retryable: expects the kind's default (true for
        // timeout), so a non-default envelope must fail.
        try assertCanonicalFailure(
            #"{"ok":false,"kind":"timeout","message":"m","retryable":true}"#, kind: .timeout)
        XCTAssertThrowsError(
            try assertCanonicalFailure(
                #"{"ok":false,"kind":"timeout","message":"m","retryable":false}"#, kind: .timeout))
    }

    func testRejectsNonJSON() {
        XCTAssertThrowsError(try assertCanonicalFailure("garbage", kind: .invalidArgs))
    }

    func testRejectsSuccessEnvelope() {
        XCTAssertThrowsError(
            try assertCanonicalFailure(#"{"ok":true,"result":1}"#, kind: .invalidArgs))
    }

    func testRejectsWrongKind() {
        XCTAssertThrowsError(
            try assertCanonicalFailure(
                Envelope.failure(.notFound, "x"), kind: .invalidArgs))
    }

    func testRejectsMissingKind() {
        XCTAssertThrowsError(
            try assertCanonicalFailure(
                #"{"ok":false,"message":"m","retryable":false}"#, kind: .invalidArgs))
    }

    func testRejectsMissingOrEmptyMessage() {
        XCTAssertThrowsError(
            try assertCanonicalFailure(
                #"{"ok":false,"kind":"invalid_args","retryable":false}"#, kind: .invalidArgs))
        XCTAssertThrowsError(
            try assertCanonicalFailure(
                #"{"ok":false,"kind":"invalid_args","message":"","retryable":false}"#,
                kind: .invalidArgs))
    }

    func testRejectsMissingOrWrongRetryable() {
        XCTAssertThrowsError(
            try assertCanonicalFailure(
                #"{"ok":false,"kind":"invalid_args","message":"m"}"#, kind: .invalidArgs))
        XCTAssertThrowsError(
            try assertCanonicalFailure(
                #"{"ok":false,"kind":"invalid_args","message":"m","retryable":"no"}"#,
                kind: .invalidArgs))
        XCTAssertThrowsError(
            try assertCanonicalFailure(
                #"{"ok":false,"kind":"invalid_args","message":"m","retryable":true}"#,
                kind: .invalidArgs))
    }
}
