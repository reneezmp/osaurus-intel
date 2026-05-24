//
//  MemoryServiceProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on MemoryService.
//

import Foundation

protocol MemoryServiceProtocol: AnyObject {
    func bufferTurn(
        userMessage: String,
        assistantMessage: String,
        agentId: UUID,
        conversationId: UUID,
        sessionDate: Date
    ) async
}
