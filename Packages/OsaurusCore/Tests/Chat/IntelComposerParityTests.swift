//
//  IntelComposerParityTests.swift
//  OsaurusCoreTests
//
//  Stage 5b slices 1-3 (docs/UPSTREAM_AUDIT_2026-11-11.md composer audit):
//  the platform line, persona fallback, project instructions in the system
//  prompt, knowledge/image/Mac Automation guidance, the effective-query
//  fallback, canonical tool order, the upstream manifest gate and grouping,
//  and grant reconcile keeping loaded tools. Isolated storage.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel composer parity (stage 5b)", .serialized)
struct IntelComposerParityTests {

    @MainActor
    private static func addAgent(prompt: String, mode: ToolSelectionMode = .manual, allow: [String]? = []) -> Agent {
        var agent = Agent(name: "parity-\(UUID().uuidString.prefix(6))", systemPrompt: prompt, agentAddress: nil)
        agent.toolSelectionMode = mode
        agent.manualToolNames = allow
        AgentManager.shared.add(agent)
        return agent
    }

    // MARK: Slice 1

    @MainActor
    @Test("The platform line is always the first section, and a blank persona falls back")
    func platformAndPersona() async throws {
        try await ChatHistoryTestStorage.run {
            let blank = Self.addAgent(prompt: "   ")
            let custom = Self.addAgent(prompt: "You are Pip.")
            let blankContext = await SystemPromptComposer.composeChatContext(agentId: blank.id, query: "hi")
            let customContext = await SystemPromptComposer.composeChatContext(agentId: custom.id, query: "hi")
            let builtIn = await SystemPromptComposer.composeChatContext(agentId: Agent.defaultId, query: "hi")

            for context in [blankContext, customContext, builtIn] {
                #expect(context.prompt.hasPrefix(SystemPromptTemplates.platformIdentity))
                #expect(context.promptSections.first?.id == "platform")
                #expect(context.promptSections.dropFirst().first?.id == "persona")
            }
            #expect(blankContext.prompt.contains(SystemPromptTemplates.defaultPersona))
            #expect(customContext.prompt.contains("You are Pip."))
            #expect(!customContext.prompt.contains(SystemPromptTemplates.defaultPersona))
            _ = await AgentManager.shared.delete(id: blank.id)
            _ = await AgentManager.shared.delete(id: custom.id)
        }
    }

    @MainActor
    @Test("Project instructions ride the system prompt, not the [Memory] prefix")
    func projectInstructionsInSystemPrompt() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.addAgent(prompt: "x")
            var project = ProjectManager.shared.create(name: "Rosy Notes")
            project.instructions = "  Keep answers local.  "
            ProjectManager.shared.update(project)

            let context = await SystemPromptComposer.composeChatContext(
                agentId: agent.id, query: "hi", projectId: project.id)
            #expect(context.prompt.contains("## Project: Rosy Notes\n\nKeep answers local."))
            #expect(context.promptSections.contains { $0.id == "projectInstructions" })
            #expect(!(context.memorySection ?? "").contains("Keep answers local."))
            ProjectManager.shared.delete(id: project.id)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test("Mac Automation Context names the working app; a blank app yields none")
    func automationContext() {
        let context = SystemPromptComposer.appleScriptWorkingAppContext(appName: "Pages\nBeta")
        #expect(context?.contains("Working app before this message: Pages Beta") == true)
        #expect(context?.hasPrefix("[Mac Automation Context]") == true)
        #expect(SystemPromptComposer.appleScriptWorkingAppContext(appName: "  ") == nil)
        #expect(SystemPromptComposer.appleScriptWorkingAppContext(appName: nil) == nil)

        let prefix = SystemPromptComposer.composeInjectedUserPrefix(
            memorySection: "m", automationContext: context, timeContext: "[Current Time]\nnow")
        let text = prefix ?? ""
        let automation = text.range(of: "[Mac Automation Context]")
        let memory = text.range(of: "[Memory]")
        let time = text.range(of: "[Current Time]")
        #expect(automation != nil && memory != nil && time != nil)
        if let automation, let memory, let time {
            #expect(automation.lowerBound < memory.lowerBound && memory.lowerBound < time.lowerBound)
        }
    }

    @MainActor
    @Test("The registry loop renders image guidance (generation only) once the image tool resolves")
    func imageGuidanceFollowsTheSchema() async throws {
        try await ChatHistoryTestStorage.run {
            var agent = Self.addAgent(prompt: "x")
            let before = await SystemPromptComposer.composeChatContext(agentId: agent.id, query: "hi")
            #expect(!before.promptSections.contains { $0.id == "imageGeneration" })

            agent.settings.imageEnabled = true
            AgentManager.shared.update(agent)
            let after = await SystemPromptComposer.composeChatContext(agentId: agent.id, query: "hi")
            if after.tools.contains(where: { $0.function.name == ToolRegistry.imageToolName }) {
                #expect(after.promptSections.contains { $0.id == "imageGeneration" })
                #expect(after.prompt.contains("Editing existing images is not available"))
            }
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    // MARK: Slice 2

    @Test("The effective query falls back to the latest non-blank user message")
    func effectiveQuery() {
        let messages = [
            ChatMessage(role: "user", content: "first"),
            ChatMessage(role: "assistant", content: "reply"),
            ChatMessage(role: "user", content: "  latest  "),
        ]
        #expect(SystemPromptComposer.resolveEffectiveQuery(query: " explicit ", messages: messages) == "explicit")
        #expect(SystemPromptComposer.resolveEffectiveQuery(query: "  ", messages: messages) == "latest")
        #expect(SystemPromptComposer.resolveEffectiveQuery(query: "", messages: []) == "")
    }

    @Test("Canonical order: loop tools, the capabilities gateway, then alphabetical")
    func canonicalOrder() {
        func tool(_ name: String) -> Tool {
            Tool(type: "function", function: ToolFunction(name: name, description: nil, parameters: nil))
        }
        let shuffled = ["zeta", "capabilities", "share_artifact", "alpha", "todo", "clarify", "complete"].map(tool)
        let ordered = SystemPromptComposer.canonicalToolOrder(shuffled).map(\.function.name)
        #expect(ordered == ["todo", "complete", "clarify", "share_artifact", "capabilities", "alpha", "zeta"])
    }

    // MARK: Slice 3

    @MainActor
    @Test("Manifest groups a plugin's skill with its tools; skills alone produce no manifest")
    func manifestGroupingAndGate() {
        let skillOnly = CapabilityCatalog(
            tools: [], skills: [.init(name: "Reviewer", description: "Review code.")], groups: [])
        #expect(CapabilityManifest.render(skillOnly) == nil)

        let tool = CapabilityCatalog.ToolItem(name: "browser_open", description: "Open a page", groupId: "browser")
        let catalog = CapabilityCatalog(
            tools: [tool],
            skills: [
                .init(name: "Browser Guide", description: "Use the browser.", pluginId: "browser"),
                .init(name: "Standalone", description: "No plugin."),
            ],
            groups: [.init(id: "browser", display: "Browser", tools: [tool])])
        let rendered = CapabilityManifest.render(catalog) ?? ""
        let plugin = rendered.range(of: "<plugin: Browser>")
        let skill = rendered.range(of: "  skill/Browser Guide")
        let toolLine = rendered.range(of: "  tool/browser_open")
        let standalone = rendered.range(of: "<plugin: Skills (no plugin)>")
        #expect(plugin != nil && skill != nil && toolLine != nil && standalone != nil)
        if let plugin, let skill, let toolLine, let standalone {
            #expect(plugin.lowerBound < skill.lowerBound)
            #expect(skill.lowerBound < toolLine.lowerBound)
            #expect(toolLine.lowerBound < standalone.lowerBound)
        }
        #expect(rendered.contains("Worked example"))
        #expect(SystemPromptTemplates.enabledManifestNeedsSkillGovernance(rendered, compact: false))
    }

    @Test("A grant change keeps the tools a session already loaded; a mode flip still resets")
    func reconcileKeepsLoadedTools() async {
        let store = SessionToolStateStore()
        let key = UUID()
        let fingerprint = SessionToolState.fingerprint(executionMode: "none", toolMode: "auto")
        // Turn 1 reconciles before any state exists (as ChatView does), then composes and stores.
        let first = SessionToolStateStore.ToolGrantSnapshot(capabilityRevision: 1, allowedNames: nil)
        await store.reconcileToolGrants(key, current: first)
        await store.setInitial(key, preflight: "old", alwaysLoadedNames: ["a"], fingerprint: fingerprint)
        await store.appendLoadedTools(key, names: ["weather"], fallbackAlwaysLoadedNames: nil)
        await store.reconcileToolGrants(key, current: first)
        #expect(await store.get(key)?.loadedToolNames == ["weather"])
        #expect(await store.get(key)?.initialPreflight as? String == "old")  // unchanged grants: no-op

        await store.reconcileToolGrants(
            key, current: SessionToolStateStore.ToolGrantSnapshot(capabilityRevision: 2, allowedNames: ["x"]))
        #expect(await store.get(key)?.loadedToolNames == ["weather"])
        #expect(await store.get(key)?.initialPreflight == nil)

        // The fingerprint no longer carries the capability revision.
        #expect(SessionToolState.fingerprint(executionMode: "none", toolMode: "auto") == fingerprint)
        await store.invalidateIfFingerprintChanged(
            key, liveFingerprint: SessionToolState.fingerprint(executionMode: "none", toolMode: "manual"))
        #expect(await store.get(key) == nil)
    }
}
