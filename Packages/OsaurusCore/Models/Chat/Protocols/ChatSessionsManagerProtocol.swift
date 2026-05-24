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
}
