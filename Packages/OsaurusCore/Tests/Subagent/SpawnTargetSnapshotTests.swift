//
//  SpawnTargetSnapshotTests.swift
//  OsaurusCoreTests
//
//  Upstream #3121 on Intel: callers iterating a snapshot of the agents array
//  pass the record they hold instead of re-reading the @Published property per
//  agent. The instance overloads must answer exactly as the id lookups do.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct SpawnTargetSnapshotTests {

    @Test
    func effectiveModelOverload_usesTheRecordsOwnModel() {
        var agent = AgentManager.newCustomAgentRecord(name: "Snap")
        agent.defaultModel = "openai/gpt-test"
        #expect(AgentManager.shared.effectiveModel(for: agent) == "openai/gpt-test")
        agent.defaultModel = nil
        #expect(
            AgentManager.shared.effectiveModel(for: agent)
                == AgentManager.shared.effectiveModel(for: UUID()))
    }

    @Test
    func targetFactsOverload_matchesTheRecord() {
        var agent = AgentManager.newCustomAgentRecord(name: "Snap2")
        agent.defaultModel = "anthropic/claude-test"
        let facts = IntelSpawnAdmission.targetFacts(agent)
        #expect(facts.id == agent.id)
        #expect(facts.name == "Snap2")
        #expect(!facts.isBuiltIn)
        #expect(facts.effectiveModel == "anthropic/claude-test")
    }

    @Test
    func resolveTargets_readsTheSnapshotOnce() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Subagent/IntelSpawnAdmission.swift"),
            encoding: .utf8)
        #expect(source.contains("for agent in AgentManager.shared.agents where snapshot[agent.id] == nil"))
        #expect(!source.contains("manager.agent(for: id)"))
    }
}
