//
//  IntelLastChatStore.swift
//  OsaurusCore (Intel fork)
//
//  Intel analogue of upstream `ChatTabLayoutStore` (c240123ed). Intel chat
//  windows hold one conversation each (no tabs), so the durable fact worth
//  keeping across a window close or relaunch is which saved chat was last
//  showing. Only the id is stored; the transcript stays in
//  `ChatSessionsManager`. Blank chats are never recorded.
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

    /// Remember `sessionId` as the most recently closed chat.
    func record(_ sessionId: UUID) {
        defaults.set(sessionId.uuidString, forKey: Self.defaultsKey)
    }

    /// Return and forget the remembered chat, so it is restored only once.
    func take() -> UUID? {
        defer { defaults.removeObject(forKey: Self.defaultsKey) }
        return defaults.string(forKey: Self.defaultsKey).flatMap(UUID.init(uuidString:))
    }
}

#endif
