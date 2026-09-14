import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel Orchestrator prompt")
struct IntelOrchestratorPromptTests {
    @Test("built-in role survives an empty editable prompt")
    func builtInRoleIsAlwaysPresent() {
        let prompt = IntelOrchestratorPrompt.compose(agentID: Agent.defaultId, editablePrompt: "")

        #expect(prompt.contains("built-in Orchestrator"))
        #expect(prompt.contains("`orchestrator_delegate`"))
        #expect(prompt.contains("`orchestrator_config`"))
        #expect(prompt.contains("tool-free"))
        #expect(prompt.contains("inline text"))
    }

    @Test("editable text extends rather than replaces the built-in role")
    func editablePersonaIsAppended() {
        let prompt = IntelOrchestratorPrompt.compose(
            agentID: Agent.defaultId,
            editablePrompt: "  Speak with measured warmth.  "
        )

        #expect(prompt.contains("built-in Orchestrator"))
        #expect(prompt.hasSuffix("## User-defined persona\nSpeak with measured warmth."))
    }

    @Test("custom agents receive their prompt unchanged")
    func customPromptIsUntouched() {
        let original = "  Keep this spacing.  "
        #expect(IntelOrchestratorPrompt.compose(agentID: UUID(), editablePrompt: original) == original)
    }

    @Test("the built-in Orchestrator receives both model-callable schemas")
    func composedContextExposesOnlyOrchestratorSchemas() async {
        let context = await SystemPromptComposer.composeChatContext(
            agentId: Agent.defaultId,
            toolsDisabled: false
        )
        let names = Set(context.tools.map(\.function.name))

        #expect(names.contains(IntelOrchestratorConfigurationTool.toolName))
        #expect(names.contains(IntelOrchestratorDelegationTool.toolName))
        #expect(context.prompt.contains("built-in Orchestrator"))
    }
}
