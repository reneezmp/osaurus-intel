//
//  ChatSessionDataProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on ChatSessionData.
//

import Foundation

protocol ChatSessionDataProtocol: Identifiable, Sendable {
    var id: UUID { get }
    var title: String { get set }
    var createdAt: Date { get }
    var updatedAt: Date { get set }
    var agentId: UUID { get }
    var source: Any? { get }
    var sourcePluginId: String? { get }
    var externalSessionKey: String? { get }
    var dispatchTaskId: String? { get }
    var archived: Bool { get set }
    var selectedModel: String? { get set }
    var turns: [any ChatTurnProtocol] { get }

    static func generateTitle(from turnData: [any ChatTurnProtocol]) -> String
}
