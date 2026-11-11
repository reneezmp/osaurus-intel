//
//  IntelOptionalToolTogglesTests.swift
//  osaurusTests
//
//  Upstream #3307 on Intel: Calculator is a per-agent opt-in (default off);
//  Task Checklist, Clarify and Artifacts are per-agent switches (default on).
//  Redaction Tools are not on Intel.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelOptionalToolTogglesTests {
    @Test func defaultsRoundTripAndLegacyDecode() throws {
        let fresh = AgentSettings.defaultDisabled
        #expect(!fresh.calculatorEnabled)
        #expect(fresh.taskChecklistEnabled && fresh.clarifyEnabled && fresh.artifactsEnabled)

        var settings = fresh
        settings.calculatorEnabled = true
        settings.taskChecklistEnabled = false
        settings.clarifyEnabled = false
        settings.artifactsEnabled = false
        let back = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.calculatorEnabled)
        #expect(!back.taskChecklistEnabled && !back.clarifyEnabled && !back.artifactsEnabled)

        let legacy = try JSONDecoder().decode(AgentSettings.self, from: Data(#"{"dbEnabled":false}"#.utf8))
        #expect(!legacy.calculatorEnabled)
        #expect(legacy.taskChecklistEnabled && legacy.clarifyEnabled && legacy.artifactsEnabled)
    }

    @Test func disabledNamesFollowTheSwitches() {
        var settings = AgentSettings.defaultDisabled
        #expect(ToolRegistry.disabledOptionalToolNames(settings) == ["calculate"])
        settings.calculatorEnabled = true
        #expect(ToolRegistry.disabledOptionalToolNames(settings).isEmpty)
        settings.taskChecklistEnabled = false
        settings.clarifyEnabled = false
        settings.artifactsEnabled = false
        #expect(
            ToolRegistry.disabledOptionalToolNames(settings)
                == ["todo", "complete", "clarify", "share_artifact"])
    }

    @MainActor
    @Test func composedToolsFollowTheSwitches() async throws {
        try await ChatHistoryTestStorage.run {
            var agent = Agent(name: "toggles-\(UUID().uuidString.prefix(6))", systemPrompt: "x", agentAddress: nil)
            agent.manualToolNames = ["file_read"]
            agent.settings.calculatorEnabled = true
            agent.settings.clarifyEnabled = false
            AgentManager.shared.add(agent)
            let context = await SystemPromptComposer.composeChatContext(agentId: agent.id, query: "hi")
            let names = Set(context.tools.map(\.function.name))
            #expect(names.contains("calculate"))
            #expect(names.contains("todo") && names.contains("complete"))
            #expect(!names.contains("clarify"))
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }
}
