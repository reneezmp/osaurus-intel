//
//  KnowledgeCurationService.swift
//  osaurus
//
//  Intel: the ticket half of upstream's `KnowledgeCurationService`. Upstream
//  keeps its proposal approval for proposals made before direct writes
//  replaced that queue; Intel never had proposals, so only the user's ticket
//  decisions live here. Documents are changed by the write tools
//  (`KnowledgeWriteService`), never by this service.
//  See docs/KNOWLEDGE_WRITE_INTEL.md.
//

import Foundation

/// Upstream error type; Intel uses only `writeFailed` (git clone failures).
public enum KnowledgeCurationError: Error, LocalizedError {
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let message): return "Could not write the document: \(message)"
        }
    }
}

public actor KnowledgeCurationService {
    public static let shared = KnowledgeCurationService()

    private init() {}

    /// Dismiss a ticket without action (false positive, won't fix).
    public func dismissTicket(ticketId: Int) async throws {
        try KnowledgeDatabase.shared.updateTicketStatus(id: ticketId, status: .dismissed)
        Self.postCurationChanged()
    }

    /// Mark a ticket fixed (the user confirmed the document was updated).
    public func resolveTicket(ticketId: Int) async throws {
        try KnowledgeDatabase.shared.updateTicketStatus(id: ticketId, status: .resolved)
        Self.postCurationChanged()
    }

    private static func postCurationChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .knowledgeCurationChanged, object: nil)
        }
    }
}
