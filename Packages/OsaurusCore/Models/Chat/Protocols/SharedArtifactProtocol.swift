//
//  SharedArtifactProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on SharedArtifact.
//

import Foundation

protocol SharedArtifactProtocol {
    static func processToolResultDetailed(
        _ text: String,
        contextId: UUID,
        contextType: String,
        executionMode: Any?,
        sandboxAgentName: String?
    ) -> String

    static func fromEnrichedToolResult(_ resultText: String) -> Any?
}

enum ResolutionFailure: Sendable {
    case notFound, ambiguous, sandboxRequired
}
