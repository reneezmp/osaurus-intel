//
//  ChatWindowManagerProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on ChatWindowManager.
//

import Foundation

protocol ChatWindowManagerProtocol: AnyObject {
    func activeLocalModelNames() -> [String]
    func createWindow(agentId: UUID, sessionData: (any ChatSessionDataProtocol)?) -> UUID
    func closeWindow(id: UUID)
    func setCloseCallback(for windowId: UUID, callback: @escaping () -> Void)
    func getNSWindow(id: UUID) -> AnyObject?
}
