//
//  IntelSpawnComposerTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  W-subagents stage 3: how the composer offers `spawn_agent`. A target is
//  offered only when Gate 4 admits it (pool, admitted cloud model, available
//  model, permission not Deny); a delegated child never gets the tool; the
//  Orchestrator's one-turn `orchestrator_delegate` yields to it. Availability
//  is injected (`availableModelIDsOverrideForTests`); no provider, network or
//  live data.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("spawn_agent composer wiring", .serialized)
struct IntelSpawnComposerTests {
    private static let model = "cloud/child"

    @MainActor
    private static func setUp(admit: Bool = true, permission: OrchestratorDelegationPermission? = nil)
        -> (target: Agent, launcher: Agent)
    {
        var target = Agent(name: "target-\(UUID().uuidString.prefix(6))", systemPrompt: "You research.")
        target.toolSelectionMode = .manual
        target.manualToolNames = []
        AgentManager.shared.add(target)
        AgentManager.shared.updateDefaultModel(for: target.id, model: model)
        var launcher = Agent(name: "launcher-\(UUID().uuidString.prefix(6))", systemPrompt: "You lead.")
        launcher.toolSelectionMode = .manual
        launcher.manualToolNames = []
        launcher.settings.spawnDelegationEnabled = true
        launcher.settings.spawnableAgentIDs = [target.id]
        AgentManager.shared.add(launcher)
        var configuration = DefaultAgentConfigurationStore.load()
        configuration.delegation.customAgentAllowlist = [target.id]
        configuration.delegation.admittedCloudModelIDs = admit ? [model] : []
        if let permission {
            configuration.delegation.setPermission(
                permission,
                for: OrchestratorDelegationPermissionScope(
                    launcherAgentID: Agent.defaultId, targetAgentID: target.id))
        }
        AgentManager.shared.updateDefaultAgentConfiguration(configuration)
        return (target, launcher)
    }

    @MainActor
    private static func tearDown(_ agents: Agent...) async {
        var configuration = DefaultAgentConfigurationStore.load()
        configuration.delegation = .default
        AgentManager.shared.updateDefaultAgentConfiguration(configuration)
        for agent in agents { _ = await AgentManager.shared.delete(id: agent.id) }
    }

    private func compose(
        _ agentId: UUID, available: Set<String> = [model], source: SessionSource = .chat
    ) async -> ComposedContext {
        await IntelSpawnAdmission.$availableModelIDsOverrideForTests.withValue(available) {
            await ChatExecutionContext.$currentSessionSource.withValue(source) {
                await SystemPromptComposer.composeChatContext(agentId: agentId, query: "hi")
            }
        }
    }

    private func enumValues(_ context: ComposedContext) -> [String]? {
        guard let spec = context.tools.first(where: { $0.function.name == "spawn_agent" }),
            case .object(let root)? = spec.function.parameters,
            case .object(let properties)? = root["properties"],
            case .object(let agent)? = properties["agent"],
            case .array(let values)? = agent["enum"]
        else { return nil }
        return values.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    @MainActor
    @Test("The Orchestrator gets spawn_agent narrowed to its admitted pool, and yields orchestrator_delegate")
    func orchestratorGetsSpawn() async throws {
        try await ChatHistoryTestStorage.run {
            let (target, launcher) = Self.setUp()
            let context = await compose(Agent.defaultId)
            let names = Set(context.tools.map(\.function.name))
            #expect(names.contains("spawn_agent"))
            #expect(!names.contains("orchestrator_delegate"))
            #expect(names.contains("osaurus_config"))
            #expect(enumValues(context)?.contains(target.id.uuidString) == true)
            #expect(enumValues(context)?.contains(target.name) == true)
            #expect(context.prompt.contains("## Your agents (spawn_agent targets)"))
            #expect(context.prompt.contains("Delegation is available only through `spawn_agent`"))
            #expect(!context.prompt.contains("tool-free, limited to one turn"))
            #expect(context.promptSections.contains { $0.id == "spawn" })
            await Self.tearDown(target, launcher)
        }
    }

    @MainActor
    @Test("Without an admitted or available model the tool is not offered and the old path stays")
    func notOfferedWithoutAdmission() async throws {
        try await ChatHistoryTestStorage.run {
            let (target, launcher) = Self.setUp(admit: false)
            let unadmitted = await compose(Agent.defaultId)
            #expect(!unadmitted.tools.contains { $0.function.name == "spawn_agent" })
            #expect(unadmitted.tools.contains { $0.function.name == "orchestrator_delegate" })
            await Self.tearDown(target, launcher)

            let (target2, launcher2) = Self.setUp()
            let unavailable = await compose(Agent.defaultId, available: [])
            #expect(!unavailable.tools.contains { $0.function.name == "spawn_agent" })
            await Self.tearDown(target2, launcher2)

            let (target3, launcher3) = Self.setUp(permission: .deny)
            let denied = await compose(Agent.defaultId)
            #expect(!denied.tools.contains { $0.function.name == "spawn_agent" })
            await Self.tearDown(target3, launcher3)
        }
    }

    @MainActor
    @Test("A custom launcher needs its own Spawn switch and an admitted model; the grant bypasses the allowlist")
    func customLauncher() async throws {
        try await ChatHistoryTestStorage.run {
            let (target, launcher) = Self.setUp()
            let on = await compose(launcher.id)
            #expect(on.tools.contains { $0.function.name == "spawn_agent" })
            #expect(on.prompt.contains("## Delegating work (spawn_agent)"))
            #expect(enumValues(on)?.contains(target.id.uuidString) == true)

            var off = launcher
            off.settings.spawnDelegationEnabled = false
            AgentManager.shared.update(off)
            let disabled = await compose(launcher.id)
            #expect(!disabled.tools.contains { $0.function.name == "spawn_agent" })
            await Self.tearDown(target, launcher)
        }
    }

    @MainActor
    @Test("A delegated child never carries spawn_agent, whatever its configuration")
    func delegatedChildNeverSpawns() async throws {
        try await ChatHistoryTestStorage.run {
            let (target, launcher) = Self.setUp()
            let child = await compose(launcher.id, source: .delegation)
            #expect(!child.tools.contains { $0.function.name == "spawn_agent" })
            #expect(!child.prompt.contains("spawn_agent"))
            await Self.tearDown(target, launcher)
        }
    }

    @MainActor
    @Test("Execution refuses a launcher with no pool and a delegated child")
    func executionGate() async throws {
        try await ChatHistoryTestStorage.run {
            let (target, launcher) = Self.setUp()
            #expect(AgentManager.shared.effectiveSpawnAgentAvailable(for: launcher.id))
            #expect(AgentManager.shared.effectiveSpawnAgentAvailable(for: Agent.defaultId))
            var off = launcher
            off.settings.spawnDelegationEnabled = false
            AgentManager.shared.update(off)
            #expect(!AgentManager.shared.effectiveSpawnAgentAvailable(for: launcher.id))
            await Self.tearDown(target, launcher)
            #expect(!AgentManager.shared.effectiveSpawnAgentAvailable(for: Agent.defaultId))
        }
    }
}
