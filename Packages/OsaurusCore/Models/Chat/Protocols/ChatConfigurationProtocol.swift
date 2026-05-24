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
    var systemPrompt: String { get }
    var temperature: Float? { get }
    var maxTokens: Int? { get }
    var contextLength: Int? { get }
    var defaultModel: String? { get }
    var generativeGreetingsEnabled: Bool { get }
    static func load() -> any ChatConfigurationProtocol
}
