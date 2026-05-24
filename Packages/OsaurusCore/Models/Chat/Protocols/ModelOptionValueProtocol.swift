//
//  ModelOptionValueProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on ModelOptionValue.
//

import Foundation

protocol ModelOptionValueProtocol: Sendable {
    var boolValue: Bool? { get }
}
