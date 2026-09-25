import Combine
import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel agent runtime lane", .serialized)
@MainActor
struct IntelAgentRuntimeLaneTests {

    @Test
    func capabilityRevisionInvalidatesSessionState() async {
        await SessionToolStateStore.shared.reset()
        let sessionId = UUID()
        let initial = SessionToolState.fingerprint(executionMode: "none", toolMode: "auto")

        await SessionToolStateStore.shared.setInitial(
            sessionId,
            preflight: "old preflight",
            alwaysLoadedNames: ["old_tool"],
            fingerprint: initial
        )
        #expect(await SessionToolStateStore.shared.get(sessionId)?.initialPreflight as? String == "old preflight")

        AgentManager.shared.bumpCapabilityRevision()
        let current = SessionToolState.fingerprint(executionMode: "none", toolMode: "auto")
        await SessionToolStateStore.shared.invalidateIfFingerprintChanged(
            sessionId,
            liveFingerprint: current
        )

        #expect(await SessionToolStateStore.shared.get(sessionId) == nil)
    }

    @Test
    func sessionStateAccumulatesLoadedToolsWithoutDuplicates() async {
        await SessionToolStateStore.shared.reset()
        let sessionId = UUID()

        await SessionToolStateStore.shared.appendLoadedTools(
            sessionId,
            names: ["one", "two", "one"],
            fallbackPreflight: "fallback",
            fallbackAlwaysLoadedNames: nil
        )
        await SessionToolStateStore.shared.appendLoadedTools(
            sessionId,
            names: ["two", "three"],
            fallbackPreflight: nil,
            fallbackAlwaysLoadedNames: nil
        )

        let loaded = await SessionToolStateStore.shared.get(sessionId)?.loadedToolNames
        #expect(Set(loaded ?? []) == Set(["one", "two", "three"]))
        #expect(await SessionToolStateStore.shared.get(sessionId)?.initialPreflight as? String == "fallback")
    }

    @Test
    func newSessionUsesAgentModelAndResetRestoresInheritance() async throws {
        let agent = Agent(
            name: "Intel runtime model test \(UUID().uuidString)",
            defaultModel: "intel-runtime-test-model"
        )
        AgentManager.shared.add(agent)
        #expect(AgentManager.shared.effectiveModel(for: agent.id) == "intel-runtime-test-model")
        let sessionId = ChatSessionsManager.shared.createNew(agentId: agent.id)
        defer { ChatSessionsManager.shared.delete(id: sessionId) }
        #expect(ChatSessionsManager.shared.sessions[sessionId]?.agentId == agent.id)
        #expect(ChatSessionsManager.shared.sessions[sessionId]?.selectedModel == "intel-runtime-test-model")

        AgentManager.shared.resetDefaultModel(for: agent.id)
        let inheritedModel = ChatConfigurationStore.load().defaultModel ?? "deepseek-v4-pro"
        #expect(AgentManager.shared.effectiveModel(for: agent.id) == inheritedModel)
        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test
    func deletedSessionRejectsLateSaveAndCannotReappearOnRefresh() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-deleted-session-tests-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                ChatSessionsManager.shared.refresh()
            }

            let id = ChatSessionsManager.shared.createNew()
            let staleOwner = try #require(ChatSessionsManager.shared.session(for: id))
            ChatSessionsManager.shared.save(staleOwner)
            ChatSessionsManager.shared.delete(id: id)

            // Simulates the still-open chat object flushing after deletion.
            ChatSessionsManager.shared.save(staleOwner)
            ChatSessionsManager.shared.refresh()

            #expect(ChatSessionsManager.shared.session(for: id) == nil)
        }
    }

    @Test
    func chatLocalModelSelectionDoesNotRewriteAgentDefault() async throws {
        let configuredModel = "intel-agent-default-\(UUID().uuidString)"
        let chatOverride = "intel-chat-override-\(UUID().uuidString)"
        let agent = Agent(
            name: "Intel chat-local model test \(UUID().uuidString)",
            defaultModel: configuredModel
        )
        AgentManager.shared.add(agent)

        let session = ChatSession()
        session.agentId = agent.id
        session.selectedModel = chatOverride
        await Task.yield()

        #expect(session.selectedModel == chatOverride)
        #expect(AgentManager.shared.agent(for: agent.id)?.defaultModel == configuredModel)
        #expect(AgentManager.shared.effectiveModel(for: agent.id) == configuredModel)
        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test
    func dispatchRejectsToolsWhenAgentToolsAreDisabled() async throws {
        let agent = Agent(
            name: "Intel disabled-tools test \(UUID().uuidString)",
            disableTools: true
        )
        AgentManager.shared.add(agent)

        let result = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
            try await ToolRegistry.shared.execute(name: "list_knowledge", argumentsJSON: "{}")
        }
        #expect(result.contains("Tools are disabled for this agent"))
        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test
    func dispatchRejectsToolRemovedFromLiveAgentAllowlist() async throws {
        var settings = AgentSettings.defaultDisabled
        settings.webSearchEnabled = true
        let agent = Agent(
            name: "Intel live tool revocation test \(UUID().uuidString)",
            toolSelectionMode: .auto,
            manualToolNames: [],
            settings: settings
        )
        AgentManager.shared.add(agent)

        let result = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
            try await ToolRegistry.shared.execute(name: "web_search", argumentsJSON: "{}")
        }
        #expect(result.contains("not assigned to the active agent"))
        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test
    func dispatchRejectsToolRemovedFromManualAgentAllowlist() async throws {
        var settings = AgentSettings.defaultDisabled
        settings.webSearchEnabled = true
        let agent = Agent(
            name: "Intel manual tool revocation test \(UUID().uuidString)",
            toolSelectionMode: .manual,
            manualToolNames: [],
            settings: settings
        )
        AgentManager.shared.add(agent)

        let result = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
            try await ToolRegistry.shared.execute(name: "web_search", argumentsJSON: "{}")
        }
        #expect(result.contains("not assigned to the active agent"))
        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test
    func dispatchRejectsWebSearchAndKnowledgeWithoutTheirGrants() async throws {
        let agent = Agent(name: "Intel capability-grant test \(UUID().uuidString)")
        AgentManager.shared.add(agent)

        let webResult = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
            try await ToolRegistry.shared.execute(name: "web_search", argumentsJSON: "{}")
        }
        #expect(webResult.contains("Web Search is disabled"))

        let knowledgeResult = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
            try await ToolRegistry.shared.execute(name: "list_knowledge", argumentsJSON: "{}")
        }
        #expect(knowledgeResult.contains("Knowledge is not enabled"))
        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test
    func knowledgeGrantPublishesPersistsAndRevokesRuntimeAccess() async throws {
        try await StoragePathsTestLock.shared.run {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory.appendingPathComponent(
                "osaurus-knowledge-grant-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AgentManager.shared.refresh()
            await KnowledgeManager.shared.reload()
            var createdAgentId: UUID?

            do {
                let collection = KnowledgeCollection(
                    name: "Grant test \(UUID().uuidString)",
                    folderPath: root.path
                )
                try KnowledgeCollectionStore.save(collection)
                await KnowledgeManager.shared.reload()

                let agent = Agent(
                    name: "Knowledge grant test \(UUID().uuidString)",
                    toolSelectionMode: .manual,
                    manualToolNames: []
                )
                AgentManager.shared.add(agent)
                createdAgentId = agent.id

                let grantSnapshot = await MainActor.run {
                    var publicationCount = 0
                    let observation = AgentManager.shared.objectWillChange.sink { _ in
                        publicationCount += 1
                    }
                    defer { observation.cancel() }

                    let revisionBeforeGrant = AgentManager.shared.currentCapabilityRevision()
                    AgentManager.shared.updateKnowledgeSettings(
                        enabled: true,
                        collectionIds: [collection.id],
                        for: agent.id
                    )
                    return (
                        publicationCount: publicationCount,
                        enabled: AgentManager.shared.knowledgeEnabled(for: agent.id),
                        collectionIds: AgentManager.shared.knowledgeCollectionIds(for: agent.id),
                        effectiveIds: AgentManager.shared.effectiveKnowledgeCollections(for: agent.id).map(\.id),
                        revisionAdvanced: AgentManager.shared.currentCapabilityRevision() > revisionBeforeGrant
                    )
                }

                #expect(grantSnapshot.publicationCount > 0)
                #expect(grantSnapshot.enabled)
                #expect(grantSnapshot.collectionIds == [collection.id])
                #expect(grantSnapshot.effectiveIds == [collection.id])
                #expect(grantSnapshot.revisionAdvanced)

                let composed = await SystemPromptComposer.composeChatContext(
                    agentId: agent.id,
                    query: "Search my Knowledge collection"
                )
                let offeredNames = Set(composed.tools.map { $0.function.name })
                #expect(offeredNames.isSuperset(of: ToolRegistry.knowledgeToolNames))

                let ledger = try String(contentsOf: OsaurusPaths.knowledgeAgentGrantsFile())
                #expect(ledger.contains(agent.id.uuidString))
                #expect(ledger.contains(collection.id.uuidString))
                #expect(ledger.contains("\"enabled\" : true"))

                let allowed = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
                    try await ToolRegistry.shared.execute(name: "list_knowledge", argumentsJSON: "{}")
                }
                #expect(!allowed.contains("Knowledge is not enabled"))

                let revokeSnapshot = await MainActor.run {
                    AgentManager.shared.updateKnowledgeSettings(enabled: false, collectionIds: [], for: agent.id)
                    return (
                        enabled: AgentManager.shared.knowledgeEnabled(for: agent.id),
                        effectiveIds: AgentManager.shared.effectiveKnowledgeCollections(for: agent.id).map(\.id)
                    )
                }
                #expect(!revokeSnapshot.enabled)
                #expect(revokeSnapshot.effectiveIds.isEmpty)

                let revokedContext = await SystemPromptComposer.composeChatContext(
                    agentId: agent.id,
                    query: "Search my Knowledge collection again"
                )
                let revokedNames = Set(revokedContext.tools.map { $0.function.name })
                #expect(revokedNames.isDisjoint(with: ToolRegistry.knowledgeToolNames))

                let denied = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
                    try await ToolRegistry.shared.execute(name: "list_knowledge", argumentsJSON: "{}")
                }
                #expect(denied.contains("Knowledge is not enabled"))

                _ = await AgentManager.shared.delete(id: agent.id)
            } catch {
                if let createdAgentId {
                    _ = await AgentManager.shared.delete(id: createdAgentId)
                }
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                await KnowledgeManager.shared.reload()
                try? fileManager.removeItem(at: root)
                throw error
            }

            OsaurusPaths.overrideRoot = previousRoot
            AgentManager.shared.refresh()
            await KnowledgeManager.shared.reload()
            try? fileManager.removeItem(at: root)
        }
    }

    @Test
    func memoryAndSelfSchedulingGatesAreOffByDefault() {
        #expect(AgentManager.shared.effectiveMemoryDisabled(for: Agent.defaultId) == !MemoryConfigurationStore.load().enabled)
        #expect(!AgentManager.shared.effectiveSelfSchedulingEnabled(for: Agent.defaultId))
    }

    @Test
    func manualSelectionCannotAdvertiseSchedulerToolsWhileSelfSchedulingIsOff() async throws {
        let schedulerNames = ["schedule_next_run", "cancel_next_run", "notify"]
        var settings = AgentSettings.defaultDisabled
        settings.schedule = AgentScheduleSettings.defaults(for: .manual)
        var agent = Agent(
            name: "Intel scheduler ability gate test \(UUID().uuidString)",
            toolSelectionMode: .manual,
            manualToolNames: schedulerNames,
            settings: settings
        )
        AgentManager.shared.add(agent)

        let disabledContext = await SystemPromptComposer.composeChatContext(
            agentId: agent.id,
            query: "Schedule a follow-up"
        )
        let disabledNames = Set(disabledContext.tools.map { $0.function.name })
        #expect(disabledNames.isDisjoint(with: schedulerNames))

        let denied = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
            try await ToolRegistry.shared.execute(name: "notify", argumentsJSON: "{}")
        }
        #expect(denied.contains("Self-scheduling is disabled"))

        settings.schedule = AgentScheduleSettings.defaults(for: .ambient)
        agent.settings = settings
        AgentManager.shared.update(agent)
        #expect(!AgentManager.shared.effectiveSelfSchedulingEnabled(for: agent.id))

        let legacyEnabledContext = await SystemPromptComposer.composeChatContext(
            agentId: agent.id,
            query: "Schedule a follow-up"
        )
        let legacyEnabledNames = Set(legacyEnabledContext.tools.map { $0.function.name })
        #expect(legacyEnabledNames.isDisjoint(with: schedulerNames))

        _ = await AgentManager.shared.delete(id: agent.id)
    }
}
