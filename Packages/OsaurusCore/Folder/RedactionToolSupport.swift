//
//  RedactionToolSupport.swift
//  osaurus
//
//  Shared machinery for the `detect_pii` / `redact_file` folder tools:
//  ad-hoc rule parsing and the detection runner both tools call.
//
//  Design constraints (upstream, kept on Intel):
//  - Ad-hoc `custom_rules` are per-call and EPHEMERAL. They are never
//    written into `PrivacyFilterConfiguration.customRules` — that store
//    drives the user's cloud-outbound scrubbing and agent tool calls
//    must not mutate it.
//  - Uses engine primitives (`PrivacyFilterEngine.detect`) directly,
//    NOT `PrivacyFilterPipeline.applyOutbound`: the outbound pipeline's
//    scrub/unscrub round-trip and session redaction stores are wrong
//    for permanent file redaction.
//
//  Intel difference (W-privacy-filter owner policy): upstream resolves a
//  Rampart or OpenAI privacy-filter model and offers a download prompt
//  (`PIIModelDownloadGate`). Neither model can run on macOS 13 x86_64, so
//  the tools always run the rule layer only, locally, with no model and no
//  network, and every result says names and street addresses are not found.
//

import Foundation

extension ToolRegistry {
    /// Redaction tools (upstream `ToolRegistry.redactionToolNames`): part of the
    /// host-folder schema, offered only to an agent that switched Redaction
    /// Tools on (`AgentSettings.redactionToolsEnabled`, upstream #3307). They
    /// resolve the executing chat's folder root, so they are never offered
    /// without a host folder.
    nonisolated static let redactionToolNames: Set<String> = ["detect_pii", "redact_file"]
}

// MARK: - Ad-hoc rule parsing

enum RedactionToolSupport {

    /// Cap on agent-supplied `custom_rules` per call.
    static let maxCustomRules = 32

    /// One agent-supplied rule that failed validation; surfaced per-rule
    /// in the tool result so a single bad regex doesn't fail the call.
    struct RejectedRule {
        let name: String
        let reason: String
    }

    struct ParsedRules {
        let rules: [PrivacyRule]
        let rejected: [RejectedRule]
    }

    /// Parse the `custom_rules` argument into ephemeral `PrivacyRule`
    /// values. Each entry: `{name, pattern, placeholder?, category?,
    /// case_sensitive?}`. Invalid patterns are rejected per-rule (compile
    /// check via `RegexEntityDetector.safeCompile`; here we also validate
    /// shape and emptiness).
    static func parseCustomRules(_ value: Any?) -> ParsedRules? {
        guard let value else { return ParsedRules(rules: [], rejected: []) }
        guard let raw = value as? [[String: Any]] else { return nil }
        var rules: [PrivacyRule] = []
        var rejected: [RejectedRule] = []
        for (index, entry) in raw.enumerated() {
            let name = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "rule_\(index)"
            guard rules.count < maxCustomRules else {
                rejected.append(
                    RejectedRule(name: name, reason: "over the \(maxCustomRules)-rule cap"))
                continue
            }
            guard let pattern = entry["pattern"] as? String, !pattern.isEmpty else {
                rejected.append(RejectedRule(name: name, reason: "missing or empty `pattern`"))
                continue
            }
            let category =
                (entry["category"] as? String).flatMap(EntityCategory.init(rawValue:)) ?? .secret
            let rule = PrivacyRule(
                name: name,
                pattern: pattern,
                category: category,
                enabled: true,
                kind: .regex,
                caseSensitive: (entry["case_sensitive"] as? Bool) ?? true,
                placeholderLabel: entry["placeholder"] as? String
            )
            // Compile check now so the failure is attributable to THIS
            // rule instead of silently dropping matches at detect time.
            switch RegexEntityDetector.safeCompile(pattern, caseSensitive: rule.caseSensitive) {
            case .success:
                rules.append(rule)
            case .failure(let error):
                rejected.append(RejectedRule(name: name, reason: "invalid regex: \(error)"))
            }
        }
        return ParsedRules(rules: rules, rejected: rejected)
    }

    /// Ephemeral ruleset: the default safety net (built-ins + the
    /// fresh-install presets for this Mac's locale, so US SSN and the
    /// like are still covered) + the parsed ad-hoc rules. Constructed
    /// via a throwaway configuration value; the persisted store is
    /// never read or written.
    static func ruleset(customRules: [PrivacyRule]) -> RegexEntityDetector.EffectiveRuleSet {
        var config = PrivacyFilterConfiguration.freshInstall()
        config.customRules = customRules
        return .build(from: config)
    }

    // MARK: - Detection runner

    /// What the tools tell the model on every call (Intel: always).
    static let degradationNote =
        "Name/address detection unavailable: this Mac has no PII model (needs an Apple Silicon Mac). "
        + "Emails, phones, and pattern-based categories were still detected by the built-in rules. "
        + "Compensate for undetected names with `file_edit` if needed."

    struct DetectionOutcome {
        let entities: [DetectedEntity]
        /// Always "regex-only" on Intel.
        let backend: String
        /// Degradation note; always set on Intel.
        let degradation: String?
    }

    /// Run the rule layer over `text`. Never throws and never leaves the
    /// Mac: the engine's rule path is plain regex and checksum code.
    static func detect(
        in text: String,
        customRules: [PrivacyRule]
    ) async -> DetectionOutcome {
        let map = RedactionMap(conversationID: UUID())
        let rules = ruleset(customRules: customRules)
        let entities =
            (try? await PrivacyFilterEngine.shared.detect(
                in: text, map: map, skipCodeBlocks: false, ruleset: rules,
                useModel: false)) ?? []
        return DetectionOutcome(entities: entities, backend: "regex-only", degradation: degradationNote)
    }
}
