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
        let agent = Agent(
            name: "Intel live tool revocation test \(UUID().uuidString)",
            toolSelectionMode: .auto,
            manualToolNames: []
        )
        AgentManager.shared.add(agent)

        let result = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
            try await ToolRegistry.shared.execute(name: "list_knowledge", argumentsJSON: "{}")
        }
        #expect(result.contains("not assigned to the active agent"))
        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test
    func dispatchRejectsToolRemovedFromManualAgentAllowlist() async throws {
        let agent = Agent(
            name: "Intel manual tool revocation test \(UUID().uuidString)",
            toolSelectionMode: .manual,
            manualToolNames: []
        )
        AgentManager.shared.add(agent)

        let result = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
            try await ToolRegistry.shared.execute(name: "list_knowledge", argumentsJSON: "{}")
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
    func memoryAndSelfSchedulingGatesAreOffByDefault() {
        #expect(AgentManager.shared.effectiveMemoryDisabled(for: Agent.defaultId) == !MemoryConfigurationStore.load().enabled)
        #expect(!AgentManager.shared.effectiveSelfSchedulingEnabled(for: Agent.defaultId))
    }
}
