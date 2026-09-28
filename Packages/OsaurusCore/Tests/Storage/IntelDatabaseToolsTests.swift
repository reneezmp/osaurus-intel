//
//  IntelDatabaseToolsTests.swift
//  OsaurusCoreTests
//
//  Release 1 of docs/AGENT_DATABASE_INTEL_PLAN.md: registration, approval
//  defaults, the ability gate (dispatch + prompt), read-only enforcement,
//  run linkage for History, encryption at rest, and deletion. Upstream's
//  DatabaseToolsTests (mostly import/export) returns with Release 2.
//

import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@Suite("Intel agent database (Release 1)", .serialized)
struct IntelDatabaseToolsTests {
    private static func makeAgent(dbEnabled: Bool) -> Agent {
        var agent = Agent(
            name: "dbtools-\(UUID().uuidString.prefix(6))",
            systemPrompt: "Test identity",
            agentAddress: "test-dbtools-\(UUID().uuidString)"
        )
        agent.settings.dbEnabled = dbEnabled
        return agent
    }

    private static func envelopeIsFailure(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["ok"] as? Bool == false || object["error"] != nil
    }

    // MARK: - Registration and approvals

    @Test("All seventeen database tools are registered, including import/export")
    func registration() {
        let names = Set(ToolRegistry.shared.listTools().map(\.name))
        #expect(ToolRegistry.databaseToolNames.count == 17)
        #expect(ToolRegistry.databaseToolNames.isSubset(of: names))
        #expect(names.contains("db_import"))
        #expect(names.contains("db_export"))
    }

    @Test("Raw SQL and migrations ask by default; everything else runs automatically")
    func approvalDefaults() {
        for name in ToolRegistry.databaseToolNames {
            let info = ToolRegistry.shared.policyInfo(for: name)
            let expected: ToolPermissionPolicy =
                ["db_execute", "db_migrate"].contains(name) ? .ask : .auto
            #expect(info?.defaultPolicy == expected, "\(name)")
        }
    }

    @Test("db_execute takes sql or a working-folder path")
    func executeSchema() throws {
        let tool = try #require(
            ToolRegistry.shared.listTools().first { $0.name == "db_execute" })
        guard case .object(let schema)? = tool.parameters,
            case .object(let properties)? = schema["properties"]
        else {
            Issue.record("db_execute schema missing")
            return
        }
        #expect(properties["sql"] != nil)
        #expect(properties["path"] != nil)
    }

    @MainActor
    @Test("db_import loads a working-folder CSV and db_export writes an .xlsx back")
    func importExportThroughTools() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.makeAgent(dbEnabled: true)
            AgentManager.shared.add(agent)
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-db-io-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            try "title,rating\nDune,5\nEmma,4\n".write(
                to: folder.appendingPathComponent("books.csv"), atomically: true, encoding: .utf8)

            let (imported, exported, noFolder) = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
                let imported = try await ChatExecutionContext.$currentFolderRoot.withValue(folder) {
                    try await ToolRegistry.shared.execute(
                        name: "db_import", argumentsJSON: #"{"table":"books","path":"books.csv"}"#)
                }
                let exported = try await ChatExecutionContext.$currentFolderRoot.withValue(folder) {
                    try await ToolRegistry.shared.execute(
                        name: "db_export",
                        argumentsJSON: #"{"sql":"SELECT title, rating FROM books","path":"out/books.xlsx"}"#)
                }
                // Without a working folder the file tools explain how to get one.
                let noFolder = try await ToolRegistry.shared.execute(
                    name: "db_import", argumentsJSON: #"{"table":"books","path":"books.csv"}"#)
                return (imported, exported, noFolder)
            }
            #expect(!Self.envelopeIsFailure(imported), "\(imported)")
            #expect(!Self.envelopeIsFailure(exported), "\(exported)")
            #expect(noFolder.contains("working folder"))

            let count = try LocalAgentBridge.shared.query(
                agentId: agent.id, sql: "SELECT COUNT(*) FROM books WHERE _deleted_at IS NULL", params: [])
            #expect(count.rows.first?.first == .integer(2))
            let xlsx = folder.appendingPathComponent("out/books.xlsx")
            #expect(FileManager.default.fileExists(atPath: xlsx.path))
            let reparsed = try AgentImportRunner.parse(url: xlsx)
            #expect(reparsed.columns == ["title", "rating"])
            #expect(reparsed.rows.count == 2)

            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    // MARK: - Ability gate

    @MainActor
    @Test("Dispatch refuses database tools unless the agent's ability is on")
    func dispatchGate() async throws {
        try await ChatHistoryTestStorage.run {
            let off = Self.makeAgent(dbEnabled: false)
            let on = Self.makeAgent(dbEnabled: true)
            AgentManager.shared.add(off)
            AgentManager.shared.add(on)

            let denied = try await ChatExecutionContext.$currentAgentId.withValue(off.id) {
                try await ToolRegistry.shared.execute(name: "db_schema", argumentsJSON: "{}")
            }
            #expect(denied.contains("Database ability is off"))

            let defaultDenied = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
                try await ToolRegistry.shared.execute(name: "db_schema", argumentsJSON: "{}")
            }
            #expect(defaultDenied.contains("Database ability is off"))

            let allowed = try await ChatExecutionContext.$currentAgentId.withValue(on.id) {
                try await ToolRegistry.shared.execute(name: "db_schema", argumentsJSON: "{}")
            }
            #expect(!allowed.contains("Database ability is off"))
            #expect(!Self.envelopeIsFailure(allowed))

            _ = await AgentManager.shared.delete(id: off.id)
            _ = await AgentManager.shared.delete(id: on.id)
        }
    }

    @MainActor
    @Test("Prompt offers database tools, onboarding and schema only when the ability is on")
    func promptComposition() async throws {
        try await ChatHistoryTestStorage.run {
            let off = Self.makeAgent(dbEnabled: false)
            let on = Self.makeAgent(dbEnabled: true)
            AgentManager.shared.add(off)
            AgentManager.shared.add(on)

            let offContext = await SystemPromptComposer.composeChatContext(agentId: off.id, query: "hi")
            let offTools = Set(offContext.tools.map(\.function.name))
            #expect(offTools.isDisjoint(with: ToolRegistry.databaseToolNames))
            #expect(!offContext.prompt.contains("## Your database"))

            let onContext = await SystemPromptComposer.composeChatContext(agentId: on.id, query: "hi")
            let onTools = Set(onContext.tools.map(\.function.name))
            #expect(ToolRegistry.databaseToolNames.isSubset(of: onTools))
            #expect(onContext.prompt.contains("## Your database"))
            // The schema snapshot rides the per-turn prefix, not the cached prompt.
            #expect(onContext.memorySection?.isEmpty == false)
            #expect(onContext.promptSections.contains { $0.id == "agentDB" })

            _ = await AgentManager.shared.delete(id: off.id)
            _ = await AgentManager.shared.delete(id: on.id)
        }
    }

    // MARK: - Read-only enforcement (Intel hardening)

    @Test("db_query rejects writes, PRAGMA writes, ATTACH and extra statements")
    func queryIsReadOnly() throws {
        let db = AgentDatabase(agentId: UUID())
        try db.openInMemory()
        defer { db.close() }
        try db.createTable(
            name: "notes",
            purpose: "read-only fixture",
            columns: [AgentColumnSpec(name: "title", type: "TEXT", nullable: false)],
            indexes: [],
            actor: .agent,
            runId: nil
        )
        _ = try db.insert(table: "notes", row: ["title": .text("a")], actor: .agent, runId: nil)

        #expect(throws: (any Error).self) {
            _ = try db.query(sql: "UPDATE notes SET title = 'b'")
        }
        #expect(throws: (any Error).self) {
            _ = try db.query(sql: "INSERT INTO notes (title) VALUES ('c')")
        }
        #expect(throws: (any Error).self) {
            _ = try db.query(sql: "PRAGMA foreign_keys = OFF")
        }
        #expect(throws: (any Error).self) {
            _ = try db.query(sql: "ATTACH DATABASE '/tmp/x.sqlite' AS other")
        }
        #expect(throws: (any Error).self) {
            _ = try db.query(sql: "SELECT 1; SELECT 2")
        }
        // Reads, read-only PRAGMAs and a trailing semicolon/comment still work.
        #expect(try db.query(sql: "SELECT title FROM notes").rows.count == 1)
        #expect(try db.query(sql: "PRAGMA table_info(notes)").rows.isEmpty == false)
        #expect(try db.query(sql: "SELECT 1; -- done").rows.count == 1)
        // Nothing was changed by the rejected statements.
        let rows = try db.query(sql: "SELECT title FROM notes").rows
        #expect(rows.first?.first == .text("a"))
    }

    // MARK: - Storage, History and deletion

    @MainActor
    @Test("Background writes carry the run id; chat writes have none")
    func changelogRunLinkage() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.makeAgent(dbEnabled: true)
            AgentManager.shared.add(agent)
            let bridge = LocalAgentBridge.shared
            try bridge.createTable(
                agentId: agent.id,
                name: "tasks",
                purpose: "linkage fixture",
                columns: [AgentColumnSpec(name: "title", type: "TEXT", nullable: false)],
                indexes: []
            )
            let runId = UUID()
            try ChatExecutionContext.$currentRunId.withValue(runId) {
                _ = try bridge.insert(agentId: agent.id, table: "tasks", row: ["title": .text("from run")])
            }
            _ = try bridge.insert(agentId: agent.id, table: "tasks", row: ["title": .text("from chat")])

            let linked = try bridge.query(
                agentId: agent.id,
                sql: "SELECT COUNT(*) FROM _changelog WHERE run_id = ?1",
                params: [.text(runId.uuidString)]
            )
            #expect(linked.rows.first?.first == .integer(1))
            // create_table + the chat insert have no run id.
            #expect(DatabaseHistoryView.countChatChanges(agentId: agent.id) >= 2)

            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test("History hides self-scheduled wakes and labels triggers")
    func historyFilter() {
        func run(_ kind: AgentRunTriggerKind) -> AgentRunRecord {
            AgentRunRecord(
                id: UUID(), agentId: UUID(), triggerKind: kind, triggerPayload: nil,
                instructions: "x", startedAt: Date(), endedAt: nil, status: .success,
                tokensIn: nil, tokensOut: nil, costUSD: nil, error: nil)
        }
        let visible = DatabaseHistoryView.visibleRuns([
            run(.schedule), run(.recurringSchedule), run(.watcher), run(.user),
        ])
        #expect(visible.map(\.triggerKind) == [.recurringSchedule, .watcher, .user])
        #expect(DatabaseHistoryView.triggerLabel(.recurringSchedule) == "Schedule")
    }

    @MainActor
    @Test("The database file is encrypted at rest and deleted with the agent")
    func encryptedAndDeleted() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.makeAgent(dbEnabled: true)
            AgentManager.shared.add(agent)
            try LocalAgentBridge.shared.createTable(
                agentId: agent.id,
                name: "secrets",
                purpose: "encryption fixture",
                columns: [AgentColumnSpec(name: "value", type: "TEXT", nullable: false)],
                indexes: []
            )
            _ = try LocalAgentBridge.shared.insert(
                agentId: agent.id, table: "secrets", row: ["value": .text("plaintext-marker-42")])
            AgentDatabaseStore.shared.close(agent.id)

            let file = OsaurusPaths.agentDatabaseFile(for: agent.id)
            let bytes = try Data(contentsOf: file)
            #expect(!bytes.starts(with: Data("SQLite format 3".utf8)))
            #expect(bytes.range(of: Data("plaintext-marker-42".utf8)) == nil)

            let directory = OsaurusPaths.agentDirectory(for: agent.id)
            #expect(FileManager.default.fileExists(atPath: directory.path))
            let result = await AgentManager.shared.delete(id: agent.id)
            #expect(result.deleted)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }
}
