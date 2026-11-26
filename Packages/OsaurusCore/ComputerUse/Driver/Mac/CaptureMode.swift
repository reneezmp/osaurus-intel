//
//  CaptureMode.swift
//  OsaurusCore — Computer Use
//
//  Intel (docs/W_COMPUTER_USE_PLAN.md, stage 1): only upstream's `CaptureMode`
//  enum, which the tests and driver contract use. Upstream's set-of-mark builder
//  (`SOMResult`, `buildCapture`) in the same file arrives with the native driver
//  in stage 3.
//

import Foundation

// `.ax` is the accessibility tree only (no Screen Recording permission),
// `.vision` a screenshot only, `.som` the tree plus a screenshot with element
// numbers drawn on it (default).
enum CaptureMode: String, Codable, Sendable {
    case ax
    case vision
    case som

    static let `default`: CaptureMode = .som

    static func parse(_ raw: String?) -> CaptureMode {
        guard let raw = raw?.lowercased() else { return .default }
        return CaptureMode(rawValue: raw) ?? .default
    }
}
