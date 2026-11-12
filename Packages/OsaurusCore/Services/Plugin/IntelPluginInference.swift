//
//  IntelPluginInference.swift
//  osaurus
//
//  `W-plugin-reliability` stage 2d (docs/UPSTREAM_SYNC.md, "Plugin
//  inference"): upstream's plugin inference callbacks — `complete`,
//  `complete_stream`, `complete_cancel`, `embed`, `list_models` — on
//  Intel's engines.
//
//  The plugin-facing contract is upstream's (`bce907045`): request parsing
//  and the stripped extension fields, the host-enforced agent scope, the
//  per-plugin in-flight cap (`plugin_busy`), the `stream_id` cancellation
//  registry, the chunk and envelope shapes, `tool_calls_executed` /
//  `shared_artifacts`, the `complete` / `clarify` endings, Insights and
//  notch activity, and saving the conversation to the chat sidebar.
//
//  Underneath, Intel differs:
//  - Upstream drives its own agent loop (`AgentToolLoop`) over its
//    Responses engine. Intel's `ChatEngine` runs the tool loop itself, so
//    the run hands the engine the composed request and reads its in-band
//    markers, as Intel's `/agents/{id}/run` does
//    (`IntelHTTPAgentRun.swift`). Upstream's context-budget trimming and
//    its `context_overflow` / `empty_tool_task_completion` endings are the
//    engine's business on Intel; an engine failure is `inference_error`.
//  - The agent's prompt, memory and tools come from Intel's composer.
//    Upstream also freezes them per `session_id` (`SessionToolStateStore`,
//    not compiled on Intel); Intel composes them fresh each call.
//  - `embed` runs Intel's CPU embedder (`potion-base-8M`, 256 dimensions)
//    where upstream runs `potion-base-4M` (128) on MLX; `list_models` lists
//    the remote models and that embedder (Intel has no MLX models).
//

#if OSAURUS_INTEL

import Foundation
import os

/// Bridges cancellation to the detached host task even when no model event
/// has arrived. Completion releases the task closure; attachment may race
/// with either cancellation or completion.
final class PluginStreamCancellationHandle: Sendable {
    private struct State {
        var cancelled = false
        var finished = false
        var attached = false
        var action: (@Sendable () -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func attach(_ action: @escaping @Sendable () -> Void) {
        let shouldCancel = state.withLock { state in
            guard !state.finished, !state.attached else { return false }
            state.attached = true
            if state.cancelled { return true }
            state.action = action
            return false
        }
        if shouldCancel { action() }
    }

    func cancel() {
        let action = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.finished, !state.cancelled else { return nil }
            state.cancelled = true
            let action = state.action
            state.action = nil
            return action
        }
        action?()
    }

    func finish() {
        state.withLock { state in
            state.finished = true
            state.action = nil
        }
    }
}

extension PluginHostContext {

    func completeCancel(streamId: String) {
        let trimmed = streamId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        markStreamCancelled(trimmed)
    }

    // MARK: - Inference Callbacks

    // Plugin-host completions are used by agent/tool surfaces. A one-shot
    // default turns any omitted `max_iterations` into "stop before executing
    // the first model-emitted tool call", which is especially visible on
    // Qwen-family local models that rely on multi-turn tool/result loops.
    private static let defaultMaxIterations = 30
    private static let maxIterationsCap = 120

    // MARK: Inference Types

    /// Internal so unit tests can pin `resolveAgentContext`'s nil / non-nil
    /// behavior. Intel: sampling values are `Double` (Intel's agent store).
    struct AgentContext {
        let agentId: UUID
        let systemPrompt: String
        let memorySection: String?
        let model: String?
        let temperature: Double?
        let maxTokens: Int?
        let tools: [Tool]?
        let executionMode: ExecutionMode
        /// Intel: whether the agent has tools switched off (upstream reads
        /// `effectiveToolsDisabled` in `prepareInference`).
        let toolsDisabled: Bool
    }

    struct InferenceOptions {
        let maxIterations: Int
        let wantsAgentTools: Bool

        init(from json: [String: Any]) {
            let raw = json["max_iterations"] as? Int ?? defaultMaxIterations
            self.maxIterations = max(1, min(raw, maxIterationsCap))
            self.wantsAgentTools = json["tools"] as? Bool == true
        }
    }

    /// Intel: the engine request (upstream's is a Responses request).
    struct EnrichedInference {
        var request: ChatCompletionRequest
        var tools: [Tool]?
    }

    /// Fully prepared inference state ready for the engine run.
    struct PreparedInference {
        let enriched: EnrichedInference
        let options: InferenceOptions
        let engine: any ChatEngineProtocol
        let agentId: UUID?
        let executionMode: ExecutionMode
        let contextId: String
        /// The plugin's own messages, saved to the chat sidebar as sent
        /// (without the system prompt and memory the host added).
        let requestMessages: [ChatMessage]
        /// The plugin's `session_id` (upstream's external session key).
        let sessionKey: String?
        var model: String { enriched.request.model ?? "" }
    }

    // MARK: Request Parsing

    /// Strips extension fields (`agent_address`, `agent_id`, `max_iterations`,
    /// `"tools": true`) that would break the Codable decoder, returning both
    /// the raw dict and clean Data. `agent_address` / `agent_id` are still
    /// recognized in the raw dict so that plugin trampolines can warn-once
    /// when a plugin tries to override the host-enforced agent scope.
    /// Internal (not private) so unit tests can pin the strip behavior.
    static func parseRawRequest(_ requestJSON: String) -> (json: [String: Any], sanitized: Data)? {
        let data = Data(requestJSON.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var clean = json
        clean.removeValue(forKey: "agent_address")
        clean.removeValue(forKey: "agent_id")
        clean.removeValue(forKey: "max_iterations")
        if json["tools"] is Bool { clean.removeValue(forKey: "tools") }

        guard let cleanData = try? JSONSerialization.data(withJSONObject: clean, options: .osaurusCanonical)
        else { return nil }
        return (json, cleanData)
    }

    /// Shared setup for both `complete` and `completeStream`: resolves agent
    /// context, composes the engine request and creates the engine.
    ///
    /// `activeAgentId` is the host-enforced agent scope captured on the
    /// calling thread (TLS) before the plugin trampoline crossed into
    /// `Self.blockingAsync`.
    static func prepareInference(
        request: ChatCompletionRequest,
        rawJSON: [String: Any],
        pluginId: String? = nil,
        activeAgentId: UUID? = nil,
        engineFactory: @Sendable () -> any ChatEngineProtocol = { ChatEngine(source: .plugin) }
    ) async -> PreparedInference {
        let options = InferenceOptions(from: rawJSON)
        let requestedModel = (request.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let contextModelOverride =
            requestedModel.isEmpty
                || requestedModel.caseInsensitiveCompare("default") == .orderedSame
            ? nil
            : requestedModel
        let agentCtx = await resolveAgentContext(
            agentId: activeAgentId,
            messages: request.messages,
            sessionId: request.session_id,
            modelOverride: contextModelOverride
        )
        var enriched = enrichRequest(request, context: agentCtx, options: options)
        if enriched.request.model?.isEmpty ?? true {
            // Intel: no agent and no model named. Upstream's engine resolves
            // "default" itself; Intel's needs a concrete model.
            let fallback = await MainActor.run { AgentManager.shared.effectiveModel(for: Agent.defaultId) }
            enriched.request = rebuilt(enriched.request, model: fallback ?? "")
        }
        if let pid = pluginId {
            let instructions: String? = await MainActor.run {
                PluginInstructionsResolver.instructions(pluginId: pid, agentId: agentCtx?.agentId)
            }
            // The composer already lists the instructions of every plugin whose
            // tool is active; don't append them twice.
            let alreadyComposed = instructions.map { text in
                enriched.request.messages.contains { $0.role == "system" && ($0.content ?? "").contains(text) }
            } ?? false
            if let instructions, !alreadyComposed {
                // Upstream `appendSystemContent`.
                var messages = enriched.request.messages
                SystemPromptComposer.mergeSystemContent(instructions, into: &messages, prepend: false)
                enriched.request = rebuilt(enriched.request, messages: messages)
            }
        }
        // No silent Default-agent fallback: when the plugin has no chat-bound
        // agent context, tool injection is skipped (treated as "tools off").
        // The built-in Default agent is in-app chat only and gets no injected
        // agent tools either (upstream `applyAgentTools`).
        if let ctx = agentCtx, options.wantsAgentTools, !ctx.toolsDisabled, ctx.agentId != Agent.defaultId {
            enriched = applyResolvedTools(ctx.tools ?? [], to: enriched)
        }

        let sessionKey = request.session_id.flatMap { $0.isEmpty ? nil : $0 }
        return PreparedInference(
            enriched: enriched,
            options: options,
            engine: engineFactory(),
            agentId: agentCtx?.agentId,
            executionMode: agentCtx?.executionMode ?? .none,
            contextId: sessionKey ?? UUID().uuidString,
            requestMessages: request.messages,
            sessionKey: sessionKey
        )
    }

    // MARK: Agent Context Resolution

    /// Resolves the per-agent inference context (system prompt, tool surface,
    /// model overrides, sampling defaults) for `agentId`. Returns nil when
    /// `agentId` is nil or no agent record is found, in which case callers
    /// fall back to host defaults. Plugin-supplied `agent_address` /
    /// `agent_id` is intentionally ignored.
    ///
    /// Intel: the composer is Intel's (`composeChatContext`, as
    /// `/agents/{id}/run` uses); the folder is never a session's, as on
    /// Intel's HTTP agent run.
    static func resolveAgentContext(
        agentId: UUID?,
        messages: [ChatMessage] = [],
        sessionId: String? = nil,
        modelOverride: String? = nil
    ) async -> AgentContext? {
        guard let agentId else { return nil }

        let resolved: (autonomousEnabled: Bool, toolsDisabled: Bool, model: String?)? = await MainActor.run {
            guard AgentManager.shared.agent(for: agentId) != nil else { return nil }
            let manager = AgentManager.shared
            return (
                manager.effectiveAutonomousExec(for: agentId)?.enabled == true,
                manager.effectiveToolsDisabled(for: agentId),
                manager.effectiveModel(for: agentId)
            )
        }
        guard let resolved else { return nil }

        // Upstream: a plugin inference resolves the folder of the SESSION
        // driving it (the live dispatched session with this id), never a
        // process-wide folder that could belong to an unrelated chat window.
        let sessionFolderContext: FolderContext? = await MainActor.run {
            guard let sid = sessionId, let sessionUUID = UUID(uuidString: sid) else { return nil }
            return BackgroundTaskManager.shared.liveTask(forSessionId: sessionUUID)?.chatSession?.folderState.context
        }
        let execMode: ExecutionMode = await MainActor.run {
            ToolRegistry.shared.resolveExecutionMode(
                folderContext: sessionFolderContext,
                autonomousEnabled: resolved.autonomousEnabled
            )
        }
        // Upstream: wait for the first plugin catalog scan before composing.
        await PluginManager.shared.ensurePromptCatalogReady()
        let composed = await SystemPromptComposer.composeChatContext(
            agentId: agentId,
            executionMode: execMode,
            model: modelOverride ?? resolved.model,
            query: extractLatestUserQuery(from: messages),
            messages: messages,
            toolsDisabled: resolved.toolsDisabled,
            folderContext: sessionFolderContext
        )
        return await MainActor.run {
            let mgr = AgentManager.shared
            return AgentContext(
                agentId: agentId,
                systemPrompt: composed.prompt,
                memorySection: composed.memorySection,
                model: resolved.model,
                temperature: mgr.effectiveTemperature(for: agentId),
                maxTokens: mgr.effectiveMaxTokens(for: agentId),
                tools: composed.tools.isEmpty ? nil : composed.tools,
                executionMode: execMode,
                toolsDisabled: resolved.toolsDisabled
            )
        }
    }

    private static func extractLatestUserQuery(from messages: [ChatMessage]) -> String {
        messages.last(where: { $0.role == "user" })?.content ?? ""
    }

    // MARK: Request Enrichment

    static func enrichRequest(
        _ request: ChatCompletionRequest,
        context: AgentContext?,
        options: InferenceOptions
    ) -> EnrichedInference {
        guard let ctx = context else {
            return EnrichedInference(request: request, tools: request.tools)
        }

        var model = request.model ?? ""
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("default") == .orderedSame,
            let agentModel = ctx.model, !agentModel.isEmpty
        {
            model = agentModel
        }

        var messages = request.messages
        SystemPromptComposer.injectSystemContent(ctx.systemPrompt, into: &messages)
        // Intel: memory rides the latest user message only (upstream also
        // replays earlier prefixes for a `session_id`).
        SystemPromptComposer.injectMemoryPrefix(ctx.memorySection, into: &messages)

        let effectiveTools: [Tool]?
        if let explicit = request.tools, !explicit.isEmpty {
            effectiveTools = explicit
        } else if options.wantsAgentTools {
            effectiveTools = ctx.tools
        } else {
            effectiveTools = nil
        }

        var enriched = ChatCompletionRequest(
            model: model,
            messages: messages,
            temperature: request.temperature ?? ctx.temperature,
            max_tokens: request.max_tokens ?? ctx.maxTokens,
            stream: request.stream,
            top_p: request.top_p,
            frequency_penalty: request.frequency_penalty,
            presence_penalty: request.presence_penalty,
            stop: request.stop,
            n: request.n,
            tools: effectiveTools,
            tool_choice: request.tool_choice,
            session_id: request.session_id
        )
        enriched.samplingParametersAreImplicit = request.temperature == nil
        return EnrichedInference(request: enriched, tools: effectiveTools)
    }

    /// Merge a set of resolved tool specs into an inference request,
    /// replacing any existing spec with the same name. Intel keeps the
    /// composer's order (Intel's composer has no canonical order).
    static func applyResolvedTools(_ specs: [Tool], to inference: EnrichedInference) -> EnrichedInference {
        var tools = inference.tools ?? []
        for spec in specs {
            if let index = tools.firstIndex(where: { $0.function.name == spec.function.name }) {
                tools[index] = spec
            } else {
                tools.append(spec)
            }
        }
        let effectiveTools = tools.isEmpty ? nil : tools
        var resolved = inference
        resolved.request.tools = effectiveTools
        resolved.tools = effectiveTools
        return resolved
    }

    /// A copy with a new model or messages (both are `let` on Intel's
    /// request).
    private static func rebuilt(
        _ request: ChatCompletionRequest,
        model: String? = nil,
        messages: [ChatMessage]? = nil
    ) -> ChatCompletionRequest {
        var copy = ChatCompletionRequest(
            model: model ?? request.model,
            messages: messages ?? request.messages,
            temperature: request.temperature,
            max_tokens: request.max_tokens,
            stream: request.stream,
            top_p: request.top_p,
            frequency_penalty: request.frequency_penalty,
            presence_penalty: request.presence_penalty,
            stop: request.stop,
            n: request.n,
            tools: request.tools,
            tool_choice: request.tool_choice,
            session_id: request.session_id
        )
        copy.samplingParametersAreImplicit = request.samplingParametersAreImplicit
        return copy
    }

    /// The request the engine runs: streamed, tools run by the engine up to
    /// the iteration budget, tool starts and usage reported in-band.
    static func engineRequest(for prep: PreparedInference) -> ChatCompletionRequest {
        var request = prep.enriched.request
        request.stream = true
        if let tools = request.tools, !tools.isEmpty, request.tool_choice == nil {
            request.tool_choice = .auto
        }
        request.reportsUsage = true
        request.reportsToolStarts = true
        request.maxToolRounds = prep.options.maxIterations
        return request
    }

    // MARK: Engine Run (Intel)

    /// What a plugin run streams, decoded from the engine's markers.
    enum RunEvent {
        case content(String)
        case reasoning(String)
        case toolStarted(callId: String, name: String, arguments: String)
        case toolDone(callId: String, name: String, arguments: String, result: String)
        case usage([String: Any])
    }

    /// How a run ended.
    enum RunExit {
        /// The model gave its answer.
        case finalResponse
        /// A successful `complete` (summary) or `clarify` (question).
        case intercepted(tool: String, text: String)
        /// The iteration budget ran out while the model still called tools.
        case iterationCapReached
        /// Stopped through `complete_cancel`.
        case cancelled
        /// The output token limit cut the answer off.
        case lengthExhausted
        case failed(Error)
    }

    /// The run's result, in upstream's envelope fields.
    final class RunState: @unchecked Sendable {
        /// The visible answer since the last tool call (upstream `lastContent`).
        var content = ""
        var toolCallsExecuted: [[String: String]] = []
        var sharedArtifacts: [[String: Any]] = []
        var usage: [String: Any]?
        var stopReason: String?
        let transcript = PhoneRunTranscript()
        private var promptTokens: Int?
        private var completionTokens: Int?
        private var tokensPerSecond: Double?
        private var unclosedReasoning = false

        /// Upstream `PluginResponsesCompatibility.reportedUsage`: sparse, no
        /// zero-filled counts.
        func recordUsage(prompt: Int?, completion: Int?, tps: Double?, unclosed: Bool?) {
            if let prompt { promptTokens = prompt }
            if let completion { completionTokens = completion }
            if let tps { tokensPerSecond = tps }
            if let unclosed { unclosedReasoning = unclosed }
            var usage: [String: Any] = ["unclosed_reasoning": unclosedReasoning]
            if let promptTokens { usage["prompt_tokens"] = promptTokens }
            if let completionTokens { usage["completion_tokens"] = completionTokens }
            if let promptTokens, let completionTokens { usage["total_tokens"] = promptTokens + completionTokens }
            if let tokensPerSecond { usage["tokens_per_second"] = tokensPerSecond }
            self.usage = usage
        }

        var hasBothCounts: Bool { promptTokens != nil && completionTokens != nil }
    }

    /// Runs the engine for a prepared plugin inference. `onEvent` sees each
    /// event as it arrives; `isCancelled` is polled between deltas.
    static func runEngine(
        prep: PreparedInference,
        state: RunState,
        isCancelled: @escaping () -> Bool = { false },
        onEvent: (RunEvent) -> Void = { _ in }
    ) async -> RunExit {
        let request = engineRequest(for: prep)
        var intercept: (tool: String, text: String)?
        do {
            let stream = try await ChatExecutionContext.$currentAgentId.withValue(prep.agentId) {
                try await ChatExecutionContext.$currentSessionId.withValue(prep.contextId) {
                    try await ChatExecutionContext.$currentExecutionMode.withValue(prep.executionMode) {
                        try await prep.engine.streamChat(request: request)
                    }
                }
            }
            for try await delta in stream {
                if isCancelled() { return .cancelled }
                try Task.checkCancellation()
                if let started = StreamingToolHint.decodeStarted(delta) {
                    onEvent(.toolStarted(callId: started.callId, name: started.name, arguments: started.arguments))
                    continue
                }
                if StreamingGroundedRetryHint.isRetry(delta) {
                    // The engine retracts an ungrounded draft; the corrected
                    // answer follows.
                    state.transcript.groundedRetry()
                    state.content = ""
                    continue
                }
                if let done = StreamingToolHint.decodeDone(delta) {
                    state.transcript.toolDone(
                        callId: done.callId, name: done.name, arguments: done.arguments, result: done.result)
                    state.toolCallsExecuted.append(["name": done.name, "tool_call_id": done.callId])
                    if done.name == "share_artifact", !ToolEnvelope.isError(done.result),
                        let artifact = SharedArtifact.fromEnrichedToolResult(done.result)
                    {
                        state.sharedArtifacts.append(serializeArtifactDict(artifact))
                    }
                    // The staged assistant batch owns its original prose;
                    // the final answer starts a fresh visible buffer.
                    state.content = ""
                    onEvent(.toolDone(callId: done.callId, name: done.name, arguments: done.arguments, result: done.result))
                    if AgentLoopRunEnd.endsRun(toolName: done.name, result: done.result),
                        let text = interceptText(toolName: done.name, arguments: done.arguments)
                    {
                        intercept = (done.name, text)
                    }
                    continue
                }
                if let usage = StreamingUsageHint.decode(delta) {
                    state.recordUsage(
                        prompt: usage.promptTokens, completion: usage.completionTokens, tps: nil, unclosed: nil)
                    onEvent(.usage(state.usage ?? [:]))
                    continue
                }
                if let stats = StreamingStatsHint.decode(delta) {
                    state.stopReason = stats.stopReason
                    state.recordUsage(
                        prompt: nil, completion: nil, tps: stats.tokensPerSecond, unclosed: stats.unclosedReasoning)
                    continue
                }
                if let reasoning = StreamingReasoningHint.decode(delta) {
                    if !reasoning.isEmpty {
                        state.transcript.reasoning(reasoning)
                        onEvent(.reasoning(reasoning))
                    }
                    continue
                }
                if StreamingToolHint.isSentinel(delta) || delta.isEmpty { continue }
                state.content += delta
                state.transcript.content(delta)
                onEvent(.content(delta))
            }
        } catch is ChatEngine.ToolRoundLimitReached {
            return .iterationCapReached
        } catch {
            if isCancelled() || error is CancellationError { return .cancelled }
            return .failed(error)
        }
        if isCancelled() { return .cancelled }
        if let intercept { return .intercepted(tool: intercept.tool, text: intercept.text) }
        if state.stopReason == "length" { return .lengthExhausted }
        return .finalResponse
    }

    /// The text a successful `complete` / `clarify` call leaves as the run's
    /// answer (upstream's terminal handlers); nil for any other tool.
    static func interceptText(toolName: String, arguments: String) -> String? {
        switch toolName {
        case "complete": return CompleteTool.parseSummary(from: arguments) ?? "Task completed."
        case "clarify": return ClarifyTool.parse(argumentsJSON: arguments)?.question ?? ""
        default: return nil
        }
    }

    // MARK: complete (non-streaming)

    func complete(requestJSON: String) -> String {
        guard tryEnterInflightInference() else {
            return Self.pluginBusyJSON(kind: "complete")
        }
        let pid = self.pluginId
        let engineFactory = inferenceEngineFactory
        // Capture host-enforced agent scope on the calling thread before
        // crossing into `Self.blockingAsync` — TLS does not survive the
        // `Task.detached` hop. See `dispatch` for the full rationale.
        let activeAgent = Self.activeAgentId()
        let releaseSlot: @Sendable () -> Void = { [weak self] in
            self?.exitInflightInference()
        }
        let activityId = Self.beginPluginActivity(pluginId: pid, kind: .complete)
        return Self.blockingAsync(fallback: Self.pluginHostTimeoutJSON(kind: "complete")) {
            defer {
                releaseSlot()
                Self.endPluginActivity(activityId)
            }
            guard let (rawJSON, sanitized) = Self.parseRawRequest(requestJSON),
                let request = try? JSONDecoder().decode(ChatCompletionRequest.self, from: sanitized)
            else {
                return Self.jsonString([
                    "error": "invalid_request", "message": "Failed to parse chat completion request",
                ])
            }

            // Agent scope is host-enforced — see `auditAgentScope`.
            Self.auditAgentScope(json: rawJSON, pluginId: pid, op: "complete", activeAgent: activeAgent)

            let prep = await Self.prepareInference(
                request: request,
                rawJSON: rawJSON,
                pluginId: pid,
                activeAgentId: activeAgent,
                engineFactory: engineFactory
            )
            let state = RunState()
            let exit = await Self.runEngine(prep: prep, state: state)
            Self.persistInference(pluginId: pid, prep: prep, state: state)

            switch exit {
            case .failed(let error):
                return Self.jsonString(["error": "inference_error", "message": error.localizedDescription])
            case .cancelled:
                // `complete` takes no stream id; only host shutdown cancels it.
                return Self.jsonString(["error": "inference_error", "message": "The completion was cancelled."])
            case .lengthExhausted:
                return Self.jsonString([
                    "error": "output_token_limit",
                    "message": Self.lengthExhaustedMessage,
                    "tool_calls_executed": state.toolCallsExecuted,
                    "shared_artifacts": state.sharedArtifacts,
                ])
            case .iterationCapReached:
                // The final iteration's tool calls executed, but the model
                // never produced a final text answer. Surface what ran so
                // the plugin isn't left with an opaque error.
                return Self.jsonString([
                    "error": "max_iterations_reached",
                    "message": "Reached max iterations (\(prep.options.maxIterations)) without a final response",
                    "tool_calls_executed": state.toolCallsExecuted,
                    "shared_artifacts": state.sharedArtifacts,
                ])
            case .intercepted(let tool, let text) where tool == "clarify":
                // The headless loop cannot pause for input; surface the
                // question so the plugin can ask its user and follow up.
                return Self.jsonString([
                    "error": "clarify_requested",
                    "message": "The model paused to ask a clarifying question; answer it in a follow-up request.",
                    "question": text,
                    "tool_calls_executed": state.toolCallsExecuted,
                    "shared_artifacts": state.sharedArtifacts,
                ])
            case .intercepted(_, let summary):
                // `complete`: a normal chat-completion response whose content
                // is the model's verified summary.
                return Self.completionResponse(model: prep.model, content: summary, finishReason: "stop", state: state)
            case .finalResponse:
                return Self.completionResponse(
                    model: prep.model, content: state.content, finishReason: state.stopReason ?? "stop", state: state)
            }
        }
    }

    /// Upstream `AgentToolLoop.lengthExhaustedFallback`.
    static let lengthExhaustedMessage =
        "The model reached the configured output-token limit before naturally completing an answer or tool call. "
        + "The agent task is incomplete; increase Max Tokens, disable Thinking for this task, "
        + "or continue from the latest tool result."

    /// Chat Completions-shaped response (upstream
    /// `PluginResponsesCompatibility.response`).
    private static func completionResponse(
        model: String,
        content: String,
        finishReason: String,
        state: RunState
    ) -> String {
        var response: [String: Any] = [
            "id": "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": content],
                "finish_reason": finishReason,
            ]],
        ]
        let usage = state.usage ?? ["unclosed_reasoning": false]
        response["generation_metrics"] = usage
        if state.hasBothCounts { response["usage"] = usage }
        if !state.toolCallsExecuted.isEmpty { response["tool_calls_executed"] = state.toolCallsExecuted }
        if !state.sharedArtifacts.isEmpty { response["shared_artifacts"] = state.sharedArtifacts }
        return jsonString(response)
    }

    // MARK: complete_stream (streaming)

    func completeStream(
        requestJSON: String,
        onChunk: osr_on_chunk_t?,
        userData: UnsafeMutableRawPointer?
    ) -> String {
        guard tryEnterInflightInference() else {
            return Self.pluginBusyJSON(kind: "complete_stream")
        }
        // Warn once per plugin if the plugin passed a null chunk callback —
        // chunks would otherwise be silently dropped, which is almost
        // always a bug rather than intent.
        if onChunk == nil {
            Self.warnNullChunkCallbackOnce(pluginId: pluginId)
        }
        let pid = self.pluginId
        let engineFactory = inferenceEngineFactory
        // Capture host-enforced agent scope on the calling thread before
        // crossing into `Self.blockingAsync`.
        let activeAgent = Self.activeAgentId()
        nonisolated(unsafe) let userData = userData
        nonisolated(unsafe) weak var ctxRef = self
        let releaseSlot: @Sendable () -> Void = {
            ctxRef?.exitInflightInference()
        }
        let streamOwner = UUID()
        let cancellation = PluginStreamCancellationHandle()
        // `unregisterStream` runs once at the end of the streaming work,
        // regardless of how it terminates.
        let unregisterStream: @Sendable (String?) -> Void = { streamId in
            if let id = streamId { ctxRef?.unregisterStream(id, owner: streamOwner) }
        }
        // `isCancelled` is the cheap per-delta check the run calls.
        // Returns false when no stream id was supplied.
        let isCancelled: @Sendable (String?) -> Bool = { streamId in
            guard let id = streamId, let ctx = ctxRef else { return false }
            return ctx.isStreamCancelled(id, owner: streamOwner)
        }
        let activityId = Self.beginPluginActivity(pluginId: pid, kind: .completeStream)
        return Self.blockingAsync(
            fallback: Self.pluginHostTimeoutJSON(kind: "complete_stream"),
            onTaskCreated: { task in cancellation.attach { task.cancel() } }
        ) {
            // Stream id is per-call: if the plugin supplied one in the
            // request, register it so a concurrent `complete_cancel` call
            // can flag the stream for cancellation. We treat it as opaque
            // — any non-empty string works, but a UUID is recommended.
            var streamId: String?
            defer {
                cancellation.finish()
                releaseSlot()
                unregisterStream(streamId)
                Self.endPluginActivity(activityId)
            }
            guard let (rawJSON, sanitized) = Self.parseRawRequest(requestJSON),
                let request = try? JSONDecoder().decode(ChatCompletionRequest.self, from: sanitized)
            else {
                return Self.jsonString([
                    "error": "invalid_request", "message": "Failed to parse chat completion request",
                ])
            }

            if let raw = rawJSON["stream_id"] as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    streamId = trimmed
                    ctxRef?.registerStream(trimmed, owner: streamOwner, cancel: { cancellation.cancel() })
                }
            }

            // Agent scope is host-enforced — see `auditAgentScope`.
            Self.auditAgentScope(
                json: rawJSON,
                pluginId: pid,
                op: "complete_stream",
                activeAgent: activeAgent
            )

            let prep = await Self.prepareInference(
                request: request,
                rawJSON: rawJSON,
                pluginId: pid,
                activeAgentId: activeAgent,
                engineFactory: engineFactory
            )
            let cid = "cmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
            let state = RunState()
            let currentStreamId = streamId
            let emit: ([String: Any]) -> Void = { payload in
                Self.emitChunk(payload, callback: onChunk, userData: userData)
            }

            let exit = await Self.runEngine(
                prep: prep,
                state: state,
                isCancelled: { isCancelled(currentStreamId) }
            ) { event in
                switch event {
                case .content(let text):
                    emit(Self.chunkPayload(id: cid, delta: ["content": text]))
                case .reasoning(let text):
                    emit(Self.chunkPayload(id: cid, delta: ["reasoning_content": text]))
                case .toolStarted(let callId, let name, let arguments):
                    // Surface the tool call to the plugin before it runs.
                    // Upstream streams `SecretArgumentScrubber`'s view, which
                    // only changes `sandbox_secret_set` (not on Intel), so
                    // the arguments go through as they are.
                    emit(Self.chunkPayload(id: cid, delta: [
                        "tool_calls": [["id": callId, "function": ["name": name, "arguments": arguments]]],
                    ], finishReason: "tool_calls"))
                case .toolDone(let callId, _, _, let result):
                    emit(Self.chunkPayload(id: cid, delta: [
                        "role": "tool", "tool_call_id": callId, "content": result,
                    ]))
                case .usage(let usage):
                    emit(Self.chunkPayload(id: cid, delta: ["usage": usage]))
                }
            }
            Self.persistInference(pluginId: pid, prep: prep, state: state)

            switch exit {
            case .intercepted(let tool, let text):
                let finish = tool == "complete" ? "stop" : "clarify"
                if !text.isEmpty {
                    emit(Self.chunkPayload(id: cid, delta: ["content": text]))
                }
                emit(Self.chunkPayload(id: cid, delta: [:], finishReason: finish))
                return Self.buildStreamResult(
                    id: cid, model: prep.model, content: text,
                    toolCallsExecuted: state.toolCallsExecuted, sharedArtifacts: state.sharedArtifacts,
                    usage: state.usage, finishReason: finish
                )
            case .finalResponse:
                let finish = state.stopReason ?? "stop"
                emit(Self.chunkPayload(id: cid, delta: [:], finishReason: finish))
                return Self.buildStreamResult(
                    id: cid, model: prep.model, content: state.content,
                    toolCallsExecuted: state.toolCallsExecuted, sharedArtifacts: state.sharedArtifacts,
                    usage: state.usage, finishReason: finish
                )
            case .lengthExhausted:
                emit(Self.chunkPayload(id: cid, delta: [:], finishReason: "length"))
                return Self.jsonString([
                    "error": "output_token_limit",
                    "message": Self.lengthExhaustedMessage,
                    "tool_calls_executed": state.toolCallsExecuted,
                    "shared_artifacts": state.sharedArtifacts,
                ])
            case .cancelled:
                emit(Self.chunkPayload(id: cid, delta: [:], finishReason: "cancelled"))
                return Self.cancelledStreamEnvelope(
                    id: cid, streamId: currentStreamId, model: prep.model,
                    partialContent: state.content, toolCallsExecuted: state.toolCallsExecuted,
                    sharedArtifacts: state.sharedArtifacts, usage: state.usage
                )
            case .iterationCapReached:
                // Iteration budget exhausted while the model was still
                // requesting tools. Emit a finish chunk that is honest about
                // why we stopped.
                emit(Self.chunkPayload(id: cid, delta: [:], finishReason: "max_iterations"))
                return Self.jsonString([
                    "error": "max_iterations_reached",
                    "message":
                        "Plugin streaming completion exhausted \(prep.options.maxIterations) iterations without converging on a final answer.",
                    "partial_content": state.content,
                    "tool_calls_executed": state.toolCallsExecuted,
                    "shared_artifacts": state.sharedArtifacts,
                    "model": prep.model,
                    "id": cid,
                ])
            case .failed(let error):
                emit(Self.chunkPayload(id: cid, delta: [:], finishReason: "error"))
                return Self.jsonString(["error": "inference_error", "message": error.localizedDescription])
            }
        }
    }

    // MARK: Inference Helpers

    private static func buildStreamResult(
        id: String,
        model: String,
        content: String,
        toolCallsExecuted: [[String: String]],
        sharedArtifacts: [[String: Any]] = [],
        usage: [String: Any]? = nil,
        finishReason: String = "stop"
    ) -> String {
        var result: [String: Any] = [
            "id": id, "model": model,
            "choices": [
                [
                    "index": 0,
                    "message": ["role": "assistant", "content": content],
                    "finish_reason": finishReason,
                ]
            ],
        ]
        if !toolCallsExecuted.isEmpty { result["tool_calls_executed"] = toolCallsExecuted }
        if !sharedArtifacts.isEmpty { result["shared_artifacts"] = sharedArtifacts }
        if let usage { result["usage"] = usage }
        return jsonString(result)
    }

    /// Cancelled-stream envelope returned from `completeStream` when the
    /// plugin invokes `complete_cancel(stream_id)` mid-stream. Mirrors the
    /// fields a normal stream return carries (model, id, partial content,
    /// usage, executed tool calls, shared artifacts) plus the stream id
    /// the plugin supplied so it can correlate the cancellation back to
    /// its own bookkeeping.
    private static func cancelledStreamEnvelope(
        id: String,
        streamId: String?,
        model: String,
        partialContent: String,
        toolCallsExecuted: [[String: String]],
        sharedArtifacts: [[String: Any]],
        usage: [String: Any]?
    ) -> String {
        jsonString([
            "error": "cancelled",
            "message": "Streaming completion cancelled by plugin via complete_cancel.",
            "id": id,
            "stream_id": streamId ?? "",
            "model": model,
            "partial_content": partialContent,
            "tool_calls_executed": toolCallsExecuted,
            "shared_artifacts": sharedArtifacts,
            "usage": usage ?? [:],
        ])
    }

    private static func chunkPayload(
        id: String,
        delta: [String: Any],
        finishReason: String? = nil
    ) -> [String: Any] {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let reason = finishReason { choice["finish_reason"] = reason }
        return ["id": id, "choices": [choice]]
    }

    private static func emitChunk(
        _ payload: [String: Any],
        callback: osr_on_chunk_t?,
        userData: UnsafeMutableRawPointer?
    ) {
        guard let callback,
            let data = try? JSONSerialization.data(withJSONObject: payload, options: .osaurusCanonical),
            let str = String(data: data, encoding: .utf8)
        else { return }
        str.withCString { callback($0, userData) }
    }

    /// Emit a one-shot warning when `complete_stream` is invoked with a
    /// nil `on_chunk` callback. Streamed deltas would silently be dropped
    /// in this case; the aggregated return value still works, but plugin
    /// authors usually expect chunks to be delivered.
    static func warnNullChunkCallbackOnce(pluginId: String) {
        PluginOnceLogger.warnOnce(
            key: "\(pluginId)|complete_stream|null_chunk",
            "[PluginHostAPI] Plugin '%@' invoked complete_stream with a NULL on_chunk callback. "
                + "Streamed deltas will be discarded; the aggregated return value still flows. "
                + "Pass a callback if your plugin needs incremental output. "
                + "This warning is logged once per plugin per process.",
            pluginId
        )
    }

    // MARK: - Embeddings

    func embed(requestJSON: String) -> String {
        guard tryEnterInflightInference() else {
            return Self.pluginBusyJSON(kind: "embed")
        }
        let pid = self.pluginId
        // Capture host-enforced agent scope on the calling thread before
        // crossing into `Self.blockingAsync`. Embed currently uses no
        // per-agent overrides, but we still warn-on-override so the
        // boundary is consistent across all plugin trampolines.
        let activeAgent = Self.activeAgentId()
        let releaseSlot: @Sendable () -> Void = { [weak self] in
            self?.exitInflightInference()
        }
        let activityId = Self.beginPluginActivity(pluginId: pid, kind: .embed)
        return Self.blockingAsync(fallback: Self.pluginHostTimeoutJSON(kind: "embed")) {
            defer {
                releaseSlot()
                Self.endPluginActivity(activityId)
            }
            let data = Data(requestJSON.utf8)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return Self.jsonString(["error": "invalid_request", "message": "Failed to parse embedding request"])
            }

            // Agent scope is host-enforced — see `auditAgentScope`.
            Self.auditAgentScope(json: json, pluginId: pid, op: "embed", activeAgent: activeAgent)

            var texts: [String] = []
            if let single = json["input"] as? String {
                texts = [single]
            } else if let batch = json["input"] as? [String] {
                texts = batch
            } else {
                return Self.jsonString(["error": "invalid_request", "message": "Missing or invalid 'input' field"])
            }

            do {
                // Intel: the CPU embedder the API's `/embeddings` serves.
                let vectors = try await MediaActivityLogger.$embeddingPurpose.withValue("plugin_embed") {
                    try await IntelAPIEmbedder.embed(texts: texts)
                }
                var embeddings: [[String: Any]] = []
                for (i, vec) in vectors.enumerated() {
                    embeddings.append([
                        "index": i,
                        "embedding": vec,
                        "dimensions": vec.count,
                    ])
                }
                let tokenEstimate = texts.reduce(0) { $0 + TokenEstimator.estimate($1) }
                let response: [String: Any] = [
                    "model": json["model"] as? String ?? IntelAPIEmbedder.modelName,
                    "data": embeddings,
                    "usage": ["prompt_tokens": tokenEstimate, "total_tokens": tokenEstimate],
                ]
                return Self.jsonString(response)
            } catch {
                return Self.jsonString(["error": "embedding_error", "message": error.localizedDescription])
            }
        }
    }

    // MARK: - Models Callback

    /// Intel's embedder (`potion-base-8M`).
    static let intelEmbeddingDimensions = 256

    func listModels() -> String {
        Self.blockingAsync(fallback: Self.pluginHostTimeoutJSON(kind: "list_models")) {
            var models: [[String: Any]] = []
            let exposure = ModelExposureStore.shared

            // Apple Foundation Model (never available on Intel Macs).
            if FoundationModelService.isDefaultModelAvailable(),
                exposure.isExposed(id: "foundation", kind: .local)
            {
                models.append([
                    "id": "foundation",
                    "name": "Apple Foundation Model",
                    "provider": "apple",
                    "type": "chat",
                    "capabilities": ["chat"],
                ])
            }

            // Intel: no local MLX models.

            // Local embedding model
            models.append([
                "id": IntelAPIEmbedder.modelName,
                "name": "Potion Base 8M",
                "provider": "local",
                "type": "embedding",
                "dimensions": Self.intelEmbeddingDimensions,
                "capabilities": ["embedding"],
            ])

            // Remote provider models
            let remoteModels = await MainActor.run {
                RemoteProviderManager.shared.getOpenAIModels()
            }
            for m in remoteModels {
                models.append([
                    "id": m.id,
                    "name": m.id,
                    "provider": m.owned_by,
                    "type": "chat",
                    "capabilities": ["chat", "tool_calling"],
                ])
            }

            return Self.jsonString(["models": models])
        }
    }

    // MARK: - Activity registration (upstream PluginHostAPI+SessionPersistence)

    /// Allocate a fresh activity id and register it with the
    /// `PluginActivityManager` from the C-trampoline thread (no `await`).
    /// The actual `@MainActor` mutation hops to the main actor.
    static func beginPluginActivity(
        pluginId: String,
        kind: PluginActivityRecord.Kind
    ) -> UUID {
        let id = UUID()
        Task { @MainActor in
            let displayName = pluginDisplayName(for: pluginId)
            PluginActivityManager.shared.begin(
                id: id,
                pluginId: pluginId,
                pluginDisplayName: displayName,
                kind: kind
            )
        }
        return id
    }

    /// Release an activity id from the `PluginActivityManager`.
    static func endPluginActivity(_ id: UUID) {
        Task { @MainActor in
            PluginActivityManager.shared.end(id)
        }
    }

    @MainActor
    private static func pluginDisplayName(for pluginId: String) -> String {
        if let manifestName = PluginManager.shared.loadedPlugin(for: pluginId)?.plugin
            .manifest.name, !manifestName.isEmpty
        {
            return manifestName
        }
        return pluginId
    }

    // MARK: - Session persistence

    /// Save the run to the chat sidebar (upstream `persistInference` /
    /// `persistStreamingInference`): the plugin's messages as it sent them,
    /// then the run's own turns. Plugins that pass a stable `session_id`
    /// get one growing chat per `(plugin, session_id, agent)`.
    static func persistInference(pluginId: String, prep: PreparedInference, state: RunState) {
        let turns = RemoteSessionContinuation.turns(from: prep.requestMessages) + state.transcript.finished()
        let agentId = prep.agentId
        let key = prep.sessionKey
        let model = prep.model
        Task { @MainActor in
            ChatHistoryWriter.persist(
                source: .plugin,
                sourcePluginId: pluginId,
                agentId: agentId,
                externalKey: key,
                turns: turns,
                model: model
            )
        }
    }
}

#endif
