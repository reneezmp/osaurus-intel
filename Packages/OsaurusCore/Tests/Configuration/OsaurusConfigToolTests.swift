//
//  OsaurusConfigToolTests.swift
//  OsaurusCoreTests
//
//  W-declarative-config stage 4: `osaurus_config` (upstream Classic's
//  `OsaurusConfigTool`) replaced Intel's `orchestrator_config`. Ported from
//  upstream's `ConfigurationToolsTests` (gate contract, action surface) and
//  `DeclarativeConfigTests.OsaurusConfigToolHighRiskGateTests`, plus Intel's
//  owner-policy pins: nothing applies without the approval, an unattended or
//  external run is refused, no mounted chat surface fails closed, secrets
//  never travel, and the grounded-claim check keys off the real envelope.
//
//  Approvals are answered through `OsaurusConfigTool.approvalOverrideForTests`
//  (honored only under tests); the real modal is never mounted here.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("osaurus_config tool", .serialized)
struct OsaurusConfigToolTests {

    // MARK: Helpers

    private static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// Run as the Default agent in an interactive chat turn, answering the
    /// approval with `answer` (nil = no override: the real queue/service).
    private func runAttended(
        _ args: [String: Any],
        answer: (@Sendable (ConfigPlan, Bool) async -> ConfigApprovalOutcome)? = nil
    ) async throws -> String {
        try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await ChatExecutionContext.$interactiveChatRun.withValue(true) {
                try await OsaurusConfigTool.$approvalOverrideForTests.withValue(answer) {
                    try await OsaurusConfigTool().execute(argumentsJSON: Self.json(args))
                }
            }
        }
    }

    private func runAsDefault(_ args: [String: Any]) async throws -> String {
        try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await OsaurusConfigTool().execute(argumentsJSON: Self.json(args))
        }
    }

    private static let highRiskYAML = """
        tools:
          policies:
            web_search: auto
        """

    private func webSearchPolicy() async -> String? {
        await MainActor.run { ConfigExporter.export().tools?.policies?["web_search"] }
    }

    // MARK: Gate contract (upstream ConfigurationToolsGateContractTests)

    @Test func refusesWithoutAgentContext() async throws {
        let result = try await OsaurusConfigTool().execute(argumentsJSON: #"{"action":"apply"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("chat session context"), "got \(result)")
    }

    @Test func refusesFromCustomAgent() async throws {
        let result = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await OsaurusConfigTool().execute(argumentsJSON: #"{"action":"apply"}"#)
        }
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Default agent"), "got \(result)")
    }

    @Test func offersTheDeclarativeSurface() {
        guard case .object(let root)? = OsaurusConfigTool().parameters,
            case .object(let props)? = root["properties"],
            case .object(let action)? = props["action"],
            case .array(let values)? = action["enum"]
        else {
            Issue.record("osaurus_config has no action enum")
            return
        }
        let actions = values.compactMap { value -> String? in
            if case .string(let s) = value { return s } else { return nil }
        }
        #expect(Set(actions) == ["schema", "export", "plan", "apply", "templates"])
    }

    @Test func registryExposesItOnlyToTheDefaultAgentAndItOwnsItsApproval() {
        let unbound = ToolRegistry.shared.openAISpecs(for: nil).map(\.function.name)
        let custom = ToolRegistry.shared.openAISpecs(for: UUID()).map(\.function.name)
        let orchestrator = ToolRegistry.shared.openAISpecs(for: Agent.defaultId).map(\.function.name)
        #expect(!unbound.contains(OsaurusConfigTool.toolName))
        #expect(!custom.contains(OsaurusConfigTool.toolName))
        #expect(orchestrator.contains(OsaurusConfigTool.toolName))
        // The Intel-only predecessor is gone.
        #expect(!orchestrator.contains("orchestrator_config"))
        #expect(ToolRegistry.shared.handlesOwnApproval(for: OsaurusConfigTool.toolName))
        #expect(OsaurusConfigTool.toolName == "osaurus_config")
    }

    // MARK: Read-only actions

    @Test func schemaAction_honorsSectionsFilter_inArrayAndStringForm() async throws {
        for sectionsValue: Any in [["memory"], "memory"] {
            let result = try await runAsDefault(["action": "schema", "sections": sectionsValue])
            #expect(result.contains("memory:"))
            #expect(!result.contains("mcp_servers:"), "filter ignored for \(sectionsValue)")
        }
    }

    @Test func schemaAction_unknownSection_suggestsTheRealOne() async throws {
        let result = try await runAsDefault(["action": "schema", "sections": "mcp"])
        #expect(result.contains("mcp_servers"))
        #expect(result.contains("Did you mean"))
    }

    @Test func sectionNameSuggestions_bridgeCommonMisses() {
        #expect(OsaurusConfigTool.closestSectionName(to: "mcp") == "mcp_servers")
        #expect(OsaurusConfigTool.closestSectionName(to: "provider") == "providers")
        #expect(OsaurusConfigTool.closestSectionName(to: "zzz_nonsense") == nil)
    }

    @Test func planResult_isMarkedAsDryRun_neverAsAnOutcome() async throws {
        let yaml = """
            providers:
              - name: zz-dry-run-probe-\(UUID().uuidString.prefix(8))
                provider: openrouter
            """
        let result = try await runAsDefault(["action": "plan", "yaml": yaml])
        #expect(result.contains("DRY RUN — nothing changed yet"), "missing dry-run marker: \(result)")
        #expect(result.contains("dry_run_not_applied"))
        #expect(!result.contains("\"status\":\"applied\""))
    }

    @Test func scopedExport_carriesTheFullKeyRosterAsYamlShape() async throws {
        let result = try await runAsDefault(["action": "export", "sections": "tools"])
        #expect(result.contains("yaml_shape"), "scoped export lost its yaml_shape: \(result)")
        #expect(result.contains("policies"))
    }

    @Test func schemaAndExport_neverCarryASecret() async throws {
        let schema = try await runAsDefault(["action": "schema"])
        let export = try await runAsDefault(["action": "export"])
        for text in [schema, export] {
            #expect(!text.contains("sk-"))
        }
        let lowered = export.lowercased()
        for forbidden in ["api_key:", "access_token", "refresh_token", "password"] {
            #expect(!lowered.contains(forbidden), "export contains `\(forbidden)`")
        }
    }

    @Test func aDocumentCarryingAKeyIsRejectedAndTheKeyIsNeverEchoed() async throws {
        let secret = "sk-test-not-a-real-key-\(UUID().uuidString.prefix(8))"
        let yaml = """
            providers:
              - name: zz-secret-probe
                provider: openrouter
                api_key: \(secret)
            """
        for action in ["plan", "apply"] {
            let result = try await runAttended(
                ["action": action, "yaml": yaml], answer: { _, _ in .approved })
            #expect(ToolEnvelope.isError(result), "\(action) accepted a document with a key")
            #expect(!result.contains(secret), "\(action) echoed the secret")
        }
    }

    // MARK: Owner policy: nothing applies without the user's approval

    @Test func unattendedRun_isRefusedAndNothingApplies() async throws {
        // No interactive chat turn and no paired phone: a schedule, watcher or
        // background dispatch. Refused as unanswerable, never as "user said no".
        let result = try await runAsDefault(["action": "apply", "yaml": Self.highRiskYAML])
        #expect(result.contains("permission_denied"), "got \(result)")
        #expect(!result.contains("declined"))
        #expect(!result.contains("\"status\":\"applied\""))
        #expect(await webSearchPolicy() != "auto", "unattended apply leaked through")
    }

    @Test func headlessDenyContext_refusesEvenAnInteractiveRun() async throws {
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await ChatExecutionContext.$interactiveChatRun.withValue(true) {
                try await ChatExecutionContext.$denyUnapprovedToolPrompts.withValue(true) {
                    try await OsaurusConfigTool().execute(
                        argumentsJSON: Self.json(["action": "apply", "yaml": Self.highRiskYAML]))
                }
            }
        }
        #expect(result.contains("permission_denied"))
        #expect(!result.contains("declined"))
        #expect(await webSearchPolicy() != "auto")
    }

    @Test func externalSurface_refusesWithoutAPairedPhone() async throws {
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await ChatExecutionContext.$interactiveChatRun.withValue(true) {
                try await ChatExecutionContext.$isExternalSurface.withValue(true) {
                    try await OsaurusConfigTool().execute(
                        argumentsJSON: Self.json(["action": "apply", "yaml": Self.highRiskYAML]))
                }
            }
        }
        #expect(result.contains("permission_denied"))
        #expect(await webSearchPolicy() != "auto", "high-risk apply leaked through the external-surface gate")
    }

    @Test func noMountedChatSurface_failsClosed() async throws {
        // Interactive turn, no override, and no chat window mounted: the
        // service cancels (it never falls back to a generic prompt).
        let hasSurface = await MainActor.run { ConfigApprovalQueue.shared.hasMountedSurface }
        try #require(!hasSurface)
        let result = try await runAttended(["action": "apply", "yaml": Self.highRiskYAML])
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("cancelled"), "got \(result)")
        #expect(result.contains("Nothing was applied"))
        #expect(await webSearchPolicy() != "auto")
    }

    @Test func deniedTimedOutAndCancelledApprovalsApplyNothing() async throws {
        let cases: [(ConfigApprovalOutcome, String)] = [
            (.denied, "declined"), (.timedOut, "timed out"), (.cancelled, "cancelled"),
        ]
        for (outcome, word) in cases {
            let result = try await runAttended(
                ["action": "apply", "yaml": Self.highRiskYAML], answer: { _, _ in outcome })
            #expect(ToolEnvelope.isError(result), "\(outcome) did not fail: \(result)")
            #expect(result.contains(word), "\(outcome): \(result)")
            #expect(result.contains("Nothing was applied"))
            #expect(await webSearchPolicy() != "auto", "\(outcome) applied the change")
        }
    }

    @Test func theApprovalSeesTheExactPlanAndPruneFlag() async throws {
        let captured = PlanCapture()
        _ = try await runAttended(
            ["action": "apply", "yaml": Self.highRiskYAML, "prune": false],
            answer: { plan, prune in
                await captured.set(plan: plan, prune: prune)
                return .denied
            })
        let seen = await captured.value
        let plan = try #require(seen?.plan)
        #expect(plan.hasHighRiskChanges, "auto tool policy must be flagged high risk")
        #expect(plan.actions.contains { $0.section == "tools" })
        #expect(seen?.prune == false)
    }

    @Test func relayExposure_isHighRiskAndNeverAppliesOnADeniedPlan() async throws {
        // Owner policy: relay/network exposure is never turned on without the
        // user's approval; the planner flags it HIGH RISK for the modal.
        let name = "zz-relay-probe-\(UUID().uuidString.prefix(6))"
        let yaml = """
            agents:
              - name: \(name)
                capabilities:
                  relay_enabled: true
            """
        let planned = try await runAsDefault(["action": "plan", "yaml": yaml])
        #expect(planned.contains("high-risk"), "plan did not flag relay exposure: \(planned)")

        let result = try await runAttended(
            ["action": "apply", "yaml": yaml], answer: { _, _ in .denied })
        #expect(ToolEnvelope.isError(result))
        let exists = await MainActor.run { AgentManager.shared.agents.contains { $0.name == name } }
        #expect(!exists, "a denied plan created the agent")
    }

    @Test func approvedApply_landsAndSaysDoneOnce() async throws {
        let probe = "zz-apply-probe-\(UUID().uuidString.prefix(8))"
        let before = await MainActor.run { ConfigExporter.export() }
        let keep = (before.commands ?? []).map { "  - name: \($0.name)" }
        let yaml = "commands:\n" + (keep + ["  - name: \(probe)\n    template: \"probe\""]).joined(separator: "\n")

        let result = try await runAttended(
            ["action": "apply", "yaml": yaml], answer: { _, _ in .approved })
        #expect(!ToolEnvelope.isError(result), "got \(result)")
        #expect(result.contains("\"status\":\"applied\""), "got \(result)")
        #expect(result.contains("DONE"))
        let landed = await MainActor.run { ConfigExporter.export().commands?.contains { $0.name == probe } }
        #expect(landed == true)

        // Re-applying the same document is a no-op (idempotent), and says so.
        let again = try await runAttended(
            ["action": "apply", "yaml": yaml], answer: { _, _ in .approved })
        #expect(again.contains("no_changes"), "got \(again)")

        // Cleanup: restore the original commands (prunes the probe).
        let cleanup = keep.isEmpty ? "commands: []" : "commands:\n" + keep.joined(separator: "\n")
        _ = try await runAttended(
            ["action": "apply", "yaml": cleanup, "prune": true], answer: { _, _ in .approved })
    }

    @Test func pruneApplyThatDeletesNothing_saysSoInTheNotes() async throws {
        let before = await MainActor.run { ConfigExporter.export() }
        let keep = (before.commands ?? []).map { "  - name: \($0.name)" }
        let probe = "zz-prune-probe-\(UUID().uuidString.prefix(8))"
        let yaml = "commands:\n" + (keep + ["  - name: \(probe)\n    template: \"probe\""]).joined(separator: "\n")
        let result = try await runAttended(
            ["action": "apply", "yaml": yaml, "prune": true], answer: { _, _ in .approved })
        #expect(result.contains("prune: true deleted NOTHING"), "got \(result)")
        #expect(result.contains("This apply CREATED"), "got \(result)")
        let cleanup = keep.isEmpty ? "commands: []" : "commands:\n" + keep.joined(separator: "\n")
        _ = try await runAttended(
            ["action": "apply", "yaml": cleanup, "prune": true], answer: { _, _ in .approved })
    }

    // MARK: Paired phone

    @Test func pairedPhoneRun_parksThePlanForThePhoneAndAnswersApplyOrCancel() async throws {
        let yaml = Self.highRiskYAML
        // Cancel from the phone: user_denied, nothing applied.
        let run = Task {
            try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
                try await ChatExecutionContext.$isExternalSurface.withValue(true) {
                    try await ChatExecutionContext.$hasRemoteReviewer.withValue(true) {
                        try await OsaurusConfigTool().execute(
                            argumentsJSON: Self.json(["action": "apply", "yaml": yaml]))
                    }
                }
            }
        }
        var id: UUID?
        for _ in 0 ..< 500 {
            id = await MainActor.run { ConfigApprovalQueue.shared.pending.first { $0.fromPairedPhone }?.id }
            if id != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let requestId = try #require(id, "the phone's plan was never parked")
        let answered = await MainActor.run {
            ConfigApprovalQueue.shared.resolveFromPairedPhone(id: requestId, apply: false)
        }
        #expect(answered)
        let result = try await run.value
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("declined"))
        #expect(await webSearchPolicy() != "auto")
    }

    // MARK: Grounded-claim check keys off the real envelope

    @Test func groundedConfigCheck_isLiveForTheRealTool() async throws {
        let probe = "zz-grounded-probe-\(UUID().uuidString.prefix(8))"
        let before = await MainActor.run { ConfigExporter.export() }
        let keep = (before.commands ?? []).map { "  - name: \($0.name)" }
        let yaml = "commands:\n" + (keep + ["  - name: \(probe)\n    template: \"probe\""]).joined(separator: "\n")
        let applyArgs = Self.json(["action": "apply", "yaml": yaml])

        // A dry run, a denial and a refusal never ground a "done" claim.
        var guardState = IntelGroundedClaimGuard()
        let plan = try await runAsDefault(["action": "plan", "yaml": yaml])
        guardState.record(
            toolName: OsaurusConfigTool.toolName, argumentsJSON: Self.json(["action": "plan", "yaml": yaml]), result: plan)
        #expect(!guardState.hasGroundedConfigApply)
        let denied = try await runAttended(["action": "apply", "yaml": yaml], answer: { _, _ in .denied })
        guardState.record(toolName: OsaurusConfigTool.toolName, argumentsJSON: applyArgs, result: denied)
        #expect(!guardState.hasGroundedConfigApply)
        let ungrounded = guardState.finalAnswerNotice(
            visibleText: "I've added the command for you.", configToolOffered: true)
        #expect(ungrounded != nil, "an ungrounded 'done' claim passed the check")

        // A landed apply grounds it.
        var grounded = IntelGroundedClaimGuard()
        let applied = try await runAttended(["action": "apply", "yaml": yaml], answer: { _, _ in .approved })
        grounded.record(toolName: OsaurusConfigTool.toolName, argumentsJSON: applyArgs, result: applied)
        #expect(grounded.hasGroundedConfigApply, "the real envelope did not ground the claim: \(applied)")
        #expect(
            grounded.finalAnswerNotice(visibleText: "I've added the command for you.", configToolOffered: true) == nil)

        let cleanup = keep.isEmpty ? "commands: []" : "commands:\n" + keep.joined(separator: "\n")
        _ = try await runAttended(
            ["action": "apply", "yaml": cleanup, "prune": true], answer: { _, _ in .approved })
    }
}

private actor PlanCapture {
    private(set) var value: (plan: ConfigPlan, prune: Bool)?
    func set(plan: ConfigPlan, prune: Bool) { value = (plan, prune) }
}
