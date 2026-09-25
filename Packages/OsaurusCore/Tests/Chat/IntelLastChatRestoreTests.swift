//
//  IntelLastChatRestoreTests.swift
//  osaurusTests
//
//  Intel analogue of upstream c240123ed (persist open chat tabs): the saved
//  chat a window last showed is reopened, once, when chat is next summoned
//  with no window open. Uses a private defaults suite, never the live one.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct IntelLastChatRestoreTests {

    nonisolated private static func makeStore() -> (IntelLastChatStore, UserDefaults, String) {
        let suite = "osaurus-last-chat-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (IntelLastChatStore(defaults: defaults), defaults, suite)
    }

    @Test
    func rememberedChatIsTakenExactlyOnce() {
        let (store, defaults, suite) = Self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        store.record(id)
        #expect(store.take() == id)
        #expect(store.take() == nil)
    }

    @Test
    func restoresAnExistingChatAndSkipsADeletedOne() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-last-chat-tests-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                ChatSessionsManager.shared.refresh()
            }
            let (store, defaults, suite) = Self.makeStore()
            defer { defaults.removePersistentDomain(forName: suite) }

            let manager = ChatSessionsManager.shared
            let id = manager.createNew()
            let session = try #require(manager.session(for: id))
            manager.save(session)

            store.record(id)
            let restored = await MainActor.run { ChatWindowManager.restorableLastChat(from: store)?.id }
            #expect(restored == id)

            store.record(id)
            manager.delete(id: id)
            let afterDelete = await MainActor.run { ChatWindowManager.restorableLastChat(from: store)?.id }
            #expect(afterDelete == nil)
            #expect(store.take() == nil)
        }
    }
}
