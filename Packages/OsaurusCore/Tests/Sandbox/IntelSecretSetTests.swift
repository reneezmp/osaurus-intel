//
//  IntelSecretSetTests.swift
//  osaurusTests
//
//  W-seatbelt-sandbox: `sandbox_secret_set` on Intel. The tool returns the
//  prompt marker, `CloudChatEngine` hands it to `IntelSecretPromptIntercept`
//  (the chat's `PromptQueue` shows the secure card), and a secret never lands
//  in a tool argument, the chat stream, the model's next request or Insights.
//  Secrets live only in the in-memory keychain seam; nothing touches the real
//  keychain, `~/.osaurus` or the network.
//

import Foundation
import Testing

@testable import OsaurusCore

/// Plays the user at the secure card of a `PromptQueue`.
enum SecretPromptDriver {
    /// Waits (briefly) until a secret card is mounted and returns its state.
    @MainActor
    static func waitForCard(_ queue: PromptQueue) async -> SecretPromptState? {
        for _ in 0..<400 {
            if case .secret(let state)? = queue.current { return state }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    @MainActor
    static func submit(_ value: String, on queue: PromptQueue) async {
        guard let state = await waitForCard(queue) else { return }
        state.submit(value)
        queue.advance()
    }

    @MainActor
    static func cancel(on queue: PromptQueue) async {
        guard let state = await waitForCard(queue) else { return }
        state.cancel()
        queue.advance()
    }
}

@Suite(.serialized)
struct IntelSecretSetTests {
    private static let agentId = UUID()
    private static let secretValue = "tok-live-9f3A7c-NEVER-LEAK"

    private func marker(key: String = "NOTION_API_KEY") async throws -> String {
        let context = SandboxToolContext(
            agentId: Self.agentId, agentName: "a", home: "/workspace/agents/a",
            config: AutonomousExecConfig(enabled: true))
        return try await SandboxToolContext.$testingContext.withValue(context) {
            try await SandboxSecretSetTool().execute(
                argumentsJSON: #"{"key":"\#(key)","description":"Notion token","instructions":"Paste it from Settings."}"#)
        }
    }

    // MARK: The marker opens the prompt

    @Test func theMarkerOpensTheSecurePromptAndAStoredValueIsReportedByNameOnly() async throws {
        try await AgentSecretsKeychain._withInMemoryStoreForTesting {
            let queue = await MainActor.run { PromptQueue() }
            let result = try await IntelSecretPromptIntercept.$testingQueue.withValue(queue) {
                let marker = try await self.marker()
                #expect(SecretPromptParser.parse(marker)?.key == "NOTION_API_KEY")
                async let resolved = IntelSecretPromptIntercept.resolving(
                    toolName: "sandbox_secret_set", result: marker)
                // The card is up with the tool's own wording, and nothing is stored yet.
                let state = await SecretPromptDriver.waitForCard(queue)
                let shown = await MainActor.run { (state?.key, state?.description) }
                #expect(shown.0 == "NOTION_API_KEY")
                #expect(shown.1 == "Notion token")
                #expect(AgentSecretsKeychain.getSecret(id: "NOTION_API_KEY", agentId: Self.agentId) == nil)
                await SecretPromptDriver.submit(Self.secretValue, on: queue)
                return await resolved
            }
            #expect(result == SecretToolResult.stored(key: "NOTION_API_KEY"))
            #expect(!result.contains(Self.secretValue))
            #expect(AgentSecretsKeychain.getSecret(id: "NOTION_API_KEY", agentId: Self.agentId) == Self.secretValue)
            #expect(await MainActor.run { queue.current == nil })
        }
    }

    // MARK: Cancel stores nothing

    @Test func cancelStoresNothingAndTheModelGetsTheCancelledResult() async throws {
        try await AgentSecretsKeychain._withInMemoryStoreForTesting {
            let queue = await MainActor.run { PromptQueue() }
            let result = try await IntelSecretPromptIntercept.$testingQueue.withValue(queue) {
                let marker = try await self.marker()
                async let resolved = IntelSecretPromptIntercept.resolving(
                    toolName: "sandbox_secret_set", result: marker)
                await SecretPromptDriver.cancel(on: queue)
                return await resolved
            }
            #expect(result == SecretToolResult.cancelled(key: "NOTION_API_KEY"))
            #expect(ToolEnvelope.isError(result))
            #expect(ToolEnvelope.failureMessage(result).contains("User cancelled the secret prompt"))
            #expect(AgentSecretsKeychain.getSecret(id: "NOTION_API_KEY", agentId: Self.agentId) == nil)
        }
    }

    @Test func stoppingTheRunClosesTheCardAndStoresNothing() async throws {
        try await AgentSecretsKeychain._withInMemoryStoreForTesting {
            let queue = await MainActor.run { PromptQueue() }
            let marker = try await self.marker()
            let task = Task {
                await IntelSecretPromptIntercept.$testingQueue.withValue(queue) {
                    await IntelSecretPromptIntercept.resolving(toolName: "sandbox_secret_set", result: marker)
                }
            }
            #expect(await SecretPromptDriver.waitForCard(queue) != nil)
            task.cancel()
            let result = await task.value
            #expect(result == SecretToolResult.cancelled(key: "NOTION_API_KEY"))
            for _ in 0..<200 where await MainActor.run(body: { queue.current != nil }) {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(await MainActor.run { queue.current == nil })
            #expect(AgentSecretsKeychain.getSecret(id: "NOTION_API_KEY", agentId: Self.agentId) == nil)
        }
    }

    @Test func otherToolResultsPassThroughUntouched() async {
        let plain = ToolEnvelope.success(tool: "sandbox_exec", result: ["stdout": "hi"])
        #expect(await IntelSecretPromptIntercept.resolving(toolName: "sandbox_exec", result: plain) == plain)
        // The marker for any other tool name is not a prompt either.
        let fake = SecretToolResult.encode([
            "action": SecretPromptAction.actionKey, "key": "K", "description": "d", "instructions": "i",
            "agent_id": UUID().uuidString,
        ])
        #expect(await IntelSecretPromptIntercept.resolving(toolName: "file_read", result: fake) == fake)
    }

    @Test func withNoChatToHostTheCardNothingIsStoredAndTheModelIsTold() async throws {
        try await AgentSecretsKeychain._withInMemoryStoreForTesting {
            let marker = try await self.marker()
            let result = await IntelSecretPromptIntercept.resolving(toolName: "sandbox_secret_set", result: marker)
            #expect(ToolEnvelope.isError(result))
            #expect(AgentSecretsKeychain.getSecret(id: "NOTION_API_KEY", agentId: Self.agentId) == nil)
        }
    }

    // MARK: Remote prompts (paired phone)

    @Test func aRunFromThePairedPhoneAsksThePhoneAndStoresWhatItSends() async throws {
        try await AgentSecretsKeychain._withInMemoryStoreForTesting {
            let key = "PHONE_KEY_\(UUID().uuidString.prefix(6))"
            let context = SandboxToolContext(
                agentId: Self.agentId, agentName: "a", home: "/workspace/agents/a",
                config: AutonomousExecConfig(enabled: true))
            let args = #"{"key":"\#(key)","description":"d","instructions":"i"}"#
            let task = Task {
                try await SandboxToolContext.$testingContext.withValue(context) {
                    try await ChatExecutionContext.$hasRemoteReviewer.withValue(true) {
                        try await SandboxSecretSetTool().execute(argumentsJSON: args)
                    }
                }
            }
            var promptId: UUID?
            for _ in 0..<400 where promptId == nil {
                promptId = await MainActor.run { RemoteSecretPromptQueue.shared.pending.first { $0.key == key }?.id }
                if promptId == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            }
            let id = try #require(promptId)
            // The phone's list shows what is asked for, never a value.
            let listed = await MainActor.run { String(decoding: RemoteSecretPromptQueue.shared.listJSON(), as: UTF8.self) }
            #expect(listed.contains(key))
            _ = await MainActor.run { RemoteSecretPromptQueue.shared.resolve(id: id, value: Self.secretValue) }
            let result = try await task.value
            #expect(result == SecretToolResult.stored(key: key))
            #expect(!result.contains(Self.secretValue))
            #expect(AgentSecretsKeychain.getSecret(id: key, agentId: Self.agentId) == Self.secretValue)
        }
    }

    // MARK: Registration and opt-in

    @Test func theToolIsRegisteredButOnlyAnOptedInAgentSeesIt() async throws {
        await MainActor.run { BuiltinSandboxTools.register() }
        defer { Task { @MainActor in ToolRegistry.shared.unregisterAllBuiltinSandboxTools() } }
        let registry = ToolRegistry.shared
        #expect(registry.builtInSandboxToolNames.contains("sandbox_secret_set"))
        for agent in [nil, Agent.defaultId, UUID()] {
            let names = Set(registry.openAISpecs(for: agent).map(\.function.name))
            #expect(!names.contains("sandbox_secret_set"), "leaked to \(String(describing: agent))")
        }
        #expect(registry.openAISpecs(named: ["sandbox_secret_set"]).isEmpty)
        let denied = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await registry.execute(
                name: "sandbox_secret_set",
                argumentsJSON: #"{"key":"K","description":"d","instructions":"i"}"#)
        }
        #expect(ToolEnvelope.isError(denied), "\(denied)")
        #expect(SecretPromptParser.parse(denied) == nil)
        #expect(ToolRegistry.externallyDeniedToolNames.contains("sandbox_secret_set"))
    }

    @Test func thePromptTellsTheModelToUseTheDialogAndNeverAValue() {
        let text = IntelSandboxPrompt.secretHandling
        #expect(text.contains("`sandbox_secret_set`"))
        #expect(text.contains("there is no `value` argument"))
        #expect(!text.contains("settings, then wait"))
    }

    // MARK: Recording-side scrubbing

    @Test func aValueTheModelSendsIsRedactedEverywhereInTheRecordedCall() throws {
        let sent = #"{"key":"K","description":"token \#(Self.secretValue)","instructions":"i","value":"\#(Self.secretValue)"}"#
        let recorded = SecretArgumentScrubber.recordedArguments(toolName: "sandbox_secret_set", argumentsJSON: sent)
        #expect(!recorded.contains(Self.secretValue))
        #expect(recorded.contains("[REDACTED]"))
        // Other tools are returned byte for byte.
        #expect(SecretArgumentScrubber.recordedArguments(toolName: "file_read", argumentsJSON: sent) == sent)
        // A clean prompt call is unchanged.
        let clean = #"{"description":"d","instructions":"i","key":"K"}"#
        #expect(SecretArgumentScrubber.recordedArguments(toolName: "sandbox_secret_set", argumentsJSON: clean) == clean)
    }

    @Test func malformedOrOddPayloadsFailClosedInsteadOfEchoingTheInput() {
        for bad in [
            "not json \(Self.secretValue)",
            #"{"key":"K","description":"d","instructions":"i","value":42}"#,
            #"{"key":"K","description":"d","instructions":"i","extra":"\#(Self.secretValue)"}"#,
            #"{"key":"K","description":"d"}"#,
        ] {
            let recorded = SecretArgumentScrubber.recordedArguments(toolName: "sandbox_secret_set", argumentsJSON: bad)
            #expect(recorded == SecretArgumentScrubber.failClosedArgumentsJSON, "\(bad)")
            #expect(!recorded.contains(Self.secretValue))
        }
    }

    @Test func aResponsesCompletionIsScrubbedInTheCallAndTheReplayedItem() throws {
        let sent = #"{"key":"K","description":"d","instructions":"i","value":"\#(Self.secretValue)"}"#
        let completion = IntelCodexResponsesCompletion(
            outputItems: [
                ["type": "reasoning", "id": "r1", "encrypted_content": "enc"],
                ["type": "function_call", "call_id": "c1", "name": "sandbox_secret_set", "arguments": sent],
                ["type": "function_call", "call_id": "c2", "name": "file_read", "arguments": #"{"path":"a"}"#],
            ],
            toolCalls: [
                IntelCodexResponsesToolCall(callID: "c1", name: "sandbox_secret_set", arguments: sent),
                IntelCodexResponsesToolCall(callID: "c2", name: "file_read", arguments: #"{"path":"a"}"#),
            ])
        let scrubbed = completion.scrubbingSecretSetArguments()
        let replay = try scrubbed.replayInputItems(toolResults: [
            .init(callID: "c1", output: "ok"), .init(callID: "c2", output: "ok"),
        ])
        let all = String(decoding: try JSONSerialization.data(withJSONObject: replay), as: UTF8.self)
        #expect(!all.contains(Self.secretValue))
        #expect(!scrubbed.toolCalls.contains { $0.arguments.contains(Self.secretValue) })
        #expect(all.contains("enc"))
        #expect(scrubbed.toolCalls[1].arguments == #"{"path":"a"}"#)
    }

    @Test func aResponsesStreamNeverEmitsTheSecretArgumentsToTheCard() throws {
        var decoder = IntelCodexResponsesSSEDecoder(allowedToolNames: ["sandbox_secret_set"])
        let args = #"{"key":"K","description":"d","instructions":"i","value":"\#(Self.secretValue)"}"#
        let escaped = args.replacingOccurrences(of: "\"", with: "\\\"")
        let events = [
            #"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"c1","name":"sandbox_secret_set","arguments":""}}"#,
            #"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"\#(escaped)"}"#,
            #"{"type":"response.function_call_arguments.done","output_index":0,"arguments":"\#(escaped)"}"#,
        ]
        let sse = events.map { "data: \($0)\n\n" }.joined()
        let emissions = try decoder.append(Data(sse.utf8))
        #expect(!emissions.contains { $0.contains(Self.secretValue) })
    }
}

// MARK: - Engine: the secret never reaches the chat stream or the next request

@Suite("Secret set engine", .serialized)
struct IntelSecretSetEngineTests {
    private static let secretValue = "tok-live-9f3A7c-NEVER-LEAK"

    private static func frame(_ delta: String, finish: String? = nil) -> String {
        let reason = finish.map { "\"\($0)\"" } ?? "null"
        return "data: {\"choices\":[{\"index\":0,\"delta\":{\(delta)},\"finish_reason\":\(reason)}]}\n\n"
    }

    private static let offered = Tool(
        function: ToolFunction(
            name: "sandbox_secret_set", description: "Ask the user for a secret",
            parameters: SandboxSecretSetTool().parameters))

    @Test("A secret value the model sends never reaches the chat stream, the card or the next request")
    func theValueDoesNotLeak() async throws {
        let arguments = #"{"key":"K","description":"d","instructions":"i","value":"\#(Self.secretValue)"}"#
        let chunk: [String: Any] = [
            "choices": [
                [
                    "index": 0,
                    "delta": [
                        "tool_calls": [
                            [
                                "index": 0, "id": "call_1", "type": "function",
                                "function": ["name": "sandbox_secret_set", "arguments": arguments],
                            ]
                        ]
                    ],
                    "finish_reason": "tool_calls",
                ]
            ]
        ]
        let call =
            "data: " + String(decoding: try JSONSerialization.data(withJSONObject: chunk), as: UTF8.self)
            + "\n\n" + "data: [DONE]\n\n"
        let answer = Self.frame(#""content":"Done.""#) + Self.frame("", finish: "stop") + "data: [DONE]\n\n"
        SecretFixtureProtocol.configure(responses: [call, answer])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SecretFixtureProtocol.self]
        let provider = RemoteProvider(
            name: "Fixture", host: SecretFixtureProtocol.host, providerProtocol: .https,
            port: nil, basePath: "/v1", customHeaders: [:], authType: .none,
            providerType: .openaiLegacy, enabled: true, autoConnect: false, timeout: 5)
        let engine = ChatEngine(provider: provider, session: URLSession(configuration: configuration))
        let request = ChatCompletionRequest(
            model: "fixture-model", messages: [ChatMessage(role: "user", content: "Set up Notion")],
            tools: [Self.offered])
        let stream = try await ChatExecutionContext.$interactiveChatRun.withValue(false) {
            try await engine.streamChat(request: request)
        }
        var deltas: [String] = []
        for try await delta in stream { deltas.append(delta) }

        #expect(!deltas.contains { $0.contains(Self.secretValue) })
        let done = deltas.compactMap(StreamingToolHint.decodeDone).first { $0.name == "sandbox_secret_set" }
        let recorded = try #require(done)
        #expect(!recorded.arguments.contains(Self.secretValue))
        #expect(recorded.arguments.contains("[REDACTED]"))
        let bodies = SecretFixtureProtocol.bodies
        #expect(bodies.count == 2)
        #expect(bodies.dropFirst().allSatisfy { !$0.contains(Self.secretValue) })
        #expect(bodies.dropFirst().first?.contains("[REDACTED]") == true)
    }
}

private final class SecretFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let host = "secret-fixture.invalid"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [String] = []
    nonisolated(unsafe) private static var captured: [String] = []
    static var bodies: [String] { lock.lock(); defer { lock.unlock() }; return captured }
    static func configure(responses: [String]) {
        lock.lock(); defer { lock.unlock() }
        queue = responses; captured = []
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.captured.append(String(decoding: body, as: UTF8.self))
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
