//
//  AgentSubagentRunner.swift
//  osaurus
//
//  Intel version (docs/SUBAGENTS_INTEL.md, Browser Use). Upstream's runner
//  is the bounded text loop behind the tool-using subagent kinds (Browser
//  Use, spawn): a context-isolated `AgentToolLoop` on a chosen model with an
//  optional private toolset, returning a compact digest. Upstream streams it
//  through its typed Responses engine. Intel has neither that loop nor that
//  interface, so this keeps upstream's types and `run` signature and drives
//  the loop on the desktop model step (`ChatEngine.completeDesktopStep`,
//  `stopAtToolCalls`): one model turn, the proposed calls run through the
//  private toolset, their results fed back, until the model answers in text.
//  Same exits, cancellation causes and digest as upstream; usage is not
//  reported by Intel's engine, so token counts are estimates.
//

import Foundation

/// Why a subagent run stopped before finishing (upstream).
enum SubagentCancelCause: String, Sendable {
    case userInterrupt = "user_interrupt"
    case deadline
    case parentTask = "parent_task"
    case upstream
}

/// Aggregated model usage across one run (upstream; Intel estimates).
struct AgentSubagentUsage: Sendable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var tokensPerSecond: Double?
}

/// Upstream's loop driver namespace; Intel keeps only the exit reasons the
/// kinds map to user-facing copy.
enum AgentToolLoop {
    enum Exit: Equatable, Sendable {
        case finalResponse
        case endedBySurface
        case cancelled
        case iterationCapReached
        case toolRejected
        case overBudget
        case emptyResponseExhausted
        case lengthExhausted
        case truncatedToolCallExhausted
        case repetitionLoopExhausted
        case incompleteReasoningExhausted
    }
}

struct AgentSubagentRunResult: Sendable {
    var digest: String?
    var exit: AgentToolLoop.Exit
    var iterations: Int
    var cancelCause: SubagentCancelCause?
    var usage: AgentSubagentUsage = AgentSubagentUsage()
}

/// Optional child toolset (upstream, unchanged). `nil` makes the run
/// text-only; every tool call is refused.
struct AgentSubagentToolset: Sendable {
    var specs: [Tool]
    var beginExecution: @Sendable (_ invocation: ServiceToolInvocation) -> OwnedSubagentOperation<String>

    init(
        specs: [Tool],
        beginExecution: @escaping @Sendable (ServiceToolInvocation) -> OwnedSubagentOperation<String>
    ) {
        self.specs = specs
        self.beginExecution = beginExecution
    }

    init(specs: [Tool], execute: @escaping @Sendable (ServiceToolInvocation) async -> String) {
        self.init(specs: specs, beginExecution: { invocation in OwnedSubagentOperation { await execute(invocation) } })
    }

    func execute(_ invocation: ServiceToolInvocation) async -> String {
        let operation = beginExecution(invocation)
        do {
            return try await operation.value()
        } catch {
            return ToolEnvelope.fromError(error, tool: invocation.toolName)
        }
    }
}

enum AgentSubagentRunner {
    typealias Progress = @Sendable (_ completionTokens: Int, _ tokensPerSecond: Double?) -> Void

    /// Upstream gives an empty turn a bounded nudge before giving up.
    static let maxEmptyRetries = 2
    /// Identical tool rounds in a row before the run is declared stuck.
    static let maxIdenticalRounds = 3

    static let emptyTurnNotice =
        "[System Notice] Your last turn was empty. Call a tool to make progress, or answer in plain text."

    // swiftlint:disable:next function_body_length
    static func run(
        modelName: String,
        seedMessages: [ChatMessage],
        maxTokens: Int?,
        admissionPositionLimit: Int? = nil,
        maxIterations: Int,
        deadline: Date,
        sessionId: String,
        temperature: Float? = nil,
        enableThinking: Bool? = nil,
        reasoningEffort: String? = nil,
        isAgentRequest: Bool = true,
        stopOnToolRejection: Bool = false,
        treatEmptyChoicesAsFinal: Bool = false,
        isInterrupted: @escaping @Sendable () -> Bool = { false },
        toolset: AgentSubagentToolset? = nil,
        onProgress: Progress? = nil,
        engine suppliedEngine: (any ResponsesEngineProtocol)? = nil
    ) async throws -> AgentSubagentRunResult {
        let engine: any ResponsesEngineProtocol = suppliedEngine ?? ChatEngine(source: .agent)
        var messages = seedMessages
        var usage = AgentSubagentUsage()
        var iterations = 0
        var notices: [String] = []
        var emptyRetries = 0
        var lastRoundSignature: String?
        var identicalRounds = 0

        let contextWindow = await AgentLoopBudget.resolveContextWindow(modelId: modelName)
        let systemChars = seedMessages.first(where: { $0.role == "system" })?.content?.count ?? 0
        let toolTokens = toolset.map { _ in 400 * max(1, toolset?.specs.count ?? 1) } ?? 0
        let manager = AgentLoopBudget.makeBudgetManager(
            contextWindow: contextWindow, systemPromptChars: systemChars,
            toolTokens: toolTokens, maxResponseTokens: maxTokens)
        let watermark = CompactionWatermark()
        let allowedNames = Set(toolset?.specs.map(\.function.name) ?? [])

        func cancelCause() -> SubagentCancelCause? {
            if isInterrupted() { return .userInterrupt }
            if Date() >= deadline { return .deadline }
            if Task.isCancelled { return .parentTask }
            return nil
        }
        func finish(_ exit: AgentToolLoop.Exit, digest: String? = nil, cause: SubagentCancelCause? = nil)
            -> AgentSubagentRunResult
        {
            AgentSubagentRunResult(
                digest: digest, exit: exit, iterations: iterations, cancelCause: cause, usage: usage)
        }

        while iterations < maxIterations {
            if let cause = cancelCause() { return finish(.cancelled, cause: cause) }
            iterations += 1

            let input = AgentLoopBudget.composeIterationMessages(
                messages, notices: notices, manager: manager, watermark: watermark)
            notices = []
            if input.overBudget, iterations > 1 { return finish(.overBudget) }

            var request = ResponsesInferenceRequest(model: modelName, input: input.messages)
            if let toolset, !toolset.specs.isEmpty {
                request.tools = toolset.specs
                request.toolChoice = .auto
            }
            request.sessionID = sessionId
            request.context.isAgentRequest = isAgentRequest
            request.context.samplingParametersAreImplicit = temperature == nil
            request.generation.temperature = temperature
            request.generation.enableThinking = enableThinking
            request.generation.reasoningEffort = reasoningEffort
            request.generation.maxOutputTokens = maxTokens

            let stepRequest = request
            let step = OwnedSubagentOperation {
                try await engine.completeDesktopStep(request: stepRequest, attempt: nil)
            }
            let response: ResponsesGenerationResult
            do {
                response = try await step.value(cancellationRequested: { isInterrupted() || Date() >= deadline })
            } catch is CancellationError {
                return finish(.cancelled, cause: cancelCause() ?? .parentTask)
            }

            usage.promptTokens = ContextBudgetManager.estimateTokens(for: input.messages)
            let stepTokens = max(1, response.text.count / 4)
            usage.completionTokens += stepTokens
            onProgress?(usage.completionTokens, nil)

            if response.completion.stopReason == "length" { return finish(.lengthExhausted) }
            let calls = response.completion.functionCalls

            if calls.isEmpty {
                let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    if treatEmptyChoicesAsFinal { return finish(.finalResponse, digest: "") }
                    emptyRetries += 1
                    if emptyRetries > maxEmptyRetries { return finish(.emptyResponseExhausted) }
                    notices = [emptyTurnNotice]
                    continue
                }
                return finish(.finalResponse, digest: text)
            }

            // A model stuck proposing the same round over and over.
            let signature = calls.map { "\($0.name)\u{1F}\($0.arguments)" }.joined(separator: "\u{1E}")
            if signature == lastRoundSignature {
                identicalRounds += 1
                if identicalRounds >= maxIdenticalRounds { return finish(.repetitionLoopExhausted) }
            } else {
                lastRoundSignature = signature
                identicalRounds = 1
            }

            messages.append(try response.completedAssistantInput())
            for call in calls {
                if let cause = cancelCause() { return finish(.cancelled, cause: cause) }
                let result: String
                if allowedNames.contains(call.name), let toolset {
                    result = await toolset.execute(
                        ServiceToolInvocation(
                            toolName: call.name, jsonArguments: call.arguments, toolCallId: call.callID))
                } else {
                    if stopOnToolRejection { return finish(.toolRejected) }
                    result = ToolEnvelope.failure(
                        kind: .rejected,
                        message: "Tool '\(call.name)' is not available here.",
                        tool: call.name,
                        retryable: false)
                }
                messages.append(ChatMessage(role: "tool", content: result, tool_calls: nil, tool_call_id: call.callID))
            }
        }
        return finish(.iterationCapReached)
    }
}
