//
//  SpawnAgentToolTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  W-subagents stage 3: the `spawn_agent` tool as Intel wires it. Ported from
//  upstream Classic's `AgentDelegationDispatcherTests`, `SpawnGuidanceTests`
//  and the composer's spawn cases, adapted to Intel's Gate 4 pool and the
//  remote-only kind. Model-free, in-process, isolated storage.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("spawn_agent tool (stage 3)", .serialized)
struct SpawnAgentToolTests {

    // MARK: Schema

    @Test func schemaMatchesUpstreams() throws {
        let tool = SpawnAgentTool()
        #expect(tool.name == "spawn_agent")
        guard case .object(let root)? = tool.parameters,
            case .object(let properties)? = root["properties"]
        else { Issue.record("no schema"); return }
        #expect(Set(properties.keys) == ["input", "agent", "continue", "background"])
        #expect(root["additionalProperties"] == .bool(false))
        #expect(root["required"] == .array([.string("input")]))
        #expect(tool.handlesOwnApproval)
        #expect(tool.bypassRegistryTimeout)
    }

    @Test func constrainedSpecNarrowsTheAgentEnumAndRoutingMetadata() throws {
        let a = UUID(), b = UUID()
        let base = SpawnAgentTool().asOpenAITool()
        let descriptor = SpawnAgentDescriptor(
            id: a, name: "Researcher", description: "Finds sources", modelId: "cloud/child", isLocal: false,
            providerName: nil)
        let narrowed = SpawnAgentTool.constrainedSpec(
            base, allowedAgentIDs: [a, b], allowedAgentNames: ["Researcher", "Writer", "Researcher", "  "],
            agents: [descriptor])
        guard case .object(let root)? = narrowed.function.parameters,
            case .object(let properties)? = root["properties"],
            case .object(let agent)? = properties["agent"],
            case .array(let enumValues)? = agent["enum"]
        else { Issue.record("no enum"); return }
        let values = enumValues.compactMap { value -> String? in
            if case .string(let s) = value { return s }
            return nil
        }
        // UUIDs first (sorted-normalised), then each distinct non-blank name once.
        #expect(Set(values.prefix(2)) == Set([a.uuidString, b.uuidString]))
        #expect(Array(values.dropFirst(2)) == ["Researcher", "Writer"])
        #expect(narrowed.function.description?.contains(SpawnAgentTool.routingMetadataMarker) == true)
        #expect(narrowed.function.description?.contains("Finds sources") == true)

        // Re-narrowing a frozen payload replaces the metadata instead of stacking it.
        let again = SpawnAgentTool.constrainedSpec(narrowed, allowedAgentIDs: [a], agents: [descriptor])
        let markers = again.function.description?.components(separatedBy: SpawnAgentTool.routingMetadataMarker)
        #expect(markers?.count == 2)

        // No allowed agent: the schema is returned untouched.
        let none = SpawnAgentTool.constrainedSpec(base, allowedAgentIDs: [])
        #expect(none.function.description == base.function.description)
    }

    // MARK: Refusals before any run

    private func run(_ arguments: String, source: SessionSource? = nil) async throws -> [String: Any] {
        let output: String
        if let source {
            output = try await ChatExecutionContext.$currentSessionSource.withValue(source) {
                try await SpawnAgentTool().execute(argumentsJSON: arguments)
            }
        } else {
            output = try await SpawnAgentTool().execute(argumentsJSON: arguments)
        }
        return try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    @Test func blankInputIsRefusedAsInvalidArgs() async throws {
        let result = try await run(#"{"input":"   ","agent":"x"}"#)
        #expect(result["ok"] as? Bool == false)
        #expect(result["kind"] as? String == "invalid_args")
        #expect(result["retryable"] as? Bool == true)
    }

    @Test func missingAgentAndContinueIsInvalidArgs() async throws {
        let result = try await run(#"{"input":"do it"}"#)
        #expect(result["kind"] as? String == "invalid_args")
        #expect((result["message"] as? String)?.contains("`agent` is required") == true)
    }

    @Test func badContinueIsInvalidArgs() async throws {
        let result = try await run(#"{"input":"do it","continue":"not-a-uuid"}"#)
        #expect(result["kind"] as? String == "invalid_args")
        #expect(result["field"] as? String == "continue")
    }

    @Test func aDelegatedChildCannotSpawn() async throws {
        let result = try await run(#"{"input":"do it","agent":"x"}"#, source: .delegation)
        #expect(result["ok"] as? Bool == false)
        #expect(result["kind"] as? String == "rejected")
        #expect(result["retryable"] as? Bool == false)
    }

    @Test func continuingAnUnknownSessionIsUnavailable() async throws {
        try await ChatHistoryTestStorage.run {
            let result = try await run(#"{"input":"more","continue":"\#(UUID().uuidString)"}"#)
            #expect(result["kind"] as? String == "unavailable")
        }
    }

    @Test func anUnknownAgentNameListsNothingWhenNoPoolIsConfigured() async throws {
        try await ChatHistoryTestStorage.run {
            let result = try await run(#"{"input":"do it","agent":"Nobody"}"#)
            #expect(result["kind"] as? String == "invalid_args")
            #expect(result["field"] as? String == "agent")
        }
    }

    // MARK: Registry wiring

    @MainActor
    @Test func theToolIsRegisteredAndOwnsItsApproval() {
        let registry = ToolRegistry.shared
        #expect(registry.isRegistered("spawn_agent"))
        #expect(registry.handlesOwnApproval(for: "spawn_agent"))
    }

    // MARK: Dispatcher pure parts

    @Test func sessionTitleUsesFirstLineWithPrefixAndCap() {
        #expect(AgentDelegationDispatcher.sessionTitle(for: "Summarize the Q3 report") == "Delegated: Summarize the Q3 report")
        #expect(AgentDelegationDispatcher.sessionTitle(for: "Fix the bug\nwith full detail below") == "Delegated: Fix the bug")
        let long = String(repeating: "a", count: 100)
        let title = AgentDelegationDispatcher.sessionTitle(for: long)
        #expect(title.hasPrefix("Delegated: ") && title.hasSuffix("…") && title.count < long.count)
        #expect(AgentDelegationDispatcher.sessionTitle(for: "   ") == "Delegated: task")
    }

    @Test func delegatedPromptAppendsTheDeliveryContract() {
        let input = "Build a Three.js endless runner game."
        let prompt = AgentDelegationDispatcher.delegatedPrompt(input: input)
        #expect(prompt.hasPrefix(input))
        #expect(prompt.contains("[Delegated task]"))
        #expect(prompt.contains("ONLY your final message"))
        #expect(prompt.contains("`share_artifact`"))
        #expect(prompt.contains("Only when `share_artifact` is unavailable"))
        let withFolder = AgentDelegationDispatcher.delegatedPrompt(input: input, workingFolderPath: "/tmp/work")
        #expect(withFolder.contains("Your working folder is `/tmp/work`"))
        #expect(!withFolder.contains("Only when `share_artifact` is unavailable"))
        let resumed = AgentDelegationDispatcher.delegatedPrompt(input: input, resuming: true)
        #expect(resumed.contains("[Delegated follow-up]"))
        #expect(!resumed.contains("[Delegated task]"))
    }

    @Test func needsInputIsAPrefixContract() {
        #expect(AgentDelegationDispatcher.isNeedsInput("  needs input: which file?"))
        #expect(!AgentDelegationDispatcher.isNeedsInput("I think NEEDS INPUT: is a marker"))
        #expect(AgentDelegationDispatcher.hasOffPrefixNeedsInputMarker("I think NEEDS INPUT: is a marker"))
        #expect(!AgentDelegationDispatcher.hasOffPrefixNeedsInputMarker("NEEDS INPUT: x"))
    }

    private static func turn(_ role: MessageRole, _ content: String) -> ChatTurnData {
        ChatTurnData(id: UUID(), role: role, content: content, createdAt: Date())
    }

    @Test func outcomeHarvestsFinalNonEmptyAssistantTurn() {
        let session = ChatSessionData(
            id: UUID(),
            turns: [
                Self.turn(.user, "task"),
                Self.turn(.assistant, "intermediate step"),
                Self.turn(.tool, "{\"ok\":true}"),
                Self.turn(.assistant, "  Final answer.  "),
                Self.turn(.assistant, "   "),
            ],
            source: .delegation
        )
        let outcome = AgentDelegationDispatcher.outcome(from: session, elapsed: 1.5)
        #expect(outcome?.finalText == "Final answer.")
        #expect(outcome?.assistantTurns == 3)
        #expect(outcome?.sessionId == session.id)
        #expect(AgentDelegationDispatcher.outcome(from: ChatSessionData(turns: [], source: .delegation), elapsed: 0) == nil)
    }

    @Test func queueGraceFloorsAt60AndTracksTheRunBudget() {
        #expect(AgentDelegationDispatcher.queueGraceSeconds(runBudget: 5) == 60)
        #expect(AgentDelegationDispatcher.queueGraceSeconds(runBudget: 900) == 900)
    }

    @Test func childFolderPrefersTheTargetsOwn() {
        let own = DelegatedWorkingFolder(bookmark: nil, path: "/own")
        let launcher = DelegatedWorkingFolder(bookmark: nil, path: "/launcher")
        #expect(AgentDelegationDispatcher.resolveChildWorkingFolder(targetFolder: own, launcherFolder: launcher).folder == own)
        let inherited = AgentDelegationDispatcher.resolveChildWorkingFolder(targetFolder: nil, launcherFolder: launcher)
        #expect(inherited.folder == launcher && inherited.inherited)
        #expect(AgentDelegationDispatcher.resolveChildWorkingFolder(targetFolder: nil, launcherFolder: nil).folder == nil)
    }

    @Test func aTerminalDenialStaysADenialAcrossTheChildBoundary() throws {
        var state = DelegatedToolFailureState()
        let run = UUID()
        state.begin(runID: run)
        state.record(
            ToolEnvelope.failure(kind: .userDenied, message: "stopped", tool: "image", retryable: false), runID: run)
        let denied = AgentDelegationDispatcher.failureForChild(
            message: "Tool call failed.", targetAgentName: "worker", terminalFailure: state.current)
        let deniedJSON = try #require(
            JSONSerialization.jsonObject(with: Data(denied.envelope(tool: "spawn_agent").utf8)) as? [String: Any])
        #expect(deniedJSON["kind"] as? String == "user_denied")
        #expect(deniedJSON["retryable"] as? Bool == false)

        var other = DelegatedToolFailureState()
        other.begin(runID: run)
        other.record(
            ToolEnvelope.failure(kind: .executionError, message: "temporary", tool: "image", retryable: true), runID: run)
        let failed = AgentDelegationDispatcher.failureForChild(
            message: "Tool call failed.", targetAgentName: "worker", terminalFailure: other.current)
        let failedJSON = try #require(
            JSONSerialization.jsonObject(with: Data(failed.envelope(tool: "spawn_agent").utf8)) as? [String: Any])
        #expect(failedJSON["kind"] as? String == "execution_error")
        #expect(failedJSON["retryable"] as? Bool == true)
    }

    // MARK: Guidance

    private func descriptor(_ name: String, folder: String? = nil) -> SpawnAgentDescriptor {
        SpawnAgentDescriptor(
            id: UUID(), name: name, description: "Does \(name) things", modelId: "cloud/child", isLocal: false,
            providerName: nil, workingFolderPath: folder)
    }

    @Test func guidanceListsTargetsAndStatesTheLimit() {
        let text = SystemPromptTemplates.spawnGuidance(agents: [descriptor("Researcher")], maxRemoteParallel: 8)
        #expect(text.hasPrefix("## Delegating work (spawn_agent)"))
        #expect(text.contains("Researcher"))
        #expect(text.contains("model: cloud/child (remote)"))
        #expect(text.contains("up to 8 agents at once"))
        #expect(text.contains("`continue` set to the `session_id`"))
        #expect(text.contains("NEEDS INPUT:"))
        #expect(text.contains("untrusted routing metadata"))
        // Background mechanics arrived with stage 6.
        #expect(text.contains("`background: true` returns immediately"))
    }

    @Test func orchestratorGuidanceIsRosterAndLimitsOnly() {
        let text = SystemPromptTemplates.spawnGuidance(
            agents: [descriptor("Researcher")], maxRemoteParallel: 4, targetsOnly: true)
        #expect(text.hasPrefix("## Your agents (spawn_agent targets)"))
        #expect(text.contains("up to 4 agents run together"))
        #expect(text.contains("Researcher"))
        #expect(!text.contains("## Delegating work"))
    }

    @Test func guidanceAdvertisesWorkingFolders() {
        let withOwn = SystemPromptTemplates.spawnGuidance(agents: [descriptor("Coder", folder: "/proj")])
        #expect(withOwn.contains("Coder work in their own folder"))
        #expect(withOwn.contains("own folder: /proj"))
        let inheriting = SystemPromptTemplates.spawnGuidance(agents: [descriptor("Coder")], launcherHasFolder: true)
        #expect(inheriting.contains("work in YOUR working folder"))
        let none = SystemPromptTemplates.spawnGuidance(agents: [descriptor("Coder")])
        #expect(none.contains("cannot write files to disk"))
    }
}
