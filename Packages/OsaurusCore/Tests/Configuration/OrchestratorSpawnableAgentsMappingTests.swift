//
//  OrchestratorSpawnableAgentsMappingTests.swift
//  OsaurusCoreTests
//
//  W-declarative-config stage 4: `delegation.spawnable_agents` is mapped onto
//  Intel's Orchestrator Gate 4 allowlist (`OrchestratorDelegationConfiguration
//  .customAgentAllowlist`), not upstream's spawn pool
//  (`SubagentConfigurationStore.spawnableAgentIDs`), which the Orchestrator on
//  this Mac never consults. Pins that applying it changes exactly what
//  `orchestrator_delegate` may spawn, and nothing else of Gate 4.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("spawnable_agents maps onto Gate 4", .serialized)
struct OrchestratorSpawnableAgentsMappingTests {

    private static func makeAgent(_ name: String, model: String? = nil) -> Agent {
        var agent = Agent(
            name: name,
            systemPrompt: "Runs delegated probes",
            agentAddress: "test-spawnable-\(UUID().uuidString)",
            autonomousExec: AutonomousExecConfig(enabled: false)
        )
        agent.defaultModel = model
        return agent
    }

    /// Sandboxes nothing itself (the gate runs on a temporary data root); it
    /// restores the Default agent's configuration and removes its agents.
    private func withProbeAgents(
        _ count: Int,
        model: String? = nil,
        _ body: ([Agent]) async throws -> Void
    ) async throws {
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }
        let original = DefaultAgentConfigurationStore.load()
        let agents = (0 ..< count).map { Self.makeAgent("Gate4 Probe \($0) \(UUID().uuidString.prefix(6))", model: model) }
        await MainActor.run { agents.forEach { AgentManager.shared.add($0) } }
        do {
            try await body(agents)
        } catch {
            await cleanup(agents, original)
            throw error
        }
        await cleanup(agents, original)
    }

    private func cleanup(_ agents: [Agent], _ original: DefaultAgentConfiguration) async {
        for agent in agents { _ = await AgentManager.shared.delete(id: agent.id) }
        DefaultAgentConfigurationStore.save(original)
    }

    private func apply(_ names: [String]) async -> [ConfigApplyResult] {
        var document = OsaurusConfigDocument()
        var section = DelegationSection()
        section.spawnableAgents = names
        document.delegation = section
        return await ConfigApplier.apply(document: document, prune: false)
    }

    @Test func applyingTheListReplacesExactlyTheGate4Allowlist() async throws {
        try await withProbeAgents(2) { agents in
            // Seed Gate 4 with admission and a permission so we can prove they survive.
            var seeded = DefaultAgentConfigurationStore.load()
            seeded.delegation.admittedCloudModelIDs = ["probe-model"]
            seeded.delegation.setPermission(
                .alwaysAllow,
                for: OrchestratorDelegationPermissionScope(
                    launcherAgentID: Agent.defaultId, targetAgentID: agents[0].id))
            seeded.delegation.customAgentAllowlist = [agents[1].id]
            DefaultAgentConfigurationStore.save(seeded)
            let poolBefore = SubagentConfigurationStore.snapshot().spawnableAgentIDs

            let results = await apply([agents[0].name])
            #expect(results.allSatisfy { $0.status != .failed }, "\(results)")

            let after = DefaultAgentConfigurationStore.load().delegation
            #expect(after.customAgentAllowlist == [agents[0].id], "the list was not replaced")
            // Gate 4's other fields are untouched: this tool never admits a model or loosens a permission.
            #expect(after.admittedCloudModelIDs == ["probe-model"])
            #expect(after.permissionModes == seeded.delegation.permissionModes)
            #expect(after.maximumChildTokens == seeded.delegation.maximumChildTokens)
            // Upstream's spawn pool, which this Orchestrator does not read, is not written.
            #expect(SubagentConfigurationStore.snapshot().spawnableAgentIDs == poolBefore)
        }
    }

    @Test func exportReadsTheGate4AllowlistByName() async throws {
        try await withProbeAgents(2) { agents in
            var config = DefaultAgentConfigurationStore.load()
            config.delegation.customAgentAllowlist = [agents[0].id, agents[1].id]
            DefaultAgentConfigurationStore.save(config)
            let exported = await MainActor.run { ConfigExporter.export().delegation?.spawnableAgents ?? [] }
            #expect(Set(exported).isSuperset(of: [agents[0].name, agents[1].name]))
            #expect(exported == exported.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        }
    }

    @Test func theExportedListRoundTripsAsANoOp() async throws {
        try await withProbeAgents(1) { agents in
            var config = DefaultAgentConfigurationStore.load()
            config.delegation.customAgentAllowlist = [agents[0].id]
            DefaultAgentConfigurationStore.save(config)
            let exported = await MainActor.run { ConfigExporter.export().filtered(to: [.delegation]) }
            let plan = try await MainActor.run { try ConfigPlanner.plan(document: exported, prune: false) }
            #expect(plan.isEmpty, "\(plan.summaryText())")
        }
    }

    @Test func listingAgentsMakesThemRunnableOnlyWhenTheirModelIsAdmitted() async throws {
        try await withProbeAgents(1, model: "probe-model") { agents in
            var config = DefaultAgentConfigurationStore.load()
            config.delegation.customAgentAllowlist = []
            config.delegation.admittedCloudModelIDs = []
            DefaultAgentConfigurationStore.save(config)

            // Allowed but the model is not admitted: saved, and the result says
            // the agent still cannot be delegated to (this tool never admits a model).
            let results = await apply([agents[0].name])
            let row = try #require(results.first { $0.section == "delegation" })
            #expect(row.status == .done)
            #expect(row.message?.contains("only 0 of 1") == true, "\(row.message ?? "nil")")
            #expect(row.message?.contains("not an admitted model") == true || row.message?.contains("No remote cloud model is admitted") == true)
            let delegation = DefaultAgentConfigurationStore.load().delegation
            #expect(delegation.customAgentAllowlist == [agents[0].id])
            #expect(delegation.admittedCloudModelIDs.isEmpty, "the tool admitted a model")

            // With the model admitted in Settings, the same list is runnable.
            var admitted = DefaultAgentConfigurationStore.load()
            admitted.delegation.admittedCloudModelIDs = ["probe-model"]
            DefaultAgentConfigurationStore.save(admitted)
            let evaluation = await MainActor.run {
                IntelOrchestratorAdmission.evaluate(
                    configuration: DefaultAgentConfigurationStore.load().delegation,
                    agents: AgentManager.shared.agents,
                    effectiveModel: { AgentManager.shared.effectiveModel(for: $0) })
            }
            #expect(evaluation.targets.map(\.id) == [agents[0].id])
        }
    }

    @Test func anEmptyListClearsTheAllowlistAndIsFlaggedHighRisk() async throws {
        try await withProbeAgents(1) { agents in
            var config = DefaultAgentConfigurationStore.load()
            config.delegation.customAgentAllowlist = [agents[0].id]
            DefaultAgentConfigurationStore.save(config)

            var document = OsaurusConfigDocument()
            var section = DelegationSection()
            section.spawnableAgents = []
            document.delegation = section
            let plan = try await MainActor.run { try ConfigPlanner.plan(document: document, prune: false) }
            #expect(plan.hasHighRiskChanges)
            #expect(plan.risks.contains { $0.contains("allowed-agents list") }, "\(plan.risks)")

            _ = await ConfigApplier.apply(document: document, prune: false)
            #expect(DefaultAgentConfigurationStore.load().delegation.customAgentAllowlist.isEmpty)
        }
    }

    @Test func builtInAgentsAndTheDefaultAgentAreRejected() async throws {
        let builtIn = await MainActor.run { AgentManager.shared.agents.first { $0.isBuiltIn && $0.id != Agent.defaultId } }
        var names = ["Default"]
        if let builtIn { names.append(builtIn.name) }
        var document = OsaurusConfigDocument()
        var section = DelegationSection()
        section.spawnableAgents = names
        document.delegation = section
        do {
            _ = try await MainActor.run { try ConfigPlanner.plan(document: document, prune: false) }
            Issue.record("a built-in agent was accepted into the Orchestrator's allowlist")
        } catch let issues as ConfigPlanIssues {
            #expect(issues.issues.contains { $0.contains("cannot spawn itself") })
            if let builtIn {
                #expect(issues.issues.contains { $0.contains("built-in") && $0.contains(builtIn.name) })
            }
        }
    }

    @Test func otherDelegationKeysAreLabelledStoredOnly() async throws {
        var document = OsaurusConfigDocument()
        var section = DelegationSection()
        let current = await MainActor.run { ConfigExporter.export().delegation?.budgetMaxTokens }
        section.budgetMaxTokens = current == 4096 ? 2048 : 4096
        document.delegation = section
        let plan = try await MainActor.run { try ConfigPlanner.plan(document: document, prune: false) }
        let lines = plan.actions.flatMap(\.changes)
        #expect(lines.contains { $0.contains("stored only") }, "\(lines)")
    }

    // MARK: - #3227 orchestrator_spawnable on creation

    private func createAgent(_ name: String, spawnable: Bool?, delegating: Bool) async -> (ConfigPlan?, [ConfigApplyResult]) {
        var document = OsaurusConfigDocument()
        var entry = AgentEntry(name: name)
        entry.systemPrompt = "Runs delegated probes"
        entry.orchestratorSpawnable = spawnable
        document.agents = [entry]
        if delegating {
            var section = DelegationSection()
            section.spawnableAgents = [name]
            document.delegation = section
        }
        let plan = try? await MainActor.run { try ConfigPlanner.plan(document: document, prune: false) }
        let results = await ConfigApplier.apply(document: document, prune: false)
        return (plan, results)
    }

    private func deleteAgent(named name: String) async {
        let id = await MainActor.run {
            AgentManager.shared.agents.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
        }
        if let id { _ = await AgentManager.shared.delete(id: id) }
    }

    @Test func aCreatedAgentIsNeverAddedToGate4_whateverOrchestratorSpawnableSays() async throws {
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }
        let original = DefaultAgentConfigurationStore.load()
        defer { DefaultAgentConfigurationStore.save(original) }
        for spawnable in [nil, true, false] as [Bool?] {
            let name = "Gate4 Created \(UUID().uuidString.prefix(6))"
            let before = DefaultAgentConfigurationStore.load().delegation.customAgentAllowlist
            let (plan, results) = await createAgent(name, spawnable: spawnable, delegating: false)
            let lines = plan?.actions.flatMap(\.changes) ?? []
            #expect(lines.contains { $0.contains("not added to the Orchestrator's delegation list") }, "\(lines)")
            let row = results.first { $0.section == "agents" }
            #expect(row?.status == .done, "\(results)")
            #expect(row?.message?.contains("not in the Orchestrator's delegation list") == true)
            #expect(DefaultAgentConfigurationStore.load().delegation.customAgentAllowlist == before)
            await deleteAgent(named: name)
        }
    }

    @Test func aDelegationListInTheSameDocumentStillWinsOverSpawnableFalse() async throws {
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }
        let original = DefaultAgentConfigurationStore.load()
        defer { DefaultAgentConfigurationStore.save(original) }
        let name = "Gate4 Listed \(UUID().uuidString.prefix(6))"
        let (_, results) = await createAgent(name, spawnable: false, delegating: true)
        #expect(results.allSatisfy { $0.status != .failed }, "\(results)")
        let id = await MainActor.run {
            AgentManager.shared.agents.first { $0.name == name }?.id
        }
        let allow = DefaultAgentConfigurationStore.load().delegation.customAgentAllowlist
        #expect(id.map { allow.contains($0) } == true, "the explicit delegation list was overridden")
        await deleteAgent(named: name)
    }
}
