//
//  IntelKnowledgeWriteTests.swift
//  OsaurusCoreTests
//
//  `W-knowledge-write` (docs/KNOWLEDGE_WRITE_INTEL.md): the Intel wiring
//  around upstream's write tools — offered only with a collection grant, the
//  approval-card manifest hook, per-call deletes, dispatch through the
//  registry with the write log, and key rotation coverage. Upstream's own
//  suites cover the tools and the service.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@Suite("Intel knowledge writing", .serialized)
struct IntelKnowledgeWriteTests {
    private static let writeTools: Set<String> = ["write_knowledge", "edit_knowledge", "delete_knowledge"]

    @Test("Write tools are registered and follow the Knowledge grant set")
    func registration() {
        let names = Set(ToolRegistry.shared.listTools().map(\.name))
        #expect(Self.writeTools.isSubset(of: names))
        #expect(Self.writeTools.isSubset(of: ToolRegistry.knowledgeToolNames))
        #expect(ToolRegistry.shared.requiresApprovalEveryCall("delete_knowledge"))
        #expect(!ToolRegistry.shared.requiresApprovalEveryCall("write_knowledge"))
        #expect(ToolRegistry.shared.effectivePolicy(for: "write_knowledge", argumentsJSON: "{}") != .auto)
    }

    @Test("The write log follows a storage key rotation")
    func rotationCoverage() {
        let paths = StorageMigrator.databaseTargets().map(\.path)
        #expect(paths.contains(OsaurusPaths.knowledgeWriteLogDatabaseFile().path))
    }

    @MainActor
    @Test("Granted agent: offered, previewed, written with a revertable log; ungranted: none of it")
    func grantedWriteRoundTrip() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-kwrite-\(UUID().uuidString)", isDirectory: true)
            let folder = root.appendingPathComponent("notes", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "# Pantry\n\nRice.\n".write(
                to: folder.appendingPathComponent("pantry.md"), atomically: true, encoding: .utf8)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            StorageKeyManager.shared._setKeyForTesting(SymmetricKey(data: Data(repeating: 0x4B, count: 32)))
            AgentManager.shared.refresh()
            await KnowledgeManager.shared.reload()

            let collection = KnowledgeCollection(name: "Kitchen \(UUID().uuidString.prefix(4))", folderPath: folder.path)
            try KnowledgeCollectionStore.save(collection)
            await KnowledgeManager.shared.reload()
            let granted = Agent(name: "kw-granted", toolSelectionMode: .manual, manualToolNames: [])
            let ungranted = Agent(name: "kw-none", toolSelectionMode: .manual, manualToolNames: [])
            AgentManager.shared.add(granted)
            AgentManager.shared.add(ungranted)
            await MainActor.run {
                AgentManager.shared.updateKnowledgeSettings(
                    enabled: true, collectionIds: [collection.id], for: granted.id)
            }

            func cleanUp() async {
                KnowledgeWriteLogDatabase.shared.close()
                KnowledgeDatabase.shared.close()
                await MainActor.run { KnowledgeManager.shared.delete(id: collection.id) }
                _ = await AgentManager.shared.delete(id: granted.id)
                _ = await AgentManager.shared.delete(id: ungranted.id)
                StorageKeyManager.shared.wipeCache()
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }
            do {

            let offered = await SystemPromptComposer.composeChatContext(agentId: granted.id, query: "hi")
            #expect(Self.writeTools.isSubset(of: Set(offered.tools.map(\.function.name))))
            let hidden = await SystemPromptComposer.composeChatContext(agentId: ungranted.id, query: "hi")
            #expect(Set(hidden.tools.map(\.function.name)).isDisjoint(with: Self.writeTools))

            let args = ##"{"documents":[{"path":"pantry.md","content":"# Pantry\n\nRice and lentils.\n"}],"rationale":"add lentils"}"##
            let preview = await ChatExecutionContext.$currentAgentId.withValue(granted.id) {
                await ToolRegistry.shared.knowledgeWritePreview(for: "write_knowledge", argumentsJSON: args)
            }
            #expect(preview?.entries.first?.relPath == "pantry.md")
            #expect(await ToolRegistry.shared.knowledgeWritePreview(for: "read_knowledge", argumentsJSON: "{}") == nil)

            // Refused without a grant, even by exact call.
            let refused = try await ChatExecutionContext.$currentAgentId.withValue(ungranted.id) {
                try await ToolRegistry.shared.execute(name: "write_knowledge", argumentsJSON: args)
            }
            #expect(ToolEnvelope.isError(refused), "\(refused)")
            #expect(try String(contentsOf: folder.appendingPathComponent("pantry.md"), encoding: .utf8) == "# Pantry\n\nRice.\n")

            // The approval is the engine's job; the registry call is what runs after "Allow".
            let written = try await ChatExecutionContext.$currentAgentId.withValue(granted.id) {
                try await ToolRegistry.shared.execute(name: "write_knowledge", argumentsJSON: args)
            }
            #expect(!ToolEnvelope.isError(written), "\(written)")
            #expect(try String(contentsOf: folder.appendingPathComponent("pantry.md"), encoding: .utf8).contains("lentils"))

            let record = try #require(try KnowledgeWriteLogDatabase.shared.recentRecords(limit: 5).first)
            #expect(record.relPath == "pantry.md" && record.operation == .replace)
            try await KnowledgeWriteService.shared.revert(recordId: record.id)
            #expect(try String(contentsOf: folder.appendingPathComponent("pantry.md"), encoding: .utf8) == "# Pantry\n\nRice.\n")

            // Tickets: any granted agent flags and claims (no curator flag on Intel).
            let flagged = try await ChatExecutionContext.$currentAgentId.withValue(granted.id) {
                try await ToolRegistry.shared.execute(
                    name: "flag_knowledge_stale",
                    argumentsJSON: #"{"path":"pantry.md","reason":"Lentils are missing"}"#)
            }
            #expect(!ToolEnvelope.isError(flagged), "\(flagged)")
            let ticket = try #require(
                try KnowledgeDatabase.shared.listTickets(collectionIds: [collection.id.uuidString], status: .open).first)
            let claimed = try await ChatExecutionContext.$currentAgentId.withValue(granted.id) {
                try await ToolRegistry.shared.execute(
                    name: "update_knowledge_ticket",
                    argumentsJSON: #"{"ticket_id":\#(ticket.id),"status":"in_progress"}"#)
            }
            #expect(!ToolEnvelope.isError(claimed), "\(claimed)")
            #expect(try KnowledgeDatabase.shared.getTicket(id: ticket.id)?.status == .inProgress)
            } catch {
                await cleanUp()
                throw error
            }
            await cleanUp()
        }
    }

    // MARK: - Part 2

    @Test("An Intel v1 index upgrades in place: documents kept, types inferred, tickets added")
    func schemaUpgradeFromV1() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-kdb-v1-\(UUID().uuidString)", isDirectory: true)
            let directory = root.appendingPathComponent("knowledge", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            let key = SymmetricKey(data: Data(repeating: 0x31, count: 32))
            StorageKeyManager.shared._setKeyForTesting(key)
            defer {
                KnowledgeDatabase.shared.close()
                StorageKeyManager.shared.wipeCache()
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }

            // Build a database exactly as Intel v1 wrote it.
            let legacy = try EncryptedSQLiteOpener.open(
                path: directory.appendingPathComponent("knowledge.sqlite").path, key: key)
            for sql in [
                """
                CREATE TABLE documents (id INTEGER PRIMARY KEY AUTOINCREMENT, collection_id TEXT NOT NULL,
                rel_path TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', doc_type TEXT NOT NULL DEFAULT '',
                summary TEXT NOT NULL DEFAULT '', tags_csv TEXT NOT NULL DEFAULT '', content_hash TEXT NOT NULL,
                size_bytes INTEGER NOT NULL DEFAULT 0, modified_at TEXT NOT NULL DEFAULT '', indexed_at TEXT NOT NULL,
                UNIQUE(collection_id, rel_path))
                """,
                """
                CREATE TABLE chunks (id INTEGER PRIMARY KEY AUTOINCREMENT, document_id INTEGER NOT NULL,
                chunk_index INTEGER NOT NULL, heading_path TEXT NOT NULL DEFAULT '', content TEXT NOT NULL,
                embedding BLOB, embedding_model TEXT NOT NULL DEFAULT '', UNIQUE(document_id, chunk_index))
                """,
                "CREATE VIRTUAL TABLE chunks_fts USING fts5(content, heading_path, content='chunks', content_rowid='id', tokenize='unicode61 remove_diacritics 2')",
                "INSERT INTO documents(collection_id,rel_path,content_hash,indexed_at) VALUES('c1','recipes/soup.md','h','t')",
                "INSERT INTO documents(collection_id,rel_path,doc_type,content_hash,indexed_at) VALUES('c1','notes/a.md','guide','h','t')",
                "PRAGMA user_version = 1",
            ] {
                #expect(sqlite3_exec(legacy, sql, nil, nil, nil) == SQLITE_OK, "\(sql.prefix(40))")
            }
            sqlite3_close(legacy)

            try KnowledgeDatabase.shared.open()
            let soup = try #require(try KnowledgeDatabase.shared.getDocument(collectionId: "c1", relPath: "recipes/soup.md"))
            #expect(soup.docType == "recipes")  // inferred from the folder
            let note = try #require(try KnowledgeDatabase.shared.getDocument(collectionId: "c1", relPath: "notes/a.md"))
            #expect(note.docType == "guide")  // explicit type wins
            let ticket = try KnowledgeDatabase.shared.createTicket(
                collectionId: "c1", relPath: "recipes/soup.md", reason: "old", evidence: "", createdBy: "")
            #expect(try KnowledgeDatabase.shared.getTicket(id: ticket)?.status == .open)
        }
    }

    @Test("A code span naming a real knowledge document becomes a link; others do not")
    @MainActor
    func linkResolver() async throws {
        try await ChatHistoryTestStorage.run {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-klink-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "# Soup".write(to: folder.appendingPathComponent("soup.md"), atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: folder) }
            let collection = KnowledgeCollection(name: "Recipes Link", folderPath: folder.path)
            try KnowledgeCollectionStore.save(collection)
            await KnowledgeManager.shared.reload()
            defer { KnowledgeManager.shared.delete(id: collection.id) }

            let match = KnowledgeLinkResolver.linkURL(forCodeSpan: "Recipes Link/soup.md")
            #expect(match?.url.scheme == KnowledgeLinkResolver.scheme)
            #expect(match.flatMap { KnowledgeLinkResolver.fileURL(from: $0.url) }?.lastPathComponent == "soup.md")
            #expect(KnowledgeLinkResolver.linkURL(forCodeSpan: "Recipes Link/missing.md") == nil)
            #expect(KnowledgeLinkResolver.linkURL(forCodeSpan: "let x = 1") == nil)
        }
    }

    @Test("A folder that is a git repo is offered Sync (git badge via its remote slot)")
    @MainActor
    func gitRepoDetected() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-kgit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(KnowledgeCollection(name: "g", folderPath: folder.path).isGitRepository)
        #expect(!KnowledgeCollection(name: "p", folderPath: FileManager.default.temporaryDirectory.path).isGitRepository)
    }
}
