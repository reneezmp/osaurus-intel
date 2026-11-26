//
//  SpawnWaveGateTests.swift
//  OsaurusCoreTests
//
//  N spawn calls in one model message rendezvous into one approval card and
//  one fan-out limit check. Model-free: the wave's card is replaced by a
//  task-local override, and membership is driven directly on the actor.
//
//  Ported from upstream Classic (W-subagents stage 6); Intel's members carry a
//  Gate 4 pair scope, there are no workspace members, and the batch executor
//  is Intel's `AgentToolLoop.runBatchInParallel`.
//

import Foundation
import Testing

@testable import OsaurusCore

private actor WaveCardProbe {
    private(set) var calls: [[SpawnWaveGate.Member]] = []
    private(set) var leaders: [String] = []
    private var release: CheckedContinuation<Void, Never>?
    private var holding = false

    func record(_ members: [SpawnWaveGate.Member], leader: SpawnWaveGate.Member) {
        calls.append(members)
        leaders.append(leader.callId)
    }

    /// Suspend the card until `open()`; observes cancellation.
    func hold() async -> Bool {
        holding = true
        let cancelled = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                release = c
            }
            return Task.isCancelled
        } onCancel: {
            Task { await self.open() }
        }
        return cancelled
    }

    func open() {
        release?.resume()
        release = nil
    }

    var isHolding: Bool { holding }
}

@Suite("Spawn wave gate", .serialized)
struct SpawnWaveGateTests {
    private func call(
        _ id: String,
        _ tool: String,
        _ args: String = #"{"input":"Do one bounded task","agent":"Worker"}"#
    ) -> IntelBatchCall {
        IntelBatchCall(callId: id, toolName: tool, jsonArguments: args)
    }

    private let pair = OrchestratorDelegationPermissionScope(launcherAgentID: Agent.defaultId, targetAgentID: UUID())

    private func scope(_ callId: String, agent: UUID = Agent.defaultId) -> SubagentScope {
        SubagentScope(sessionId: "wave-tests", toolCallId: callId, agentId: agent)
    }

    private func member(_ callId: String, local: Bool = true, tool: String = "spawn_agent")
        -> SpawnWaveGate.Member
    {
        SpawnWaveGate.Member(
            callId: callId,
            toolName: tool,
            scope: scope(callId),
            argumentsJSON: #"{"target":"Worker","input":"task \#(callId)"}"#,
            isLocal: local,
            pairScope: pair
        )
    }

    // MARK: - Context

    @Test("a wave exists only for two or more foreground spawn calls, in model order")
    func waveContextRequiresTwoForegroundSpawnCalls() {
        let spawn = SubagentCapabilityRegistry.spawnAgentToolName

        #expect(SpawnWaveContext.make(for: [call("a", spawn)]) == nil)
        #expect(SpawnWaveContext.make(for: [call("a", spawn), call("b", "file_read", "{}")]) == nil)

        let mixed = SpawnWaveContext.make(for: [
            call("r", "file_read", "{}"),
            call("a", spawn),
            call("b", spawn, #"{"input":"x","agent":"Other"}"#),
            call("bg", spawn, #"{"input":"x","agent":"W","background":true}"#),
            call("c", spawn),
        ])
        #expect(mixed?.expectedCallIds == ["a", "b", "c"], "background calls and other tools are not members")
    }

    @Test("Intel's batch executor binds the wave for two foreground spawns only, and closes it after")
    func batchExecutorBindsTheWave() async {
        let spawn = SubagentCapabilityRegistry.spawnAgentToolName
        let seen = LockedBox<[String: [String]]>([:])
        let twoSpawns = [call("a", spawn), call("b", spawn), call("r", "file_read", "{}")]
        _ = await AgentToolLoop.runBatchInParallel(twoSpawns) { batch in
            seen.mutate { $0[batch.callId] = (ChatExecutionContext.spawnWave?.expectedCallIds ?? []) }
            return "{}"
        }
        #expect(seen.value["a"] == ["a", "b"])
        #expect(seen.value["b"] == ["a", "b"])
        #expect(seen.value["r"] == ["a", "b"], "the wave is bound for the whole batch; only spawn calls join it")

        seen.set([:])
        let oneSpawn = [call("a", spawn), call("bg", spawn, #"{"input":"x","agent":"W","background":true}"#)]
        _ = await AgentToolLoop.runBatchInParallel(oneSpawn) { batch in
            seen.mutate { $0[batch.callId] = (ChatExecutionContext.spawnWave?.expectedCallIds ?? []) }
            return "{}"
        }
        #expect(seen.value["a"] == [], "one foreground spawn is not a wave")

        // The batch closed its wave: nothing stays open on the shared gate.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await SpawnWaveGate.shared.openWaveCountForTesting == 0)
    }

    // MARK: - Pure limit policy

    @Test("an approved wave admits members in model order up to the local and remote limits")
    func outcomeAppliesIndependentLocalAndRemoteLimits() {
        let members = [
            member("l1", local: true), member("r1", local: false), member("l2", local: true),
            member("l3", local: true), member("r2", local: false), member("r3", local: false),
        ]
        let outcome = SpawnWaveGate.outcome(
            for: members,
            limits: SpawnFanOutLimits(local: 2, remote: 2),
            decision: .allow
        )
        #expect(outcome.verdicts["l1"] == .allow)
        #expect(outcome.verdicts["l2"] == .allow)
        #expect(outcome.verdicts["r1"] == .allow)
        #expect(outcome.verdicts["r2"] == .allow)
        guard case .unavailable(let localReason)? = outcome.verdicts["l3"] else {
            Issue.record("third local member must be refused for capacity, got \(String(describing: outcome.verdicts["l3"]))")
            return
        }
        #expect(localReason.contains("3 local subagents"))
        #expect(localReason.contains("at most 2 local"))
        guard case .unavailable(let remoteReason)? = outcome.verdicts["r3"] else {
            Issue.record("third remote member must be refused for capacity")
            return
        }
        #expect(remoteReason.contains("remote"))
    }

    @Test("a denied wave denies every member; remote members never consume the local limit")
    func outcomePropagatesDenialAndKeepsBudgetsSeparate() {
        let members = [member("l1"), member("r1", local: false), member("r2", local: false)]
        let denied = SpawnWaveGate.outcome(
            for: members,
            limits: SpawnFanOutLimits(local: 1, remote: 8),
            decision: .userDenied("no")
        )
        #expect(denied.verdicts.values.allSatisfy { $0 == .userDenied("no") })

        let allowed = SpawnWaveGate.outcome(
            for: members,
            limits: SpawnFanOutLimits(local: 1, remote: 8),
            decision: .allow
        )
        #expect(allowed.verdicts.values.allSatisfy { $0 == .allow })
    }

    @Test("the wave's card names the one delegation tool and lists every member")
    func cardCopyNamesEveryMember() {
        let same = [member("a"), member("b")]
        #expect(SpawnWaveGate.cardToolName(for: same) == "spawn_agent")
        let mixed = [member("a"), member("b", local: false)]
        #expect(SpawnWaveGate.cardToolName(for: mixed) == "spawn_agent")
        #expect(SpawnWaveGate.cardDescription(count: 3).hasPrefix("Let this agent run 3 subagents in parallel?"))
        #expect(SpawnWaveGate.cardDescription(count: 3).contains("cloud"))

        let json = SpawnWaveGate.cardArgumentsJSON(for: mixed)
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(object?["parallel_subagents"] as? Int == 2)
        let entries = object?["subagents"] as? [[String: Any]]
        #expect(entries?.count == 2)
        #expect(entries?[0]["input"] as? String == "task a")
        #expect(entries?[1]["tool"] as? String == "spawn_agent")
    }

    // MARK: - Rendezvous

    @Test("siblings rendezvous into one card and each receives its own verdict")
    func siblingsShareOneCard() async {
        let context = SpawnWaveContext(expectedCallIds: ["a", "b", "c"])
        let gate = SpawnWaveGate.shared
        await gate.open(context)
        defer { Task { await gate.close(waveId: context.waveId) } }
        let probe = WaveCardProbe()

        let verdicts = await SpawnWaveGate.$authorizeOverrideForTests.withValue(
            { members, leader in
                await probe.record(members, leader: leader)
                return .allow
            }
        ) {
            await withTaskGroup(of: (String, SubagentDecision?).self) { group in
                // Join out of model order to prove the leader is model-ordered.
                for id in ["c", "a", "b"] {
                    group.addTask {
                        (
                            id,
                            await gate.join(
                                self.member(id, local: id != "b"),
                                wave: context,
                                limits: SpawnFanOutLimits(local: 1, remote: 8)
                            )
                        )
                    }
                }
                var collected: [String: SubagentDecision?] = [:]
                for await (id, verdict) in group { collected[id] = verdict }
                return collected
            }
        }

        let calls = await probe.calls
        #expect(calls.count == 1, "exactly one card for the whole wave")
        #expect(calls.first?.map(\.callId) == ["a", "b", "c"], "members listed in model order")
        #expect(await probe.leaders == ["a"])
        #expect(verdicts["a"] == .allow)
        #expect(verdicts["b"] == .allow, "remote member does not consume the local limit")
        guard case .unavailable? = verdicts["c"] ?? nil else {
            Issue.record("second local member over a local limit of 1 must be refused; got \(String(describing: verdicts["c"]))")
            return
        }
    }

    @Test("a sibling that settles before joining does not hold the rendezvous")
    func settledSiblingReleasesTheRendezvous() async {
        let context = SpawnWaveContext(expectedCallIds: ["a", "b"])
        let gate = SpawnWaveGate.shared
        await gate.open(context)
        defer { Task { await gate.close(waveId: context.waveId) } }
        let probe = WaveCardProbe()

        // `a` failed argument validation and settled without joining.
        await gate.settle(waveId: context.waveId, callId: "a")

        let started = ContinuousClock.now
        let verdict = await SpawnWaveGate.$authorizeOverrideForTests.withValue(
            { members, leader in
                await probe.record(members, leader: leader)
                return .allow
            }
        ) {
            await gate.join(member("b"), wave: context, limits: SpawnFanOutLimits(local: 3, remote: 8))
        }
        #expect(verdict == .allow)
        #expect(ContinuousClock.now - started < .seconds(2), "must not wait for the safety deadline")
        #expect(await probe.calls.first?.map(\.callId) == ["b"])
    }

    @Test("a user denial on the shared card denies every sibling")
    func sharedDenialReachesEveryMember() async {
        let context = SpawnWaveContext(expectedCallIds: ["a", "b"])
        let gate = SpawnWaveGate.shared
        await gate.open(context)
        defer { Task { await gate.close(waveId: context.waveId) } }

        let verdicts = await SpawnWaveGate.$authorizeOverrideForTests.withValue(
            { _, _ in .userDenied("User denied spawning subagents.") }
        ) {
            await withTaskGroup(of: SubagentDecision?.self) { group in
                for id in ["a", "b"] {
                    group.addTask {
                        await gate.join(
                            self.member(id), wave: context, limits: SpawnFanOutLimits(local: 3, remote: 8))
                    }
                }
                var out: [SubagentDecision?] = []
                for await v in group { out.append(v) }
                return out
            }
        }
        #expect(verdicts.count == 2)
        #expect(verdicts.allSatisfy { $0 == .userDenied("User denied spawning subagents.") })
    }

    @Test("cancelling one waiting sibling releases it alone and the survivors still get the card")
    func cancelledSiblingDoesNotBlockSurvivors() async {
        let context = SpawnWaveContext(expectedCallIds: ["a", "b"])
        let gate = SpawnWaveGate.shared
        await gate.open(context)
        defer { Task { await gate.close(waveId: context.waveId) } }
        let probe = WaveCardProbe()

        let cancelled = Task {
            await gate.join(member("a"), wave: context, limits: SpawnFanOutLimits(local: 3, remote: 8))
        }
        // Let `a` register as a waiter before pulling the plug.
        try? await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        let aVerdict = await cancelled.value
        #expect(aVerdict == .userDenied("Spawn permission was cancelled."))

        // `b` arrives afterwards: the wave is complete (a is accounted for as
        // cancelled) and decides for `b` alone.
        let bVerdict = await SpawnWaveGate.$authorizeOverrideForTests.withValue(
            { members, leader in
                await probe.record(members, leader: leader)
                return .allow
            }
        ) {
            await gate.join(member("b"), wave: context, limits: SpawnFanOutLimits(local: 3, remote: 8))
        }
        #expect(bVerdict == .allow)
        #expect(await probe.calls.first?.map(\.callId) == ["b"])
    }

    @Test("cancelling every waiting sibling dismisses the shared card")
    func cancellingAllSiblingsCancelsTheCard() async {
        let context = SpawnWaveContext(expectedCallIds: ["a", "b"])
        let gate = SpawnWaveGate.shared
        await gate.open(context)
        defer { Task { await gate.close(waveId: context.waveId) } }
        let probe = WaveCardProbe()
        let cardCancelled = LockedBox<Bool?>(nil)

        let tasks = SpawnWaveGate.$authorizeOverrideForTests.withValue(
            { _, _ in
                let cancelled = await probe.hold()
                cardCancelled.set(cancelled)
                return .allow
            }
        ) {
            ["a", "b"].map { id in
                Task {
                    await gate.join(
                        self.member(id), wave: context, limits: SpawnFanOutLimits(local: 3, remote: 8))
                }
            }
        }
        for _ in 0 ..< 200 where !(await probe.isHolding) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.isHolding, "both joined, the card is open")

        for task in tasks { task.cancel() }
        for task in tasks {
            #expect(await task.value == .userDenied("Spawn permission was cancelled."))
        }
        for _ in 0 ..< 200 where cardCancelled.value == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(cardCancelled.value == true, "nobody is left to answer: the card must be dismissed")
    }

    @Test("a join after the wave decided, or after close, falls back to the per-call path")
    func lateAndClosedJoinsFallBack() async {
        let context = SpawnWaveContext(expectedCallIds: ["a", "b"])
        let gate = SpawnWaveGate.shared
        await gate.open(context)

        // `b` settles, `a` joins: decided for `a` alone.
        await gate.settle(waveId: context.waveId, callId: "b")
        let a = await SpawnWaveGate.$authorizeOverrideForTests.withValue({ _, _ in .allow }) {
            await gate.join(member("a"), wave: context, limits: SpawnFanOutLimits(local: 3, remote: 8))
        }
        #expect(a == .allow)
        // `b` turns up after all (settle then join is not a real path, but a
        // late arrival must never hang or receive a stale verdict).
        let late = await gate.join(member("b"), wave: context, limits: SpawnFanOutLimits(local: 3, remote: 8))
        #expect(late == nil)

        await gate.close(waveId: context.waveId)
        #expect(await gate.openWaveCountForTesting == 0)
        let closed = await gate.join(member("a"), wave: context, limits: SpawnFanOutLimits(local: 3, remote: 8))
        #expect(closed == nil)
        // A settle after close is a no-op, not a leaked wave.
        await gate.settle(waveId: context.waveId, callId: "a")
        #expect(await gate.openWaveCountForTesting == 0)
    }

    // MARK: - Through the permission gate

    @Test("two spawn_agent calls under one wave context prompt once through the permission gate")
    func permissionGateJoinsTheWave() async {
        // The gate reads the launcher's fan-out limits from the delegation
        // store (first touch may seed it); hold the store lease like every
        // other test that goes through `SpawnPermissionGate` for real.
        let lease = await acquireSubagentStoreSandbox("spawn-wave-gate-permission")
        defer { lease.release() }
        let context = SpawnWaveContext(expectedCallIds: ["a", "b"])
        let gate = SpawnWaveGate.shared
        await gate.open(context)
        defer { Task { await gate.close(waveId: context.waveId) } }
        let prompts = LockedBox<[SpawnPermissionGate.PromptRequest]>([])

        let decisions = await ChatExecutionContext.$spawnWave.withValue(context) {
            await SpawnPermissionGate.$promptOverride.withValue(
                { request in
                    prompts.mutate { $0.append(request) }
                    return .allowOnce
                }
            ) {
                await withTaskGroup(of: SubagentDecision.self) { group in
                    for id in ["a", "b"] {
                        group.addTask {
                            await SpawnPermissionGate.authorize(
                                scope: self.scope(id),
                                policy: .ask,
                                toolName: SubagentCapabilityRegistry.spawnAgentToolName,
                                description: "Allow this agent to spawn one bounded subagent?",
                                argumentsJSON: #"{"target":"Worker","input":"task \#(id)"}"#,
                                pairScope: self.pair,
                                waveMember: self.member(id, local: false)
                            )
                        }
                    }
                    var out: [SubagentDecision] = []
                    for await d in group { out.append(d) }
                    return out
                }
            }
        }

        #expect(decisions == [.allow, .allow])
        let seen = prompts.value
        #expect(seen.count == 1, "one card for two sibling calls")
        #expect(seen.first?.description.contains("run 2 subagents in parallel") == true)
        #expect(seen.first?.argumentsJSON.contains("task a") == true)
        #expect(seen.first?.argumentsJSON.contains("task b") == true)
    }

    @Test("a wave of Ask pairs never auto-approves when nobody can answer, and a Deny pair is not asked")
    func waveCardRefusesWithoutAnAnswerer() async {
        let lease = await acquireSubagentStoreSandbox("spawn-wave-gate-noask")
        defer { lease.release() }
        let context = SpawnWaveContext(expectedCallIds: ["a", "b"])
        let gate = SpawnWaveGate.shared
        await gate.open(context)
        defer { Task { await gate.close(waveId: context.waveId) } }
        let prompts = LockedBox<Int>(0)

        let decisions = await ChatExecutionContext.$spawnWave.withValue(context) {
            await ChatExecutionContext.$denyUnapprovedToolPrompts.withValue(true) {
                await SpawnPermissionGate.$promptOverride.withValue(
                    { _ in
                        prompts.mutate { $0 += 1 }
                        return .allowOnce
                    }
                ) {
                    await withTaskGroup(of: SubagentDecision.self) { group in
                        for id in ["a", "b"] {
                            group.addTask {
                                await SpawnPermissionGate.authorize(
                                    scope: self.scope(id), policy: .ask,
                                    toolName: SubagentCapabilityRegistry.spawnAgentToolName,
                                    description: "d", argumentsJSON: "{}", pairScope: self.pair,
                                    waveMember: self.member(id, local: false))
                            }
                        }
                        var out: [SubagentDecision] = []
                        for await d in group { out.append(d) }
                        return out
                    }
                }
            }
        }
        #expect(prompts.value == 0)
        for decision in decisions {
            if case .userDenied = decision {} else { Issue.record("Expected a refusal, got \(decision)") }
        }

        // A pair on Deny short-circuits before any rendezvous.
        let denied = await SpawnPermissionGate.authorize(
            scope: scope("d"), policy: .deny, toolName: "spawn_agent", description: "d", argumentsJSON: "{}",
            waveMember: member("d"))
        if case .denied = denied {} else { Issue.record("Deny must refuse, got \(denied)") }
    }

    @Test("a spawn call outside any wave context keeps its own card")
    func noWaveContextMeansPerCallPrompt() async {
        let lease = await acquireSubagentStoreSandbox("spawn-wave-gate-solo")
        defer { lease.release() }
        let prompts = LockedBox<[SpawnPermissionGate.PromptRequest]>([])
        let decision = await SpawnPermissionGate.$promptOverride.withValue(
            { request in
                prompts.mutate { $0.append(request) }
                return .allowOnce
            }
        ) {
            await SpawnPermissionGate.authorize(
                scope: scope("solo"),
                policy: .ask,
                toolName: SubagentCapabilityRegistry.spawnAgentToolName,
                description: "Allow this agent to spawn one bounded subagent?",
                argumentsJSON: "{}",
                pairScope: pair,
                waveMember: member("solo")
            )
        }
        #expect(decision == .allow)
        #expect(prompts.value.count == 1)
        #expect(prompts.value.first?.description.contains("one bounded") == true)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&stored)
        lock.unlock()
    }
}
