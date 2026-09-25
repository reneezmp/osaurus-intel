//
//  RecentFoldersStoreTests.swift
//  osaurusTests
//
//  Upstream 3034800ef, Intel adaptation (path-only entries). Uses a private
//  defaults suite, never the live one.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct RecentFoldersStoreTests {

    private func makeStore() -> (RecentFoldersStore, UserDefaults, String) {
        let suite = "osaurus-recent-folders-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (RecentFoldersStore(defaults: defaults), defaults, suite)
    }

    @Test func mostRecentFirstDedupedAndCapped() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        for i in 1...7 { store.record(path: "/tmp/f\(i)") }
        store.record(path: "/tmp/f5/")
        #expect(store.entries.map(\.path) == ["/tmp/f5", "/tmp/f7", "/tmp/f6", "/tmp/f4", "/tmp/f3"])
        #expect(store.entries.count == RecentFoldersStore.limit)
    }

    @Test func persistsAcrossInstancesAndRemoves() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.record(path: "/tmp/a")
        store.record(path: "/tmp/b")
        let reloaded = RecentFoldersStore(defaults: defaults)
        #expect(reloaded.entries.map(\.path) == ["/tmp/b", "/tmp/a"])
        reloaded.remove(path: "/tmp/b")
        #expect(RecentFoldersStore(defaults: defaults).entries.map(\.path) == ["/tmp/a"])
    }

    @Test func missingFolderDoesNotResolve() async {
        let entry = RecentFoldersStore.Entry(path: "/nonexistent-\(UUID().uuidString)")
        #expect(await RecentFoldersStore.resolveURL(for: entry) == nil)
    }
}
