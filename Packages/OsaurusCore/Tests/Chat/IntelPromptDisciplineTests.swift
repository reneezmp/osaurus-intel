//
//  IntelPromptDisciplineTests.swift
//  osaurusTests
//
//  `W-cov-reaudit` stage 3c-2 (docs/COV_REAUDIT.md): upstream's static
//  discipline sections (#1317, #1430) on Intel's chat composer, with
//  upstream's gates and order. Pure: no managers, no disk.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelPromptDisciplineTests {
    private let folderTools: Set<String> = [
        "file_read", "file_write", "file_edit", "shell_run", "todo", "complete", "clarify", "share_artifact",
    ]

    @Test func folderChatGetsEverySectionInUpstreamOrder() {
        let sections = IntelPromptDiscipline.sections(
            modelId: "deepseek/deepseek-v4-flash", toolNames: folderTools, toolsOff: false)
        #expect(
            sections.map(\.id) == ["modelFamilyGuidance", "grounding", "codeStyle", "riskAware", "agentLoopGuidance"])
        #expect(sections[0].text == ModelFamilyGuidance.guidance(for: .deepSeek))
        #expect(sections[2].text == SystemPromptTemplates.codeStyleGuidance)
        #expect(sections[3].text == SystemPromptTemplates.riskAwareGuidance)
    }

    @Test func gatewaySchemasGetTheBaseGrounding() throws {
        // Intel offers the `capabilities` gateway, never `capabilities_discover`.
        let sections = IntelPromptDiscipline.sections(
            modelId: "gpt-5.5", toolNames: ["capabilities", "todo"], toolsOff: false)
        let grounding = try #require(sections.first { $0.id == "grounding" })
        #expect(grounding.text == SystemPromptTemplates.groundingDirectiveBase)
        #expect(!grounding.text.contains("capabilities_discover"))
        let legacy = IntelPromptDiscipline.sections(
            modelId: "gpt-5.5", toolNames: ["capabilities_discover"], toolsOff: false)
        #expect(legacy.first { $0.id == "grounding" }?.text == SystemPromptTemplates.groundingDirectiveFull)
    }

    @Test func shellOnlyGetsRiskAwareButNotCodeStyle() {
        let ids = IntelPromptDiscipline.sections(modelId: "gpt-5.5", toolNames: ["shell_run"], toolsOff: false)
            .map(\.id)
        #expect(ids.contains("riskAware"))
        #expect(!ids.contains("codeStyle"))
        #expect(!ids.contains("agentLoopGuidance"))
    }

    @Test func agentLoopDropsShareArtifactWhenNotOffered() throws {
        let sections = IntelPromptDiscipline.sections(
            modelId: "gpt-5.5", toolNames: ["todo", "complete"], toolsOff: false)
        let loop = try #require(sections.first { $0.id == "agentLoopGuidance" })
        #expect(!loop.text.contains("share_artifact("))
        #expect(loop.text.contains("`todo(markdown)`"))
        let withShare = IntelPromptDiscipline.sections(
            modelId: "gpt-5.5", toolNames: ["share_artifact"], toolsOff: false)
        #expect(withShare.first { $0.id == "agentLoopGuidance" }?.text.contains("share_artifact(") == true)
    }

    @Test func familyBlockFollowsTheModelId() {
        func family(_ id: String?) -> String? {
            IntelPromptDiscipline.sections(modelId: id, toolNames: ["todo"], toolsOff: false)
                .first { $0.id == "modelFamilyGuidance" }?.text
        }
        #expect(family("chatgpt/gpt-5.6-terra")?.contains("## Execution discipline") == true)
        #expect(family("gemini/gemini-3-pro") == ModelFamilyGuidance.googleGeminiGuidance)
        #expect(family("openrouter/qwen/qwen3-coder") == ModelFamilyGuidance.glmQwenGuidance)
        #expect(family("anthropic/claude-sonnet") == ModelFamilyGuidance.defaultGuidance)
        // No model picked yet: no block (upstream returns nil for a blank id).
        #expect(family(nil) == nil)
        #expect(family("  ") == nil)
    }

    @Test func toolsOffOrNoToolsKeepsThePromptLean() {
        #expect(IntelPromptDiscipline.sections(modelId: "gpt-5.5", toolNames: folderTools, toolsOff: true).isEmpty)
        // An empty schema keeps only the family block (upstream gates it on
        // tools being on, not on the schema).
        #expect(
            IntelPromptDiscipline.sections(modelId: "gpt-5.5", toolNames: [], toolsOff: false).map(\.id)
                == ["modelFamilyGuidance"])
    }
}
