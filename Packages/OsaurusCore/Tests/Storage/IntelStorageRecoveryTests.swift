//
//  IntelStorageRecoveryTests.swift
//  osaurusTests
//
//  W-storage-health (2026-10-11): Retry records an unreadable store in
//  upstream's `PersistenceHealth`; Reset quarantines it (nothing deleted) and
//  opens a fresh one. Runs only under the test root (OSAURUS_TEST_ROOT).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelStorageRecoveryTests {
    @Test func retryRecordsAnUnreadableStore_resetQuarantinesAndRecovers() throws {
        let store = IntelStorageRecovery.Store.knowledgeWriteLog
        let fm = FileManager.default
        let root = OsaurusPaths.root().path
        #expect(store.path.hasPrefix(root), "the store lives under the test root")
        KnowledgeWriteLogDatabase.shared.close()
        defer {
            KnowledgeWriteLogDatabase.shared.close()
            PersistenceHealth.shared.clearStoreIssue(store: store.rawValue)
        }

        // A file that isn't a database where the store expects one.
        try fm.createDirectory(
            at: URL(fileURLWithPath: store.path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 8192).write(to: URL(fileURLWithPath: store.path))

        #expect(!IntelStorageRecovery.retry(store))
        let issue = try #require(PersistenceHealth.shared.storeIssue(for: store.rawValue))
        #expect(issue.kind != .forwardVersion)

        let quarantine = try #require(IntelStorageRecovery.reset(store))
        #expect(quarantine.path.hasPrefix(root + "/quarantine/"))
        let kept = quarantine.appendingPathComponent((store.path as NSString).lastPathComponent)
        #expect(fm.fileExists(atPath: kept.path), "the original is kept, not deleted")
        #expect(KnowledgeWriteLogDatabase.shared.isOpen, "a fresh store opened")
        #expect(PersistenceHealth.shared.storeIssue(for: store.rawValue) == nil)
    }

    @Test func forwardVersionIsNeverOfferedReset() {
        #expect(StorageSettingsView.issueKindCause(.forwardVersion).contains("Do not Reset"))
        #expect(StorageSettingsView.issueKindBadge(.locked) == "LOCKED")
    }
}
