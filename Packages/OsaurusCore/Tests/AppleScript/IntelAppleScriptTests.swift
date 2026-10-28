//
//  IntelAppleScriptTests.swift
//  osaurus
//
//  Intel's side of `W-applescript-agent` (docs/SUBAGENTS_INTEL.md, layer 3):
//  the kind's cloud-model resolution, registration and the per-agent switch,
//  the Intel guidance text, and the settings round trip. Nothing here runs a
//  script or reaches a provider.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelAppleScriptTests {
    @Test func noAssignmentUsesTheChatsModel() async throws {
        let model = try await AppleScriptKind.intelCloudModel(
            assigned: nil, parentModel: "osaurus/claude-opus-5-5", agentId: UUID())
        #expect(model == "osaurus/claude-opus-5-5")
        let blank = try await AppleScriptKind.intelCloudModel(
            assigned: "   ", parentModel: "venice/llama", agentId: UUID())
        #expect(blank == "venice/llama")
    }

    @Test func noChatModelFallsBackToTheAgentsDefault() async throws {
        let agentId = UUID()
        let expected = await MainActor.run { AgentManager.shared.effectiveModel(for: agentId) }
        if let expected, !expected.isEmpty {
            let model = try await AppleScriptKind.intelCloudModel(assigned: nil, parentModel: nil, agentId: agentId)
            #expect(model == expected)
        } else {
            await #expect(throws: SubagentError.self) {
                _ = try await AppleScriptKind.intelCloudModel(assigned: nil, parentModel: nil, agentId: agentId)
            }
        }
    }

    @Test func toolsAreRegisteredAndGatedByTheAgentSwitch() async throws {
        let names = Set(ToolRegistry.shared.listTools().map(\.name))
        #expect(names.contains("applescript"))
        #expect(names.contains("mac_query"))
        #expect(ToolRegistry.appleScriptToolNames == ["applescript", "mac_query"])
        // An agent without the switch (here: one that doesn't exist) is refused
        // before the tool runs.
        let result = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await ToolRegistry.shared.execute(name: "mac_query", argumentsJSON: #"{"question":"volume?"}"#)
        }
        #expect(!ToolEnvelope.isSuccess(result))
    }

    @Test func intelGuidanceDropsTheOnDeviceClaim() {
        let guidance = SystemPromptTemplates.intelAppleScriptGuidance
        #expect(!guidance.contains("on-device"))
        #expect(guidance.contains("AppleScript helper"))
        #expect(guidance.contains("`mac_query`"))
        #expect(guidance != SystemPromptTemplates.appleScriptGuidance)
    }

    @Test func settingsRoundTrip() throws {
        var settings = AgentSettings.defaultDisabled
        #expect(!settings.appleScriptEnabled)
        #expect(settings.appleScriptExecutionMode == .confirmEach)
        settings.appleScriptEnabled = true
        settings.appleScriptExecutionMode = .autoRunWithWarning
        settings.appleScriptModelId = "osaurus/claude-opus-5-5"
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.appleScriptEnabled)
        #expect(decoded.appleScriptExecutionMode == .autoRunWithWarning)
        #expect(decoded.appleScriptModelId == "osaurus/claude-opus-5-5")
        // A malformed stored mode falls back to the safe default.
        let json = #"{"dbEnabled":false,"appleScriptEnabled":true,"appleScriptExecutionMode":"yolo"}"#
        let legacy = try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))
        #expect(legacy.appleScriptExecutionMode == .confirmEach)
    }
}
