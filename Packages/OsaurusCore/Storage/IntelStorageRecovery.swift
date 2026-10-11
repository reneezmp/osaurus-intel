//
//  IntelStorageRecovery.swift
//  osaurus
//
//  W-storage-health (2026-10-11): upstream's `StorageRecoveryService`
//  (Retry / Reset for a store that can't be opened) over Intel's own stores.
//  Upstream's store list is mostly databases Intel doesn't compile (SQLite
//  chat history, methods, tool index, agent channels), and its reset uses
//  `StorageMutationGate` + `StorageFile.quarantine`; Intel quiesces with
//  `OsaurusDatabaseHandle.withAllHandlesQuiesced`, the path key rotation
//  already uses. Every Intel store is SQLCipher-encrypted, so a lost or
//  mismatched storage key is the common cause.
//
//  - `probe()`   : try to open each store that isn't open, recording failures
//                  in upstream's `PersistenceHealth` (and clearing them on
//                  success). Run by the Storage page.
//  - `retry`     : re-attempt the open (keychain unlocked, signing fixed).
//  - `reset`     : move the unreadable file and its sidecars to
//                  `~/.osaurus/quarantine/<timestamp>-<store>/` (never
//                  deleted) and open a fresh, empty store.
//
//  The knowledge index is not listed: it is derived data and rebuilds itself
//  (`KnowledgeDatabase.openOrRecoverDerivedIndex`).
//

import Foundation

enum IntelStorageRecovery {
    enum Store: String, CaseIterable, Sendable {
        case memory
        case scheduler
        case activityLog = "activity-log"
        case routerBilling = "router-billing"
        case fileHistory = "file-history"
        case knowledgeWriteLog = "knowledge-write-log"

        var displayName: String {
            switch self {
            case .memory: return "Memory"
            case .scheduler: return "Schedules and run history"
            case .activityLog: return "Activity log"
            case .routerBilling: return "Router billing"
            case .fileHistory: return "File history"
            case .knowledgeWriteLog: return "Knowledge write log"
            }
        }

        var path: String {
            switch self {
            case .memory: return OsaurusPaths.memoryDatabaseFile().path
            case .scheduler: return OsaurusPaths.schedulerDatabaseFile().path
            case .activityLog: return OsaurusPaths.activityLogDatabaseFile().path
            case .routerBilling: return OsaurusPaths.billingLedgerDatabaseFile().path
            case .fileHistory: return OsaurusPaths.fileHistoryDatabaseFile().path
            case .knowledgeWriteLog: return OsaurusPaths.knowledgeWriteLogDatabaseFile().path
            }
        }

        /// Extra files that belong to the store besides SQLite's sidecars.
        var extraFiles: [String] {
            switch self {
            case .activityLog: return [OsaurusPaths.activityLogHeadFile().path]
            default: return []
            }
        }

        var isOpen: Bool {
            switch self {
            case .memory: return MemoryDatabase.shared.isOpen
            case .scheduler: return SchedulerDatabase.shared.isOpen
            case .activityLog: return ActivityLogStore.shared.isOpen
            case .routerBilling: return RouterBillingDatabase.shared.isOpen
            case .fileHistory: return FileHistoryDatabase.shared.isOpen
            case .knowledgeWriteLog: return KnowledgeWriteLogDatabase.shared.isOpen
            }
        }

        func open() throws {
            switch self {
            case .memory: try MemoryDatabase.shared.open()
            case .scheduler: try SchedulerDatabase.shared.open()
            case .activityLog: try ActivityLogStore.shared.open()
            case .routerBilling: try RouterBillingDatabase.shared.open()
            case .fileHistory: try FileHistoryDatabase.shared.open()
            case .knowledgeWriteLog: try KnowledgeWriteLogDatabase.shared.open()
            }
        }

        func close() {
            switch self {
            case .memory: MemoryDatabase.shared.close()
            case .scheduler: SchedulerDatabase.shared.close()
            case .activityLog: ActivityLogStore.shared.close()
            case .routerBilling: RouterBillingDatabase.shared.close()
            case .fileHistory: FileHistoryDatabase.shared.close()
            case .knowledgeWriteLog: KnowledgeWriteLogDatabase.shared.close()
            }
        }
    }

    /// Try every store that isn't open; record failures, clear recoveries.
    /// A store that has never been created opens empty, which is fine.
    static func probe() {
        for store in Store.allCases where !store.isOpen {
            _ = retry(store)
        }
    }

    /// Re-attempt opening `store`. Returns true on success.
    @discardableResult
    static func retry(_ store: Store) -> Bool {
        do {
            try store.open()
            PersistenceHealth.shared.clearStoreIssue(store: store.rawValue)
            return true
        } catch {
            PersistenceHealth.shared.recordDatabaseOpenFailure(
                subsystem: store.rawValue, error: error, path: store.path)
            return false
        }
    }

    /// Quarantine `store` (never deleted) and open a fresh one. Returns the
    /// quarantine folder, or nil when nothing was on disk to move.
    @discardableResult
    static func reset(_ store: Store, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let destination = OsaurusPaths.root()
            .appendingPathComponent("quarantine", isDirectory: true)
            .appendingPathComponent("\(stamp)-\(store.rawValue)", isDirectory: true)
        let candidates = [store.path, store.path + "-wal", store.path + "-shm", store.path + "-journal"]
            + store.extraFiles
        var moved = false
        OsaurusDatabaseHandle.withAllHandlesQuiesced {
            store.close()
            for path in candidates where fm.fileExists(atPath: path) {
                do {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    try fm.moveItem(
                        atPath: path,
                        toPath: destination.appendingPathComponent((path as NSString).lastPathComponent).path)
                    moved = true
                } catch {
                    print("[IntelStorageRecovery] could not quarantine \(path): \(error)")
                }
            }
        }
        _ = retry(store)
        if moved {
            print("[IntelStorageRecovery] \(store.rawValue) reset; original kept in \(destination.path)")
        }
        return moved ? destination : nil
    }
}
