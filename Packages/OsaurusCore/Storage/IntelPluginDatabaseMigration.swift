//
//  IntelPluginDatabaseMigration.swift
//  osaurus
//
//  `W-plugin-reliability` stage 2b (docs/UPSTREAM_SYNC.md, "Plugin
//  database"). Until 2026-11-05 Intel's plugin host kept each plugin's
//  `db_exec` / `db_query` data in a plaintext SQLite file,
//  `~/.osaurus/Tools/<id>/plugin.db`. Upstream's `PluginDatabase` keeps it
//  encrypted with the storage key at `Tools/<id>/data/data.db`, the path
//  Intel's key rotation, mismatch check and orphan cleanup already walk.
//
//  On a plugin's first database open, this moves the old file over once:
//  `sqlcipher_export` into a temporary encrypted file (the same export
//  `StorageMigrator` uses for the core stores), a per-table row-count check
//  against the original, a rename into place, and only then removal of the
//  plaintext file and its journal. Any failure leaves the plaintext file
//  untouched and fails the open, so the plugin sees an error instead of an
//  empty database and the move is retried on its next call.
//

#if OSAURUS_INTEL

import CryptoKit
import Foundation
import OsaurusSQLCipher
import os

enum IntelPluginDatabaseMigration {
    enum Outcome: Equatable {
        /// No old plaintext file.
        case nothingToMove
        /// Moved: the old file's tables and rows are in `data.db`.
        case moved(tables: Int, rows: Int)
        /// Both files exist; the old one is left alone, never merged.
        case keptBesideExisting
    }

    struct MigrationError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { "Moving the plugin's old database failed: \(message)" }
    }

    private static let log = Logger(subsystem: "com.osaurus.intel", category: "plugin-db-migration")

    /// Intel's pre-2b plaintext file.
    static func legacyFile(for pluginId: String) -> URL {
        OsaurusPaths.pluginDirectory(for: pluginId).appendingPathComponent("plugin.db")
    }

    /// Called by `PluginDatabase.open()` on the database queue, before the
    /// encrypted file is opened.
    @discardableResult
    static func migrateLegacyIfNeeded(pluginId: String, key: SymmetricKey) throws -> Outcome {
        let fm = FileManager.default
        let legacy = legacyFile(for: pluginId).path
        guard fm.fileExists(atPath: legacy) else { return .nothingToMove }
        let target = OsaurusPaths.pluginDatabaseFile(for: pluginId).path
        if fm.fileExists(atPath: target) {
            log.warning("plugin \(pluginId, privacy: .public): data.db already exists; old plugin.db left in place")
            return .keptBesideExisting
        }

        let temp = target + ".intel-migrate.tmp"
        removeWithSidecars(temp)

        // ATTACH inherits the main connection's flags, so CREATE is needed
        // for the export target (the old file itself already exists).
        var source: OpaquePointer?
        guard sqlite3_open_v2(legacy, &source, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
            let source
        else {
            let message = source.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let source { sqlite3_close(source) }
            throw MigrationError(message: "open: \(message)")
        }
        defer { sqlite3_close(source) }

        let sourceCounts: [String: Int64]
        do {
            sourceCounts = try tableRowCounts(source)
            try export(source: source, to: temp, key: key)
        } catch {
            removeWithSidecars(temp)
            throw error
        }

        // Read back the encrypted copy with the storage key, as
        // `PluginDatabase` will, and compare every table.
        do {
            let copy = try EncryptedSQLiteOpener.open(path: temp, key: key, applyPerfPragmas: false)
            defer { sqlite3_close(copy) }
            let copyCounts = try tableRowCounts(copy)
            guard copyCounts == sourceCounts else {
                throw MigrationError(message: "row counts differ after export")
            }
        } catch {
            removeWithSidecars(temp)
            throw (error as? MigrationError) ?? MigrationError(message: "verify: \(error.localizedDescription)")
        }

        do {
            try fm.moveItem(atPath: temp, toPath: target)
        } catch {
            removeWithSidecars(temp)
            throw MigrationError(message: "rename: \(error.localizedDescription)")
        }
        removeWithSidecars(legacy)

        let rows = sourceCounts.values.reduce(0, +)
        log.info(
            "plugin \(pluginId, privacy: .public): moved plugin.db into encrypted data.db (\(sourceCounts.count) tables, \(rows) rows)"
        )
        return .moved(tables: sourceCounts.count, rows: Int(rows))
    }

    // MARK: - Helpers

    /// `sqlcipher_export` of the plaintext `source` into a new encrypted file
    /// (`StorageMigrator.migrateOneDatabase`'s recipe), keeping `user_version`.
    private static func export(source: OpaquePointer, to path: String, key: SymmetricKey) throws {
        let keyHex = key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        let escaped = path.replacingOccurrences(of: "'", with: "''")
        try exec(source, "ATTACH DATABASE '\(escaped)' AS encrypted KEY \"x'\(keyHex)'\"", step: "attach")
        defer { _ = sqlite3_exec(source, "DETACH DATABASE encrypted", nil, nil, nil) }
        for pragma in [
            "PRAGMA encrypted.cipher_memory_security = OFF",
            "PRAGMA encrypted.cipher_page_size = 4096",
            "PRAGMA encrypted.kdf_iter = 256000",
        ] {
            _ = sqlite3_exec(source, pragma, nil, nil, nil)
        }
        try exec(source, "SELECT sqlcipher_export('encrypted')", step: "export")

        var version: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(source, "PRAGMA main.user_version", -1, &stmt, nil) == SQLITE_OK,
            sqlite3_step(stmt) == SQLITE_ROW
        {
            version = sqlite3_column_int(stmt, 0)
        }
        sqlite3_finalize(stmt)
        if version > 0 {
            try exec(source, "PRAGMA encrypted.user_version = \(version)", step: "user_version")
        }
    }

    private static func exec(_ connection: OpaquePointer, _ sql: String, step: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(connection, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(connection))
            sqlite3_free(error)
            throw MigrationError(message: "\(step): \(message)")
        }
    }

    /// Row count of every user table in the main database.
    static func tableRowCounts(_ connection: OpaquePointer) throws -> [String: Int64] {
        var names: [String] = []
        var stmt: OpaquePointer?
        let list = "SELECT name FROM main.sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        guard sqlite3_prepare_v2(connection, list, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError(message: "list tables: \(String(cString: sqlite3_errmsg(connection)))")
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) { names.append(String(cString: text)) }
        }
        sqlite3_finalize(stmt)

        var counts: [String: Int64] = [:]
        for name in names {
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            var countStmt: OpaquePointer?
            guard sqlite3_prepare_v2(connection, "SELECT count(*) FROM main.\(quoted)", -1, &countStmt, nil)
                == SQLITE_OK,
                sqlite3_step(countStmt) == SQLITE_ROW
            else {
                sqlite3_finalize(countStmt)
                throw MigrationError(message: "count \(name): \(String(cString: sqlite3_errmsg(connection)))")
            }
            counts[name] = sqlite3_column_int64(countStmt, 0)
            sqlite3_finalize(countStmt)
        }
        return counts
    }

    private static func removeWithSidecars(_ path: String) {
        for suffix in ["", "-journal", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }
}

#endif
