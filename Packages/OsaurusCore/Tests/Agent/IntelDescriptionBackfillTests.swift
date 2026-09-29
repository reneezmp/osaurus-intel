//
//  IntelDescriptionBackfillTests.swift
//  OsaurusCoreTests
//
//  `W-description-backfill`: opt-in (off by default) background purposes for
//  agents without a description. A fake generator stands in for the paid
//  model; nothing reaches a network.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Intel description backfill (opt-in)", .serialized)
struct IntelDescriptionBackfillTests {
    private static func makeAgent(description: String = "", prompt: String = "You plan meals from the pantry.") -> Agent {
        var agent = Agent(name: "fill-\(UUID().uuidString.prefix(6))", systemPrompt: prompt, agentAddress: nil)
        agent.description = description
        return agent
    }

    @Test("Off by default; the setting persists")
    func defaults() {
        #expect(ChatConfiguration().backfillAgentDescriptions == false)
    }

    @Test("Generated fields round-trip and older agents decode without them")
    func codable() throws {
        var agent = Self.makeAgent()
        agent.generatedDescription = "Plans meals"
        agent.generatedDescriptionPromptHash = AgentDescriptionPolicy.promptHash(agent.systemPrompt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(agent)
        let back = try decoder.decode(Agent.self, from: data)
        #expect(back.generatedDescription == "Plans meals")
        #expect(back.routingDescription == "Plans meals")
        #expect(back.displayDescription == "Plans meals")

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "generatedDescription")
        object.removeValue(forKey: "generatedDescriptionPromptHash")
        let old = try decoder.decode(Agent.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.generatedDescription == nil)
        #expect(old.displayDescription.isEmpty)
    }

    @Test("Your own description always wins over a generated one")
    func authoredWins() {
        var agent = Self.makeAgent(description: "Keeps my recipes")
        agent.generatedDescription = "Plans meals"
        #expect(agent.routingDescription == "Keeps my recipes")
        #expect(agent.displayDescription == "Keeps my recipes")
        #expect(!AgentDescriptionBackfill.needsGeneration(agent))
    }

    @Test("While off, nothing is requested")
    func offMakesNoRequests() async throws {
        try await ChatHistoryTestStorage.run {
            var calls = 0
            let backfill = AgentDescriptionBackfill(isEnabled: { false }, generator: { _, _ in calls += 1; return "x" })
            let agent = Self.makeAgent()
            AgentManager.shared.add(agent)
            backfill.scheduleAll()
            await backfill.drain()
            #expect(calls == 0)
            #expect(AgentManager.shared.agent(for: agent.id)?.generatedDescription == nil)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test("While on, blank agents get a purpose once; an instruction edit redoes it")
    func onFillsAndInvalidates() async throws {
        try await ChatHistoryTestStorage.run {
            var calls = 0
            let backfill = AgentDescriptionBackfill(
                isEnabled: { true },
                generator: { prompt, _ in
                    calls += 1
                    return prompt.contains("pantry") ? "Plans meals from the pantry" : "Tracks books"
                })
            let agent = Self.makeAgent()
            let authored = Self.makeAgent(description: "Mine")
            AgentManager.shared.add(agent)
            AgentManager.shared.add(authored)
            backfill.scheduleAll()
            await backfill.drain()
            #expect(AgentManager.shared.agent(for: agent.id)?.displayDescription == "Plans meals from the pantry")
            #expect(AgentManager.shared.agent(for: authored.id)?.generatedDescription == nil)
            #expect(calls == 1)

            backfill.scheduleAll()  // same instructions: nothing to do
            await backfill.drain()
            #expect(calls == 1)

            var edited = try #require(AgentManager.shared.agent(for: agent.id))
            edited.systemPrompt = "You track the books I read."
            AgentManager.shared.update(edited)
            backfill.scheduleIfNeeded(agent.id)
            await backfill.drain()
            #expect(AgentManager.shared.agent(for: agent.id)?.generatedDescription == "Tracks books")
            #expect(calls == 2)
            _ = await AgentManager.shared.delete(id: agent.id)
            _ = await AgentManager.shared.delete(id: authored.id)
        }
    }

    @Test("A description typed while the model works is kept")
    func userEditDuringGenerationWins() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.makeAgent()
            AgentManager.shared.add(agent)
            let backfill = AgentDescriptionBackfill(
                isEnabled: { true },
                generator: { _, _ in
                    // The user types a description mid-request.
                    if var current = AgentManager.shared.agent(for: agent.id) {
                        current.description = "Typed by me"
                        AgentManager.shared.update(current)
                    }
                    return "Generated"
                })
            backfill.scheduleIfNeeded(agent.id)
            await backfill.drain()
            let saved = try #require(AgentManager.shared.agent(for: agent.id))
            #expect(saved.description == "Typed by me")
            #expect(saved.generatedDescription == nil)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test("The Orchestrator roster uses a generated purpose when none is written")
    func rosterUsesGenerated() {
        var agent = Self.makeAgent()
        agent.generatedDescription = "Plans meals"
        agent.defaultModel = "deepseek-flash"
        var configuration = OrchestratorDelegationConfiguration()
        configuration.customAgentAllowlist = [agent.id]
        configuration.admittedCloudModelIDs = ["deepseek-flash"]
        let evaluation = IntelOrchestratorAdmission.evaluate(
            configuration: configuration, agents: [agent], effectiveModel: { _ in "deepseek-flash" })
        #expect(evaluation.targets.first?.purpose == "Plans meals")
    }
}
