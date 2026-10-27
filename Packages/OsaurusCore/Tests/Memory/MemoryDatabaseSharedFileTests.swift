//
//  MemoryDatabaseSharedFileTests.swift
//  osaurusTests
//
//  Intel (2026-10-27, `W-memory-db-sync`): Intel and upstream builds can open
//  the same `memory.sqlite` (a dev Mac that also runs the upstream app, or a
//  Migration Assistant copy). These tests pin what that requires:
//
//    * a file stamped newer than this build is refused (upstream #1323 /
//      #1635), the connection is closed, and the refusal is classified as a
//      harmless downgrade, never as a migration fault that invites Reset;
//    * a file the upstream app stamped v10 gets Intel's embedding columns,
//      which used to be Intel's own v8/v9 and were skipped on such a file;
//    * a file an older Intel build stamped v9 (embedding columns, no
//      `attempts`) moves to v10 without losing rows.
//
//  Every file lives under a temporary root set through
//  `OsaurusPaths.overrideRoot` inside `StoragePathsTestLock`, deleted after.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct MemoryDatabaseSharedFileTests {

    private static func withTempRoot(_ body: @escaping @Sendable (String) throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-memory-shared-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            StorageKeyManager.shared._setKeyForTesting(SymmetricKey(data: Data(repeating: 0x5C, count: 32)))
            defer {
                OsaurusPaths.overrideRoot = nil
                try? FileManager.default.removeItem(at: root)
                StorageKeyManager.shared.wipeCache()
            }
            let path = OsaurusPaths.memoryDatabaseFile().path
            #expect(path.hasPrefix(root.path), "the memory file lives under the temporary root")
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.memory())
            try body(path)
        }
    }

    /// Runs SQL against the file with the same key the store uses.
    private static func raw(_ path: String, _ sql: String) throws {
        let connection = try EncryptedSQLiteOpener.open(path: path, key: try StorageKeyManager.shared.currentKey())
        defer { sqlite3_close(connection) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(connection, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw MemoryDatabaseError.failedToExecute(message)
        }
    }

    private static func intValue(_ path: String, _ sql: String) throws -> Int {
        let connection = try EncryptedSQLiteOpener.open(path: path, key: try StorageKeyManager.shared.currentKey())
        defer { sqlite3_close(connection) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw MemoryDatabaseError.failedToPrepare(sql)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private static func columns(_ path: String, table: String) throws -> Set<String> {
        let connection = try EncryptedSQLiteOpener.open(path: path, key: try StorageKeyManager.shared.currentKey())
        defer { sqlite3_close(connection) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK,
            let stmt
        else { throw MemoryDatabaseError.failedToPrepare(table) }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            names.insert(String(cString: sqlite3_column_text(stmt, 1)))
        }
        return names
    }

    private static let embeddingTables = ["transcript", "episodes", "pinned_facts"]
    private static let embeddingColumns: Set<String> = ["embedding", "embedding_dim", "embedding_provider"]

    @Test func newerFileIsRefusedClosedAndClassifiedAsDowngrade() async throws {
        try await Self.withTempRoot { path in
            let first = MemoryDatabase()
            try first.open()
            #expect(first.schemaUserVersion() == MemoryDatabase.expectedSchemaVersion)
            #expect(MemoryDatabase.expectedSchemaVersion == 10)
            first.close()

            try Self.raw(path, "PRAGMA user_version = 11")

            let db = MemoryDatabase()
            var thrown: Error?
            do { try db.open() } catch { thrown = error }
            let error = try #require(thrown)
            guard case MemoryDatabaseError.databaseFromNewerVersion(let found, let expected) = error else {
                Issue.record("expected the forward-version refusal, got \(error)")
                return
            }
            #expect(found == 11)
            #expect(expected == 10)
            #expect(!db.isOpen, "the half-opened connection is closed, so a retry can't no-op into success")
            #expect(db.lastOpenErrorDescription?.contains("v11") == true)
            #expect(StorageOpenIssueKind.classify(error) == .forwardVersion)
            #expect(MemoryDatabaseError.failedToOpen("x").isForwardVersion == false)

            // The newer file is left exactly as found.
            #expect(try Self.intValue(path, "PRAGMA user_version") == 11)
        }
    }

    @Test func upstreamStampedV10FileGetsIntelEmbeddingColumns() async throws {
        try await Self.withTempRoot { path in
            // Build a v10 file, then strip Intel's columns: what the upstream
            // app leaves behind when it created the file.
            let seed = MemoryDatabase()
            try seed.open()
            seed.close()
            for table in Self.embeddingTables {
                for column in Self.embeddingColumns {
                    try Self.raw(path, "ALTER TABLE \(table) DROP COLUMN \(column)")
                }
            }
            for table in Self.embeddingTables {
                #expect(try Self.columns(path, table: table).isDisjoint(with: Self.embeddingColumns))
            }
            #expect(try Self.intValue(path, "PRAGMA user_version") == 10)

            let db = MemoryDatabase()
            try db.open()
            defer { db.close() }
            for table in Self.embeddingTables {
                #expect(
                    try Self.columns(path, table: table).isSuperset(of: Self.embeddingColumns),
                    "\(table) has Intel's embedding columns")
            }
            #expect(db.schemaUserVersion() == 10, "Intel's columns never bump the shared version")

            // The embedding write path works on the formerly-upstream file.
            try db.insertTranscriptTurn(
                agentId: "a", conversationId: "c", chunkIndex: 0, role: "user", content: "hello", tokenCount: 1)
            try db.setTranscriptEmbedding(
                agentId: "a", conversationId: "c", chunkIndex: 0, embedding: [0.1, 0.2], provider: "test")
            #expect(try db.loadEmbeddedTranscript(agentId: "a", days: 1, limit: 10).count == 1)
        }
    }

    @Test func olderIntelV9FileMovesToV10AndKeepsRows() async throws {
        try await Self.withTempRoot { path in
            // An older Intel build's v9: embedding columns present, no
            // `pending_signals.attempts`, version 9.
            let seed = MemoryDatabase()
            try seed.open()
            try seed.insertPendingSignal(PendingSignal(agentId: "a", conversationId: "c", userMessage: "kept"))
            seed.close()
            try Self.raw(path, "ALTER TABLE pending_signals DROP COLUMN attempts")
            try Self.raw(path, "PRAGMA user_version = 9")
            #expect(try !Self.columns(path, table: "pending_signals").contains("attempts"))

            let db = MemoryDatabase()
            try db.open()
            defer { db.close() }
            #expect(db.schemaUserVersion() == 10)
            #expect(try Self.columns(path, table: "pending_signals").contains("attempts"))
            let pending = try db.loadPendingSignals(conversationId: "c")
            #expect(pending.map(\.userMessage) == ["kept"])
            #expect(try db.recordDistillFailure(ids: pending.map(\.id), maxAttempts: 3).attempts == 1)
        }
    }
}
