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
            } catch {
                await cleanUp()
                throw error
            }
            await cleanUp()
        }
    }
}
