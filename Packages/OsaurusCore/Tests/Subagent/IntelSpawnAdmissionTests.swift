//
//  IntelSpawnAdmissionTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  W-subagents stage 3: Gate 4's admission rules for `spawn_agent`
//  (`IntelSpawnAdmission`), the permission gate (`SpawnPermissionGate`) and the
//  per-launcher concurrency cap. Pure and in-process: no network, no keychain,
//  no live data.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel spawn admission (Gate 4)", .serialized)
struct IntelSpawnAdmissionTests {
    private let launcher = UUID()
    private let target = UUID()

    private func facts(
        launcher: UUID? = nil,
        isDefault: Bool = false,
        pool: [UUID]? = nil,
        admitted: Set<String> = ["cloud/child"],
        available: Set<String> = ["cloud/child"],
        override: String? = nil,
        permission: OrchestratorDelegationPermission? = nil
    ) -> IntelSpawnAdmission.Facts {
        let launcherID = launcher ?? self.launcher
        var configuration = OrchestratorDelegationConfiguration(admittedCloudModelIDs: admitted)
        if let permission {
            configuration.setPermission(
                permission,
                for: OrchestratorDelegationPermissionScope(launcherAgentID: launcherID, targetAgentID: target))
        }
        return IntelSpawnAdmission.Facts(
            launcherID: launcherID, isDefaultLauncher: isDefault, pool: pool ?? [target],
            configuration: configuration, availableCloudModelIDs: available, launcherModelOverride: override)
    }

    private func targetFacts(model: String? = "cloud/child", builtIn: Bool = false) -> IntelSpawnAdmission.TargetFacts {
        .init(id: target, name: "Researcher", isBuiltIn: builtIn, effectiveModel: model)
    }

    private func verdict(
        _ facts: IntelSpawnAdmission.Facts, target targetFacts: IntelSpawnAdmission.TargetFacts?
    ) -> Result<IntelSpawnAdmission.Admitted, IntelSpawnAdmission.Denial> {
        IntelSpawnAdmission.evaluate(facts, targetID: target, target: targetFacts)
    }

    // MARK: Admission

    @Test func admitsAPooledCustomAgentOnAnAdmittedAvailableModel() throws {
        let admitted = try verdict(facts(), target: targetFacts()).get()
        #expect(admitted.model == "cloud/child")
        #expect(admitted.targetName == "Researcher")
        #expect(admitted.pairPermission == .ask)
        #expect(admitted.scope.targetAgentID == target)
    }

    @Test func refusesEveryUnadmittedShape() {
        #expect(verdict(facts(pool: []), target: targetFacts()) == .failure(.notSpawnable))
        #expect(verdict(facts(), target: nil) == .failure(.missingTarget))
        #expect(verdict(facts(), target: targetFacts(builtIn: true)) == .failure(.builtInTarget))
        #expect(verdict(facts(), target: targetFacts(model: nil)) == .failure(.noModel))
        #expect(verdict(facts(), target: targetFacts(model: "  ")) == .failure(.noModel))
        #expect(
            verdict(facts(admitted: []), target: targetFacts()) == .failure(.modelNotAdmitted("cloud/child")))
        #expect(
            verdict(facts(admitted: ["other/model"]), target: targetFacts())
                == .failure(.modelNotAdmitted("cloud/child")))
        #expect(
            verdict(facts(available: []), target: targetFacts()) == .failure(.modelUnavailable("cloud/child")))
        #expect(verdict(facts(permission: .deny), target: targetFacts()) == .failure(.permissionDenied))
        // A launcher never spawns itself, whatever the pool says.
        let selfFacts = facts(launcher: target, pool: [target])
        #expect(verdict(selfFacts, target: targetFacts()) == .failure(.selfTarget))
        #expect(
            IntelSpawnAdmission.evaluate(facts(), targetID: Agent.defaultId, target: nil)
                == .failure(.missingTarget))
    }

    @Test func theDefaultAgentIsNeverATarget() {
        let defaultTarget = IntelSpawnAdmission.TargetFacts(
            id: Agent.defaultId, name: "Default", isBuiltIn: false, effectiveModel: "cloud/child")
        let defaultFacts = IntelSpawnAdmission.Facts(
            launcherID: launcher, isDefaultLauncher: false, pool: [Agent.defaultId],
            configuration: OrchestratorDelegationConfiguration(admittedCloudModelIDs: ["cloud/child"]),
            availableCloudModelIDs: ["cloud/child"], launcherModelOverride: nil)
        #expect(
            IntelSpawnAdmission.evaluate(defaultFacts, targetID: Agent.defaultId, target: defaultTarget)
                == .failure(.builtInTarget))
    }

    @Test func aLauncherModelOverrideMustItselfBeAdmitted() throws {
        // The override replaces the target's model, and Gate 4 judges the model
        // that will actually run.
        let ok = try verdict(
            facts(admitted: ["cloud/child", "cloud/big"], available: ["cloud/child", "cloud/big"], override: "cloud/big"),
            target: targetFacts()
        ).get()
        #expect(ok.model == "cloud/big")
        #expect(
            verdict(facts(override: "cloud/big"), target: targetFacts()) == .failure(.modelNotAdmitted("cloud/big")))
        // A blank override inherits.
        #expect(try verdict(facts(override: "   "), target: targetFacts()).get().model == "cloud/child")
    }

    @Test func permissionModesComeFromGateFour() throws {
        #expect(try verdict(facts(permission: .alwaysAllow), target: targetFacts()).get().pairPermission == .alwaysAllow)
        #expect(try verdict(facts(permission: .ask), target: targetFacts()).get().pairPermission == .ask)
    }

    @Test func refusalCopyNamesTheRepair() {
        let copy = IntelSpawnAdmission.error(
            for: .modelNotAdmitted("cloud/child"), targetLabel: "Researcher", isDefaultLauncher: true)
        #expect(copy.envelope(tool: "spawn_agent").contains("Settings → Orchestrator"))
        let notSpawnable = IntelSpawnAdmission.error(
            for: .notSpawnable, targetLabel: "Researcher", isDefaultLauncher: false)
        #expect(notSpawnable.envelope(tool: "spawn_agent").contains("Subagents tab"))
    }

    // MARK: Permission combination

    @Test func theStricterPermissionWins() {
        #expect(TextSubagentKind.combine(launcher: .alwaysAllow, pair: .alwaysAllow) == .alwaysAllow)
        #expect(TextSubagentKind.combine(launcher: .alwaysAllow, pair: .ask) == .ask)
        #expect(TextSubagentKind.combine(launcher: .ask, pair: .alwaysAllow) == .ask)
        #expect(TextSubagentKind.combine(launcher: .alwaysAllow, pair: .deny) == .deny)
        #expect(TextSubagentKind.combine(launcher: .deny, pair: .alwaysAllow) == .deny)
        #expect(SpawnPermissionGate.combinedPolicy([.alwaysAllow, .ask, .deny]) == .deny)
    }

    // MARK: Permission gate

    private func scope(agent: UUID? = nil) -> SubagentScope {
        SubagentScope(sessionId: "s", toolCallId: "c", agentId: agent ?? launcher)
    }

    @Test func denyAndAlwaysAllowNeverPrompt() async {
        let prompts = PromptCounter()
        let (denied, allowed) = await SpawnPermissionGate.$promptOverride.withValue({ _ in
            prompts.bump()
            return .allowOnce
        }) {
            let denied = await SpawnPermissionGate.authorize(
                scope: scope(), policy: .deny, toolName: "spawn_agent", description: "d", argumentsJSON: "{}")
            let allowed = await SpawnPermissionGate.authorize(
                scope: scope(), policy: .alwaysAllow, toolName: "spawn_agent", description: "d", argumentsJSON: "{}")
            return (denied, allowed)
        }
        #expect(prompts.count == 0)
        if case .denied = denied {} else { Issue.record("Deny must refuse, got \(denied)") }
        if case .allow = allowed {} else { Issue.record("Always Allow must allow, got \(allowed)") }
    }

    @Test func askPromptsOncePerCallAndHonoursTheChoice() async {
        let prompts = PromptCounter()
        for (choice, expectAllow) in [
            (SpawnPermissionGate.PromptChoice.allowOnce, true), (.deny, false),
        ] {
            let decision = await SpawnPermissionGate.$promptOverride.withValue({ request in
                prompts.bump()
                #expect(request.toolName == "spawn_agent")
                #expect(request.launchingAgentId == launcher)
                return choice
            }) {
                // The pair scope makes the queued-card revalidation read Gate 4's
                // default (Ask) instead of the launcher's Always Allow default.
                await SpawnPermissionGate.authorize(
                    scope: scope(), policy: .ask, toolName: "spawn_agent", description: "d", argumentsJSON: "{}",
                    pairScope: OrchestratorDelegationPermissionScope(launcherAgentID: launcher, targetAgentID: UUID()))
            }
            switch decision {
            case .allow: #expect(expectAllow)
            case .userDenied: #expect(!expectAllow)
            default: Issue.record("Unexpected decision \(decision)")
            }
        }
        #expect(prompts.count == 2)
    }

    @Test func askWithNoWayToAskIsRefusedNeverApproved() async {
        let prompts = PromptCounter()
        // An external surface and a run that denies unapproved prompts both
        // cannot reach the user's card: refuse, and never show one.
        let external = await SpawnPermissionGate.$promptOverride.withValue({ _ in
            prompts.bump()
            return .allowOnce
        }) {
            await ChatExecutionContext.$isExternalSurface.withValue(true) {
                await SpawnPermissionGate.authorize(
                    scope: scope(), policy: .ask, toolName: "spawn_agent", description: "d", argumentsJSON: "{}")
            }
        }
        let denying = await SpawnPermissionGate.$promptOverride.withValue({ _ in
            prompts.bump()
            return .allowOnce
        }) {
            await ChatExecutionContext.$denyUnapprovedToolPrompts.withValue(true) {
                await SpawnPermissionGate.authorize(
                    scope: scope(), policy: .ask, toolName: "spawn_agent", description: "d", argumentsJSON: "{}")
            }
        }
        for decision in [external, denying] {
            if case .userDenied = decision {} else { Issue.record("Expected a refusal, got \(decision)") }
        }
        #expect(prompts.count == 0)
    }

    @Test func aHeadlessTestProcessDeniesTheRealCard() async {
        // No override bound: the real approval service denies in a test
        // process (nobody can press the button), so Ask is refused.
        let decision = await SpawnPermissionGate.authorize(
            scope: scope(), policy: .ask, toolName: "spawn_agent", description: "d", argumentsJSON: "{}")
        if case .userDenied = decision {} else { Issue.record("Expected a refusal, got \(decision)") }
    }

    @Test func silentResolutionSettlesAQueuedCard() {
        #expect(SpawnPermissionGate.silentResolution(for: .alwaysAllow) == .allowOnce)
        #expect(SpawnPermissionGate.silentResolution(for: .deny) == .denied)
        #expect(SpawnPermissionGate.silentResolution(for: .ask) == nil)
    }

    // MARK: Concurrency cap

    @Test func concurrencyGuardNeverExceedsTheLimit() {
        let guardrail = SpawnConcurrencyGuard()
        let a = UUID(), b = UUID()
        var leases: [SpawnConcurrencyGuard.Lease] = []
        for _ in 0 ..< 3 { leases.append(guardrail.acquire(launcher: a, limit: 3)!) }
        #expect(guardrail.acquire(launcher: a, limit: 3) == nil)
        // Another launcher has its own budget.
        #expect(guardrail.acquire(launcher: b, limit: 3) != nil)
        guardrail.release(leases[0])
        #expect(guardrail.acquire(launcher: a, limit: 3) != nil)
        #expect(guardrail.activeCount(launcher: a) == 3)
        // The limit is floored at one, never zero.
        #expect(SpawnConcurrencyGuard().acquire(launcher: a, limit: 0) != nil)
    }

    @Test func fanOutDefaultsAreUpstreamsAndNotRaised() {
        #expect(SubagentBudgets.defaultMaxRemoteParallelSpawns == 8)
        #expect(SubagentBudgets().maxRemoteParallelSpawns == 8)
        #expect(SubagentBudgets.defaultMaxDelegateTurns == 24)
        #expect(SubagentBudgets.defaultMaxDelegateTokens == 8_192)
        #expect(SubagentBudgets.defaultMaxElapsedSeconds == 900)
    }
}

private final class PromptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
