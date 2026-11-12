//
//  IntelComposerFreezeTests.swift
//  OsaurusCoreTests
//
//  Stage 5b slices 4-5: the per-chat freeze (upstream #2171), the frozen
//  user-prefix ledger for HTTP/plugin history, `composePreviewContext`
//  parity with the send path, and the Abilities context readout pricing
//  (upstream #2306/#2323). Isolated storage.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel composer freeze and preview (stage 5b)", .serialized)
struct IntelComposerFreezeTests {

    @MainActor
    private static func addAgent(
        prompt: String = "You are Pip.", mode: ToolSelectionMode = .manual, allow: [String]? = []
    ) -> Agent {
        var agent = Agent(name: "freeze-\(UUID().uuidString.prefix(6))", systemPrompt: prompt, agentAddress: nil)
        agent.toolSelectionMode = mode
        agent.manualToolNames = allow
        AgentManager.shared.add(agent)
        return agent
    }

    private static func tool(_ name: String, _ description: String = "d") -> Tool {
        Tool(type: "function", function: ToolFunction(name: name, description: description, parameters: nil))
    }

    // MARK: Store

    @Test("setInitial fills only the missing fields and keeps what a load already wrote")
    func setInitialFillsMissing() async {
        let store = SessionToolStateStore()
        let key = UUID()
        // A load (or a frozen-prefix write) can create the entry first.
        await store.appendLoadedTools(key, names: ["weather"], fallbackAlwaysLoadedNames: nil)
        await store.recordUserPrefix(key, key: "k#0", prefix: "[Memory]\nm\n[/Memory]\n\n")
        await store.setInitial(
            key, alwaysLoadedNames: ["todo"], toolSpecs: [Self.tool("todo")], fingerprint: "fp", manifest: "M")
        var state = await store.get(key)
        #expect(state?.loadedToolNames == ["weather"])
        #expect(state?.initialAlwaysLoadedNames == ["todo"])
        #expect(state?.initialToolSpecs?.map(\.function.name) == ["todo"])
        #expect(state?.frozenManifest == "M")
        #expect(state?.sessionFingerprint == "fp")
        #expect(state?.frozenUserPrefixes["k#0"] != nil)

        // A second compose never overwrites the frozen values.
        await store.setInitial(
            key, alwaysLoadedNames: ["other"], toolSpecs: [Self.tool("other")], fingerprint: "fp2",
            manifest: "N")
        state = await store.get(key)
        #expect(state?.initialAlwaysLoadedNames == ["todo"])
        #expect(state?.frozenManifest == "M")
        #expect(state?.sessionFingerprint == "fp")
    }

    @Test("A grant change clears the frozen tool fields but keeps loaded tools and user prefixes")
    func reconcileClearsFrozenFields() async {
        let store = SessionToolStateStore()
        let key = UUID()
        let first = SessionToolStateStore.ToolGrantSnapshot(capabilityRevision: 1, allowedNames: nil, gates: "a")
        await store.reconcileToolGrants(key, current: first)
        await store.setInitial(
            key, alwaysLoadedNames: ["todo"], toolSpecs: [Self.tool("todo")], fingerprint: "fp", manifest: "M")
        await store.appendLoadedTools(key, names: ["weather"], fallbackAlwaysLoadedNames: nil)
        await store.recordUserPrefix(key, key: "k#0", prefix: "P")

        await store.reconcileToolGrants(key, current: first)
        #expect(await store.get(key)?.frozenManifest == "M")  // unchanged grants: no-op

        // A different ability gate (gates string) is a change.
        await store.reconcileToolGrants(
            key, current: SessionToolStateStore.ToolGrantSnapshot(capabilityRevision: 1, allowedNames: nil, gates: "b"))
        let state = await store.get(key)
        #expect(state?.initialAlwaysLoadedNames == nil)
        #expect(state?.initialToolSpecs == nil)
        #expect(state?.frozenManifest == nil)
        #expect(state?.loadedToolNames == ["weather"])
        #expect(state?.frozenUserPrefixes["k#0"] == "P")
    }

    @Test("A tool catalog change drops every chat's frozen tool fields, nothing else")
    func catalogChange() async {
        let store = SessionToolStateStore()
        let a = UUID()
        let b = UUID()
        for key in [a, b] {
            await store.setInitial(
                key, alwaysLoadedNames: ["todo"], toolSpecs: [Self.tool("todo")], fingerprint: "fp", manifest: "M")
            await store.appendLoadedTools(key, names: ["weather"], fallbackAlwaysLoadedNames: nil)
        }
        await store.invalidateToolCatalog()
        for key in [a, b] {
            let state = await store.get(key)
            #expect(state?.initialToolSpecs == nil && state?.frozenManifest == nil)
            #expect(state?.initialAlwaysLoadedNames == nil)
            #expect(state?.loadedToolNames == ["weather"])
            #expect(state?.sessionFingerprint == "fp")
        }
    }

    @Test("The fingerprint carries the agent: switching agents mid-chat resets the session")
    func fingerprintHasAgent() async {
        let agentA = UUID()
        let agentB = UUID()
        let a = SessionToolState.fingerprint(executionMode: ExecutionMode.none, toolMode: ToolSelectionMode.auto, agentId: agentA)
        let b = SessionToolState.fingerprint(executionMode: ExecutionMode.none, toolMode: ToolSelectionMode.auto, agentId: agentB)
        #expect(a != b)
        #expect(a == "intel/none/auto/agent:\(agentA.uuidString)")

        let store = SessionToolStateStore()
        let key = UUID()
        await store.setInitial(key, alwaysLoadedNames: ["todo"], fingerprint: a)
        await store.appendLoadedTools(key, names: ["weather"], fallbackAlwaysLoadedNames: nil)
        await store.invalidateIfFingerprintChanged(key, liveFingerprint: b)
        #expect(await store.get(key) == nil)
    }

    @Test("The mounted folder's root is part of the fingerprint, as a hash and not the path")
    func fingerprintHasFolderRoot() {
        func context(_ path: String) -> FolderContext {
            FolderContext(
                rootPath: URL(fileURLWithPath: path), projectType: .unknown, tree: "", manifest: nil,
                gitStatus: nil, isGitRepo: false, contextFiles: nil)
        }
        let one = SessionToolState.fingerprint(
            executionMode: ExecutionMode.hostFolder(context("/tmp/one")), toolMode: ToolSelectionMode.auto)
        let two = SessionToolState.fingerprint(
            executionMode: ExecutionMode.hostFolder(context("/tmp/two")), toolMode: ToolSelectionMode.auto)
        #expect(one != two)
        #expect(!one.contains("/tmp/one"))
    }

    // MARK: Frozen user prefixes (HTTP / plugin)

    @Test("Earlier prefixes replay onto clean history; the latest message gets this request's block")
    func replayAndRecord() {
        var turn1 = [ChatMessage(role: "user", content: "What's on today?")]
        let first = SystemPromptComposer.applyFrozenMemoryPrefixes(
            memorySection: "likes tea", frozen: [:], timeContext: "[Current Time]\nnoon", into: &turn1)
        let recorded = try? #require(first)
        #expect(turn1[0].content?.hasPrefix("[Memory]\nlikes tea\n[/Memory]\n\n[Current Time]\nnoon\n\n") == true)
        #expect(turn1[0].content?.hasSuffix("What's on today?") == true)

        // The client resends CLEAN history plus a new message.
        var turn2 = [
            ChatMessage(role: "user", content: "What's on today?"),
            ChatMessage(role: "assistant", content: "Tea at four."),
            ChatMessage(role: "user", content: "And tomorrow?"),
        ]
        let second = SystemPromptComposer.applyFrozenMemoryPrefixes(
            memorySection: "likes coffee", frozen: [recorded!.key: recorded!.prefix], timeContext: nil, into: &turn2)
        #expect(turn2[0].content == turn1[0].content)  // byte for byte
        #expect(turn2[1].content == "Tea at four.")
        #expect(turn2[2].content?.hasPrefix("[Memory]\nlikes coffee\n[/Memory]\n\n") == true)
        #expect(second?.key != recorded?.key)
    }

    @Test("An identical retry keeps the recorded bytes; duplicate texts get distinct ledger keys")
    func retryAndDuplicates() {
        var messages = [
            ChatMessage(role: "user", content: "yes"),
            ChatMessage(role: "assistant", content: "ok"),
            ChatMessage(role: "user", content: "yes"),
        ]
        let keys = SystemPromptComposer.frozenPrefixKeys(for: messages)
        #expect(keys[0] != keys[2])
        #expect(keys[0]?.hasSuffix("#0") == true && keys[2]?.hasSuffix("#1") == true)

        let frozen = [keys[2]!: "[Memory]\nold\n[/Memory]\n\n"]
        let result = SystemPromptComposer.applyFrozenMemoryPrefixes(
            memorySection: "fresh", frozen: frozen, into: &messages)
        #expect(result == nil)  // nothing new to record
        #expect(messages[2].content == "[Memory]\nold\n[/Memory]\n\nyes")
        #expect(messages[0].content == "yes")  // no prefix was recorded for it
    }

    @Test("With nothing to inject and no ledger the history is untouched")
    func nothingToInject() {
        var messages = [ChatMessage(role: "user", content: "hi")]
        #expect(SystemPromptComposer.applyFrozenMemoryPrefixes(memorySection: nil, frozen: [:], into: &messages) == nil)
        #expect(messages[0].content == "hi")
    }

    @Test("A message with an image gets the block as a leading text part")
    func multimodalPrefix() throws {
        var messages = [ChatMessage(role: "user", text: "look", imageData: [Data([0x89, 0x50])])]
        _ = SystemPromptComposer.applyFrozenMemoryPrefixes(memorySection: "m", frozen: [:], into: &messages)
        let parts = try #require(messages[0].contentParts)
        guard case .text(let first) = try #require(parts.first) else {
            Issue.record("first part is not text")
            return
        }
        #expect(first == "[Memory]\nm\n[/Memory]\n\n")
    }

    // MARK: Compose freeze

    @MainActor
    @Test("Turn 1 returns the baseline names, specs and manifest; turn 2 reuses them verbatim")
    func composeFreezes() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.addAgent(mode: .auto, allow: nil)
            let turn1 = await SystemPromptComposer.composeChatContext(agentId: agent.id, query: "hi")
            let names = try #require(turn1.alwaysLoadedNames)
            #expect(!names.isEmpty)
            let specs = try #require(turn1.initialToolSpecs)
            #expect(Set(specs.map(\.function.name)).isSuperset(of: names))

            // A frozen spec replaces the live one; a frozen manifest is reused
            // verbatim in the same place.
            let victim = try #require(specs.first { names.contains($0.function.name) })
            let frozenSpec = Self.tool(victim.function.name, "FROZEN DESCRIPTION")
            let frozenManifest = "\n\nFROZEN MANIFEST BLOCK"
            let turn2 = await SystemPromptComposer.composeChatContext(
                agentId: agent.id, query: "again",
                frozenAlwaysLoadedNames: names, frozenToolSpecs: [frozenSpec], frozenManifest: frozenManifest)
            #expect(
                turn2.tools.first { $0.function.name == victim.function.name }?.function.description
                    == "FROZEN DESCRIPTION")
            #expect(turn2.alwaysLoadedNames == names)
            if turn1.tools.contains(where: { $0.function.name == "capabilities" }) {
                #expect(turn2.prompt.contains("FROZEN MANIFEST BLOCK"))
                #expect(turn2.enabledManifest == frozenManifest)
            }
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @MainActor
    @Test("The frozen names filter the baseline: a tool that was not in turn 1 stays out")
    func frozenNamesFilter() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.addAgent(mode: .auto, allow: nil)
            let turn1 = await SystemPromptComposer.composeChatContext(agentId: agent.id, query: "hi")
            let names = try #require(turn1.alwaysLoadedNames)
            let dropped = try #require(names.sorted().first)
            let turn2 = await SystemPromptComposer.composeChatContext(
                agentId: agent.id, query: "again", frozenAlwaysLoadedNames: names.subtracting([dropped]))
            #expect(!turn2.tools.contains { $0.function.name == dropped })
            // The frozen set is echoed back so the session keeps it.
            #expect(turn2.alwaysLoadedNames == names.subtracting([dropped]))
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @MainActor
    @Test("With tools off nothing is frozen, so the session records the real set once tools return")
    func toolsOffFreezesNothing() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.addAgent(mode: .auto, allow: nil)
            let off = await SystemPromptComposer.composeChatContext(
                agentId: agent.id, query: "hi", toolsDisabled: true)
            #expect(off.tools.isEmpty)
            #expect(off.alwaysLoadedNames == nil && off.initialToolSpecs == nil && off.enabledManifest == nil)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    // MARK: Preview

    @MainActor
    @Test("The preview lists the same sections, tools and prompt as the send path (no memory)")
    func previewMatchesSend() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.addAgent(mode: .auto, allow: nil)
            let preview = SystemPromptComposer.composePreviewContext(agentId: agent.id, model: "gpt-test")
            let send = await SystemPromptComposer.composeChatContext(
                agentId: agent.id, model: "gpt-test", query: "")
            #expect(preview.prompt == send.prompt)
            #expect(preview.promptSections.map(\.id) == send.promptSections.map(\.id))
            #expect(preview.tools.map(\.function.name) == send.tools.map(\.function.name))
            #expect(preview.toolTokens == send.toolTokens)
            #expect(preview.promptSections.first?.id == "platform")
            #expect(preview.toolTokens > 0)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @MainActor
    @Test("The preview prices tools off as no tools and the persona only")
    func previewToolsOff() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.addAgent()
            let preview = SystemPromptComposer.composePreviewContext(agentId: agent.id, toolsDisabled: true)
            #expect(preview.tools.isEmpty)
            #expect(preview.toolTokens == 0)
            #expect(preview.prompt.contains("You are Pip."))
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @MainActor
    @Test("The preview never opens the agent database")
    func previewDoesNotOpenDatabase() async throws {
        try await ChatHistoryTestStorage.run {
            var agent = Self.addAgent(mode: .manual, allow: nil)
            agent.settings.dbEnabled = true
            AgentManager.shared.update(agent)
            let preview = SystemPromptComposer.composePreviewContext(agentId: agent.id)
            // Not open yet: the empty-state block. The onboarding framing is a
            // full-path section, so a custom agent's lean preview omits it (#2250).
            #expect(preview.memorySection == SchemaSnapshot.emptyStateBlock)
            #expect(!preview.promptSections.contains { $0.id == "agentDB" })
            #expect(SystemPromptComposer.renderSchemaSnapshot(agentId: agent.id, allowOpen: false)
                == SchemaSnapshot.emptyStateBlock)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    // MARK: Abilities readout

    @MainActor
    @Test("The readout prices a draft: tools off drops the tool rows and the figure")
    func readoutDraft() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.addAgent(mode: .auto, allow: nil)
            func draft(tools: Bool, memory: Bool) -> AgentAbilityContextPreview.Draft {
                .init(toolsEnabled: tools, memoryEnabled: memory, dbEnabled: false, webSearchEnabled: false, model: nil)
            }
            let on = AgentAbilityContextPreview.compute(agentId: agent.id, draft: draft(tools: true, memory: true))
            let off = AgentAbilityContextPreview.compute(agentId: agent.id, draft: draft(tools: false, memory: false))
            #expect(on.staticTokens > off.staticTokens)
            #expect(off.displayRows.contains { $0.id == "tools" } == false)
            #expect(on.displayRows.contains { $0.id == "tools" })
            #expect(off.memoryUpperTokens == 0)
            #expect(off.highTokens == off.staticTokens && !off.isRange)
            #expect(on.highTokens >= on.lowTokens)
            #expect(on.displayRows.first?.id == "instructions")
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test("Severity follows the usable window; an unknown window stays normal; tokens format compactly")
    func readoutSeverityAndFormat() {
        func preview(static staticTokens: Int, window: Int?) -> AgentAbilityContextPreview {
            AgentAbilityContextPreview(
                breakdown: ContextBreakdown(), staticTokens: staticTokens, memoryUpperTokens: 0, contextWindow: window)
        }
        #expect(preview(static: 500, window: nil).severity == .normal)
        #expect(preview(static: 500, window: 100_000).severity == .normal)
        #expect(preview(static: 30_000, window: 100_000).severity == .warning)
        #expect(preview(static: 90_000, window: 100_000).severity == .critical)
        #expect(AgentAbilityContextPreview.format(tokens: 842) == "842")
        #expect(AgentAbilityContextPreview.format(tokens: 2_140) == "2.1K")
        #expect(AgentAbilityContextPreview.format(tokens: 12_400) == "12K")
    }
}
