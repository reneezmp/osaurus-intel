//
//  IntelPluginDatabaseTests.swift
//  OsaurusCoreTests
//
//  `W-plugin-reliability` stage 2b (docs/UPSTREAM_SYNC.md, "Plugin
//  database"). Upstream's `PluginDatabaseTests` runs from
//  `PluginTests.swift` (included since stage 2f; until then a copy lived
//  here). `IntelPluginDatabaseMoveTests` pins the
//  one-time move of Intel's old plaintext `Tools/<id>/plugin.db` into the
//  encrypted `Tools/<id>/data/data.db`, the host context's lifecycle, and
//  key rotation's lock.
//
//  Files live under a temporary root set through `OsaurusPaths.overrideRoot`
//  inside `StoragePathsTestLock`, with a test storage key; never the
//  Keychain, never `~/.osaurus`.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelPluginDatabaseMoveTests {

    private static func withTempRoot(_ body: @escaping @Sendable (URL) throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-plugin-db-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            StorageKeyManager.shared._setKeyForTesting(SymmetricKey(data: Data(repeating: 0x3A, count: 32)))
            defer {
                OsaurusPaths.overrideRoot = nil
                try? FileManager.default.removeItem(at: root)
                StorageKeyManager.shared.wipeCache()
            }
            #expect(OsaurusPaths.tools().path.hasPrefix(root.path), "plugin files live under the temporary root")
            try body(root)
        }
    }

    /// Writes an old-style plaintext database with `rows` memos, the way
    /// Intel's host (and the `memo` plugin) used to.
    private static func writeLegacy(pluginId: String, rows: Int) throws {
        let url = IntelPluginDatabaseMigration.legacyFile(for: pluginId)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var sql = "CREATE TABLE memos(id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, created INTEGER);"
        for i in 0 ..< rows { sql += "INSERT INTO memos(text, created) VALUES('memo \(i)', \(i));" }
        sql += "CREATE TABLE empty_table(x INTEGER);"
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func oldPlaintextDatabaseMovesInOnFirstOpen() async throws {
        try await Self.withTempRoot { _ in
            let pluginId = "memo-intel"
            try Self.writeLegacy(pluginId: pluginId, rows: 3)

            let db = PluginDatabase(pluginId: pluginId)
            try db.open()
            defer { db.close() }

            let reply = db.query(sql: "SELECT text FROM memos ORDER BY id", paramsJSON: nil)
            #expect(reply.contains("\"memo 0\"") && reply.contains("\"memo 2\""), "\(reply)")
            #expect(db.query(sql: "SELECT count(*) FROM empty_table", paramsJSON: nil).contains("[[0]]"))

            let legacy = IntelPluginDatabaseMigration.legacyFile(for: pluginId).path
            let moved = OsaurusPaths.pluginDatabaseFile(for: pluginId).path
            #expect(!FileManager.default.fileExists(atPath: legacy), "the plaintext copy is removed")
            #expect(FileManager.default.fileExists(atPath: moved))
            #expect(EncryptedSQLiteOpener.isEncryptedDatabase(path: moved))
            #expect(
                StorageMigrator.databaseTargets().contains { $0.pluginId == pluginId },
                "key rotation and the mismatch check now see the plugin's database")

            // New writes land in the moved database.
            #expect(db.exec(sql: "INSERT INTO memos(text) VALUES(?)", paramsJSON: #"["after"]"#)
                .contains("\"changes\":1"))
        }
    }

    @Test func moveReportsWhatItDid() async throws {
        try await Self.withTempRoot { _ in
            let key = try StorageKeyManager.shared.currentKey()
            #expect(try IntelPluginDatabaseMigration.migrateLegacyIfNeeded(pluginId: "none", key: key) == .nothingToMove)

            try Self.writeLegacy(pluginId: "counted", rows: 4)
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.pluginDataDirectory(for: "counted"))
            #expect(
                try IntelPluginDatabaseMigration.migrateLegacyIfNeeded(pluginId: "counted", key: key)
                    == .moved(tables: 2, rows: 4))
        }
    }

    /// Both files present: the encrypted one wins and the old one is left
    /// alone, never merged or deleted.
    @Test func existingEncryptedDatabaseIsKept() async throws {
        try await Self.withTempRoot { _ in
            let pluginId = "both"
            let fresh = PluginDatabase(pluginId: pluginId)
            try fresh.open()
            _ = fresh.exec(sql: "CREATE TABLE current(x INTEGER)", paramsJSON: nil)
            fresh.close()
            try Self.writeLegacy(pluginId: pluginId, rows: 1)

            let db = PluginDatabase(pluginId: pluginId)
            try db.open()
            defer { db.close() }
            #expect(!db.query(sql: "SELECT * FROM current", paramsJSON: nil).contains("error"))
            #expect(db.query(sql: "SELECT * FROM memos", paramsJSON: nil).contains("error"))
            #expect(FileManager.default.fileExists(atPath: IntelPluginDatabaseMigration.legacyFile(for: pluginId).path))
        }
    }

    /// A move that fails leaves the old file untouched and fails the open,
    /// so the plugin gets an error rather than an empty database.
    @Test func failedMoveKeepsTheOldFileAndFailsTheOpen() async throws {
        try await Self.withTempRoot { _ in
            let pluginId = "broken"
            let legacy = IntelPluginDatabaseMigration.legacyFile(for: pluginId)
            try FileManager.default.createDirectory(
                at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
            let garbage = Data("not a database".utf8)
            try garbage.write(to: legacy)

            let db = PluginDatabase(pluginId: pluginId)
            #expect(throws: PluginDatabaseError.self) { try db.open() }
            #expect(try Data(contentsOf: legacy) == garbage)
            #expect(!FileManager.default.fileExists(atPath: OsaurusPaths.pluginDatabaseFile(for: pluginId).path))
            #expect(db.query(sql: "SELECT 1", paramsJSON: nil).contains("Database not open"))
        }
    }

    /// Plugin SQL goes through upstream's `PluginHostContext`: lazy open on
    /// first call, refused after teardown.
    @Test func hostContextOpensLazilyAndRefusesAfterTeardown() async throws {
        try await Self.withTempRoot { _ in
            let ctx = try PluginHostContext(pluginId: "ctx-db")
            let path = OsaurusPaths.pluginDatabaseFile(for: "ctx-db").path
            #expect(!FileManager.default.fileExists(atPath: path), "no file until the plugin uses SQL")

            #expect(ctx.dbExec(sql: "CREATE TABLE t(x INTEGER)", paramsJSON: nil).contains("\"changes\""))
            #expect(ctx.dbExec(sql: "INSERT INTO t VALUES(?)", paramsJSON: "[7]").contains("\"changes\":1"))
            #expect(ctx.dbQuery(sql: "SELECT x FROM t", paramsJSON: nil).contains("[[7]]"))
            #expect(ctx.dbExec(sql: "ATTACH DATABASE '/tmp/x.db' AS x", paramsJSON: nil).contains("Forbidden"))
            #expect(EncryptedSQLiteOpener.isEncryptedDatabase(path: path))

            ctx.teardown()
            #expect(ctx.dbQuery(sql: "SELECT x FROM t", paramsJSON: nil).contains("shutting down"))
        }
    }

    /// Key rotation closes open plugin databases and holds their reopen
    /// until it's done; the next plugin call reopens.
    @Test func storageMutationClosesAndTheNextCallReopens() async throws {
        try await Self.withTempRoot { _ in
            let ctx = try PluginHostContext(pluginId: "rotating")
            defer { ctx.teardown() }
            _ = ctx.dbExec(sql: "CREATE TABLE t(x INTEGER)", paramsJSON: nil)
            _ = ctx.dbExec(sql: "INSERT INTO t VALUES(1)", paramsJSON: nil)

            PluginDatabase.withStorageMutation {
                #expect(ctx.database.query(sql: "SELECT x FROM t", paramsJSON: nil).contains("Database not open"))
            }
            #expect(ctx.dbQuery(sql: "SELECT x FROM t", paramsJSON: nil).contains("[[1]]"))
        }
    }
}
