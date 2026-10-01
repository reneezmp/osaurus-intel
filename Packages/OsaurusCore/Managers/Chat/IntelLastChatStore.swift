//
//  IntelLastChatStore.swift
//  OsaurusCore (Intel fork)
//
//  Migration only. Before chat tabs, Intel remembered the one saved chat a
//  closing window showed (key `intelLastOpenChat.v1`), as its analogue of
//  upstream `ChatTabLayoutStore` (c240123ed). Tabs replaced it with
//  `ChatTabLayoutStore`; the first window opened after the update takes
//  this id once (`ChatWindowManager.legacyLastChatRecord`) and the key is
//  removed. Nothing writes it any more.
//

#if OSAURUS_INTEL

import Foundation

/// `UserDefaults` is documented thread-safe but not marked `Sendable`.
struct IntelLastChatStore: @unchecked Sendable {
    static let shared = IntelLastChatStore()
    static let defaultsKey = "intelLastOpenChat.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Return and forget the remembered chat, so it is restored only once.
    func take() -> UUID? {
        defer { defaults.removeObject(forKey: Self.defaultsKey) }
        return defaults.string(forKey: Self.defaultsKey).flatMap(UUID.init(uuidString:))
    }
}

#endif
