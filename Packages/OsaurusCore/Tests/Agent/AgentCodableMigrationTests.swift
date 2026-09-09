//
//  AgentCodableMigrationTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing
@testable import OsaurusCore

@Suite("Agent Codable migrations")
struct AgentCodableMigrationTests {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    @Test("Old Intel agent JSON retains legacy ability flags and safe Claude defaults")
    func oldIntelJSONKeepsLegacyAbilityFlags() throws {
        let agent = try decoder.decode(Agent.self, from: Data(oldIntelJSON.utf8))

        #expect(agent.disableTools == true)
        #expect(agent.disableMemory == true)
        #expect(agent.claudeCode == nil)
    }

    @Test("Upstream positive ability keys override legacy flags and preserve Claude config")
    func upstreamJSONUsesPositiveAbilityKeys() throws {
        let agent = try decoder.decode(Agent.self, from: Data(upstreamJSON.utf8))

        #expect(agent.disableTools == true)
        #expect(agent.disableMemory == nil)
        #expect(agent.claudeCode == ClaudeCodeAgentConfig(
            mode: .textOnly,
            allowWrites: true,
            allowShell: true,
            allowOsaurusTools: true,
            allowOsaurusConfigWrites: true
        ))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let roundTripped = try decoder.decode(Agent.self, from: encoder.encode(agent))
        #expect(roundTripped.claudeCode == agent.claudeCode)
        #expect(roundTripped.disableTools == agent.disableTools)
        #expect(roundTripped.disableMemory == agent.disableMemory)
    }

    private let oldIntelJSON = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "name": "Old Intel",
      "description": "",
      "systemPrompt": "",
      "isBuiltIn": false,
      "createdAt": "2026-09-01T00:00:00Z",
      "updatedAt": "2026-09-01T00:00:00Z",
      "disableTools": true,
      "disableMemory": true
    }
    """

    private let upstreamJSON = """
    {
      "id": "22222222-2222-2222-2222-222222222222",
      "name": "Upstream",
      "description": "",
      "systemPrompt": "",
      "isBuiltIn": false,
      "createdAt": "2026-09-01T00:00:00Z",
      "updatedAt": "2026-09-01T00:00:00Z",
      "toolsEnabled": false,
      "memoryEnabled": true,
      "disableTools": false,
      "disableMemory": true,
      "claudeCode": {
        "mode": "textOnly",
        "allowWrites": true,
        "allowShell": true,
        "allowOsaurusTools": true,
        "allowOsaurusConfigWrites": true
      }
    }
    """
}

@Suite("Intel Agent presentation persistence", .serialized)
@MainActor
struct IntelAgentPresentationPersistenceTests {
    @Test("custom avatar and theme survive manager refresh and can be cleared")
    func avatarAndThemePersist() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-agent-presentation-tests-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            try await MainActor.run {
                let previousRoot = OsaurusPaths.overrideRoot
                OsaurusPaths.overrideRoot = root
                AgentManager.shared.refresh()
                defer {
                    OsaurusPaths.overrideRoot = previousRoot
                    AgentManager.shared.refresh()
                }

                let themeId = UUID()
                let agent = Agent(name: "Presentation Test", themeId: themeId, avatar: "pink")
                AgentManager.shared.add(agent)

                let bytes = Data([0x89, 0x50, 0x4E, 0x47])
                #expect(AgentManager.shared.setCustomAvatar(bytes, ext: "PNG", for: agent.id))
                #expect(AgentManager.shared.themeId(for: agent.id) == themeId)

                AgentManager.shared.refresh()
                let stored = try #require(AgentManager.shared.agent(for: agent.id))
                let avatarURL = try #require(stored.customAvatarURL)
                #expect(stored.avatar == nil)
                #expect(try Data(contentsOf: avatarURL) == bytes)

                AgentManager.shared.clearCustomAvatar(for: agent.id)
                AgentManager.shared.refresh()
                #expect(AgentManager.shared.agent(for: agent.id)?.customAvatarFilename == nil)
                #expect(!FileManager.default.fileExists(atPath: avatarURL.path))
            }
        }
    }
}
