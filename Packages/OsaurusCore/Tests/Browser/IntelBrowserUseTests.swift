//
//  IntelBrowserUseTests.swift
//  osaurus
//
//  Intel's side of `W-browser-use` (docs/SUBAGENTS_INTEL.md): the subagent
//  runner on the desktop model step (scripted engine, no network), the
//  Ventura profile choice, and the tool's registration and switch gate.
//

import Foundation
import Testing

@testable import OsaurusCore

/// Replays scripted model turns and records what each request carried.
private final class ScriptedEngine: ResponsesEngineProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [ResponsesGenerationResult]
    private(set) var requests: [ResponsesInferenceRequest] = []

    init(_ turns: [ResponsesGenerationResult]) { self.turns = turns }

    func completeDesktopStep(
        request: ResponsesInferenceRequest, attempt: DesktopResponsesAttempt?
    ) async throws -> ResponsesGenerationResult {
        next(request)
    }

    private func next(_ request: ResponsesInferenceRequest) -> ResponsesGenerationResult {
        lock.withLock {
            requests.append(request)
            return turns.isEmpty ? ResponsesGenerationResult(text: "", completion: .init()) : turns.removeFirst()
        }
    }

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    var lastMessages: [ChatMessage] { lock.lock(); defer { lock.unlock() }; return requests.last?.input ?? [] }
}

private func call(_ name: String, _ args: String = "{}", id: String = "c1") -> ResponsesGenerationResult {
    ResponsesGenerationResult(
        text: "", completion: .init(functionCalls: [ResponsesFunctionCall(callID: id, name: name, arguments: args)]))
}

private func text(_ value: String) -> ResponsesGenerationResult {
    ResponsesGenerationResult(text: value, completion: .init())
}

private let navigateSpec = Tool(
    type: "function",
    function: ToolFunction(name: "browser_navigate", description: "Open a URL.", parameters: nil))

@Suite(.serialized)
struct IntelBrowserUseTests {
    private func run(
        _ engine: ScriptedEngine,
        toolset: AgentSubagentToolset?,
        maxIterations: Int = 6,
        deadline: Date = Date().addingTimeInterval(60),
        interrupted: @escaping @Sendable () -> Bool = { false }
    ) async throws -> AgentSubagentRunResult {
        try await AgentSubagentRunner.run(
            modelName: "fixture-model",
            seedMessages: [
                ChatMessage(role: "system", content: "Browse."),
                ChatMessage(role: "user", content: "Goal: find the title"),
            ],
            maxTokens: nil,
            maxIterations: maxIterations,
            deadline: deadline,
            sessionId: "s",
            isInterrupted: interrupted,
            toolset: toolset,
            engine: engine)
    }

    @Test func toolCallsRunThroughTheToolsetUntilTheModelAnswers() async throws {
        let engine = ScriptedEngine([call("browser_navigate", #"{"url":"https://example.com"}"#), text("Example Domain")])
        let seen = Box()
        let toolset = AgentSubagentToolset(specs: [navigateSpec]) { invocation in
            seen.append("\(invocation.toolName) \(invocation.jsonArguments)")
            return ToolEnvelope.success(tool: invocation.toolName, text: "loaded")
        }
        let result = try await run(engine, toolset: toolset)
        #expect(result.exit == .finalResponse)
        #expect(result.digest == "Example Domain")
        #expect(result.iterations == 2)
        #expect(seen.values == [#"browser_navigate {"url":"https://example.com"}"#])
        // The second request carried the assistant call and the tool result.
        let messages = engine.lastMessages
        #expect(messages.contains { $0.role == "assistant" && $0.tool_calls?.first?.id == "c1" })
        #expect(messages.contains { $0.role == "tool" && $0.tool_call_id == "c1" && ($0.content ?? "").contains("loaded") })
        #expect(engine.requests.first?.tools?.map(\.function.name) == ["browser_navigate"])
    }

    @Test func anUnofferedToolIsRefusedNotRun() async throws {
        let engine = ScriptedEngine([call("shell_run"), text("done")])
        let toolset = AgentSubagentToolset(specs: [navigateSpec]) { _ in
            Issue.record("an unoffered tool must not run")
            return ""
        }
        let result = try await run(engine, toolset: toolset)
        #expect(result.exit == .finalResponse)
        #expect(engine.lastMessages.contains { $0.role == "tool" && ($0.content ?? "").contains("not available") })
    }

    @Test func emptyTurnsAreNudgedThenGiveUp() async throws {
        let engine = ScriptedEngine([text(""), text(""), text("")])
        let result = try await run(engine, toolset: nil)
        #expect(result.exit == .emptyResponseExhausted)
        #expect(engine.lastMessages.last?.content == AgentSubagentRunner.emptyTurnNotice)
    }

    @Test func aRepeatedRoundStopsTheRun() async throws {
        let same = call("browser_navigate", #"{"url":"https://a.example"}"#)
        let engine = ScriptedEngine([same, same, same, same])
        let toolset = AgentSubagentToolset(specs: [navigateSpec]) { _ in "ok" }
        let result = try await run(engine, toolset: toolset)
        #expect(result.exit == .repetitionLoopExhausted)
    }

    @Test func iterationCapAndCancellationCauses() async throws {
        let toolset = AgentSubagentToolset(specs: [navigateSpec]) { _ in "ok" }
        let capped = try await run(
            ScriptedEngine((0..<5).map { call("browser_navigate", "{\"n\":\($0)}", id: "c\($0)") }),
            toolset: toolset, maxIterations: 3)
        #expect(capped.exit == .iterationCapReached)

        let stopped = try await run(ScriptedEngine([text("x")]), toolset: toolset, interrupted: { true })
        #expect(stopped.exit == .cancelled)
        #expect(stopped.cancelCause == .userInterrupt)

        let late = try await run(ScriptedEngine([text("x")]), toolset: toolset, deadline: Date().addingTimeInterval(-1))
        #expect(late.cancelCause == .deadline)
    }

    @Test func profileIsolationFollowsTheOSVersion() {
        if #available(macOS 14, *) {
            #expect(BrowserProfileStore.isolatesAgents)
        } else {
            #expect(!BrowserProfileStore.isolatesAgents)
        }
    }

    @Test func toolIsRegisteredAndGatedByTheAgentSwitch() async throws {
        #expect(Set(ToolRegistry.shared.listTools().map(\.name)).contains("browser_use"))
        let result = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await ToolRegistry.shared.execute(name: "browser_use", argumentsJSON: #"{"goal":"open example.com"}"#)
        }
        #expect(!ToolEnvelope.isSuccess(result))
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ value: String) { lock.lock(); items.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
