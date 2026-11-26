//
//  IntelSandboxConfigTests.swift
//  OsaurusCoreTests
//
//  W-seatbelt-sandbox stage 5: the sandbox switches in declarative config.
//  Plans only (nothing is applied, so no agent or file is created): each
//  switch that widens what an agent can do is a high-risk line, so it needs
//  an explicit approval, and `allowed_domains` is refused because the macOS
//  sandbox cannot filter by domain.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct IntelSandboxConfigTests {

    private func document(_ sandbox: String) throws -> OsaurusConfigDocument {
        try ConfigYAML.decode(
            """
            version: 1
            agents:
              - name: Sbx Probe \(UUID().uuidString.prefix(6))
                system_prompt: Probe
                sandbox:
            \(sandbox)
            """)
    }

    @Test func everyWideningSwitchIsAHighRiskLine() throws {
        let doc = try document(
            "      enabled: true\n      network_enabled: true\n      background_process_enabled: true\n      plugin_create: true"
        )
        let plan = try ConfigPlanner.plan(document: doc, prune: false)
        let name = try #require(doc.agents?.first).name
        let risks = plan.risks
        #expect(risks.contains(ConfigRisk.sandboxEnabled(name)))
        #expect(risks.contains(ConfigRisk.sandboxNetwork(name)))
        #expect(risks.contains(ConfigRisk.sandboxBackground(name)))
        #expect(risks.contains(ConfigRisk.sandboxPluginCreate(name)))
        let changes = plan.actions.flatMap(\.changes)
        #expect(changes.contains("sandbox.network_enabled: true"))
        #expect(changes.contains("sandbox.background_process_enabled: true"))
    }

    @Test func switchingThingsOffOrLeavingThemOutIsNotARisk() throws {
        let off = try document(
            "      enabled: false\n      network_enabled: false\n      background_process_enabled: false\n      plugin_create: false"
        )
        #expect(try ConfigPlanner.plan(document: off, prune: false).risks.isEmpty)
        let maxOnly = try document("      max_commands_per_turn: 5")
        #expect(try ConfigPlanner.plan(document: maxOnly, prune: false).risks.isEmpty)
    }

    @Test func allowedDomainsIsRefusedButAnEmptyListIsFine() throws {
        let domains = try document("      allowed_domains:\n        - example.com")
        do {
            _ = try ConfigPlanner.plan(document: domains, prune: false)
            Issue.record("a domain allowlist was accepted")
        } catch let issues as ConfigPlanIssues {
            #expect(issues.issues.contains { $0.contains("allowed_domains") && $0.contains("not supported") })
        }
        let empty = try document("      allowed_domains: []")
        #expect(try ConfigPlanner.plan(document: empty, prune: false).risks.isEmpty)
    }

    @Test func theKeysAreInTheSchemaAndNothingEnablesByDefault() throws {
        let sandbox = try #require(
            try ConfigYAML.decode(
                """
                version: 1
                agents:
                  - name: Schema Probe
                    system_prompt: Probe
                    sandbox:
                      network_enabled: false
                      background_process_enabled: false
                """
            ).agents?.first?.sandbox)
        #expect(sandbox.networkEnabled == false)
        #expect(sandbox.backgroundProcessEnabled == false)
        #expect(sandbox.enabled == nil)
        // Intel defaults: everything off, plugin creation included.
        #expect(AutonomousExecConfig.default.pluginCreate == false)
        #expect(AutonomousExecConfig.default.enabled == false)
        #expect(AutonomousExecConfig.default.sandboxNetworkEnabled == false)
        #expect(AutonomousExecConfig.default.backgroundProcessEnabled == false)
    }
}
