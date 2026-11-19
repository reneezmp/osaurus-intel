//
//  AgentTemplateOrchestratorHintTests.swift
//  OsaurusCoreTests
//
//  `osaurus_config` with `template` / `overrides` (W-agent-templates stage 2,
//  ported from upstream Classic): the plan carries the template lineage,
//  empty `yaml` beside a template is ignored, agent fields beside a template
//  become overrides, typos are rejected, and unknown names point at the
//  agents entry. Upstream's read-hint and delegation-rubric tests are not
//  ported: Intel has no `ConfigurationReadNextStep` / `DefaultAgentSystemPromptBuilder`
//  (the template guidance sits in the tool description and `templates` result).
//  Plans only: nothing here applies anything.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentTemplateOrchestratorHintTests {

    // MARK: - Template plan

    /// A template plan has no YAML document to repeat. Told to apply "this
    /// same document", small models transcribed the plan into an `agents:`
    /// entry instead, dropping the template's model and its lineage.
    @Test
    func templatePlan_nextStepRepeatsTheTemplateNotADocument() async throws {
        let args: [String: Any] = [
            "action": "plan",
            "template": "Sub Agent",
            "overrides": ["name": "zz-template-plan-probe-\(UUID().uuidString.prefix(8))"],
        ]
        let data = try JSONSerialization.data(withJSONObject: args)
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await OsaurusConfigTool().execute(argumentsJSON: String(decoding: data, as: UTF8.self))
        }
        #expect(result.contains("dry_run_not_applied"), "plan did not run: \(result)")
        #expect(result.contains("the same `template` and `overrides`"), "next_step: \(result)")
        #expect(!result.contains("this same document"))
    }

    /// Models that fill every argument send `yaml: "{}"` with a template;
    /// refusing that looped Grok on the same rejected plan for eight turns.
    @Test
    func emptyYAMLBesideTemplate_plansTheTemplate() async throws {
        for empty in ["{}", " ", "null"] {
            let args: [String: Any] = [
                "action": "plan",
                "template": "Sub Agent",
                "yaml": empty,
                "overrides": ["name": "zz-empty-yaml-probe-\(UUID().uuidString.prefix(8))"],
            ]
            let data = try JSONSerialization.data(withJSONObject: args)
            let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
                try await OsaurusConfigTool().execute(argumentsJSON: String(decoding: data, as: UTF8.self))
            }
            #expect(result.contains("dry_run_not_applied"), "yaml \(empty): \(result)")
        }
    }

    @Test
    func unnamedTemplatePlan_saysHowToNameTheAgent() async throws {
        let unnamed = try await plan(["template": "Sub Agent", "yaml": "{}"])
        #expect(unnamed.contains("No `overrides.name` given"), "\(unnamed)")

        let named = try await plan([
            "template": "Sub Agent", "overrides": ["name": "zz-named-probe-\(UUID().uuidString.prefix(8))"],
        ])
        #expect(!named.contains("No `overrides.name` given"), "\(named)")
    }

    private func plan(_ args: [String: Any]) async throws -> String {
        var args = args
        if args["action"] == nil { args["action"] = "plan" }
        let data = try JSONSerialization.data(withJSONObject: args)
        return try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await OsaurusConfigTool().execute(argumentsJSON: String(decoding: data, as: UTF8.self))
        }
    }

    /// Grok put the agent's fields in `yaml` next to `template` and kept
    /// re-sending them after being told to use `overrides`; agent fields
    /// (bare, or a one-entry `agents:` list) are the overrides.
    @Test
    func agentFieldsInYAMLBesideTemplate_becomeOverrides() async throws {
        let name = "zz-yaml-fields-\(UUID().uuidString.prefix(8))"
        for yaml in [
            "name: \(name)\nsystem_prompt: Track my budget.\ncapabilities:\n  calculator_enabled: true",
            "agents:\n  - name: \(name)\n    capabilities:\n      calculator_enabled: true",
            "name: \(name)\noverrides:\n  capabilities:\n    calculator_enabled: true",
        ] {
            let result = try await plan(["template": "Sub Agent", "yaml": yaml])
            #expect(result.contains("dry_run_not_applied"), "yaml \(yaml): \(result)")
            #expect(result.contains(name))
            #expect(result.contains("calculator"), "capabilities dropped: \(result)")
        }

        let invented = try await plan([
            "template": "Sub Agent",
            "yaml": "name: \(name)\noverrides:\n  capabilities:\n    file_search_enabled: true",
        ])
        #expect(invented.contains("Unknown `overrides.capabilities` key(s): file_search_enabled"), "\(invented)")
    }

    @Test
    func wholeDocumentBesideTemplate_staysAConflict() async throws {
        for yaml in ["memory:\n  enabled: true", "agents:\n  - name: A\n  - name: B"] {
            let result = try await plan(["template": "Sub Agent", "yaml": yaml])
            #expect(result.contains("not both"), "yaml \(yaml): \(result)")
            #expect(result.contains("`overrides`"))
            #expect(result.contains(#""retryable":false"#))
        }
        let both = try await plan([
            "template": "Sub Agent", "yaml": "name: A", "overrides": ["name": "B"],
        ])
        #expect(both.contains("not both"), "\(both)")
    }

    @Test
    func overridesCapabilities_reachThePlanAndRejectTypos() async throws {
        let name = "zz-caps-\(UUID().uuidString.prefix(8))"
        let ok = try await plan([
            "template": "Sub Agent",
            "overrides": ["name": name, "capabilities": ["calculator_enabled": true]],
        ])
        #expect(ok.contains("dry_run_not_applied"), "\(ok)")
        #expect(ok.contains("calculator"), "capabilities dropped: \(ok)")

        let typo = try await plan([
            "template": "Sub Agent",
            "overrides": ["name": name, "capabilities": ["calculater_enabled": true]],
        ])
        #expect(typo.contains("Unknown `overrides.capabilities` key(s): calculater_enabled"), "\(typo)")
        #expect(typo.contains("calculator_enabled"))

        let stray = try await plan(["template": "Sub Agent", "overrides": ["name": name, "tools": "all"]])
        #expect(stray.contains("Unknown `overrides` key(s): tools"), "\(stray)")

        let numeric = try await plan([
            "template": "Sub Agent", "overrides": ["name": name, "capabilities": ["calculator_enabled": 1]],
        ])
        #expect(numeric.contains("on/off toggles"), "\(numeric)")
    }

    @Test
    func unknownTemplateWithOverrides_pointsAtAgentsEntryNotSaveAs() async throws {
        let args: [String: Any] = [
            "action": "plan",
            "template": "zz-missing-\(UUID().uuidString.prefix(8))",
            "overrides": ["name": "Researcher"],
        ]
        let data = try JSONSerialization.data(withJSONObject: args)
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await OsaurusConfigTool().execute(argumentsJSON: String(decoding: data, as: UTF8.self))
        }
        #expect(result.contains("No agent template named"), "message: \(result)")
        #expect(result.contains("Sub Agent"))
        #expect(result.contains("`agents:` entry"))
        #expect(!result.contains("save_as"))
    }

    @Test
    func starterPromptAsTemplate_pointsAtTheAgentsEntryTemplateKey() async throws {
        let args: [String: Any] = [
            "action": "plan",
            "template": "Researcher",
            "overrides": ["name": "Researcher"],
        ]
        let data = try JSONSerialization.data(withJSONObject: args)
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await OsaurusConfigTool().execute(argumentsJSON: String(decoding: data, as: UTF8.self))
        }
        #expect(result.contains("is a starter prompt, not an agent template"), "message: \(result)")
        #expect(result.contains("template: researcher"))
        #expect(result.contains("Cloud Agent"))
    }

    @Test
    func templatesAction_listsTheVisibleAgentTemplates() async throws {
        let result = try await plan(["action": "templates", "kind": "agent"])
        #expect(result.contains("Cloud Agent"), "\(result)")
        #expect(result.contains("agent_templates"))
        let bad = try await plan(["action": "templates", "kind": "nope"])
        #expect(bad.contains("`kind` must be agent or all."), "\(bad)")
    }

    @Test
    func saveAs_refusesTraversalNames() async throws {
        for hostile in ["../x", "a/b", ".hidden"] {
            let result = try await plan(["action": "export", "sections": ["memory"], "save_as": hostile])
            #expect(result.contains("save_as"), "\(hostile): \(result)")
            #expect(!result.contains("saved_to"))
        }
    }
}
