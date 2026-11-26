//
//  PolicyGateTests.swift
//  OsaurusCoreTests — Computer Use
//
//  PR2 coverage for the configurable-autonomy layer: the context-sensitive
//  `EffectClassifier`, the strictest-wins `AutonomyPolicy` merge (global +
//  per-app + per-agent ceiling), the app allowlist, and the policy-driven
//  `ComputerUseGate` decisions. All pure over their inputs — no driver, no
//  permissions, no UI.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Effect classifier

@Suite struct EffectClassifierTests {
    private func click(describe: String? = nil, note: String? = nil) -> AgentAction {
        AgentAction(verb: .click, target: AgentTarget(mark: 1, describe: describe), note: note)
    }

    @Test func testBaselinePreservedWithoutSignals() {
        #expect(EffectClassifier.classify(action: AgentAction(verb: .observe)) == .read)
        #expect(EffectClassifier.classify(action: click(), resolvedRole: "AXButton", resolvedLabel: "Files") == .navigate)
        #expect(EffectClassifier.classify(
                action: AgentAction(verb: .type, text: "hello"),
                resolvedRole: "AXTextField",
                resolvedLabel: "Search"
            ) == .edit)
    }

    @Test func testCommitButtonsEscalateToConsequential() {
        for label in ["Send", "Delete", "Purchase", "Publish", "Move to Trash", "Reply All"] {
            let effect = EffectClassifier.classify(
                action: click(),
                resolvedRole: "AXButton",
                resolvedLabel: label
            )
            #expect(effect == .consequential, "\(label) should be consequential")
        }
    }

    @Test func testTokenMatchAvoidsSubstringFalsePositive() {
        // "display" contains "pay" but must NOT escalate (token, not substring).
        let effect = EffectClassifier.classify(
            action: click(),
            resolvedRole: "AXButton",
            resolvedLabel: "Display Settings"
        )
        #expect(effect == .navigate)
    }

    @Test func testTypedTextDoesNotEscalate() {
        // Typing the word "delete" into a field is an edit, not consequential —
        // the classifier scans the target, not the payload.
        let effect = EffectClassifier.classify(
            action: AgentAction(verb: .type, text: "please delete everything"),
            resolvedRole: "AXTextField",
            resolvedLabel: "Message"
        )
        #expect(effect == .edit)
    }

    @Test func testCommitWithRecipientsIsConsequential() {
        // The "calendar-save-with-invitees" case: a generic Save/Done commit
        // becomes consequential when recipients are in play.
        let effect = EffectClassifier.classify(
            action: click(note: "Save the event with the invitees"),
            resolvedRole: "AXButton",
            resolvedLabel: "Save"
        )
        #expect(effect == .consequential)
    }

    @Test func testCommandReturnIsSubmit() {
        let cmdReturn = AgentAction(verb: .pressKey, key: "return", modifiers: ["cmd"])
        #expect(EffectClassifier.classify(action: cmdReturn) == .consequential)

        let bareReturn = AgentAction(verb: .pressKey, key: "return")
        #expect(EffectClassifier.classify(action: bareReturn) == .edit)
    }

    @Test func testAmbiguousClickIsStricter() {
        // No mark resolution, no role, no describe → escalate navigate → edit.
        let blind = AgentAction(verb: .click, target: AgentTarget(describe: ""))
        #expect(EffectClassifier.classify(action: blind) == .edit)
    }

    @Test func testNeverLowersBelowBaseline() {
        // An edit verb with a totally benign target stays at least edit.
        let effect = EffectClassifier.classify(
            action: AgentAction(verb: .setValue, target: AgentTarget(mark: 2), text: "x"),
            resolvedRole: "AXTextField",
            resolvedLabel: "Name"
        )
        #expect(effect >= .edit)
    }
}

// MARK: - Presets + policy merge

@Suite struct AutonomyPolicyTests {
    @Test func testPresetDispositions() {
        #expect(AutonomyPreset.balanced.disposition(for: .read) == .allow)
        #expect(AutonomyPreset.balanced.disposition(for: .navigate) == .allow)
        #expect(AutonomyPreset.balanced.disposition(for: .edit) == .confirm)
        #expect(AutonomyPreset.balanced.disposition(for: .consequential) == .confirm)

        #expect(AutonomyPreset.readOnly.disposition(for: .navigate) == .allow)
        #expect(AutonomyPreset.readOnly.disposition(for: .edit) == .deny)
        #expect(AutonomyPreset.readOnly.disposition(for: .consequential) == .deny)

        #expect(AutonomyPreset.cautious.disposition(for: .navigate) == .confirm)

        #expect(AutonomyPreset.trusted.disposition(for: .edit) == .allow)
        #expect(AutonomyPreset.trusted.disposition(for: .consequential) == .confirm)

        for effect in EffectClass.allCases {
            #expect(AutonomyPreset.autonomous.disposition(for: effect) == .allow)
        }
    }

    @Test func testPerAppOverrideOnlyTightens() {
        // Global trusted (edits auto), but Mail is held to cautious.
        var policy = AutonomyPolicy(globalPreset: .trusted)
        policy.perApp["mail"] = .cautious
        #expect(policy.disposition(for: .edit, app: "Mail", ceiling: nil) == .confirm)
        // An app with no override follows the global preset.
        #expect(policy.disposition(for: .edit, app: "Notes", ceiling: nil) == .allow)
    }

    @Test func testPerAppCannotLoosen() {
        // Global cautious; per-app "autonomous" must NOT weaken it (strictest wins).
        var policy = AutonomyPolicy(globalPreset: .cautious)
        policy.perApp["safari"] = .autonomous
        #expect(policy.disposition(for: .navigate, app: "Safari", ceiling: nil) == .confirm)
    }

    @Test func testCeilingTightensAcrossPolicy() {
        let policy = AutonomyPolicy(globalPreset: .autonomous)
        let ceiling = AutonomyCeiling.cappedAt(.balanced)
        #expect(policy.disposition(for: .consequential, app: "Notes", ceiling: ceiling) == .confirm)
        #expect(policy.disposition(for: .edit, app: "Notes", ceiling: ceiling) == .confirm)
        // Read is never capped.
        #expect(policy.disposition(for: .read, app: "Notes", ceiling: ceiling) == .allow)
    }

    @Test func testAllowlistGating() {
        #expect(AutonomyPolicy().isAppAllowed("anything"))
        #expect(AutonomyPolicy(allowlist: []).isAppAllowed("anything"))

        let restricted = AutonomyPolicy(allowlist: ["safari", "notes"])
        #expect(restricted.isAppAllowed("Safari"))  // case-insensitive
        #expect(restricted.isAppAllowed("NOTES"))
        #expect(!(restricted.isAppAllowed("Mail")))
        #expect(!(restricted.isAppAllowed(nil)))
    }

    @Test func testCeilingPresetRoundTrips() {
        for preset in AutonomyPreset.allCases {
            #expect(AutonomyCeiling.cappedAt(preset).matchingPreset == preset)
        }
    }

    @Test func testPolicyCodableRoundTrip() throws {
        var policy = AutonomyPolicy(globalPreset: .trusted, allowlist: ["safari"])
        policy.perApp["mail"] = .cautious
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(AutonomyPolicy.self, from: data)
        #expect(decoded == policy)
    }
}

// MARK: - Gate

@Suite struct ComputerUseGateTests {
    private let clickSend = AgentAction(
        verb: .click,
        target: AgentTarget(describe: "the Send button")
    )

    @Test func testRejectsNonAllowlistedApp() async {
        let gate = ComputerUseGate(policy: AutonomyPolicy(allowlist: ["notes"]))
        let decision = await gate.evaluate(
            action: clickSend,
            effect: .navigate,
            appName: "Mail",
            targetLabel: "Send"
        )
        guard case .reject = decision else {
            Issue.record("expected reject for non-allowlisted app"); return
        }
    }

    @Test func testAllowRunsConfirmConfirmsDenyRejects() async {
        let gate = ComputerUseGate(policy: AutonomyPolicy(globalPreset: .balanced))

        let read = await gate.evaluate(
            action: AgentAction(verb: .observe),
            effect: .read,
            appName: "Notes",
            targetLabel: nil
        )
        #expect(read == .run)

        let edit = await gate.evaluate(
            action: AgentAction(verb: .type, text: "x"),
            effect: .edit,
            appName: "Notes",
            targetLabel: "Body"
        )
        guard case .confirm(let preview) = edit else { Issue.record("expected confirm"); return }
        #expect(preview.effect == .edit)
        #expect(preview.appName == "Notes")
        #expect(preview.targetLabel == "Body")

        let readOnlyGate = ComputerUseGate(policy: AutonomyPolicy(globalPreset: .readOnly))
        let blocked = await readOnlyGate.evaluate(
            action: clickSend,
            effect: .consequential,
            appName: "Notes",
            targetLabel: "Send"
        )
        guard case .reject = blocked else { Issue.record("expected reject under read-only"); return }
    }

    @Test func testCeilingAppliesInGate() async {
        let gate = ComputerUseGate(
            policy: AutonomyPolicy(globalPreset: .autonomous),
            ceiling: AutonomyCeiling.cappedAt(.balanced)
        )
        let decision = await gate.evaluate(
            action: clickSend,
            effect: .consequential,
            appName: "Notes",
            targetLabel: "Send"
        )
        guard case .confirm = decision else {
            Issue.record("ceiling should force a confirm even under autonomous policy"); return
        }
    }

    /// The `open` verb is navigate-class and must clear the allowlist + the
    /// navigate disposition exactly like the loop now gates it (classify the app
    /// being opened, then evaluate). This guards the closed allowlist-bypass.
    @Test func testOpenIsGatedByAllowlistAndPreset() async {
        let openMail = AgentAction(verb: .open, app: "Mail")
        let effect = EffectClassifier.classify(
            action: openMail,
            appName: "Mail",
            recipeSignals: AppRecipes.signals(for: "Mail")
        )
        #expect(effect == .navigate)

        // Allowlist excludes Mail → reject, even though navigate would otherwise run.
        let restricted = ComputerUseGate(policy: AutonomyPolicy(allowlist: ["notes"]))
        guard
            case .reject = await restricted.evaluate(
                action: openMail,
                effect: effect,
                appName: "Mail",
                targetLabel: "Mail"
            )
        else { Issue.record("expected reject when opening a non-allowlisted app"); return }

        // Cautious preset → navigate confirms, so `open` pauses for approval.
        let cautious = ComputerUseGate(policy: AutonomyPolicy(globalPreset: .cautious))
        guard
            case .confirm = await cautious.evaluate(
                action: openMail,
                effect: effect,
                appName: "Mail",
                targetLabel: "Mail"
            )
        else { Issue.record("expected confirm under cautious"); return }

        // Allowed + balanced → runs immediately.
        let allowed = ComputerUseGate(
            policy: AutonomyPolicy(globalPreset: .balanced, allowlist: ["mail"])
        )
        let allowedDecision = await allowed.evaluate(
            action: openMail,
            effect: effect,
            appName: "Mail",
            targetLabel: "Mail"
        )
        #expect(allowedDecision == .run)
    }
}
