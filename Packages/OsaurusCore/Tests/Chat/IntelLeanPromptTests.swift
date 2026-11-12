//
//  IntelLeanPromptTests.swift
//  OsaurusCoreTests
//
//  Stage 5b slice 6 (upstream #2250): custom agents and folder chats get
//  the lean prompt; only the built-in Default agent without a folder keeps
//  the full guidance set. Also the skills-govern block after the manifest
//  (audit row 20) and `leanFolderContext`. Isolated storage.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel lean prompt path (#2250)", .serialized)
struct IntelLeanPromptTests {

    private static let richSectionIds: Set<String> = [
        "modelFamilyGuidance", "grounding", "codeStyle", "riskAware", "agentLoopGuidance",
        "knowledge", "appleApps", "agentDB", "imageGeneration", "appleScript", "browserUse",
    ]

    private static func folder(
        projectType: ProjectType = .swift, contextFiles: String? = nil
    ) -> FolderContext {
        FolderContext(
            rootPath: URL(fileURLWithPath: "/tmp/lean-prompt-folder"),
            projectType: projectType,
            tree: "./\nREADME.md",
            manifest: nil,
            gitStatus: nil,
            isGitRepo: false,
            contextFiles: contextFiles
        )
    }

    @MainActor
    private static func addAgent() -> Agent {
        var agent = Agent(name: "lean-\(UUID().uuidString.prefix(6))", systemPrompt: "You are Pip.", agentAddress: nil)
        agent.toolSelectionMode = .auto
        AgentManager.shared.add(agent)
        return agent
    }

    private func ids(_ context: ComposedContext) -> [String] { context.promptSections.map(\.id) }

    // MARK: Pure

    @Test("Only the Default agent without a folder keeps the full set")
    func leanGate() {
        #expect(!IntelPromptDiscipline.usesLeanPath(agentId: Agent.defaultId, hasFolder: false))
        #expect(IntelPromptDiscipline.usesLeanPath(agentId: Agent.defaultId, hasFolder: true))
        #expect(IntelPromptDiscipline.usesLeanPath(agentId: UUID(), hasFolder: false))
        #expect(IntelPromptDiscipline.usesLeanPath(agentId: UUID(), hasFolder: true))
        let tools: Set<String> = ["file_write", "shell_run", "todo"]
        #expect(!IntelPromptDiscipline.sections(modelId: "gpt-5.5", toolNames: tools, toolsOff: false).isEmpty)
        #expect(IntelPromptDiscipline.sections(modelId: "gpt-5.5", toolNames: tools, toolsOff: false, lean: true).isEmpty)
    }

    @Test("leanFolderContext is the short contract: path, confinement, no dispatch guide")
    func leanFolderText() {
        let text = SystemPromptTemplates.leanFolderContext(from: Self.folder(), toolNames: [])
        #expect(text.hasPrefix("## Working directory\n**Path:** /tmp/lean-prompt-folder"))
        #expect(text.contains("Writes are confined to this folder"))
        #expect(text.contains(SystemPromptTemplates.batchReadLine))
        #expect(text.contains(SystemPromptTemplates.runnableCodeCheckLine))
        #expect(text.contains(SystemPromptTemplates.folderDocumentFormatsLine))
        #expect(!text.contains(SystemPromptTemplates.folderToolGuide))
        #expect(!text.contains("Root contents"))
        #expect(!text.contains(SystemPromptTemplates.folderShareArtifactLine))
    }

    @Test("leanFolderContext gates optional lines on the schema and appends project instructions")
    func leanFolderOptionalLines() {
        let unknown = SystemPromptTemplates.leanFolderContext(
            from: Self.folder(projectType: .unknown, contextFiles: "Use tabs."),
            toolNames: ["share_artifact", "redact_file"])
        #expect(!unknown.contains(SystemPromptTemplates.runnableCodeCheckLine))
        #expect(unknown.contains(SystemPromptTemplates.folderShareArtifactLine))
        #expect(unknown.contains(SystemPromptTemplates.folderRedactionLine))
        #expect(unknown.hasSuffix("## Project instructions\nUse tabs."))
    }

    // MARK: Composer

    @MainActor
    @Test("Default agent without a folder keeps the full guidance set")
    func defaultAgentFull() async throws {
        try await ChatHistoryTestStorage.run {
            let context = await SystemPromptComposer.composeChatContext(
                agentId: Agent.defaultId, model: "gpt-5", query: "hi")
            let found = ids(context)
            #expect(found.contains("grounding"))
            #expect(found.contains("modelFamilyGuidance"))
            #expect(!found.contains("folderContext"))
        }
    }

    @MainActor
    @Test("A custom agent gets only platform and persona (plus its manifest and notices)")
    func customAgentLean() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.addAgent()
            let context = await SystemPromptComposer.composeChatContext(
                agentId: agent.id, model: "gpt-5", query: "hi")
            let found = ids(context)
            #expect(Array(found.prefix(2)) == ["platform", "persona"])
            #expect(Set(found).isDisjoint(with: Self.richSectionIds), "got \(found)")
            #expect(!context.tools.isEmpty)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @MainActor
    @Test("A folder chat is lean for the Default agent too, with Intel's Tool Use directive after the folder text")
    func folderChatsAreLean() async throws {
        try await ChatHistoryTestStorage.run {
            let custom = Self.addAgent()
            for agentId in [Agent.defaultId, custom.id] {
                let context = await SystemPromptComposer.composeChatContext(
                    agentId: agentId, model: "deepseek/deepseek-v4-flash", query: "hi",
                    folderContext: Self.folder())
                let found = ids(context)
                #expect(Set(found).isDisjoint(with: Self.richSectionIds), "got \(found)")
                let folderIndex = found.firstIndex(of: "folderContext")
                let directiveIndex = found.firstIndex(of: "folderToolUse")
                #expect(folderIndex != nil && directiveIndex != nil)
                if let folderIndex, let directiveIndex {
                    #expect(folderIndex < directiveIndex)
                    #expect(found.firstIndex(of: "persona").map { $0 < folderIndex } == true)
                }
                #expect(context.prompt.contains("## Tool Use (MANDATORY)"))
                #expect(context.prompt.contains(SystemPromptTemplates.batchReadLine))
                #expect(!context.prompt.contains(SystemPromptTemplates.folderToolGuide))
            }
            _ = await AgentManager.shared.delete(id: custom.id)
        }
    }

    @MainActor
    @Test("A folder chat with tools off drops to the short disabled notice, never the directive")
    func folderToolsOff() async throws {
        try await ChatHistoryTestStorage.run {
            let context = await SystemPromptComposer.composeChatContext(
                agentId: Agent.defaultId, toolsDisabled: true, folderContext: Self.folder())
            #expect(context.prompt.contains("Folder tools are disabled for this turn"))
            #expect(!context.prompt.contains("## Tool Use (MANDATORY)"))
            #expect(!context.prompt.contains(SystemPromptTemplates.leanFolderContext(from: Self.folder())))
        }
    }

    @MainActor
    @Test("skillsGovern follows the manifest when a plugin group holds both a skill and tools")
    func skillsGovernAfterManifest() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.addAgent()
            let tool = CapabilityCatalog.ToolItem(name: "browser_open", description: "Open a page", groupId: "browser")
            let catalog = CapabilityCatalog(
                tools: [tool],
                skills: [.init(name: "Browser Guide", description: "Use the browser.", pluginId: "browser")],
                groups: [.init(id: "browser", display: "Browser", tools: [tool])])
            let manifest = "\n\n" + (CapabilityManifest.render(catalog) ?? "")
            #expect(SystemPromptTemplates.enabledManifestNeedsSkillGovernance(manifest, compact: false))

            // A frozen manifest (turn 2+) is reused verbatim and drives the block.
            let context = await SystemPromptComposer.composeChatContext(
                agentId: agent.id, model: "gpt-5", query: "hi", frozenManifest: manifest)
            let found = ids(context)
            let manifestIndex = found.firstIndex(of: "enabledManifest")
            let governIndex = found.firstIndex(of: "skillsGovern")
            #expect(manifestIndex != nil && governIndex != nil)
            if let manifestIndex, let governIndex { #expect(manifestIndex + 1 == governIndex) }
            #expect(context.prompt.contains(SystemPromptTemplates.skillsGovernToolGroups()))

            let tools = CapabilityCatalog.ToolItem(name: "plain_tool", description: "x", groupId: "other")
            let plain = CapabilityCatalog(
                tools: [tools], skills: [], groups: [.init(id: "other", display: "Other", tools: [tools])])
            let plainManifest = "\n\n" + (CapabilityManifest.render(plain) ?? "")
            let withoutSkill = await SystemPromptComposer.composeChatContext(
                agentId: agent.id, model: "gpt-5", query: "hi", frozenManifest: plainManifest)
            #expect(!ids(withoutSkill).contains("skillsGovern"))
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }
}
