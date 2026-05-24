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
    case remote(String, UUID)
    case foundation

    var remoteProviderId: UUID? {
        if case .remote(_, let id) = self { return id }
        return nil
    }
}
