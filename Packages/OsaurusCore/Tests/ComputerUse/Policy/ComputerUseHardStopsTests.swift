//
//  ComputerUseHardStopsTests.swift
//  OsaurusCoreTests — Intel fork owner policy for Computer Use.
//
//  Pure value tests: no driver, no screen, no input, no network.
//

import Testing

@testable import OsaurusCore

@Suite struct ComputerUseHardStopsTests {
    private func typeAction(_ text: String, into describe: String? = nil) -> AgentAction {
        AgentAction(
            verb: .type,
            target: describe.map { AgentTarget(describe: $0) },
            text: text
        )
    }

    @Test func testSecureFieldTypingIsRefused() {
        let reason = ComputerUseHardStops.rejection(
            for: typeAction("hunter2"),
            appName: "Safari",
            resolvedRole: "AXSecureTextField"
        )
        #expect(reason != nil)
    }

    @Test func testPasswordLabelIsRefusedForTypeAndSetValue() {
        #expect(ComputerUseHardStops.rejection(
                for: typeAction("x", into: "Password field"),
                appName: "Safari"
            ) != nil)
        let set = AgentAction(verb: .setValue, target: AgentTarget(describe: "CVV"), text: "123")
        #expect(ComputerUseHardStops.rejection(for: set, appName: "Safari") != nil)
    }

    @Test func testClickingAPasswordLabelIsNotAHardStop() {
        // Focusing the field is harmless; only entering text is refused.
        let click = AgentAction(verb: .click, target: AgentTarget(describe: "Password field"))
        #expect(ComputerUseHardStops.rejection(for: click, appName: "Safari") == nil)
    }

    @Test func testPaymentCardNumberTextIsRefused() {
        #expect(ComputerUseHardStops.rejection(for: typeAction("4242 4242 4242 4242"), appName: "Safari") != nil)
        // Not Luhn-valid, and ordinary numbers stay allowed.
        #expect(ComputerUseHardStops.rejection(for: typeAction("1234 5678 9012 3456"), appName: "Notes") == nil)
        #expect(ComputerUseHardStops.rejection(for: typeAction("42"), appName: "Notes") == nil)
    }

    @Test func testCaptchaTargetsAreRefusedForAnyAction() {
        let click = AgentAction(verb: .click, target: AgentTarget(describe: "I'm not a robot checkbox"))
        #expect(ComputerUseHardStops.rejection(for: click, appName: "Safari") != nil)
        let click2 = AgentAction(verb: .click, target: AgentTarget(describe: "reCAPTCHA"))
        #expect(ComputerUseHardStops.rejection(for: click2, appName: "Safari") != nil)
    }

    @Test func testSystemDialogAppsAreRefused() {
        let click = AgentAction(verb: .click, target: AgentTarget(describe: "Allow"))
        #expect(ComputerUseHardStops.rejection(for: click, appName: "SecurityAgent") != nil)
        #expect(ComputerUseHardStops.rejection(for: click, appName: "UserNotificationCenter") != nil)
        let key = AgentAction(verb: .pressKey, key: "return")
        #expect(ComputerUseHardStops.rejection(for: key, appName: "com.apple.SecurityAgent") != nil)
    }

    @Test func testReadingAndOrdinaryWorkIsNotAHardStop() {
        for verb in [AgentVerb.observe, .wait, .find, .done, .giveUp, .open] {
            #expect(ComputerUseHardStops.rejection(for: AgentAction(verb: verb), appName: "SecurityAgent") == nil, "\(verb)")
        }
        #expect(ComputerUseHardStops.rejection(for: typeAction("hello", into: "Note body"), appName: "Notes") == nil)
        // "otp" only counts as a word ("photo" is fine).
        #expect(ComputerUseHardStops.rejection(for: typeAction("a", into: "Photo caption"), appName: "Photos") == nil)
        #expect(ComputerUseHardStops.rejection(for: typeAction("1", into: "OTP"), appName: "Safari") != nil)
    }

    @Test func testHardStopGateRefusesEvenWhenAutonomousAndSkipsInnerGate() async {
        let autonomous = AutonomyPolicy(globalPreset: .autonomous)
        let gate = HardStopGate(wrapping: ComputerUseGate(policy: autonomous))
        let decision = await gate.evaluate(
            action: typeAction("hunter2", into: "Password"),
            effect: .edit,
            appName: "Safari",
            targetLabel: "Password"
        )
        guard case .reject = decision else {
            Issue.record("expected reject, got \(decision)")
            return
        }
    }

    @Test func testHardStopGatePassesThroughOrdinaryActions() async {
        let gate = HardStopGate(wrapping: HardwiredGate())
        let decision = await gate.evaluate(
            action: typeAction("hello", into: "Note body"),
            effect: .edit,
            appName: "Notes",
            targetLabel: "Note body"
        )
        guard case .confirm = decision else {
            Issue.record("expected confirm, got \(decision)")
            return
        }
    }
}
