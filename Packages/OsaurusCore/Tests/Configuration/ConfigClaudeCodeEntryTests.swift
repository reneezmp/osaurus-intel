//
//  ConfigClaudeCodeEntryTests.swift
//  OsaurusCoreTests
//
//  W-declarative-config stage 5 (upstream #3229): an agent's `claude_code`
//  keys, including `effort`, are validated, planned and applied. Intel has no
//  harness runtime registry, so only the `claude_code` half of upstream's
//  runtime handling exists.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ConfigClaudeCodeEntryTests {

    private func document(_ claudeCode: String, agent: String) throws -> OsaurusConfigDocument {
        try ConfigYAML.decode(
            """
            version: 1
            agents:
              - name: \(agent)
                system_prompt: Probe
                claude_code:
            \(claudeCode)
            """)
    }

    private func withAgent(_ body: (String) async throws -> Void) async throws {
        let name = "CC Probe \(UUID().uuidString.prefix(6))"
        do {
            try await body(name)
        } catch {
            await cleanup(name)
            throw error
        }
        await cleanup(name)
    }

    private func cleanup(_ name: String) async {
        let id = AgentManager.shared.agents.first { $0.name == name }?.id
        if let id { _ = await AgentManager.shared.delete(id: id) }
    }

    @Test func unknownEffortAndModeAreRefusedAndNothingIsPlanned() throws {
        let bad = try document("      effort: turbo\n      mode: wild", agent: "Anyone")
        do {
            _ = try ConfigPlanner.plan(document: bad, prune: false)
            Issue.record("an unknown claude_code value was accepted")
        } catch let issues as ConfigPlanIssues {
            #expect(issues.issues.contains { $0.contains("claude_code.effort: must be one of") })
            #expect(issues.issues.contains { $0.contains("claude_code.mode: must be one of") })
        }
    }

    /// The strict schema already rejects the key for a custom agent when the
    /// document is read; the planner check is the second line of defence.
    @Test func allowOsaurusConfigWritesIsRefusedOnACustomAgent() throws {
        do {
            _ = try document("      allow_osaurus_config_writes: true", agent: "Anyone")
            Issue.record("a custom agent entry accepted allow_osaurus_config_writes")
        } catch let error as ConfigYAMLError {
            #expect(error.messages.contains { $0.contains("allow_osaurus_config_writes") })
        }

        var entry = AgentEntry(name: "Anyone")
        var claudeCode = AgentClaudeCodeEntry()
        claudeCode.allowOsaurusConfigWrites = true
        entry.claudeCode = claudeCode
        var doc = OsaurusConfigDocument()
        doc.agents = [entry]
        do {
            _ = try ConfigPlanner.plan(document: doc, prune: false)
            Issue.record("a custom agent was allowed to change Osaurus configuration")
        } catch let issues as ConfigPlanIssues {
            #expect(issues.issues.contains { $0.contains("only the Default agent") })
        }
    }

    @Test func effortIsPlannedAndApplied_andShellIsFlaggedHighRisk() async throws {
        try await withAgent { name in
            let doc = try document("      effort: high\n      allow_shell: true", agent: name)
            let plan = try ConfigPlanner.plan(document: doc, prune: false)
            let lines = plan.actions.flatMap(\.changes)
            #expect(lines.contains { $0.contains("claude_code.effort: default -> high") }, "\(lines)")
            #expect(plan.hasHighRiskChanges, "allow_shell must be high risk")

            let results = await ConfigApplier.apply(document: doc, prune: false)
            #expect(results.allSatisfy { $0.status != .failed }, "\(results)")
            let agent = try #require(AgentManager.shared.agents.first { $0.name == name })
            #expect(agent.claudeCode?.resolvedEffort == .high)
            #expect(agent.claudeCode?.allowShell == true)

            // `default` clears the override again; re-planning the export is a no-op.
            let clear = try document("      effort: default", agent: name)
            _ = await ConfigApplier.apply(document: clear, prune: false)
            let cleared = try #require(AgentManager.shared.agents.first { $0.name == name })
            #expect(cleared.claudeCode?.resolvedEffort == nil)
        }
    }
}
