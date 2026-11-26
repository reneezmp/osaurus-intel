//
//  ComputerUseLoopTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Coverage for the loop/tool seams that don't require a live model: the
//  autonomy-stance line injected into the system prompt, and the
//  `ComputerUseTool` policy-summary rendering that feeds it. The full
//  perceive→act loop is exercised through the deterministic gate/perception
//  suites and the pure-data evals.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite struct ComputerUseSystemPromptTests {
    @Test func testSystemPromptIncludesPolicyStance() {
        let summary = "Cautious — Ask before every action except reading."
        let prompt = ComputerUseLoop.systemPrompt(policySummary: summary)
        #expect(prompt.contains("Current autonomy policy: \(summary)"))
        // The base rules are still present.
        #expect(prompt.contains("agent_action"))
    }

    @Test func testSystemPromptOmitsEmptyStance() {
        let prompt = ComputerUseLoop.systemPrompt(policySummary: "   ")
        #expect(!(prompt.contains("Current autonomy policy:")))
    }
}

@Suite struct ComputerUsePolicySummaryTests {
    @Test func testSummaryMentionsPresetAllowlistAndCeiling() {
        let policy = AutonomyPolicy(globalPreset: .cautious, allowlist: ["Safari", "Notes"])
        let ceiling = AutonomyCeiling.cappedAt(.balanced)
        let summary = ComputerUseTool.policySummary(policy: policy, ceiling: ceiling)
        #expect(summary.contains("Cautious"))
        #expect(summary.contains("Safari, Notes"))
        #expect(summary.contains("Balanced"))
    }

    @Test func testSummaryWithoutAllowlistOrCeiling() {
        let summary = ComputerUseTool.policySummary(
            policy: AutonomyPolicy(globalPreset: .balanced),
            ceiling: nil
        )
        #expect(summary.contains("Balanced"))
        #expect(!(summary.contains("Only these apps")))
        #expect(!(summary.contains("capped at")))
    }
}
