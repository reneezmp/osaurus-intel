//
//  IntelForcedToolChoiceTests.swift
//  OsaurusCoreTests
//
//  Upstream Classic `ForcedToolChoiceGate` (#3203) on Intel's chat loop: the
//  chat resolves a forced `tool_choice` for the first attempt of a recognisable
//  request, the engine sends it for round one only, and a request that matches
//  nothing is exactly what it was before (`auto`, or nil without tools).
//  No network, identity or keychain: the engine is a capturing stub.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct IntelForcedToolChoiceTests {
    private static func tool(_ name: String) -> Tool {
        Tool(type: "function", function: ToolFunction(name: name, description: nil, parameters: nil))
    }

    private static func forcedName(_ choice: ToolChoiceOption?) -> String? {
        if case .function(let fn) = choice { return fn.function.name }
        return nil
    }

    private static let redactionText =
        "Replace names with \"[REDACTED NAME]\" and emails with \"[REDACTED EMAIL]\" in note.txt"

    // MARK: Policy through the intent the chat builds

    @Test func userRedactionRequest_forcesRedactFileOnlyWhenOffered() {
        let offered = [Self.tool("file_read"), Self.tool("redact_file")]
        let intent = ChatTaskIntent(userText: Self.redactionText)
        #expect(
            Self.forcedName(ChatToolChoicePolicy.resolve(tools: offered, taskIntent: intent, attempt: 1))
                == "redact_file")
        #expect(
            Self.forcedName(ChatToolChoicePolicy.resolve(tools: offered, taskIntent: intent, attempt: 2)) == nil)
        #expect(
            Self.forcedName(
                ChatToolChoicePolicy.resolve(tools: [Self.tool("file_read")], taskIntent: intent, attempt: 1)) == nil)
    }

    @Test func hostAuthoredSend_neverForces() {
        let offered = [Self.tool("redact_file")]
        #expect(
            ChatToolChoicePolicy.resolve(tools: offered, taskIntent: .hostContinuation, attempt: 1) == .auto)
        #expect(ChatToolChoicePolicy.resolve(tools: [], taskIntent: .hostContinuation, attempt: 1) == nil)
    }

    @Test func noMatch_isAutoOrNilExactlyAsBefore() {
        let offered = [Self.tool("file_read"), Self.tool("redact_file")]
        for text in ["", "hello there", "what is the weather", "Summarise this idea in two lines"] {
            let choice = ChatToolChoicePolicy.resolve(
                tools: offered, taskIntent: ChatTaskIntent(userText: text), attempt: 1)
            #expect(choice == .auto, "\(text)")
            #expect(
                ChatToolChoicePolicy.resolve(tools: [], taskIntent: ChatTaskIntent(userText: text), attempt: 1)
                    == nil)
        }
    }

    // MARK: Gate

    @Test func gate_refusesStrayCallsThenDisarmsOnTheForcedOne() {
        let gate = ForcedToolChoiceGate()
        gate.arm(.function(.init(type: "function", function: .init(name: "redact_file"))))
        #expect(gate.violationEnvelope(calledTool: "file_read")?.contains("redact_file") == true)
        #expect(gate.violationEnvelope(calledTool: "redact_file") == nil)
        #expect(gate.violationEnvelope(calledTool: "file_read") == nil)
    }

    @Test func gate_notArmedByAutoRequiredOrNil() {
        let gate = ForcedToolChoiceGate()
        for choice in [ToolChoiceOption?.some(.auto), .some(.required), nil] {
            gate.arm(choice)
            #expect(gate.violationEnvelope(calledTool: "file_read") == nil)
        }
    }

    // MARK: ChatSession request

    @Test func session_noMatchRequestKeepsTodaysToolChoice() async throws {
        try await ChatHistoryTestStorage.run {
            let engine = CapturingToolChoiceEngine()
            let session = ChatSession()
            session.chatEngineFactory = { engine }

            session.send("hello there")
            try await Self.waitUntil { !session.isStreaming && !engine.requests.isEmpty }

            let request = try #require(engine.requests.first)
            // Before this port the chat sent `toolSpecs.isEmpty ? nil : .auto`.
            let expected: ToolChoiceOption? = (request.tools ?? []).isEmpty ? nil : .auto
            #expect(request.tool_choice == expected)
            #expect(request.toolChoiceFirstRoundOnly)
        }
    }

    @Test func session_redactionRequestWithoutTheToolOffered_isNotForced() async throws {
        try await ChatHistoryTestStorage.run {
            let engine = CapturingToolChoiceEngine()
            let session = ChatSession()
            session.chatEngineFactory = { engine }

            session.send(Self.redactionText)
            try await Self.waitUntil { !session.isStreaming && !engine.requests.isEmpty }

            let request = try #require(engine.requests.first)
            let offeredNames = (request.tools ?? []).map { $0.function.name }
            if !offeredNames.contains("redact_file") {
                #expect(Self.forcedName(request.tool_choice) == nil)
            }
        }
    }

    // MARK: Engine wire choice

    @Test func providerThatRejectsForcedChoice_getsAutoSoTheGateStaysOff() {
        let forced = ToolChoiceOption.function(.init(type: "function", function: .init(name: "redact_file")))
        let sent = ChatEngine.sanitizedToolChoice(
            forced, providerType: nil, host: "api.deepseek.com", model: "deepseek-chat", thinkingDisabled: false)
        #expect(sent == .auto)
        let gate = ForcedToolChoiceGate()
        gate.arm(sent)
        #expect(gate.violationEnvelope(calledTool: "file_read") == nil)
    }

    private static func waitUntil(_ predicate: @MainActor @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "IntelForcedToolChoiceTests", code: 1)
    }
}

/// Records every request, then streams a short reply.
private final class CapturingToolChoiceEngine: ChatEngineProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [ChatCompletionRequest] = []

    var requests: [ChatCompletionRequest] { lock.withLock { captured } }

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        lock.withLock { captured.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "IntelForcedToolChoiceTests", code: 2)
    }
}
