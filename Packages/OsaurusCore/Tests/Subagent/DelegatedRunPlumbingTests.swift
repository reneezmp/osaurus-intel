//
//  DelegatedRunPlumbingTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  W-subagents stage 2: the delegated-run plumbing under `spawn_agent`.
//  Ported from upstream Classic's `SubagentAdmission16GBRegressionTests`
//  (dispatch caps → session), `DelegatedModelOverrideTests` (admitted model),
//  `GroupedDispatchOwnershipTests` (reattach keeps the contract),
//  `DelegatedToolFailureTests` (completion snapshot) and
//  `DelegatedBudgetEnforcementTests` (clamps). Intel-only: the engine's
//  context-position cap (`IntelWireHistoryTrim.effectiveWindow`) and the
//  composer's delegated-child strip. No network, keychain or live data.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct DelegatedRunPlumbingTests {

    private func item(_ id: String) -> ModelPickerItem {
        ModelPickerItem(id: id, displayName: id, source: .local)
    }

    // MARK: Dispatch caps -> session

    @Test func dispatchCapsPropagateToSession() {
        let request = DispatchRequest(
            prompt: "hello",
            agentId: UUID(),
            source: .delegation,
            delegationResponseTokenCap: 2048,
            delegationContextPositionCap: 16_684,
            delegationAssistantTurnCap: 2
        )
        #expect(request.isDelegatedRun)
        #expect(
            request.delegationContract
                == DelegatedRunContract(responseTokens: 2048, assistantTurns: 2, contextPositions: 16_684))
        let context = BackgroundTaskManager.shared.makeContextForTesting(request)
        #expect(context.chatSession.source == .delegation)
        #expect(context.chatSession.delegationBudget?.responseTokens == 2048)
        #expect(context.chatSession.delegationBudget?.assistantTurns == 2)
        #expect(context.chatSession.delegationBudget?.contextPositions == 16_684)

        // A partial contract is no contract anywhere in the chain.
        let partial = DispatchRequest(prompt: "hello", agentId: UUID(), delegationResponseTokenCap: 2048)
        #expect(partial.delegationContract == nil)
        #expect(BackgroundTaskManager.shared.makeContextForTesting(partial).chatSession.delegationBudget == nil)
        #expect(ExecutionContext(agentId: UUID()).chatSession.delegationBudget == nil)
        #expect(!partial.isDelegatedRun)
    }

    @Test func clampsOnlyTighten() {
        let contract = DelegatedRunContract(responseTokens: 2048, assistantTurns: 2, contextPositions: 16_684)
        #expect(contract.clampedResponseTokens(agentConfigured: nil) == 2048)
        #expect(contract.clampedResponseTokens(agentConfigured: 512) == 512)
        #expect(contract.clampedResponseTokens(agentConfigured: 99_999) == 2048)
        #expect(contract.clampedToolAttempts(surfaceConfigured: 15) == 2)
        #expect(contract.clampedToolAttempts(surfaceConfigured: 1) == 1)
        #expect(contract.clampedContextWindow(resolved: 128_000) == 16_684)
        #expect(contract.clampedContextWindow(resolved: 8_000) == 8_000)
    }

    // MARK: Engine context-position cap

    @Test func engineWindowIsTheTighterOfWindowAndCap() {
        #expect(IntelWireHistoryTrim.effectiveWindow(resolved: 128_000, contextPositionCap: nil) == 128_000)
        #expect(IntelWireHistoryTrim.effectiveWindow(resolved: nil, contextPositionCap: nil) == nil)
        #expect(IntelWireHistoryTrim.effectiveWindow(resolved: 128_000, contextPositionCap: 16_684) == 16_684)
        #expect(IntelWireHistoryTrim.effectiveWindow(resolved: 8_000, contextPositionCap: 16_684) == 8_000)
        // The cap holds even when no window was resolved (a headless run).
        #expect(IntelWireHistoryTrim.effectiveWindow(resolved: nil, contextPositionCap: 4_096) == 4_096)
        #expect(IntelWireHistoryTrim.effectiveWindow(resolved: 128_000, contextPositionCap: 0) == 1)
    }

    @Test func requestCapIsNotEncodedOnTheWire() throws {
        var request = ChatCompletionRequest(
            model: "m", messages: [ChatMessage(role: "user", content: "hi")], temperature: nil,
            max_tokens: nil, stream: false, top_p: nil, frequency_penalty: nil, presence_penalty: nil,
            stop: nil, n: nil, tools: nil, tool_choice: nil, session_id: nil)
        request.contextPositionCap = 4_096
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!json.contains("contextPositionCap"))
        #expect(!json.contains("4096"))
    }

    // MARK: Admitted model

    @Test func admittedModelWinsOverTheAgentDefault() async {
        let agent = Agent(name: "Delegated Model \(UUID().uuidString)")
        AgentManager.shared.add(agent)
        AgentManager.shared.updateDefaultModel(for: agent.id, model: "mlx-test/default")
        let request = DispatchRequest(
            prompt: "bounded child",
            agentId: agent.id,
            source: .delegation,
            delegationResponseTokenCap: 2048,
            delegationContextPositionCap: 4096,
            delegationAssistantTurnCap: 2,
            delegationModel: "mlx-test/admitted"
        )
        let session = BackgroundTaskManager.shared.makeContextForTesting(request).chatSession
        for _ in 0 ..< 3 { await Task.yield() }
        session.pickerItems = [item("mlx-test/default"), item("mlx-test/admitted")]
        session.applyAgentDefaultModelForDispatch()
        #expect(session.selectedModel == "mlx-test/admitted")
        #expect(AgentManager.shared.effectiveModel(for: agent.id) == "mlx-test/default")

        // A removed admitted model is not permission to run another model.
        session.pickerItems = [item("mlx-test/default")]
        session.applyAgentDefaultModelForDispatch()
        #expect(session.selectedModel == "mlx-test/admitted")
        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test func ordinaryDispatchIgnoresDelegationModel() {
        for source in [SessionSource.chat, .schedule, .plugin] {
            let request = DispatchRequest(
                prompt: "ordinary", agentId: UUID(), source: source, delegationModel: "mlx-test/not-applicable")
            #expect(request.delegationModel == nil)
            let context = BackgroundTaskManager.shared.makeContextForTesting(request)
            #expect(context.chatSession.delegationModel == nil)
        }
    }

    // MARK: Reattach keeps the contract

    @Test func reattachedDelegationKeepsBudgetAndModel() async throws {
        try await ChatHistoryTestStorage.run {
            let agentId = UUID()
            let data = ChatSessionData(
                id: UUID(), title: "Delegated: task", turns: [], agentId: agentId, source: .delegation)
            let budget = DelegatedRunContract(responseTokens: 128, assistantTurns: 2, contextPositions: 2048)
            let context = ExecutionContext(
                reattaching: data, delegationBudget: budget, delegationModel: "priced-child")
            #expect(context.chatSession.delegationBudget == budget)
            #expect(context.chatSession.delegationModel == "priced-child")
            #expect(context.chatSession.source == .delegation)

            // A non-delegation session never takes a delegated model.
            let plain = ChatSessionData(id: UUID(), title: "x", turns: [], agentId: agentId, source: .schedule)
            let other = ExecutionContext(
                reattaching: plain, delegationBudget: budget, delegationModel: "priced-child")
            #expect(other.chatSession.delegationModel == nil)
        }
    }

    // MARK: Composer strips spawn tools and clarify from a delegated child

    @Test func delegatedChildNeverCarriesSpawnClarifyOrOrchestratorDelegate() {
        #expect(SubagentCapabilityRegistry.isExcludedFromDelegatedChild("spawn_agent"))
        #expect(SubagentCapabilityRegistry.isExcludedFromDelegatedChild("clarify"))
        #expect(SubagentCapabilityRegistry.isExcludedFromDelegatedChild("orchestrator_delegate"))
        #expect(!SubagentCapabilityRegistry.isExcludedFromDelegatedChild("file_read"))
        #expect(!SubagentCapabilityRegistry.isExcludedFromDelegatedChild("share_artifact"))
    }

    @Test func composerHonoursTheBoundSessionSource() async throws {
        try await ChatHistoryTestStorage.run {
            // Auto/legacy agent: the registry-wide surface, which includes the
            // agent-loop tools (`clarify`).
            var agent = Agent(name: "child-\(UUID().uuidString.prefix(6))", systemPrompt: "You help.")
            agent.toolSelectionMode = .auto
            agent.manualToolNames = nil
            AgentManager.shared.add(agent)
            let direct = await ChatExecutionContext.$currentSessionSource.withValue(.chat) {
                await SystemPromptComposer.composeChatContext(agentId: agent.id, query: "hi")
            }
            let delegated = await ChatExecutionContext.$currentSessionSource.withValue(.delegation) {
                await SystemPromptComposer.composeChatContext(agentId: agent.id, query: "hi")
            }
            let directNames = Set(direct.tools.map(\.function.name))
            let childNames = Set(delegated.tools.map(\.function.name))
            #expect(directNames.contains("clarify"))
            #expect(!childNames.contains("clarify"))
            #expect(!childNames.contains("spawn_agent"))
            #expect(!childNames.contains("orchestrator_delegate"))
            // Everything else is untouched: the child is the target agent.
            #expect(childNames == directNames.subtracting(["clarify"]))
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    // MARK: Memory provenance

    @Test func delegatedRunsBufferWithDelegatedProvenance() {
        // The RunContext source -> provenance mapping `ChatSession` applies.
        #expect(MemoryService.TurnProvenance.delegated != .user)
        let context = ExecutionContext(agentId: UUID(), source: .delegation)
        #expect(context.chatSession.source == .delegation)
    }

    // MARK: Terminal tool failure

    @Test func toolFailureStateTracksOneRun() {
        var state = DelegatedToolFailureState()
        let old = UUID(), next = UUID()
        let denied = ToolEnvelope.failure(kind: .userDenied, message: "stopped", tool: "image", retryable: false)
        state.begin(runID: old)
        state.record(denied, runID: old)
        #expect(state.current?.kind == .userDenied)
        #expect(state.current?.retryable == false)
        state.begin(runID: next)
        state.record(denied, runID: old)
        state.finish(runID: old)
        #expect(state.runID == next && state.current == nil)

        // A success cannot become a denial, and a finished run takes nothing.
        let run = UUID()
        state.begin(runID: run)
        state.record(ToolEnvelope.success(tool: "image", text: "done"), runID: run)
        #expect(state.current == nil)
        state.finish(runID: run)
        state.record(denied, runID: run)
        #expect(state.current == nil)
    }

    @Test func completionSnapshotSurvivesTaskFinalization() async throws {
        try await ChatHistoryTestStorage.run {
            let context = ExecutionContext(agentId: Agent.defaultId)
            let session = context.chatSession
            session.chatEngineFactory = { MockChatEngine() }
            let taskID = UUID(), runID = UUID()
            session.sessionId = taskID
            session.delegatedToolFailure.begin(runID: runID)
            let state = BackgroundTaskState(
                id: taskID, taskTitle: "completion-snapshot", agentId: Agent.defaultId,
                chatSession: session, executionContext: context, status: .running, currentStep: "Running")
            let manager = BackgroundTaskManager.shared
            manager.registerTaskForTesting(state)
            manager.observeChatTask(state, session: session)
            defer { manager.finalizeTask(taskID) }
            session.isStreaming = true
            session.delegatedToolFailure.record(
                ToolEnvelope.failure(kind: .userDenied, message: "stopped", tool: "image", retryable: false),
                runID: runID)
            session.lastStreamError = "Tool call failed."
            session.delegatedToolFailure.finish(runID: runID)
            session.isStreaming = false
            let completion = await manager.awaitCompletionWithToolFailure(taskID, timeoutSeconds: 2)
            manager.finalizeTask(taskID)
            #expect(manager.taskState(for: taskID) == nil)
            await Task.yield()
            guard case .failed = completion.result else {
                Issue.record("Expected failed background completion")
                return
            }
            // The value-only snapshot keeps the exact cause after the task
            // (and its live session) is gone.
            #expect(completion.terminalToolFailure?.runID == runID)
            #expect(completion.terminalToolFailure?.kind == .userDenied)
            #expect(completion.terminalToolFailure?.retryable == false)
        }
    }

    @Test func awaitCompletionStillReturnsThePlainResult() async {
        let result = await BackgroundTaskManager.shared.awaitCompletion(UUID(), timeoutSeconds: 1)
        guard case .failed(let message) = result else {
            Issue.record("Expected a failure for an unknown task")
            return
        }
        #expect(message == "Background task not found")
    }
}
