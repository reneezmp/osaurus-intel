//
//  SameTurnSpawnStagingTests.swift
//  OsaurusCoreTests
//
//  W-subagents stage 6: an approved apply that grows the launching chat's
//  runnable `spawn_agent` targets stages the tool for the SAME turn, through
//  the engine's `CapabilityLoadBuffer` (upstream `SameTurnSpawnStagingTests`).
//  Intel's pool is Gate 4 and a target must be admitted and available, so the
//  growth here is a `delegation.spawnable_agents` apply on an admitted model.
//  No network, keychain or live data.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Same-turn spawn staging", .serialized)
struct SameTurnSpawnStagingTests {
    private func probeAgent() -> Agent {
        var agent = Agent(
            name: "Stage Probe \(UUID().uuidString.prefix(6))",
            systemPrompt: "Runs delegated probes",
            agentAddress: "test-stage-\(UUID().uuidString)",
            autonomousExec: AutonomousExecConfig(enabled: false)
        )
        agent.defaultModel = "probe-model"
        return agent
    }

    private func document(_ names: [String]) -> OsaurusConfigDocument {
        var document = OsaurusConfigDocument()
        var section = DelegationSection()
        section.spawnableAgents = names
        document.delegation = section
        return document
    }

    /// Runs `body` with one probe agent, Gate 4 admitting its model and the
    /// model reported available; restores the Default agent's configuration.
    private func withProbe(_ body: (Agent) async throws -> Void) async throws {
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }
        let original = DefaultAgentConfigurationStore.load()
        let agent = probeAgent()
        await MainActor.run { AgentManager.shared.add(agent) }
        var config = original
        config.delegation.customAgentAllowlist = []
        config.delegation.admittedCloudModelIDs = ["probe-model"]
        DefaultAgentConfigurationStore.save(config)
        do {
            try await IntelSpawnAdmission.$availableModelIDsOverrideForTests.withValue(["probe-model"]) {
                try await body(agent)
            }
        } catch {
            _ = await AgentManager.shared.delete(id: agent.id)
            DefaultAgentConfigurationStore.save(original)
            throw error
        }
        _ = await AgentManager.shared.delete(id: agent.id)
        DefaultAgentConfigurationStore.save(original)
    }

    private func apply(_ names: [String], session: ChatSession?, buffer: CapabilityLoadBuffer) async {
        let box = await MainActor.run { session.map { WeakChatSessionBox($0) } }
        await CapabilityLoadBuffer.$current.withValue(buffer) {
            await ChatExecutionContext.$currentChatSessionBox.withValue(box) {
                _ = await ConfigApplier.apply(document: self.document(names), prune: false)
            }
        }
    }

    @Test func growingTheRunnablePoolStagesSpawnAgentForTheSameTurn() async throws {
        try await withProbe { agent in
            let buffer = CapabilityLoadBuffer()
            let session = await MainActor.run { () -> ChatSession in
                let session = ChatSession()
                session.agentId = Agent.defaultId
                return session
            }
            await apply([agent.name], session: session, buffer: buffer)
            let staged = await buffer.drain()
            #expect(staged == [SubagentCapabilityRegistry.spawnAgentToolName], "\(staged)")
            // Gate 4 itself holds exactly what the user's apply listed.
            #expect(DefaultAgentConfigurationStore.load().delegation.customAgentAllowlist == [agent.id])

            // Re-applying the same list grows nothing: nothing is staged.
            await apply([agent.name], session: session, buffer: buffer)
            #expect(await buffer.drain().isEmpty)
            withExtendedLifetime(session) {}
        }
    }

    @Test func noLiveSessionStagesNothing() async throws {
        try await withProbe { agent in
            let buffer = CapabilityLoadBuffer()
            await apply([agent.name], session: nil, buffer: buffer)
            #expect(await buffer.drain().isEmpty, "an unbound apply has no loop to drain the buffer")
        }
    }

    @Test func anApplyThatCannotRunAnAgentStagesNothing() async throws {
        try await withProbe { agent in
            // The model is no longer admitted: the agent is allowed but not runnable.
            var config = DefaultAgentConfigurationStore.load()
            config.delegation.admittedCloudModelIDs = []
            DefaultAgentConfigurationStore.save(config)
            let buffer = CapabilityLoadBuffer()
            let session = await MainActor.run { () -> ChatSession in
                let session = ChatSession()
                session.agentId = Agent.defaultId
                return session
            }
            await apply([agent.name], session: session, buffer: buffer)
            #expect(await buffer.drain().isEmpty)
            withExtendedLifetime(session) {}
        }
    }

    @Test func theChatBindsItsSessionForTheWholeTurn() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let chat = try String(
            contentsOf: root.appendingPathComponent("Views/Chat/ChatView.swift"), encoding: .utf8)
        #expect(chat.contains("let folderPromptBox: WeakChatSessionBox? = WeakChatSessionBox(self)"))
    }
}
