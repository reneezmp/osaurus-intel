//
//  DesktopResponsesModelStep.swift
//  osaurus
//
//  Intel version (docs/SUBAGENTS_INTEL.md, layer 2). Upstream's desktop
//  subagents (AppleScript, Computer Use, Browser Use) ask the model for ONE
//  action per step through upstream's Responses-style engine interface
//  (`ResponsesEngineProtocol.streamResponses`, typed `ResponsesGeneration*`
//  events and an accumulator). Intel's engine has no such interface, and its
//  request model predates it, so this file keeps upstream's API for the loops
//  (`completeResponse`, `actionCall`, `DesktopResponsesAttempt`, and the
//  request / result types under upstream's names, reduced to the members the
//  loops read) and implements it on `ChatEngine.streamChat` with
//  `stopAtToolCalls`: the engine ends the stream at the round that proposes
//  tool calls and hands them back instead of running them. Every provider
//  wire Intel supports (OpenAI-compatible, Codex Responses, Anthropic, Gemini)
//  goes through it.
//

import Foundation
import os

// MARK: - Request / result (upstream names, Intel shapes)

/// One model call the desktop loops build (upstream `ResponsesInferenceRequest`).
struct ResponsesInferenceRequest: Sendable {
    struct Context: Sendable {
        var samplingParametersAreImplicit = false
        var isAgentRequest = false
    }

    struct Generation: Sendable {
        var temperature: Float?
        var enableThinking: Bool?
        var reasoningEffort: String?
        var maxOutputTokens: Int?
    }

    var model: String
    var input: [ChatMessage]
    var tools: [Tool]?
    var toolChoice: ToolChoiceOption?
    var sessionID: String?
    var context = Context()
    var generation = Generation()

    init(model: String, input: [ChatMessage]) {
        self.model = model
        self.input = input
    }

    /// Intel's chat request: tools offered, the reasoning choice as the model
    /// options Intel's engine reads, and `stopAtToolCalls` set.
    func chatCompletionRequest() -> ChatCompletionRequest {
        var options: [String: ModelOptionValue] = [:]
        if generation.enableThinking == false { options["disableThinking"] = .bool(true) }
        if let effort = generation.reasoningEffort, !effort.isEmpty {
            options["reasoningEffort"] = .string(effort)
        }
        var request = ChatCompletionRequest(
            model: model,
            messages: input,
            temperature: generation.temperature.map(Double.init),
            max_tokens: generation.maxOutputTokens,
            stream: true,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: tools,
            tool_choice: toolChoice,
            session_id: sessionID
        )
        request.samplingParametersAreImplicit = context.samplingParametersAreImplicit
        request.modelOptions = options.isEmpty ? nil : options
        request.stopAtToolCalls = true
        return request
    }
}

/// One function call the model proposed.
struct ResponsesFunctionCall: Sendable, Equatable {
    let callID: String
    let name: String
    let arguments: String
    /// Upstream's output-item id; Intel's wires expose only the call id.
    var id: String { callID }
}

/// What one desktop model step produced (upstream `ResponsesGenerationResult`).
struct ResponsesGenerationResult: Sendable {
    struct Completion: Sendable {
        enum Status: Sendable { case completed, incomplete, cancelled }
        var status: Status = .completed
        /// Upstream's provider response id (diagnostics); Intel has none.
        var responseID: String = ""
        var stopReason: String?
        /// Upstream flags reasoning that never closed; Intel's engine closes
        /// reasoning itself, so this stays false.
        var unclosedReasoning = false
        var functionCalls: [ResponsesFunctionCall] = []
        var tokenCount: Int?
        var tokensPerSecond: Double?
    }

    var text: String
    var completion: Completion
    var inputTokenCount: Int?
    /// Upstream diagnostics fields. Intel's engine keeps reasoning and raw
    /// provider items to itself, so these stay empty.
    var reasoning: String = ""
    var providerOutputItems: [String] = []

    /// The assistant turn to append before the tool result (upstream
    /// `completedAssistantInput`): the visible text plus the proposed calls.
    func completedAssistantInput() throws -> ChatMessage {
        let calls = completion.functionCalls.map {
            ToolCall(
                id: $0.callID, type: "function",
                function: ToolCallFunction(name: $0.name, arguments: $0.arguments))
        }
        return ChatMessage(role: "assistant", content: text, tool_calls: calls.isEmpty ? nil : calls)
    }
}

/// The engine surface the desktop loops drive (upstream protocol name).
protocol ResponsesEngineProtocol: Sendable {
    func completeDesktopStep(request: ResponsesInferenceRequest, attempt: DesktopResponsesAttempt?) async throws
        -> ResponsesGenerationResult
}

extension ChatEngine: ResponsesEngineProtocol {
    func completeDesktopStep(
        request: ResponsesInferenceRequest,
        attempt: DesktopResponsesAttempt?
    ) async throws -> ResponsesGenerationResult {
        let stream = try await streamChat(request: request.chatCompletionRequest())
        var text = ""
        var calls: [ResponsesFunctionCall] = []
        for try await delta in stream {
            try Task.checkCancellation()
            if let proposed = StreamingToolHint.decodeProposed(delta) {
                attempt?.markOutputObserved()
                calls = proposed.map {
                    ResponsesFunctionCall(
                        callID: $0.callId.isEmpty ? "call_\(UUID().uuidString.prefix(20))" : $0.callId,
                        name: $0.name,
                        arguments: $0.arguments)
                }
                continue
            }
            if StreamingToolHint.isSentinel(delta) { continue }
            if !delta.isEmpty { attempt?.markOutputObserved() }
            text += delta
        }
        try Task.checkCancellation()
        return ResponsesGenerationResult(
            text: text,
            completion: .init(functionCalls: calls),
            inputTokenCount: nil
        )
    }
}

/// Upstream: the one action call a desktop step executes (public upstream:
/// the AppleScript loop's public seams use it).
public struct ModelActionCall: Sendable, Equatable {
    public let id: String
    public let arguments: String

    public init(id: String, arguments: String) {
        self.id = id
        self.arguments = arguments
    }
}

// MARK: - Model step (upstream API)

/// One desktop step owns one observed action. A model batch cannot be reduced
/// to its first call: later actions may require a new captured view or policy
/// decision before they are safe to propose, so unsupported batches fail before
/// any desktop side effect. (Upstream.)
enum DesktopResponsesModelStep {
    enum Failure: Error, LocalizedError, Sendable {
        case upstreamCancelled
        case incomplete(String?)
        case unsupportedCalls(expected: String, names: [String])
        case missingCallID
        case missingVisibleAnswer
        case missingRequiredCall(String)

        var errorDescription: String? {
            switch self {
            case .upstreamCancelled:
                return "The upstream model or provider cancelled the desktop model step."
            case .incomplete(let reason):
                return "The desktop model response was incomplete (\(reason ?? "unknown reason"))."
            case .unsupportedCalls(let expected, let names):
                return "This desktop step requires one '\(expected)' call; received \(names.count) call(s): \(names.joined(separator: ", ")). No action was executed."
            case .missingCallID:
                return "The desktop model call has no call ID. No action was executed."
            case .missingVisibleAnswer:
                return "The desktop model ended without an action or visible answer."
            case .missingRequiredCall(let name):
                return "The model did not produce the required '\(name)' call."
            }
        }
    }

    /// Keep the complete response available to diagnostics even when its
    /// action shape cannot be executed. (Upstream.)
    struct InvalidResponse: Error, LocalizedError, Sendable {
        let reason: Failure
        let response: ResponsesGenerationResult
        var errorDescription: String? { reason.errorDescription }
    }

    static func completeResponse(
        engine: any ResponsesEngineProtocol,
        request: ResponsesInferenceRequest,
        attempt: DesktopResponsesAttempt?
    ) async throws -> ResponsesGenerationResult {
        try await engine.completeDesktopStep(request: request, attempt: attempt)
    }

    /// Upstream's call validation, unchanged.
    static func actionCall(
        from result: ResponsesGenerationResult,
        expectedTool: String,
        required: Bool
    ) throws -> ModelActionCall? {
        switch result.completion.status {
        case .cancelled: throw InvalidResponse(reason: .upstreamCancelled, response: result)
        case .incomplete: throw InvalidResponse(reason: .incomplete(result.completion.stopReason), response: result)
        case .completed: break
        }
        guard !result.completion.unclosedReasoning, result.completion.stopReason != "length" else {
            throw InvalidResponse(reason: .incomplete(result.completion.stopReason), response: result)
        }
        let calls = result.completion.functionCalls
        if calls.isEmpty {
            if required {
                throw NSError(domain: "OsaurusToolChoice", code: 422, userInfo: [
                    NSLocalizedDescriptionKey: "The model did not produce the required '\(expectedTool)' call.",
                    NSUnderlyingErrorKey: InvalidResponse(reason: .missingRequiredCall(expectedTool), response: result),
                ])
            }
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw InvalidResponse(reason: .missingVisibleAnswer, response: result)
            }
            return nil
        }
        guard calls.count == 1, calls[0].name == expectedTool else {
            throw InvalidResponse(
                reason: .unsupportedCalls(expected: expectedTool, names: calls.map(\.name)), response: result)
        }
        guard !calls[0].callID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InvalidResponse(reason: .missingCallID, response: result)
        }
        return ModelActionCall(id: calls[0].callID, arguments: calls[0].arguments)
    }
}

/// Retry scope is one model step, before any desktop action. Once output
/// arrives, neither a transport error nor a timeout can replay that attempt.
/// (Upstream; Intel observes output as the first visible text or proposal.)
final class DesktopResponsesAttempt: Sendable {
    private let outputObserved = OSAllocatedUnfairLock(initialState: false)

    func markOutputObserved() {
        outputObserved.withLock { $0 = true }
    }

    func permitsRetry(_ error: Error, isTimeout: Bool = false) -> Bool {
        guard !outputObserved.withLock({ $0 }), !(error is CancellationError) else { return false }
        if isTimeout { return true }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
        ].contains(nsError.code)
    }
}
