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
        #expect(prompt.contains("`orchestrator_targets`"))
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

    @Test("admitted delegation roster exposes exact target identity to the Orchestrator")
    func admittedRosterIsGrounded() {
        let first = IntelOrchestratorPrompt.DelegationTarget(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Rosy Helper",
            modelID: "cloud/helper"
        )
        let prompt = IntelOrchestratorPrompt.compose(
            agentID: Agent.defaultId,
            editablePrompt: "",
            delegationTargets: [first]
        )

        #expect(prompt.contains("Rosy Helper"))
        #expect(prompt.contains(first.id.uuidString))
        #expect(prompt.contains("cloud/helper"))
        #expect(prompt.contains("runtime will revalidate"))
    }

    @Test("empty roster tells the Orchestrator not to request an unknowable UUID")
    func emptyRosterIsTruthful() {
        let prompt = IntelOrchestratorPrompt.compose(agentID: Agent.defaultId, editablePrompt: "")
        #expect(prompt.contains("No custom agent is configured"))
        #expect(prompt.contains("Do not ask the user for an agent UUID"))
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
        #expect(names.contains(IntelOrchestratorTargetsTool.toolName))
        #expect(context.prompt.contains("built-in Orchestrator"))
    }

    @Test("disabled tools never receive folder tool-call instructions")
    func disabledFolderToolsDoNotAdvertiseDispatch() async {
        let folder = FolderContext(
            rootPath: URL(fileURLWithPath: "/tmp/disabled-folder-tools"),
            projectType: .swift,
            tree: "./\nREADME.md",
            manifest: nil,
            gitStatus: nil,
            isGitRepo: false,
            contextFiles: nil
        )
        let context = await SystemPromptComposer.composeChatContext(
            agentId: Agent.defaultId,
            toolsDisabled: true,
            folderContext: folder
        )
        #expect(context.tools.isEmpty)
        #expect(context.prompt.contains("Folder tools are disabled for this turn"))
        #expect(!context.prompt.contains("## Tool Use (MANDATORY)"))
        #expect(!context.prompt.contains(SystemPromptTemplates.folderToolGuide))
    }
}
