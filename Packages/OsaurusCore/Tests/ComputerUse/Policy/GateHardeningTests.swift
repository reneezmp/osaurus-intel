//
//  GateHardeningTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Audit-remediation coverage for the autonomy gate's default-preset
//  auto-run bypasses (P0). Pins the new escalations that close them:
//    • `EffectClassifier` now folds `value` + `roleDescription` into the
//      signal, so a value-titled or description-only control is classified.
//    • Icon-only / unidentifiable click targets escalate to at least `edit`.
//    • A bare commit control (Save / OK / Done / …) escalates to at least
//      `edit` — so it confirms under the default `balanced` preset instead of
//      silently auto-running as `navigate` — without over-escalating to
//      `consequential` (that still needs recipients), so `trusted` users keep
//      their auto-run.
//    • `ComputerUseGate` enforces a dangerous-app guardrail (Terminal, System
//      Settings, Keychain, password managers, …) that always confirms,
//      independent of the (often-empty) allowlist and any preset/ceiling.
//    • `AutonomyPolicy.normalize` strips `.app` + collapses whitespace without
//      aliasing a bundle id to its last path component.
//
//  All pure over their inputs — no driver, no permissions, no UI.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Classifier: richer signal + new escalations

@Suite struct EffectClassifierHardeningTests {
    private func click(_ target: AgentTarget = AgentTarget(mark: 1)) -> AgentAction {
        AgentAction(verb: .click, target: target)
    }

    /// An icon-only button (a known control role with no readable
    /// label/value/description) must escalate to at least `edit` so it confirms
    /// under `balanced` rather than auto-running as `navigate`.
    @Test func testIconOnlyButtonEscalatesToEdit() {
        let effect = EffectClassifier.classify(
            action: click(),
            resolvedRole: "AXButton",
            resolvedLabel: ""
        )
        #expect(effect >= .edit)
    }

    /// A genuinely unidentifiable click (no role, no label, no describe) is the
    /// strictest ambiguity case and also escalates.
    @Test func testUnidentifiableClickEscalatesToEdit() {
        let blind = AgentAction(verb: .click, target: AgentTarget(describe: ""))
        #expect(EffectClassifier.classify(action: blind) >= .edit)
    }

    /// A button whose title lives in `AXValue` (no `AXTitle`) is now seen: a
    /// value of "Send" reaches the consequential vocabulary.
    @Test func testValueTitledControlFeedsTheSignal() {
        let consequential = EffectClassifier.classify(
            action: click(),
            resolvedRole: "AXButton",
            resolvedValue: "Send"
        )
        #expect(consequential == .consequential)

        // A value-only commit ("Save") escalates to at least edit (→ confirm
        // under balanced) — the "value-only commit → confirm" bypass case.
        let commit = EffectClassifier.classify(
            action: click(),
            resolvedRole: "AXButton",
            resolvedValue: "Save"
        )
        #expect(commit >= .edit)
    }

    /// `roleDescription` is part of the signal too — a control described as a
    /// "delete button" with no title still escalates.
    @Test func testRoleDescriptionFeedsTheSignal() {
        let effect = EffectClassifier.classify(
            action: click(),
            resolvedRole: "AXButton",
            resolvedRoleDescription: "Delete button"
        )
        #expect(effect == .consequential)
    }

    /// A field's `value` is USER CONTENT, not control intent: typing the word
    /// "save" into a text field must NOT escalate via the value path (it stays
    /// the edit baseline), or every draft would re-trigger the commit rule.
    @Test func testTextInputValueIsNotTreatedAsCommitSignal() {
        let effect = EffectClassifier.classify(
            action: AgentAction(verb: .type, target: AgentTarget(mark: 1), text: "save the world"),
            resolvedRole: "AXTextField",
            resolvedLabel: "Message",
            resolvedValue: "save the world"
        )
        #expect(effect == .edit)
    }

    /// A bare "Save" commit (no recipients) escalates to exactly `edit` — enough
    /// to confirm under `balanced`, but NOT `consequential`, so `trusted` keeps
    /// auto-running edits. This is the deliberate middle ground.
    @Test func testSoloCommitEscalatesToEditNotConsequential() {
        let effect = EffectClassifier.classify(
            action: click(AgentTarget(describe: "Save")),
            resolvedRole: "AXButton",
            resolvedLabel: "Save"
        )
        #expect(effect == .edit)
    }

    /// HONEST LIMITATION (documented, not faked): the classifier vocabulary is
    /// English-only, so a foreign-language commit label with no recipe and no
    /// commit-token coincidence stays `navigate`. We do NOT fake foreign-word
    /// detection; the real safety nets are the icon-only rule (foreign UIs often
    /// use icons), the dangerous-app guardrail, and the user raising the preset
    /// to `cautious` — all covered below.
    @Test func testForeignLabelStaysNavigate_DocumentsEnglishOnlyVocabulary() {
        let effect = EffectClassifier.classify(
            action: click(AgentTarget(describe: "Senden")),
            resolvedRole: "AXButton",
            resolvedLabel: "Senden"  // German "Send"
        )
        #expect(effect == .navigate)
    }
}

// MARK: - Gate: dangerous-app guardrail

@Suite struct DangerousAppGuardrailTests {
    private let click = AgentAction(verb: .click, target: AgentTarget(describe: "x"))

    /// Even fully autonomous, driving Terminal confirms at least once.
    @Test func testTerminalAlwaysConfirmsEvenUnderAutonomous() async {
        let gate = ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous))
        let decision = await gate.evaluate(
            action: click,
            effect: .navigate,
            appName: "Terminal",
            targetLabel: "x"
        )
        guard case .confirm = decision else {
            Issue.record("dangerous app should force a confirm under autonomous"); return
        }
    }

    /// Matches on the normalized name OR bundle id, by substring, across
    /// variants and a few representative sensitive apps.
    @Test func testGuardrailMatchesVariantsAndBundleIds() async {
        let gate = ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous))
        for app in [
            "Terminal.app", "com.apple.Terminal", "iTerm", "Ghostty",
            "System Settings", "com.apple.systempreferences",
            "Keychain Access", "1Password", "Bitwarden",
        ] {
            let decision = await gate.evaluate(
                action: click,
                effect: .navigate,
                appName: app,
                targetLabel: "x"
            )
            guard case .confirm = decision else {
                Issue.record("\(app) should be guardrailed to confirm"); return
            }
        }
    }

    /// The guardrail only TIGHTENS: a read-only policy that denies edits still
    /// denies them in a dangerous app (a confirm floor can't loosen a deny).
    @Test func testGuardrailCannotLoosenADeny() async {
        let gate = ComputerUseGate(policy: AutonomyPolicy(globalPreset: .readOnly))
        let decision = await gate.evaluate(
            action: AgentAction(verb: .type, target: AgentTarget(mark: 1), text: "rm -rf /"),
            effect: .edit,
            appName: "Terminal",
            targetLabel: "shell"
        )
        guard case .reject = decision else {
            Issue.record("read-only deny must survive the dangerous-app guardrail"); return
        }
    }

    /// Reads never reach the guardrail (perception is always safe), so looking
    /// at Terminal still auto-runs.
    @Test func testGuardrailDoesNotAffectReads() async {
        let gate = ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous))
        let decision = await gate.evaluate(
            action: AgentAction(verb: .observe),
            effect: .read,
            appName: "Terminal",
            targetLabel: nil
        )
        #expect(decision == .run)
    }

    /// A non-sensitive app under autonomous is unaffected — the guardrail is
    /// targeted, not a blanket "confirm everything".
    @Test func testNonDangerousAppUnaffected() async {
        let gate = ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous))
        let decision = await gate.evaluate(
            action: click,
            effect: .navigate,
            appName: "Notes",
            targetLabel: "x"
        )
        #expect(decision == .run)
    }

    /// The allowlist is still checked first: a dangerous app that isn't on an
    /// active allowlist is rejected outright, not merely confirmed.
    @Test func testAllowlistRejectionPrecedesGuardrail() async {
        let gate = ComputerUseGate(policy: AutonomyPolicy(allowlist: ["notes"]))
        let decision = await gate.evaluate(
            action: click,
            effect: .navigate,
            appName: "Terminal",
            targetLabel: "x"
        )
        guard case .reject = decision else {
            Issue.record("allowlist should reject Terminal before the guardrail"); return
        }
    }
}

// MARK: - Gate: solo-commit confirms under balanced

@Suite struct SoloCommitGatingTests {
    private func saveClick() -> AgentAction {
        AgentAction(verb: .click, target: AgentTarget(describe: "Save"))
    }

    /// End-to-end: a solo "Save" classifies as `edit` and therefore CONFIRMS
    /// under the default `balanced` preset (the closed bypass).
    @Test func testSoloSaveConfirmsUnderBalanced() async {
        let action = saveClick()
        let effect = EffectClassifier.classify(
            action: action,
            resolvedRole: "AXButton",
            resolvedLabel: "Save"
        )
        #expect(effect == .edit)

        let gate = ComputerUseGate(policy: AutonomyPolicy(globalPreset: .balanced))
        let decision = await gate.evaluate(
            action: action,
            effect: effect,
            appName: "Notes",
            targetLabel: "Save"
        )
        guard case .confirm = decision else {
            Issue.record("a solo Save should confirm under balanced"); return
        }
    }

    /// …but a `trusted` user (edits auto-run) still gets auto-run for that same
    /// solo Save — proving we didn't over-escalate it to `consequential`.
    @Test func testSoloSaveAutoRunsUnderTrusted() async {
        let gate = ComputerUseGate(policy: AutonomyPolicy(globalPreset: .trusted))
        let decision = await gate.evaluate(
            action: saveClick(),
            effect: .edit,
            appName: "Notes",
            targetLabel: "Save"
        )
        #expect(decision == .run)
    }

    /// The foreign-label gap is closed by raising the preset: under `cautious`,
    /// navigation itself confirms, so even an unrecognized commit label pauses.
    @Test func testForeignLabelConfirmsUnderCautious() async {
        let gate = ComputerUseGate(policy: AutonomyPolicy(globalPreset: .cautious))
        let decision = await gate.evaluate(
            action: AgentAction(verb: .click, target: AgentTarget(describe: "Senden")),
            effect: .navigate,
            appName: "Mail",
            targetLabel: "Senden"
        )
        guard case .confirm = decision else {
            Issue.record("cautious should confirm navigation regardless of label language"); return
        }
    }
}

// MARK: - Allowlist name normalization

@Suite struct AutonomyPolicyNormalizeTests {
    @Test func testStripsDotAppAndCollapsesWhitespace() {
        #expect(AutonomyPolicy.normalize("Safari.app") == "safari")
        #expect(AutonomyPolicy.normalize("Safari.app") == AutonomyPolicy.normalize("safari"))
        #expect(AutonomyPolicy.normalize("System   Settings") == "system settings")
        #expect(AutonomyPolicy.normalize("  Notes \t") == "notes")
    }

    /// A `.app`-suffixed allowlist entry matches the bare display name and back.
    @Test func testAllowlistMatchesAcrossDotAppForms() {
        let policy = AutonomyPolicy(allowlist: ["Safari.app", "Notes"])
        #expect(policy.isAppAllowed("Safari"))
        #expect(policy.isAppAllowed("safari.app"))
        #expect(policy.isAppAllowed("NOTES"))
    }

    /// SECURITY: normalize must NOT alias a bundle id to its last path component
    /// — otherwise `com.evil.notes` would match an allowlist entry of "notes".
    @Test func testDoesNotAliasBundleIdToLastComponent() {
        #expect(AutonomyPolicy.normalize("com.evil.notes") == "com.evil.notes")
        let policy = AutonomyPolicy(allowlist: ["notes"])
        #expect(!(policy.isAppAllowed("com.evil.notes")))
    }

    @Test func testForcedConfirmMatchingIsNormalized() {
        let policy = AutonomyPolicy()
        #expect(policy.requiresForcedConfirm(app: "Terminal.app"))
        #expect(policy.requiresForcedConfirm(app: "com.apple.Terminal"))
        #expect(!(policy.requiresForcedConfirm(app: "Notes")))
        #expect(!(policy.requiresForcedConfirm(app: nil)))
        #expect(!(policy.requiresForcedConfirm(app: "")))
    }
}
