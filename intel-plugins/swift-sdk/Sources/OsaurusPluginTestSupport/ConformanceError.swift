//
//  ConformanceError.swift
//  OsaurusPluginTestSupport
//

import Foundation

/// Error thrown by the assertion helpers in this module. Throwing from a
/// test body fails the test with `message` in both XCTest and
/// swift-testing, so the helpers stay framework-agnostic.
public struct ConformanceError: Error, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
