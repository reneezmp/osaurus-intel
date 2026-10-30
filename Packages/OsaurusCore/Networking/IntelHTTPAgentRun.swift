//
//  IntelHTTPAgentRun.swift
//  osaurus
//
//  `POST /agents/{id}/run`, `GET /runs/{id}/events` and `POST /runs/{id}/stop`
//  (`W-server-api` stage 4c, docs/SERVER_API_INTEL.md).
//
//  Upstream drives its own agent loop (`AgentToolLoop`) from the handler.
//  Intel's `ChatEngine` runs the tool loop itself, so the run hands the
//  engine the agent's composed request and turns the engine's in-band
//  markers into upstream's stream: text and reasoning deltas, the
//  `osaurus_agent_tool` trace ("started" / "completed"), the iteration-cap
//  notice, the `complete` / `clarify` text, then finish, usage and `[DONE]`.
//
//  The phone-only parts wait for the Secure Channel (`W-identity-mobile`):
//  detached runs (`osaurus_run_id`, `/runs/{id}/*`), the host workspace
//  folder, continuing a Mac chat (`osaurus_session_id`), voice-call turns,
//  the phone's model options and privacy choice. Every remote caller needs
//  that channel to reach `/run` at all, so until then a run comes from this
//  Mac: the owner, over loopback.
//

import Foundation
import NIOCore
import NIOHTTP1

extension HTTPHandler {
    /// `/runs/{id}/events`, `/runs/{id}/stop`, then `/agents/{id}/run`, in
    /// upstream's routing order.
    func routeRunRequest(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) -> Bool {
        if head.method == .GET, path.hasPrefix("/runs/"), path.hasSuffix("/events") {
            serveRunEvents(context: context, path: path)
        } else if head.method == .POST, path.hasPrefix("/runs/"), path.hasSuffix("/stop") {
            serveRunStop(context: context, head: head, path: path)
        } else if head.method == .POST, path.hasPrefix("/agents/"), path.hasSuffix("/run") {
            serveAgentRun(context: context, head: head, path: path)
        } else {
            return false
        }
        return true
    }

    // MARK: - Helpers (upstream)

    /// Make a `/agents/{id}/run` body decodable when the caller omitted the
    /// `model` key. Mode 2 callers intentionally do not send a model (the agent
    /// runs its own effective model server-side), but the shared
    /// `ChatCompletionRequest` decoder requires `model`. Inject an empty string
    /// so decode succeeds; the run handler resolves empty/"default" → the
    /// agent's effective model. Returns the original bytes unchanged when the
    /// body isn't a JSON object or already carries a non-null `model`.
    static func injectingEmptyModelIfMissing(_ data: Data) -> Data {
        guard var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        guard obj["model"] == nil || obj["model"] is NSNull else { return data }
        obj["model"] = ""
        guard let patched = try? JSONSerialization.data(withJSONObject: obj) else { return data }
        return patched
    }

    /// Resolve the sampling values the `/agents/{id}/run` loop should use.
    /// The request body wins when present; the agent's configured value
    /// (`effectiveTemperature` / `effectiveMaxTokens`) is the fallback before
    /// the model-bundle default, matching the in-app Chat and plugin-host
    /// surfaces. A `nil` result means "no explicit value" — the engine then
    /// applies the bundle default.
    @MainActor
    static func resolveAgentSampling(
        request: ChatCompletionRequest,
        agentId: UUID
    ) -> (temperature: Float?, maxTokens: Int?) {
        let manager = AgentManager.shared
        return (
            request.temperature.map(Float.init) ?? manager.effectiveTemperature(for: agentId).map(Float.init),
            request.max_tokens ?? manager.effectiveMaxTokens(for: agentId)
        )
    }

    /// `/agents/{id}/run` may accept caller-defined function schemas, but a
    /// client schema must never revive or impersonate a registered Osaurus
    /// tool that the agent composer withheld. Registered tools come only from
    /// `agentTools`; unregistered caller functions are added after them.
    /// (Upstream also sorts the union into its canonical order for KV-cache
    /// reuse; Intel's composer has no canonical order, so the agent's order
    /// is kept.)
    static func mergeAgentContextTools(
        _ agentTools: [Tool],
        clientTools: [Tool]?
    ) async -> [Tool]? {
        let clientTools = clientTools ?? []
        guard !agentTools.isEmpty || !clientTools.isEmpty else { return nil }
        let registeredNames = await MainActor.run {
            Set(ToolRegistry.shared.listTools().map(\.name))
        }
        let externalClientTools = clientTools.filter {
            !registeredNames.contains($0.function.name)
        }
        return agentTools + externalClientTools
    }

    /// The agent's composed request (upstream `enrichWithAgentContext`): its
    /// system prompt ahead of any caller system message, memory beside the
    /// last user turn, and the agent's tools plus the caller's own functions.
    /// Upstream replays earlier memory prefixes for a `session_id`
    /// (`SessionToolStateStore`, not compiled on Intel); Intel injects memory
    /// on the latest message only, as upstream does without a session id.
    static func enrichWithAgentContext(
        _ request: ChatCompletionRequest,
        agentId: UUID,
        executionMode: ExecutionMode,
        modelOverride: String?
    ) async -> (messages: [ChatMessage], tools: [Tool]?, toolChoice: ToolChoiceOption?) {
        var messages = request.messages
        let query = request.messages.last(where: { $0.role == "user" })?.content ?? ""
        let composed = await SystemPromptComposer.composeChatContext(
            agentId: agentId,
            executionMode: executionMode,
            model: modelOverride,
            query: query,
            messages: messages,
            toolsDisabled: false
        )
        if !composed.prompt.isEmpty {
            SystemPromptComposer.injectSystemContent(composed.prompt, into: &messages)
        }
        SystemPromptComposer.injectMemoryPrefix(composed.memorySection, into: &messages)
        let mergedTools = await mergeAgentContextTools(composed.tools, clientTools: request.tools)
        let toolChoice: ToolChoiceOption? = {
            guard let mergedTools, !mergedTools.isEmpty else { return request.tool_choice }
            return request.tool_choice ?? .auto
        }()
        return (messages, mergedTools, toolChoice)
    }

    /// Upstream's iteration-cap notice, streamed as the run's last words.
    static func toolLoopBudgetNotice(_ maxIterations: Int) -> String {
        "Tool-loop budget of \(maxIterations) iterations exhausted without a final answer."
    }

    /// The text a successful `complete` / `clarify` call leaves as the run's
    /// answer (upstream `interceptAware`); `nil` for any other tool.
    static func interceptText(toolName: String, arguments: String) -> String? {
        switch toolName {
        case "complete": return CompleteTool.parseSummary(from: arguments) ?? "Task completed."
        case "clarify": return ClarifyTool.parse(argumentsJSON: arguments)?.question
        default: return nil
        }
    }

    // MARK: - GET /runs/{id}/events, POST /runs/{id}/stop

    /// Rejoin a phone run (upstream §6.4). Owner-only. Intel has no detached
    /// runs until the phone's Secure Channel (`W-identity-mobile`), so every
    /// id is unknown.
    private func serveRunEvents(context: ChannelHandlerContext, path: String) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        sendResponse(context: context, status: .notFound, headers: jsonHeaders(), body: #"{"error":"run_not_found"}"#)
    }

    /// The phone's Stop for a detached run (upstream). Owner-only, Secure
    /// Channel for a remote owner; no detached runs on Intel yet.
    private func serveRunStop(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        if requiresOwnerChannel(head: head, context: context) { return }
        sendResponse(context: context, status: .notFound, headers: jsonHeaders(), body: #"{"error":"run_not_found"}"#)
    }

    // MARK: - POST /agents/{id}/run

    /// Run the full agent chat loop server-side and stream it back as OpenAI
    /// chunks. Tool calls run on this Mac; the caller sees the tool trace,
    /// never a `tool_calls` delta.
    private func serveAgentRun(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) {
        // Hard-require end-to-end encryption for remote agent runs (upstream).
        if sendSecureChannelUpgradeRequiredIfNeeded(context: context) { return }

        let data = requestBodyData()
        let requestBodyString: String? = data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
        guard
            let req = try? JSONDecoder().decode(
                ChatCompletionRequest.self, from: Self.injectingEmptyModelIfMissing(data))
        else {
            sendResponse(
                context: context, status: .badRequest,
                headers: [("Content-Type", "text/plain; charset=utf-8")], body: "Invalid request format")
            return
        }

        // `default`, a UUID, or the agent's address (upstream).
        let components = path.split(separator: "/")
        let identifier = components.count >= 2 ? components[1] : ""
        let agentId: UUID? =
            identifier.lowercased() == "default" ? Agent.defaultId : Self.resolveAgentId(identifier)
        guard components.count >= 2, let agentId else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(),
                body: #"{"error":"invalid_agent_id","message":"Invalid agent UUID in path"}"#)
            return
        }

        // The built-in agent runs for the owner only (upstream).
        let ownerRun = callerOwnsThisMac(context)
        if !ownerRun, let rejection = Agent.rejectBuiltInForExternalSurface(agentId, source: "http/agents/run") {
            sendResponse(
                context: context, status: .forbidden, headers: jsonHeaders(),
                body: Self.jsonObjectString(["error": rejection.code, "message": rejection.message]))
            return
        }
        // Confine agent-scoped keys to their own agent.
        if let rejection = agentScopeRejection(forAgentId: agentId) {
            sendResponse(
                context: context, status: .forbidden, headers: jsonHeaders(),
                body: Self.jsonObjectString(["error": rejection.code, "message": rejection.message]))
            return
        }

        // Full tool detail (arguments, results, labels) only for callers that
        // own this Mac; everyone else gets the sanitized trace.
        let includeToolDetail = isLoopbackConnection(context) || stateRef.value.authedScopeIsMaster
        // The owner's paired phone: owner scope AND the Secure Channel it
        // always speaks (upstream). Only this caller gets cards relayed
        // (`/approvals`, `/config/approvals`, `/secrets/prompts`); a bare
        // loopback script is still owner but has no one polling for cards,
        // so it keeps failing closed. Always false on Intel until
        // `W-identity-mobile` brings the channel.
        let remoteReviewer = stateRef.value.authedScopeIsMaster && requestIsSecureChannel
        let startTime = stateRef.value.requestStartedAt ?? Date()
        let userAgent = head.headers.first(name: "User-Agent")
        let includeUsage = req.stream_options?.include_usage == true
        stateRef.value.routeLogsItself = true
        stateRef.value.isStreaming = true
        let created = Int(Date().timeIntervalSince1970)
        let responseId = Self.shortId(prefix: "chatcmpl-", length: 12)
        let eventLoop = context.eventLoop
        let stateRef = self.stateRef
        let engine = makeInferenceEngine()
        let writer = SSEResponseWriter()
        writer.writeHeaders(context, extraHeaders: stateRef.value.corsHeaders)
        let onLoop: @Sendable (@escaping @Sendable (ChannelHandlerContext) -> Void) -> Void = { body in
            eventLoop.execute {
                guard let ctx = stateRef.value.contextBox else { return }
                body(ctx)
            }
        }

        func log(model: String?, response: String, toolCalls: [ToolCallLog], error: String?) {
            logRequest(
                method: "POST", path: path, userAgent: userAgent, requestBody: requestBodyString,
                responseBody: response.isEmpty ? nil : response, responseStatus: 200, startTime: startTime,
                model: model, finishReason: error == nil ? .stop : .error, errorMessage: error,
                toolCalls: toolCalls.isEmpty ? nil : toolCalls)
        }

        let task = runRequestTask {
            // SSE keepalive (upstream): a run can sit silent through long
            // tool calls.
            let keepalive = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    if Task.isCancelled { break }
                    onLoop { writer.writePing($0) }
                }
            }
            defer { keepalive.cancel() }
            // The app's "generating" signal for HTTP inference (upstream).
            await MainActor.run { ServerController.signalGenerationStart() }
            defer { Task { @MainActor in ServerController.signalGenerationEnd() } }

            // An omitted or "default" model is the agent's own (upstream).
            let requested = req.model ?? ""
            let model: String
            if requested.isEmpty || requested == "default" {
                model = await MainActor.run { AgentManager.shared.effectiveModel(for: agentId) } ?? ""
            } else {
                model = requested
            }
            if model.isEmpty {
                let message =
                    "This agent has no model configured. Set the agent's default model on the host and try again."
                onLoop { ctx in
                    writer.writeError(message, context: ctx)
                    writer.writeEnd(ctx)
                }
                log(model: nil, response: "", toolCalls: [], error: message)
                return
            }

            let executionMode: ExecutionMode = await MainActor.run {
                ToolRegistry.shared.resolveExecutionMode(
                    folderContext: nil,
                    autonomousEnabled: AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true)
            }
            let enriched = await Self.enrichWithAgentContext(
                req, agentId: agentId, executionMode: executionMode, modelOverride: model)
            let (temperature, maxTokens) = await MainActor.run {
                Self.resolveAgentSampling(request: req, agentId: agentId)
            }
            let maxIterations = await MainActor.run {
                max(1, min(ChatConfigurationStore.load().maxToolAttempts ?? 30, 120))
            }
            let requestId = UUID().uuidString
            let sessionKey = req.session_id ?? requestId
            var engineRequest = ChatCompletionRequest(
                model: model,
                messages: enriched.messages,
                temperature: temperature.map(Double.init),
                max_tokens: maxTokens,
                stream: true,
                top_p: req.top_p,
                frequency_penalty: req.frequency_penalty,
                presence_penalty: req.presence_penalty,
                stop: req.stop,
                n: nil,
                tools: enriched.tools,
                tool_choice: enriched.toolChoice,
                session_id: sessionKey
            )
            engineRequest.samplingParametersAreImplicit = req.temperature == nil
            engineRequest.reportsUsage = true
            engineRequest.reportsToolStarts = true
            engineRequest.maxToolRounds = maxIterations

            onLoop { writer.writeRole("assistant", model: model, responseId: responseId, created: created, context: $0) }

            var loggedResponseText = ""
            var loggedToolCalls: [ToolCallLog] = []
            var usage: (prompt: Int, completion: Int)?
            var finalIntercept: String?
            let timer = AgentToolTraceTimer()
            do {
                do {
                    // Every tool call of a run is an external-surface call
                    // (upstream binds it around the batch executor), so Ask
                    // tools are refused rather than shown as a card, unless
                    // the owner's paired phone can answer it.
                    let stream = try await ChatExecutionContext.$isExternalSurface.withValue(true) {
                        try await ChatExecutionContext.$hasRemoteReviewer.withValue(remoteReviewer) {
                        try await ChatExecutionContext.$currentAgentId.withValue(agentId) {
                            try await ChatExecutionContext.$currentSessionId.withValue(sessionKey) {
                                try await ChatExecutionContext.$agentTodoRunScope.withValue(AgentTodoRunScope()) {
                                    try await ChatExecutionContext.$currentExecutionMode.withValue(executionMode) {
                                        try await engine.streamChat(request: engineRequest)
                                    }
                                }
                            }
                        }
                        }
                    }
                    for try await delta in stream {
                        try Task.checkCancellation()
                        if let started = StreamingToolHint.decodeStarted(delta) {
                            let detail: AgentToolTraceDetail? =
                                includeToolDetail
                                ? {
                                    timer.start(started.callId)
                                    return .started(toolName: started.name, arguments: started.arguments)
                                }() : nil
                            onLoop {
                                writer.writeAgentToolTrace(
                                    phase: "started", toolName: started.name, callId: started.callId,
                                    detail: detail, model: model, responseId: responseId, created: created,
                                    context: $0)
                            }
                            continue
                        }
                        if let done = StreamingToolHint.decodeDone(delta) {
                            let isError = ToolEnvelope.isError(done.result) || done.result.hasPrefix("⛔️")
                            let endRun = AgentLoopRunEnd.endsRun(toolName: done.name, result: done.result)
                            if endRun {
                                finalIntercept = Self.interceptText(toolName: done.name, arguments: done.arguments)
                            }
                            let detail: AgentToolTraceDetail? =
                                includeToolDetail
                                ? .completed(
                                    toolName: done.name, arguments: done.arguments, result: done.result,
                                    isError: isError, duration: timer.finish(done.callId))
                                : nil
                            onLoop {
                                writer.writeAgentToolTrace(
                                    phase: "completed", toolName: done.name, callId: done.callId,
                                    isError: isError, endRun: endRun, detail: detail, model: model,
                                    responseId: responseId, created: created, context: $0)
                            }
                            loggedToolCalls.append(
                                ToolCallLog(
                                    name: done.name, arguments: done.arguments, result: done.result,
                                    isError: isError))
                            continue
                        }
                        switch IntelHTTPInference.classify(delta) {
                        case .content(let text):
                            loggedResponseText += text
                            onLoop {
                                writer.writeContent(text, model: model, responseId: responseId, created: created, context: $0)
                            }
                        case .reasoning(let text):
                            onLoop {
                                writer.writeReasoning(
                                    text, model: model, responseId: responseId, created: created, context: $0)
                            }
                        case .usage(let prompt, let completion):
                            usage = (prompt, completion)
                        case .toolCalls, .stats, nil:
                            break
                        }
                    }
                } catch is ChatEngine.ToolRoundLimitReached {
                    // Upstream ends a capped run with a notice, not an error.
                    let notice = Self.toolLoopBudgetNotice(maxIterations)
                    loggedResponseText += notice
                    onLoop {
                        writer.writeContent(notice, model: model, responseId: responseId, created: created, context: $0)
                    }
                }
                // A successful `complete` / `clarify` ended the run: its
                // summary or question is the answer (upstream).
                if let text = finalIntercept, !text.isEmpty {
                    loggedResponseText += text
                    onLoop {
                        writer.writeContent(text, model: model, responseId: responseId, created: created, context: $0)
                    }
                }
                let finalUsage = usage
                onLoop { ctx in
                    writer.writeFinishWithReason("stop", model: model, responseId: responseId, created: created, context: ctx)
                    if includeUsage, let finalUsage {
                        writer.writeUsageChunk(
                            promptTokens: finalUsage.prompt, completionTokens: finalUsage.completion,
                            model: model, responseId: responseId, created: created, context: ctx)
                    }
                    writer.writeEnd(ctx)
                }
                log(model: model, response: loggedResponseText, toolCalls: loggedToolCalls, error: nil)
            } catch {
                // The 200 head is out: the failure is an in-band error chunk.
                onLoop { ctx in
                    writer.writeErrorFromThrown(error, context: ctx)
                    writer.writeEnd(ctx)
                }
                log(model: model, response: loggedResponseText, toolCalls: loggedToolCalls, error: error.localizedDescription)
            }
        }
        // Closing the connection stops the run (upstream, for runs that are
        // not detached).
        context.channel.closeFuture.whenComplete { _ in task.cancel() }
    }
}
