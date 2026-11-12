//
//  AgentGenerationSettingsTests.swift
//  OsaurusCoreTests
//
//  `W-agent-generation-overrides`: ported from upstream Classic's
//  `AgentGenerationSettingsTests` (#3233), minus the chat-template and
//  speculation fields (local MLX, Incompatible on Intel) and the AgentStore
//  persistence suite (Intel persists agents through its own store).
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentGenerationSettingsTests {
    static let explicit = AgentGenerationSettings(
        topP: 0, topK: 0, minP: 0, repetitionPenalty: 1,
        frequencyPenalty: 0, presencePenalty: 0, seed: -7, stop: [],
        enableThinking: false, reasoningEffort: "low"
    )

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    @Test("agent JSON keeps explicit zero and false without duplicating temperature or token limits")
    func agentJSONRoundTripAndLegacyInheritance() throws {
        let agent = Agent(
            name: "Generation fixture", temperature: 0, maxTokens: 1234,
            generationSettings: Self.explicit,
            autonomousExec: AutonomousExecConfig(enabled: false)
        )
        let data = try encoder.encode(agent)
        let decoded = try decoder.decode(Agent.self, from: data)
        #expect(decoded.generationSettings == Self.explicit)
        #expect(decoded.temperature == 0)
        #expect(decoded.maxTokens == 1234)

        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let settings = try #require(json["generationSettings"] as? [String: Any])
        #expect(settings["temperature"] == nil)
        #expect(settings["max_tokens"] == nil)
        #expect(settings["maxTokens"] == nil)
        #expect(settings["topP"] == nil)
        #expect(settings["top_p"] as? Double == 0)
        #expect(settings["enable_thinking"] as? Bool == false)

        json.removeValue(forKey: "generationSettings")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let inherited = try decoder.decode(Agent.self, from: legacy)
        #expect(inherited.generationSettings == nil)
        #expect(inherited.temperature == 0)
        #expect(inherited.maxTokens == 1234)
    }

    @Test("an agent saved before generation settings existed decodes unchanged")
    func oldAgentDecodes() throws {
        let old = """
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "Old Intel", "description": "", "systemPrompt": "",
              "isBuiltIn": false,
              "createdAt": "2026-09-01T00:00:00Z", "updatedAt": "2026-09-01T00:00:00Z",
              "temperature": 0.5
            }
            """
        let agent = try decoder.decode(Agent.self, from: Data(old.utf8))
        #expect(agent.generationSettings == nil)
        #expect(agent.temperature == 0.5)
        // A re-save does not invent a block.
        let json = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(agent)) as? [String: Any])
        #expect(json["generationSettings"] == nil)
    }

    @Test("an upstream agent's local-only keys are ignored, not fatal")
    func upstreamLocalKeysIgnored() throws {
        let json = """
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "name": "From Classic", "description": "", "systemPrompt": "",
              "isBuiltIn": false,
              "createdAt": "2026-09-01T00:00:00Z", "updatedAt": "2026-09-01T00:00:00Z",
              "generationSettings": {
                "top_p": 0.9, "seed": 4,
                "template_kwargs": {"x": true}, "speculative_decoding": true
              }
            }
            """
        let agent = try decoder.decode(Agent.self, from: Data(json.utf8))
        #expect(agent.generationSettings == AgentGenerationSettings(topP: 0.9, seed: 4))
    }

    @Test("a malformed settings block does not make the agent unloadable")
    func malformedBlockTolerated() throws {
        let json = """
            {
              "id": "33333333-3333-3333-3333-333333333333",
              "name": "Broken block", "description": "", "systemPrompt": "",
              "isBuiltIn": false,
              "createdAt": "2026-09-01T00:00:00Z", "updatedAt": "2026-09-01T00:00:00Z",
              "generationSettings": {"top_p": "not a number"}
            }
            """
        let agent = try decoder.decode(Agent.self, from: Data(json.utf8))
        #expect(agent.name == "Broken block")
        #expect(agent.generationSettings == nil)
    }

    @Test("empty settings inherit while explicit empty collections remain configured")
    func emptyAndExplicitValues() throws {
        #expect(AgentGenerationSettings().isEmpty)
        #expect(!AgentGenerationSettings(topK: 0).isEmpty)
        #expect(!AgentGenerationSettings(enableThinking: false).isEmpty)
        #expect(!AgentGenerationSettings(stop: []).isEmpty)
        try AgentGenerationSettings().validate()
        try Self.explicit.validate()
    }

    @Test("validation shares the request contracts without imposing provider-specific penalty bounds")
    func validatesExistingContracts() throws {
        let invalid = [
            AgentGenerationSettings(topP: -0.1),
            AgentGenerationSettings(topP: 1.1),
            AgentGenerationSettings(topP: .nan),
            AgentGenerationSettings(topK: -1),
            AgentGenerationSettings(minP: .infinity),
            AgentGenerationSettings(repetitionPenalty: 0),
            AgentGenerationSettings(frequencyPenalty: .nan),
            AgentGenerationSettings(presencePenalty: -.infinity),
            AgentGenerationSettings(reasoningEffort: "  "),
        ]
        for settings in invalid {
            #expect(throws: (any Error).self) { try settings.validate() }
        }
        try AgentGenerationSettings(
            frequencyPenalty: -3, presencePenalty: 3, reasoningEffort: "model-specific-level"
        ).validate()
    }
}

struct ChatTurnOverridesTests {
    @Test("nil inherits; zero and false are explicit")
    func emptyAndExplicit() {
        #expect(ChatTurnOverrides().isEmpty)
        #expect(!ChatTurnOverrides(temperature: 0).isEmpty)
        #expect(!ChatTurnOverrides(topK: 0).isEmpty)
        #expect(!ChatTurnOverrides(enableThinking: false).isEmpty)
    }

    @Test("validation rejects values no provider can use")
    func validation() throws {
        for bad in [
            ChatTurnOverrides(temperature: -1), ChatTurnOverrides(temperature: .nan),
            ChatTurnOverrides(topP: 1.5), ChatTurnOverrides(topK: -2),
            ChatTurnOverrides(reasoningEffort: " "),
        ] {
            #expect(throws: (any Error).self) { try bad.validate() }
        }
        try ChatTurnOverrides(temperature: 0, topP: 1, topK: 0, reasoningEffort: "high").validate()
    }
}
