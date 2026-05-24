//
//  ChatSessionsManagerProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on ChatSessionsManager.
//

import Foundation

protocol ChatSessionsManagerProtocol: AnyObject {
    func save(_ data: any ChatSessionDataProtocol)
    func delete(id: UUID)
    func rename(id: UUID, title: String)
    func setArchived(id: UUID, archived: Bool)
    func refresh()
    func createNew(selectedModel: String?, agentId: UUID?) -> UUID
    func sessions(for agentId: UUID?) -> [any ChatSessionDataProtocol]
    func session(for id: UUID) -> (any ChatSessionDataProtocol)?
}
