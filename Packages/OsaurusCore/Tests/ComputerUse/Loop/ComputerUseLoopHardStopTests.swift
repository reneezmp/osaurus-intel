//
//  ComputerUseLoopHardStopTests.swift
//  OsaurusCoreTests — Computer Use (Intel fork)
//
//  Stage 4 owner policy (docs/W_COMPUTER_USE_PLAN.md): through
//  `ComputerUseLoop.run` the hard stops refuse password / credential fields
//  before ANY gate, even one that would auto-run everything, and a confirm
//  card is never shown for them. Fakes only: `MockMacDriver`, a scripted
//  provider, no real input, screen or model.
//

import Foundation
import Testing

@testable import OsaurusCore

/// A gate that runs every action with no prompt (the "Autonomous" worst case).
private struct RunEverythingGate: ComputerUseGating {
    func evaluate(action: AgentAction, effect: EffectClass, appName: String?, targetLabel: String?) async
        -> GateDecision
    { .run }
}

private actor ConfirmCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

@Suite struct ComputerUseLoopHardStopTests {
    private func driver(_ elements: [CUElement], pid: Int32 = 4242, app: String = "Demo") -> MockMacDriver {
        let snap = CUSnapshot(
            snapshotId: 1, pid: pid, app: app, focusedWindow: "Main", tier: .ax, truncated: false,
            windows: [CUWindowSummary(id: 1, title: "Main", focused: true, x: 0, y: 0, w: 800, h: 600)],
            elements: elements, image: nil
        )
        return MockMacDriver(
            activeWindow: CUActiveWindow(pid: pid, app: app, title: "Main", x: 0, y: 0, w: 800, h: 600),
            snapshots: [pid: [snap]]
        )
    }

    private func run(
        _ driver: MockMacDriver,
        actions: [AgentAction],
        gate: ComputerUseGating = RunEverythingGate(),
        counter: ConfirmCounter = ConfirmCounter()
    ) async -> ComputerUseRunResult {
        await ComputerUseLoop.run(
            goal: "test goal",
            modelId: "test-model",
            driver: driver,
            gate: gate,
            feed: SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "test goal"),
            interrupt: InterruptToken(),
            confirm: { _ in
                await counter.bump()
                return true
            },
            limits: RunLimits(wallClockSeconds: 30),
            sessionId: "cu-hardstop-test",
            nextAction: ComputerUseLoop.scriptedProvider(actions)
        )
    }

    @Test func passwordFieldIsNeverTypedEvenWithARunEverythingGate() async {
        let d = driver([CUElement(id: "pw", role: "AXSecureTextField", label: "Password")])
        let counter = ConfirmCounter()
        let result = await run(
            d,
            actions: [
                AgentAction(verb: .type, target: AgentTarget(mark: 1), text: "hunter2", note: "enter password"),
                AgentAction(verb: .giveUp, reason: "needs the user"),
            ],
            counter: counter
        )
        #expect(await d.elementActions.isEmpty, "nothing may be typed into a password field")
        #expect(await d.coordinateActions.isEmpty)
        #expect(await counter.count == 0, "a hard stop never reaches a confirm card")
        #expect(result.metrics.blocked >= 1)
    }

    @Test func credentialLabelledFieldIsRefusedThroughTheHardStopGateToo() async {
        let d = driver([CUElement(id: "f", role: "AXTextField", label: "Card number")])
        let result = await run(
            d,
            actions: [
                AgentAction(verb: .setValue, target: AgentTarget(mark: 1), text: "abc", note: "fill"),
                AgentAction(verb: .giveUp, reason: "needs the user"),
            ]
        )
        #expect(await d.elementActions.isEmpty)
        #expect(result.metrics.blocked >= 1)
    }

    @Test func targetlessTypeIntoTheFocusedPasswordFieldIsRefused() async {
        let d = driver([
            CUElement(id: "pw", role: "AXSecureTextField", label: "Password", focused: true),
            CUElement(id: "go", role: "button", label: "Sign in"),
        ])
        _ = await run(
            d,
            actions: [
                AgentAction(verb: .type, text: "hunter2", note: "type"),
                AgentAction(verb: .giveUp, reason: "needs the user"),
            ]
        )
        #expect(await d.elementActions.isEmpty, "a target-less type must be judged against the focused field")
        #expect(await d.coordinateActions.isEmpty)
    }

    @Test func ordinaryFieldStillRunsUnderTheSameGate() async {
        let d = driver([CUElement(id: "n", role: "AXTextField", label: "Note")])
        let result = await run(
            d,
            actions: [
                AgentAction(verb: .type, target: AgentTarget(mark: 1), text: "hello", note: "fill note"),
                AgentAction(verb: .giveUp, reason: "done for the test"),
            ]
        )
        #expect(await d.elementActions.count == 1, "the hard stops must not block ordinary typing")
        #expect(result.metrics.blocked == 0)
    }
}
