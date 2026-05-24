//
//  ModelPickerItemCacheProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on ModelPickerItemCache.
//

import Foundation

protocol ModelPickerItemCacheProtocol: AnyObject {
    var isLoaded: Bool { get }
    var items: [ModelPickerItem] { get }
    func buildModelPickerItems() async -> [ModelPickerItem]
}
