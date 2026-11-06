//
//  IntelDispatchModelTests.swift
//  osaurusTests
//
//  Upstream #2232 on Intel: a headless dispatched run (schedule / HTTP /
//  plugin / watcher) follows the agent's CURRENT default model, overriding
//  the model persisted on a reattached session. The persisted model stays
//  when the agent's default isn't in the picker, and window chats
//  (`source == .chat`) are never overridden.
//
//  Upstream's `ChatSessionDispatchModelTests` also covers window model
//  restore (`applyPickerItems`, the channel source), which Intel doesn't
//  have; these are its dispatch cases with picker items set directly.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct IntelDispatchModelTests {

    private func localItem(_ id: String) -> ModelPickerItem {
        ModelPickerItem(id: id, displayName: id, source: .local)
    }

    /// Agent with a configured default model. Callers must run `cleanup`.
    private func makeAgent(defaultModel: String) -> (agent: Agent, cleanup: () async -> Void) {
        let agent = Agent(
            name: "Dispatch Model Test Agent \(UUID().uuidString)",
            autonomousExec: AutonomousExecConfig(enabled: false)
        )
        AgentManager.shared.add(agent)
        AgentManager.shared.updateDefaultModel(for: agent.id, model: defaultModel)
        return (agent, { _ = await AgentManager.shared.delete(id: agent.id) })
    }

    /// A session as a reattached dispatch sees it: picker loaded, persisted
    /// model selected.
    private func makeSession(
        agentId: UUID,
        source: SessionSource,
        persistedModel: String,
        items: [ModelPickerItem]
    ) async -> ChatSession {
        let session = ChatSession()
        session.agentId = agentId
        // Let the initial picker-cache snapshot land before setting items.
        for _ in 0 ..< 3 { await Task.yield() }
        session.source = source
        session.pickerItems = items
        session.selectedModel = persistedModel
        return session
    }

    @Test func scheduleDispatchAdoptsAgentCurrentDefault() async {
        let (agent, cleanup) = makeAgent(defaultModel: "mlx-test/new-default")
        let session = await makeSession(
            agentId: agent.id,
            source: .schedule,
            persistedModel: "mlx-test/old-model",
            items: [localItem("mlx-test/old-model"), localItem("mlx-test/new-default")]
        )

        session.applyAgentDefaultModelForDispatch()

        #expect(session.selectedModel == "mlx-test/new-default")
        await cleanup()
    }

    @Test func unavailableAgentDefaultKeepsPersistedModel() async {
        let (agent, cleanup) = makeAgent(defaultModel: "mlx-test/uninstalled-default")
        let session = await makeSession(
            agentId: agent.id,
            source: .http,
            persistedModel: "mlx-test/old-model",
            items: [localItem("mlx-test/old-model")]
        )

        session.applyAgentDefaultModelForDispatch()

        #expect(session.selectedModel == "mlx-test/old-model")
        await cleanup()
    }

    @Test func windowChatSelectionIsNeverOverridden() async {
        let (agent, cleanup) = makeAgent(defaultModel: "mlx-test/new-default")
        let session = await makeSession(
            agentId: agent.id,
            source: .chat,
            persistedModel: "mlx-test/manual-pick",
            items: [localItem("mlx-test/manual-pick"), localItem("mlx-test/new-default")]
        )

        session.applyAgentDefaultModelForDispatch()

        #expect(session.selectedModel == "mlx-test/manual-pick")
        await cleanup()
    }
}
