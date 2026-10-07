//
//  IntelAgentUnknownFieldsTests.swift
//  osaurusTests
//
//  Saving an agent on Intel must keep the fields of an upstream-written agent
//  file that Intel's `Agent` model doesn't know. On 2026-10-07 the Intel
//  encoder stripped about 30 such fields from real agents
//  (docs/TEST_STORAGE_SAFETY.md). Pure data test: nothing touches disk.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelAgentUnknownFieldsTests {
    /// An upstream-shaped agent file: Intel-known fields plus upstream-only
    /// ones at the top level and inside `settings`.
    private func upstreamFile(id: UUID) throws -> Data {
        let payload: [String: Any] = [
            "id": id.uuidString,
            "name": "Researcher",
            "description": "Finds things",
            "systemPrompt": "Be thorough.",
            "isBuiltIn": false,
            "createdAt": "2026-09-01T00:00:00Z",
            "updatedAt": "2026-09-01T00:00:00Z",
            // Intel-known fields.
            "avatar": "fox",
            "chatGreeting": "Hi! What should we dig into?",
            "chatSubtitle": "Deep research",
            // `settings` mixes Intel-known `dbEnabled` with upstream-only keys.
            "upstreamOnlyTopLevel": ["kept": true],
            "settings": [
                "dbEnabled": true,
                "browserUseEnabled": true,
                "subagentBudgets": ["maxParallelSpawns": 3],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require((try JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    @Test func saveKeepsUpstreamOnlyFieldsAndAppliesIntelChanges() throws {
        let id = UUID()
        let existing = try upstreamFile(id: id)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var agent = try decoder.decode(Agent.self, from: existing)
        agent.name = "Researcher 2"
        agent.settings.dbEnabled = false

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let intelOnly = try encoder.encode(agent)
        // Without the merge, Intel's encoder drops the upstream fields.
        #expect((try object(intelOnly)["settings"] as? [String: Any])?["browserUseEnabled"] == nil)

        let merged = try object(AgentManager.preservingUnknownFields(encoded: intelOnly, existing: existing))
        #expect(merged["avatar"] as? String == "fox")
        #expect(merged["chatGreeting"] as? String == "Hi! What should we dig into?")
        #expect(merged["chatSubtitle"] as? String == "Deep research")
        #expect((merged["upstreamOnlyTopLevel"] as? [String: Any])?["kept"] as? Bool == true)
        let settings = try #require(merged["settings"] as? [String: Any])
        #expect(settings["browserUseEnabled"] as? Bool == true)
        #expect((settings["subagentBudgets"] as? [String: Any])?["maxParallelSpawns"] as? Int == 3)
        // Intel's own edits win.
        #expect(merged["name"] as? String == "Researcher 2")
        #expect(settings["dbEnabled"] as? Bool == false)
    }

    @Test func undecodableFileLeavesTheEncodedAgentAlone() throws {
        let encoded = Data(#"{"name":"A"}"#.utf8)
        let result = AgentManager.preservingUnknownFields(encoded: encoded, existing: Data("not json".utf8))
        #expect(result == encoded)
    }

    /// The live-root guard in `OsaurusPaths.root()` keys off this; it must
    /// hold inside `swift test`, or an empty `OSAURUS_TEST_ROOT` would reach
    /// the live `~/.osaurus` again.
    @Test func testProcessIsDetectedForTheLiveRootGuard() {
        #expect(OsaurusPaths.isTestProcess)
    }
}
