//
//  IntelDesktopModelStepTests.swift
//  osaurus
//
//  Layer 2 of docs/SUBAGENTS_INTEL.md: a desktop subagent's model step on
//  Intel's engine (`stopAtToolCalls`). A proposed call comes back without
//  running and without a second request; plain text comes back as text; and
//  upstream's call validation still applies. Fixture transport only.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelDesktopModelStepTests {
    private static let runScript = Tool(
        type: "function",
        function: ToolFunction(
            name: "run_applescript",
            description: "Run one AppleScript.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object(["script": .object(["type": .string("string")])]),
                "required": .array([.string("script")]),
            ])))

    private static func toolCallStream(name: String, arguments: String) -> String {
        let escaped = arguments.replacingOccurrences(of: "\"", with: "\\\"")
        return """
            data: {"choices":[{"index":0,"delta":{"content":"Checking. "},"finish_reason":null}]}

            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_7","type":"function","function":{"name":"\(name)","arguments":"\(escaped)"}}]},"finish_reason":null}]}

            data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """
    }

    private static let textStream = """
        data: {"choices":[{"index":0,"delta":{"content":"The volume is 40."},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """

    private func step(reply: String) async throws -> (ResponsesGenerationResult, Int) {
        StepFixtureProtocol.configure(responses: [reply, Self.textStream])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StepFixtureProtocol.self]
        let provider = RemoteProvider(
            name: "Fixture", host: "step-fixture.invalid", providerProtocol: .https,
            port: nil, basePath: "/v1", customHeaders: [:], authType: .none,
            providerType: .openaiLegacy, enabled: true, autoConnect: false, timeout: 5)
        let engine = ChatEngine(provider: provider, session: URLSession(configuration: configuration))
        var request = ResponsesInferenceRequest(
            model: "fixture-model",
            input: [
                ChatMessage(role: "system", content: "Write AppleScript."),
                ChatMessage(role: "user", content: "Task: get the volume"),
            ])
        request.tools = [Self.runScript]
        request.toolChoice = .auto
        let attempt = DesktopResponsesAttempt()
        let result = try await DesktopResponsesModelStep.completeResponse(
            engine: engine, request: request, attempt: attempt)
        return (result, StepFixtureProtocol.requestCount)
    }

    @Test func proposedCallComesBackWithoutRunning() async throws {
        let (result, requests) = try await step(
            reply: Self.toolCallStream(
                name: "run_applescript", arguments: #"{"script":"output volume of (get volume settings)"}"#))
        #expect(requests == 1)  // nothing ran, nothing was sent back
        #expect(result.text == "Checking. ")
        let call = try #require(
            try DesktopResponsesModelStep.actionCall(from: result, expectedTool: "run_applescript", required: false))
        #expect(call.id == "call_7")
        #expect(call.arguments.contains("get volume settings"))
        let assistant = try result.completedAssistantInput()
        #expect(assistant.role == "assistant")
        #expect(assistant.tool_calls?.first?.function.name == "run_applescript")
    }

    @Test func plainTextIsAFinalAnswer() async throws {
        let (result, requests) = try await step(reply: Self.textStream)
        #expect(requests == 1)
        #expect(result.completion.functionCalls.isEmpty)
        #expect(
            try DesktopResponsesModelStep.actionCall(from: result, expectedTool: "run_applescript", required: false)
                == nil)
        #expect(throws: (any Error).self) {
            try DesktopResponsesModelStep.actionCall(from: result, expectedTool: "run_applescript", required: true)
        }
    }

    @Test func aDifferentToolIsRejectedBeforeAnyAction() throws {
        let result = ResponsesGenerationResult(
            text: "",
            completion: .init(functionCalls: [
                ResponsesFunctionCall(callID: "c1", name: "shell_run", arguments: "{}")
            ]))
        #expect(throws: DesktopResponsesModelStep.InvalidResponse.self) {
            try DesktopResponsesModelStep.actionCall(from: result, expectedTool: "run_applescript", required: false)
        }
    }

    @Test func outputBlocksRetry() {
        let attempt = DesktopResponsesAttempt()
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(attempt.permitsRetry(timeout))
        attempt.markOutputObserved()
        #expect(!attempt.permitsRetry(timeout))
    }

    @Test func proposedSentinelRoundTripsAndIsNeverText() {
        let encoded = StreamingToolHint.encodeProposed([.init(callId: "a", name: "run_applescript", arguments: "{}")])
        #expect(StreamingToolHint.isSentinel(encoded))
        #expect(StreamingToolHint.decodeProposed(encoded)?.first?.name == "run_applescript")
        #expect(StreamingToolHint.decodeProposed("plain text") == nil)
    }
}

private final class StepFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [String] = []
    nonisolated(unsafe) private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func configure(responses: [String]) {
        lock.lock(); defer { lock.unlock() }
        queue = responses; count = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "step-fixture.invalid" }
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
