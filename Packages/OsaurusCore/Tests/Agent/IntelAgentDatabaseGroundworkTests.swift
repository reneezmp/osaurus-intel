//
//  IntelAgentDatabaseGroundworkTests.swift
//  OsaurusCoreTests
//
//  Phase 0 of docs/AGENT_DATABASE_INTEL_PLAN.md: the one-time reset of
//  legacy `dbEnabled` flags and complete agent-deletion cleanup. Every test
//  runs against an isolated storage root and test key.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel agent database groundwork", .serialized)
struct IntelAgentDatabaseGroundworkTests {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func makeAgent(dbEnabled: Bool) -> Agent {
        var agent = Agent(
            name: "db-test-\(UUID().uuidString.prefix(6))",
            systemPrompt: "Test identity",
            agentAddress: "test-db-\(UUID().uuidString)"
        )
        agent.settings.dbEnabled = dbEnabled
        return agent
    }

    private static func writeLegacyJSON(_ agent: Agent) throws {
        let dir = OsaurusPaths.agents()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encoder.encode(agent).write(to: dir.appendingPathComponent("\(agent.id.uuidString).json"))
    }

    private static func onDisk(_ id: UUID) throws -> Agent {
        let url = OsaurusPaths.agents().appendingPathComponent("\(id.uuidString).json")
        return try decoder.decode(Agent.self, from: Data(contentsOf: url))
    }

    @Test("dbEnabled round-trips and defaults to off when absent")
    func dbEnabledCodable() throws {
        var agent = Self.makeAgent(dbEnabled: true)
        let decoded = try Self.decoder.decode(Agent.self, from: Self.encoder.encode(agent))
        #expect(decoded.settings.dbEnabled == true)

        agent.settings.dbEnabled = false
        let off = try Self.decoder.decode(Agent.self, from: Self.encoder.encode(agent))
        #expect(off.settings.dbEnabled == false)

        let bare = try Self.decoder.decode(AgentSettings.self, from: Data("{}".utf8))
        #expect(bare.dbEnabled == false)
    }

    @MainActor
    @Test("Legacy dbEnabled flags reset once; a later explicit enable survives relaunch")
    func legacyFlagsResetOnce() async throws {
        try await ChatHistoryTestStorage.run {
            let legacy = Self.makeAgent(dbEnabled: true)
            let untouched = Self.makeAgent(dbEnabled: false)
            try Self.writeLegacyJSON(legacy)
            try Self.writeLegacyJSON(untouched)
            try? FileManager.default.removeItem(at: AgentManager.databaseFlagResetMarker())

            let before = AgentManager.shared.currentCapabilityRevision()
            AgentManager.shared.refresh()

            #expect(AgentManager.shared.agent(for: legacy.id)?.settings.dbEnabled == false)
            #expect(try Self.onDisk(legacy.id).settings.dbEnabled == false)
            #expect(AgentManager.shared.effectiveDBEnabled(for: legacy.id) == false)
            #expect(AgentManager.shared.agent(for: untouched.id)?.settings.dbEnabled == false)
            #expect(FileManager.default.fileExists(atPath: AgentManager.databaseFlagResetMarker().path))
            #expect(AgentManager.shared.currentCapabilityRevision() != before)

            // The user turns the ability on; a relaunch must not reset it.
            var enabled = try #require(AgentManager.shared.agent(for: legacy.id))
            enabled.settings.dbEnabled = true
            AgentManager.shared.update(enabled)
            AgentManager.shared.refresh()
            #expect(AgentManager.shared.effectiveDBEnabled(for: legacy.id) == true)
            #expect(try Self.onDisk(legacy.id).settings.dbEnabled == true)
        }
    }

    @MainActor
    @Test("The Default agent never reports the database ability")
    func defaultAgentNeverEnabled() async throws {
        try await ChatHistoryTestStorage.run {
            #expect(AgentManager.shared.effectiveDBEnabled(for: Agent.defaultId) == false)
        }
    }

    @MainActor
    @Test("Deleting an agent removes its run history and avatar")
    func deleteRemovesRunsAndAvatar() async throws {
        try await ChatHistoryTestStorage.run {
            let scheduler = SchedulerDatabase.shared
            scheduler.close()
            try scheduler.openInMemory()
            defer { scheduler.close() }

            let agent = Self.makeAgent(dbEnabled: false)
            AgentManager.shared.add(agent)
            #expect(AgentManager.shared.setCustomAvatar(Data([0x89, 0x50]), ext: "png", for: agent.id))
            let avatar = try #require(AgentManager.shared.agent(for: agent.id)?.customAvatarURL)
            #expect(FileManager.default.fileExists(atPath: avatar.path))

            try scheduler.recordRunStart(agentId: agent.id, triggerKind: .user, instructions: "test")
            let other = UUID()
            try scheduler.recordRunStart(agentId: other, triggerKind: .user, instructions: "keep")
            #expect(try scheduler.runs(agentId: agent.id).count == 1)

            let result = await AgentManager.shared.delete(id: agent.id)
            #expect(result.deleted)
            #expect(try scheduler.runs(agentId: agent.id).isEmpty)
            #expect(try scheduler.runs(agentId: other).count == 1)
            #expect(!FileManager.default.fileExists(atPath: avatar.path))
            #expect(AgentManager.shared.agent(for: agent.id) == nil)
        }
    }
}
