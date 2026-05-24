//
//  SharedArtifactProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on SharedArtifact.
//

import Foundation

protocol SharedArtifactProtocol {
    static func fromEnrichedToolResult(_ resultText: String) -> Any?
}
