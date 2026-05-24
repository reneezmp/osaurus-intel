//
//  ContentBlockProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on ContentBlock.
//

import Foundation

protocol ContentBlockProtocol: Identifiable, Sendable {
    var id: String { get }
}
