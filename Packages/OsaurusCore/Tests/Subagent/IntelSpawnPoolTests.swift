//
//  IntelSpawnPoolTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  W-subagents stage 1: the Orchestrator's spawn pool is its Gate 4
//  allowlist, never upstream's stored pool; the delegated-run contract and
//  the spawn input contract behave as upstream's.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel spawn pool and delegated contract", .serialized)
struct IntelSpawnPoolTests {
    @Test("the Default launcher's pool is the Gate 4 allowlist in a stable order")
    func poolIsGate4Allowlist() {
        let a = UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!
        let b = UUID(uuidString: "00000000-0000-4000-8000-00000000000B")!
        let pool = IntelSpawnPool.defaultLauncherAgentIDs(gate4: [b, a])
        #expect(pool == [a, b])
        #expect(IntelSpawnPool.defaultLauncherAgentIDs(gate4: []).isEmpty)
    }

    @Test("a stored upstream pool never widens the Orchestrator's reach")
    func storedPoolIsIgnored() async {
        await StoragePathsTestLock.shared.run {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-spawnpool-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            DefaultAgentConfigurationStore.overrideDirectory = directory
            DefaultAgentConfigurationStore.resetCacheForTests()
            defer {
                DefaultAgentConfigurationStore.overrideDirectory = nil
                DefaultAgentConfigurationStore.resetCacheForTests()
            }

            let stored = UUID()
            let allowed = UUID()
            // Empty Gate 4 list, non-empty stored pool: nothing is spawnable.
            #expect(IntelSpawnPool.defaultLauncherAgentIDs(storedPool: [stored]).isEmpty)

            var configuration = DefaultAgentConfiguration()
            configuration.delegation.customAgentAllowlist = [allowed]
            DefaultAgentConfigurationStore.save(configuration)
            #expect(IntelSpawnPool.defaultLauncherAgentIDs(storedPool: [stored]) == [allowed])

            // The registry's visibility seam reads the same pool.
            let ids = SubagentToolVisibility.effectiveSpawnableAgents(
                isDefault: true,
                config: SubagentConfiguration.default,
                perAgentEnabled: false,
                perAgentTargets: []
            )
            #expect(ids == [allowed])
            #expect(
                SubagentToolVisibility.spawnAgentAvailable(
                    isDefault: true,
                    config: SubagentConfiguration.default,
                    perAgentEnabled: false,
                    perAgentTargets: []
                )
            )
        }
    }

    @Test("a custom launcher keeps its own per-agent pool, only while its toggle is on")
    func customLauncherPool() {
        let target = UUID()
        #expect(
            SubagentToolVisibility.effectiveSpawnableAgents(
                isDefault: false, config: .default, perAgentEnabled: false, perAgentTargets: [target]
            ).isEmpty
        )
        #expect(
            SubagentToolVisibility.effectiveSpawnableAgents(
                isDefault: false, config: .default, perAgentEnabled: true, perAgentTargets: [target]
            ) == [target]
        )
    }

    @Test("derive prices a bounded contract and fails closed on a zero window")
    func derivedContract() throws {
        let contract = try #require(
            DelegatedRunContract.derive(
                seedCharacters: 800,
                systemPromptCharacters: 2_000,
                toolSchemaTokens: 375,
                budgets: SubagentBudgets(maxDelegateTokens: 2048, maxDelegateTurns: 2),
                toolEnabled: true,
                resolvedContextWindow: 65_536
            )
        )
        #expect(contract.responseTokens == 2048)
        #expect(contract.assistantTurns == 2)
        #expect(contract.contextPositions <= 65_536)
        // Clamps only tighten.
        #expect(contract.clampedResponseTokens(agentConfigured: 512) == 512)
        #expect(contract.clampedResponseTokens(agentConfigured: 100_000) == 2048)
        #expect(contract.clampedToolAttempts(surfaceConfigured: 99) == 2)
        #expect(contract.clampedToolAttempts(surfaceConfigured: 1) == 1)
        #expect(contract.clampedContextWindow(resolved: 1_000_000) == contract.contextPositions)
        #expect(
            DelegatedRunContract.derive(
                seedCharacters: 1, systemPromptCharacters: 1, toolSchemaTokens: 0,
                budgets: SubagentBudgets(), toolEnabled: false, resolvedContextWindow: 0
            ) == nil
        )
        #expect(
            DelegatedRunContract.derive(
                seedCharacters: Int.max, systemPromptCharacters: 1, toolSchemaTokens: 0,
                budgets: SubagentBudgets(), toolEnabled: false, resolvedContextWindow: 8_192
            ) == nil
        )
    }

    @Test("a blank worker task is refused with a retryable invalid_args envelope")
    func blankInputRefused() {
        #expect(SpawnInputContract.validationFailure(input: "do it", tool: "spawn_agent") == nil)
        let failure = SpawnInputContract.validationFailure(input: "  \n", tool: "spawn_agent")
        #expect(failure != nil)
        #expect(failure?.contains("invalid_args") == true)
    }

    @Test("delegated sessions are tagged as delegation")
    func sessionSource() {
        #expect(SessionSource.delegation.rawValue == "delegation")
        #expect(SessionSource.delegation.originLabel() == "delegated")
        #expect(SessionSource.allCases.contains(.delegation))
    }

    @Test("fan-out limit message names the kind and the limit")
    func fanOutMessage() {
        let message = SpawnFanOutPolicy.fanOutLimitMessage(requested: 5, limit: 2, kind: "remote")
        #expect(message.contains("5 remote subagents"))
        #expect(message.contains("at most 2"))
    }
}
