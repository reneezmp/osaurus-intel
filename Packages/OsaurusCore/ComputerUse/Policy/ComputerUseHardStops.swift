//
//  ComputerUseHardStops.swift
//  OsaurusCore — Computer Use (Intel fork)
//
//  Owner policy (Intel fork, 2026-11-26): Computer Use never types
//  passwords, payment details or other credentials, never approves system
//  or permission dialogs on the user's behalf, and never works a CAPTCHA —
//  not even when the autonomy policy is "Autonomous" and not even after the
//  user clicks Approve on a confirm card. Upstream escalates secure fields
//  to `consequential` (a confirm) but does not refuse them; these are
//  refusals, so they sit in front of the policy gate.
//
//  Pure and deterministic: callers pass what they know (the resolved
//  element's role / label when the loop resolved one, else just the action
//  and the app). Any hit returns a reason that is fed back to the model as a
//  rejection ("do something else or give up"); the loop never runs the
//  action. `HardStopGate` wraps any `ComputerUseGating` so the check cannot
//  be skipped by choosing a different gate.
//

import Foundation

public enum ComputerUseHardStops {

    /// Returns a rejection reason when `action` must never run, else nil.
    /// `resolvedRole` / `resolvedLabel` describe the element the action will
    /// hit (the loop's `TargetResolver` result, or the focused element for a
    /// target-less `type`); `targetLabel` is the model's own description.
    public static func rejection(
        for action: AgentAction,
        appName: String?,
        targetLabel: String? = nil,
        resolvedRole: String? = nil,
        resolvedLabel: String? = nil
    ) -> String? {
        // Observing and waiting touch nothing, and `open` only launches an app.
        switch action.verb {
        case .observe, .wait, .find, .done, .giveUp, .open: return nil
        default: break
        }

        let app = (appName ?? "").lowercased()
        let label = [targetLabel, resolvedLabel, action.target?.describe, action.to?.describe]
            .compactMap { $0?.lowercased() }
            .joined(separator: " | ")

        // 1) System and permission dialogs: the user answers these, never the agent.
        if systemDialogApps.contains(where: { app.contains($0) }) {
            return
                "This is a macOS system or permission dialog. Computer Use never answers these for the "
                + "user. Stop and ask the user to handle it, then continue."
        }

        // 2) CAPTCHAs and human checks.
        if captchaSignals.contains(where: { label.contains($0) || app.contains($0) }) {
            return
                "This is a CAPTCHA or human-verification check. Computer Use never works these. "
                + "Stop and ask the user to complete it."
        }

        // 3) Secrets: only actions that put text into something.
        let entersText: Bool
        switch action.verb {
        case .type, .setValue: entersText = true
        case .pressKey: entersText = false
        default: entersText = false
        }

        let role = (resolvedRole ?? "").lowercased()
        if entersText || action.verb == .clear {
            if role.contains("secure") {
                return
                    "This is a password field. Computer Use never types passwords or other credentials. "
                    + "Ask the user to enter it themselves."
            }
            if credentialSignals.contains(where: { label.contains($0) })
                || label.range(of: #"\botp\b"#, options: .regularExpression) != nil
            {
                return
                    "This field looks like it takes a password, payment detail or other credential. "
                    + "Computer Use never enters those. Ask the user to enter it themselves."
            }
        }
        if entersText, let text = action.text, looksLikePaymentCard(text) {
            return
                "That text looks like a payment card number. Computer Use never enters payment details. "
                + "Ask the user to enter it themselves."
        }
        return nil
    }

    // MARK: - Signals

    /// Lowercased substrings of the owning app's name or bundle id for the
    /// processes that draw macOS permission / authorization prompts.
    static let systemDialogApps: [String] = [
        "securityagent", "com.apple.securityagent",
        "usernotificationcenter", "com.apple.usernotificationcenter",
        "coreservicesuiagent", "universalaccessauthwarn",
        "authorizationhost", "com.apple.authorizationhost",
        "tccd", "coreauthuiagent", "loginwindow",
    ]

    static let captchaSignals: [String] = [
        "captcha", "recaptcha", "hcaptcha", "turnstile",
        "i'm not a robot", "i’m not a robot", "i am not a robot",
        "verify you are human", "verify you're human", "verify you’re human",
        "prove you are human", "prove you're human",
    ]

    static let credentialSignals: [String] = [
        "password", "passcode", "passphrase", "pin code", "one-time code", "verification code",
        "security code", "two-factor", "2fa",
        "card number", "credit card", "debit card", "cvv", "cvc", "expiration date", "expiry",
        "social security", "ssn", "routing number", "account number", "iban",
        "api key", "secret key", "access token", "private key", "recovery key",
    ]

    /// 13–19 digits (spaces and dashes allowed) that pass the Luhn check.
    static func looksLikePaymentCard(_ text: String) -> Bool {
        let digits = text.filter { $0.isNumber }
        let stripped = text.filter { !$0.isNumber && $0 != " " && $0 != "-" }
        guard stripped.isEmpty, (13 ... 19).contains(digits.count) else { return false }
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d
        }
        return sum % 10 == 0
    }
}

/// Decorates any gate with the hard stops. The wrapped gate is only asked
/// when no hard stop applies.
public struct HardStopGate: ComputerUseGating {
    private let inner: any ComputerUseGating

    public init(wrapping inner: any ComputerUseGating) { self.inner = inner }

    public func evaluate(
        action: AgentAction,
        effect: EffectClass,
        appName: String?,
        targetLabel: String?
    ) async -> GateDecision {
        if let reason = ComputerUseHardStops.rejection(
            for: action,
            appName: appName,
            targetLabel: targetLabel
        ) {
            return .reject(reason: reason)
        }
        return await inner.evaluate(action: action, effect: effect, appName: appName, targetLabel: targetLabel)
    }
}
