//
//  ToolRegistryProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on ToolRegistry.
//

import Foundation

protocol ToolRegistryProtocol: AnyObject {
    func resolveExecutionMode(folderContext: FolderContext?, autonomousEnabled: Bool) -> ExecutionMode
    func execute(name: String, argumentsJSON: String) async throws -> String
}
