//
//  AutonomyPolicySummary.swift
//  osaurus
//
//  Upstream's `ComputerUseTool.policySummary`, which Browser Use also uses
//  for its child prompt. The Computer Use tool itself comes with
//  `W-computer-use` (docs/SUBAGENTS_INTEL.md).
//

import Foundation

extension AutonomyPolicy {
    static func summary(policy: AutonomyPolicy, ceiling: AutonomyCeiling?) -> String {
        var parts: [String] = ["\(policy.globalPreset.displayLabel) — \(policy.globalPreset.detail)"]
        if let allowlist = policy.allowlist, !allowlist.isEmpty {
            parts.append("Only these apps may be used: \(allowlist.joined(separator: ", ")).")
        }
        if let ceiling, !ceiling.isEmpty, let preset = ceiling.matchingPreset {
            parts.append("This agent is capped at \(preset.displayLabel).")
        }
        return parts.joined(separator: " ")
    }
}
