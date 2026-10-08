//
//  IntelAgentLoopToolsTests.swift
//  OsaurusCoreTests
//
//  `W-agent-loop-tools` (docs/INTEL_MISSING_FEATURES_BACKLOG.md): the
//  todo/complete/clarify tools and get_current_time are registered and offered,
//  and — because CloudChatEngine runs tools inside its own loop — a
//  successful complete/clarify/prompt_working_folder ends the engine's run
//  after the round instead of asking the model again. The engine is exercised
//  against an in-process HTTP fixture, never a real provider.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel agent-loop tools", .serialized)
struct IntelAgentLoopToolsTests {
    @Test("todo, complete, clarify and get_current_time are registered built-ins")
    func registration() {
        let names = Set(ToolRegistry.shared.listTools().map(\.name))
        #expect(ToolRegistry.agentLoopToolNames == ["todo", "complete", "clarify", "get_current_time", "calculate"])
        #expect(ToolRegistry.agentLoopToolNames.isSubset(of: names))
        // `speak` is registered but gated on the agent's Speak Tool switch.
        #expect(names.contains(ToolRegistry.speakToolName))
        #expect(!ToolRegistry.agentLoopToolNames.contains(ToolRegistry.speakToolName))
    }

    @Test("Only a successful complete, clarify or folder pick ends the run")
    func runEndRule() {
        let ok = ToolEnvelope.success(tool: "clarify", text: "asked")
        let failed = ToolEnvelope.failure(kind: .invalidArgs, message: "no question", tool: "clarify")
        #expect(AgentLoopRunEnd.endsRun(toolName: "clarify", result: ok))
        #expect(AgentLoopRunEnd.endsRun(toolName: "complete", result: ok))
        #expect(AgentLoopRunEnd.endsRun(toolName: PromptWorkingFolderTool.toolName, result: ok))
        #expect(!AgentLoopRunEnd.endsRun(toolName: "clarify", result: failed))
        #expect(!AgentLoopRunEnd.endsRun(toolName: "todo", result: ok))
        #expect(!AgentLoopRunEnd.endsRun(toolName: "file_read", result: ok))
    }

    @MainActor
    @Test("A seeded Tools allowlist still gets the loop tools; tools off removes them")
    func offeredLikeUpstreamBaseline() async throws {
        try await ChatHistoryTestStorage.run {
            var agent = Agent(name: "loop-\(UUID().uuidString.prefix(6))", systemPrompt: "x", agentAddress: nil)
            agent.manualToolNames = ["file_read"]
            AgentManager.shared.add(agent)
            let context = await SystemPromptComposer.composeChatContext(agentId: agent.id, query: "hi")
            let names = Set(context.tools.map(\.function.name))
            #expect(ToolRegistry.agentLoopToolNames.isSubset(of: names))

            let off = await SystemPromptComposer.composeChatContext(agentId: agent.id, query: "hi", toolsDisabled: true)
            #expect(off.tools.isEmpty)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test("get_current_time returns the local time with an offset")
    func currentTime() async throws {
        let result = try await CurrentTimeTool().execute(argumentsJSON: "{}")
        #expect(!ToolEnvelope.isError(result), "\(result)")
        #expect(result.range(of: #"\d{4}-\d{2}-\d{2}T"#, options: .regularExpression) != nil)
    }

    // MARK: - Engine run ending

    private static func toolCallStream(name: String, arguments: String) -> String {
        let escaped = arguments.replacingOccurrences(of: "\"", with: "\\\"")
        return """
            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"\(name)","arguments":"\(escaped)"}}]},"finish_reason":null}]}

            data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """
    }

    private static let textStream = """
        data: {"choices":[{"index":0,"delta":{"content":"All done."},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """

    private func run(firstReply: String, toolName: String) async throws -> (hints: [String], requests: Int) {
        LoopFixtureProtocol.configure(responses: [firstReply, Self.textStream])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LoopFixtureProtocol.self]
        let provider = RemoteProvider(
            name: "Fixture", host: "loop-fixture.invalid", providerProtocol: .https,
            port: nil, basePath: "/v1", customHeaders: [:], authType: .none,
            providerType: .openaiLegacy, enabled: true, autoConnect: false, timeout: 5)
        let engine = ChatEngine(provider: provider, session: URLSession(configuration: configuration))
        var request = ChatCompletionRequest(
            model: "fixture-model",
            messages: [ChatMessage(role: "user", content: "Help me")])
        request.tools = ToolRegistry.shared.openAISpecs().filter { $0.function.name == toolName }
        var hints: [String] = []
        for try await delta in try await engine.streamChat(request: request) {
            if let done = StreamingToolHint.decodeDone(delta) { hints.append(done.name) }
        }
        return (hints, LoopFixtureProtocol.requestCount)
    }

    @Test("A successful clarify ends the engine's run after one request")
    func clarifyEndsRun() async throws {
        let (hints, requests) = try await run(
            firstReply: Self.toolCallStream(
                name: "clarify", arguments: #"{"question":"Which file?","options":["a.txt","b.txt"]}"#),
            toolName: "clarify")
        #expect(hints == ["clarify"])
        #expect(requests == 1)  // no continuation request was sent
    }

    @Test("An ordinary tool still continues the loop")
    func ordinaryToolContinues() async throws {
        let (hints, requests) = try await run(
            firstReply: Self.toolCallStream(name: "get_current_time", arguments: "{}"),
            toolName: "get_current_time")
        #expect(hints == ["get_current_time"])
        #expect(requests == 2)  // the result went back to the model
    }
}

private final class LoopFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [String] = []
    nonisolated(unsafe) private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func configure(responses: [String]) {
        lock.lock(); defer { lock.unlock() }
        queue = responses; count = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "loop-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let text = Self.queue.isEmpty ? "data: [DONE]\n\n" : Self.queue.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
