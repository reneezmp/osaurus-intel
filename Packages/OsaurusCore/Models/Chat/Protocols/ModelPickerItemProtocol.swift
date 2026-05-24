//
//  ModelPickerItemProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on ModelPickerItem.
//

import Foundation

protocol ModelPickerItemProtocol: Identifiable, Sendable {
    var id: String { get }
    var source: ModelPickerSource { get }
    var isVLM: Bool { get }
}

enum ModelPickerSource: Sendable {
    case builtIn
    case remote(providerId: String, modelId: String)
    case foundation
}

extension Array where Element == any ModelPickerItemProtocol {
    var firstChatCapable: (any ModelPickerItemProtocol)? {
        first { !$0.isVLM }
    }
}
