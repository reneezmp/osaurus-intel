//
//  ChatConfigurationProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on ChatConfiguration.
//

import Foundation

protocol ChatConfigurationProtocol: Sendable {
    var disableTools: Bool { get }
    var maxToolAttempts: Int { get }
    var topPOverride: Double? { get }
    static func load() -> any ChatConfigurationProtocol
}
