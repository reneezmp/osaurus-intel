//
//  IntelAgentBundleTests.swift
//  OsaurusCoreTests
//
//  Release 3 of docs/AGENT_DATABASE_INTEL_PLAN.md: encrypted `.osaurus-agent`
//  bundles. Runs against an isolated storage root and test key.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel agent bundles (Release 3)", .serialized)
struct IntelAgentBundleTests {
    private static let passphrase = "correct horse battery"

    private static func makeAgent(name: String = "bundle-\(UUID().uuidString.prefix(6))") -> Agent {
        var agent = Agent(name: name, systemPrompt: "Keeps a reading list", agentAddress: nil)
        agent.settings.dbEnabled = true
        return agent
    }

    private static func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func seedDatabase(for agentId: UUID) throws {
        let bridge = LocalAgentBridge.shared
        try bridge.createTable(
            agentId: agentId,
            name: "books",
            purpose: "bundle fixture",
            columns: [AgentColumnSpec(name: "title", type: "TEXT", nullable: false)],
            indexes: []
        )
        _ = try bridge.insert(agentId: agentId, table: "books", row: ["title": .text("bundle-marker-dune")])
        _ = try bridge.defineView(
            agentId: agentId, name: "all_books", sql: "SELECT title FROM books",
            renderHint: "table", refresh: "on_open", description: nil)
    }

    @MainActor
    @Test("Export, wrong passphrase, review and activate round-trip the agent and its database")
    func roundTrip() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.makeAgent()
            AgentManager.shared.add(agent)
            try Self.seedDatabase(for: agent.id)
            let out = try Self.temporaryDirectory("bundle-out")
            defer { try? FileManager.default.removeItem(at: out) }

            let export = try await AgentBundleService.shared.exportBundle(
                agentId: agent.id, passphrase: Self.passphrase, destinationDirectory: out)
            #expect(export.manifest.schemaTables == 1)
            #expect(export.manifest.savedViews == 1)

            // The bundle never carries plaintext rows or a plaintext database.
            let bytes = try Data(contentsOf: export.bundleURL)
            #expect(bytes.range(of: Data("bundle-marker-dune".utf8)) == nil)
            #expect(bytes.range(of: Data("SQLite format 3".utf8)) == nil)

            _ = await AgentManager.shared.delete(id: agent.id)
            #expect(AgentManager.shared.agent(for: agent.id) == nil)

            await #expect(throws: AgentBundleError.self) {
                _ = try await AgentBundleService.shared.openBundleForReview(
                    url: export.bundleURL, passphrase: "wrong passphrase")
            }

            let preview = try await AgentBundleService.shared.openBundleForReview(
                url: export.bundleURL, passphrase: Self.passphrase)
            #expect(preview.manifest.agentId == agent.id)
            #expect(preview.replacesAgentName == nil)
            #expect(preview.capabilityNotes.contains("Database is on"))

            let imported = try await AgentBundleService.shared.activate(preview: preview)
            #expect(imported.id == agent.id)
            #expect(AgentManager.shared.agent(for: agent.id)?.name == agent.name)
            #expect(!FileManager.default.fileExists(atPath: preview.stagingDirectory.path))

            let rows = try LocalAgentBridge.shared.query(
                agentId: agent.id, sql: "SELECT title FROM books", params: [])
            #expect(rows.rows.first?.first == .text("bundle-marker-dune"))
            #expect(try LocalAgentBridge.shared.listViews(agentId: agent.id).map(\.name) == ["all_books"])

            // Re-opening the same bundle now names the agent it would replace.
            let again = try await AgentBundleService.shared.openBundleForReview(
                url: export.bundleURL, passphrase: Self.passphrase)
            #expect(again.replacesAgentName == agent.name)
            await AgentBundleService.shared.discard(preview: again)
            #expect(!FileManager.default.fileExists(atPath: again.stagingDirectory.path))

            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @MainActor
    @Test("A bundle containing a symlink is refused before anything is written")
    func symlinkBundleRefused() async throws {
        try await ChatHistoryTestStorage.run {
            let stage = try Self.temporaryDirectory("bundle-evil")
            let out = try Self.temporaryDirectory("bundle-evil-out")
            defer {
                try? FileManager.default.removeItem(at: stage)
                try? FileManager.default.removeItem(at: out)
            }
            let agent = Self.makeAgent()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(agent).write(to: stage.appendingPathComponent("agent.json"))
            try Data("{}".utf8).write(to: stage.appendingPathComponent("manifest.json"))
            try FileManager.default.createSymbolicLink(
                at: stage.appendingPathComponent("db.sqlite"),
                withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))

            let bundle = out.appendingPathComponent("evil.osaurus-agent")
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-cf", bundle.path, "-C", stage.path, "."]
            try tar.run()
            tar.waitUntilExit()
            #expect(tar.terminationStatus == 0)

            do {
                _ = try await AgentBundleService.shared.openBundleForReview(
                    url: bundle, passphrase: Self.passphrase)
                Issue.record("a symlinked bundle must be refused")
            } catch let error as AgentBundleError {
                guard case .unsafeBundle = error else {
                    Issue.record("expected unsafeBundle, got \(error)")
                    return
                }
            }
            #expect(AgentManager.shared.agent(for: agent.id) == nil)
            #expect(!FileManager.default.fileExists(atPath: OsaurusPaths.agentDirectory(for: agent.id).path))
        }
    }

    @Test("Short passphrases are rejected on export and import")
    func shortPassphrase() async {
        await #expect(throws: AgentBundleError.self) {
            _ = try await AgentBundleService.shared.exportBundle(
                agentId: UUID(), passphrase: "short", destinationDirectory: FileManager.default.temporaryDirectory)
        }
        await #expect(throws: AgentBundleError.self) {
            _ = try await AgentBundleService.shared.openBundleForReview(
                url: URL(fileURLWithPath: "/nonexistent.osaurus-agent"), passphrase: "short")
        }
    }

    @Test("An address already owned by another local agent is cleared on import")
    func identityCollision() {
        var bundled = Self.makeAgent(name: "traveller")
        bundled.agentIndex = 7
        bundled.agentAddress = "0xABC"
        var local = Self.makeAgent(name: "homebody")
        local.agentIndex = 7

        let collided = AgentBundleService.resolveImportIdentity(agent: bundled, localAgents: [local])
        #expect(collided.note == .collidesWithLocalAgent(name: "homebody"))
        #expect(collided.agent.agentIndex == nil)
        #expect(collided.agent.agentAddress == nil)

        // The same agent id (a re-import) is an overwrite, not a collision.
        let same = AgentBundleService.resolveImportIdentity(agent: bundled, localAgents: [bundled])
        #expect(same.note == nil)
        #expect(same.agent.agentAddress == "0xABC")

        // An address nobody else holds is kept (moving your own agent).
        let clear = AgentBundleService.resolveImportIdentity(agent: bundled, localAgents: [])
        #expect(clear.note == nil)
        #expect(clear.agent.agentIndex == 7)
    }

    @Test("Riskier abilities are listed for review")
    func capabilityNotes() {
        var agent = Self.makeAgent()
        agent.settings.webSearchEnabled = true
        agent.claudeCode = ClaudeCodeAgentConfig(
            mode: .textOnly, allowWrites: true, allowShell: true,
            allowOsaurusTools: false, allowOsaurusConfigWrites: false)
        let notes = AgentBundleService.capabilityNotes(for: agent)
        #expect(notes.contains("Claude Code may run shell commands"))
        #expect(notes.contains("Claude Code may write files"))
        #expect(notes.contains("Web Search is on"))
        #expect(notes.contains("Database is on"))
    }
}
