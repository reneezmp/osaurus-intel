//
//  IntelHTTPAnthropic.swift
//  osaurus
//
//  Anthropic Messages API (`POST /messages`) on Intel's engine
//  (`W-server-api` stage 2c, docs/SERVER_API_INTEL.md). Upstream's request
//  conversion (`AnthropicAPI.swift`), response body and SSE events; one model
//  round through `IntelHTTPInference`.
//
//  Upstream requires the provider's measured input and output token counts
//  (Anthropic clients read them), and holds the stream until the input count
//  is known. Intel's engine reports usage once, at the end
//  (`StreamingUsageHint`), so the events are written together when the
//  round finishes; a provider that reports no usage gets upstream's error.
//

import Foundation
import IkigaJSON
import NIOCore
import NIOHTTP1

extension HTTPHandler {
    /// Upstream's mapping, minus the MLX runtime errors Intel never throws.
    static func anthropicErrorType(for error: Error) -> String {
        if error is CancellationError { return "request_cancelled" }
        if (error as NSError).domain == "OsaurusToolChoice" { return "invalid_request_error" }
        if let engineError = error as? ChatEngine.EngineError, engineError.isUnknownModel {
            return "not_found_error"
        }
        return "api_error"
    }

    static let anthropicUsageMissingMessage =
        "Anthropic compatibility requires reported input and output token counts; this model or provider did not report them."

    static func anthropicStopReason(_ collected: IntelHTTPInference.Collected) -> String {
        switch collected.finishReason {
        case .length: return "max_tokens"
        case .toolCalls: return "tool_use"
        default: return "end_turn"
        }
    }

    /// Upstream's non-streaming `AnthropicMessagesResponse`.
    static func anthropicMessageBody(
        _ collected: IntelHTTPInference.Collected, messageId: String, model: String
    ) throws -> String {
        guard let usage = collected.usage else {
            throw NSError(
                domain: "OsaurusProtocolUsage", code: 502,
                userInfo: [NSLocalizedDescriptionKey: anthropicUsageMissingMessage])
        }
        var blocks: [AnthropicResponseContentBlock] = []
        if !collected.reasoning.isEmpty { blocks.append(.thinking(.init(thinking: collected.reasoning))) }
        if !collected.content.isEmpty { blocks.append(.textBlock(collected.content)) }
        for call in collected.toolCalls {
            guard let data = call.arguments.data(using: .utf8),
                let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw NSError(
                    domain: "OsaurusToolArguments", code: 422,
                    userInfo: [NSLocalizedDescriptionKey: "The model returned non-object arguments for '\(call.name)'."])
            }
            blocks.append(
                .toolUseBlock(
                    id: call.callId.isEmpty ? shortId(prefix: "toolu_") : call.callId, name: call.name,
                    input: arguments.mapValues { AnyCodableValue($0) }))
        }
        if blocks.isEmpty { blocks.append(.textBlock("")) }
        let response = AnthropicMessagesResponse(
            id: messageId, model: model, content: blocks, stopReason: anthropicStopReason(collected),
            usage: AnthropicUsage(promptTokens: usage.prompt, outputTokens: usage.completion, cachedPromptTokens: nil))
        return String(decoding: try JSONEncoder.osaurusCanonical().encode(response), as: UTF8.self)
    }

    func serveAnthropicMessages(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let data = requestBodyData()
        let requestBodyString = String(decoding: data, as: UTF8.self)
        let startTime = stateRef.value.requestStartedAt ?? Date()
        let userAgent = head.headers.first(name: "User-Agent")

        func reject(_ message: String) {
            let body = Self.errorBody(.anthropic(errorType: "invalid_request_error"), message: message)
            sendResponse(context: context, status: .badRequest, headers: jsonHeaders(), body: body)
        }
        guard let anthropicReq = try? JSONDecoder().decode(AnthropicMessagesRequest.self, from: data) else {
            reject("Invalid request format")
            return
        }
        let request: ChatCompletionRequest
        do {
            request = try anthropicReq.toValidatedChatCompletionRequest()
        } catch {
            reject(error.localizedDescription)
            return
        }

        stateRef.value.routeLogsItself = true
        let messageId = Self.shortId(prefix: "msg_")
        let model = anthropicReq.model
        let engine = makeInferenceEngine()
        let eventLoop = context.eventLoop
        let stateRef = self.stateRef
        let cors = stateRef.value.corsHeaders

        func log(status: Int, body: String?, finish: RequestLog.FinishReason?, error: String?) {
            logRequest(
                method: "POST", path: "/messages", userAgent: userAgent, requestBody: requestBodyString,
                responseBody: body, responseStatus: status, startTime: startTime, model: model,
                finishReason: finish, errorMessage: error)
        }

        guard anthropicReq.stream ?? false else {
            runRequestTask {
                do {
                    let collected = try await IntelHTTPInference.collect(engine: engine, request: request)
                    let body = try Self.anthropicMessageBody(collected, messageId: messageId, model: model)
                    self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: body)
                    log(status: 200, body: body, finish: collected.finishReason, error: nil)
                } catch {
                    let status = (error as NSError).domain == "OsaurusProtocolUsage"
                        ? HTTPResponseStatus.badGateway : Self.inferenceHTTPStatus(for: error).status
                    let body = Self.errorBody(
                        .anthropic(errorType: Self.anthropicErrorType(for: error)), message: error.localizedDescription)
                    self.respondOnLoop(eventLoop, status: status, headers: self.jsonHeaders(), body: body)
                    log(status: Int(status.code), body: body, finish: .error, error: error.localizedDescription)
                }
            }
            return
        }

        stateRef.value.isStreaming = true
        let writer = AnthropicSSEResponseWriter()
        writer.writeHeaders(context, extraHeaders: cors)
        writer.writeMessageStart(messageId: messageId, model: model, inputTokens: nil, context: context, deferUntilInput: true)
        let onLoop: @Sendable (@escaping @Sendable (ChannelHandlerContext) -> Void) -> Void = { body in
            eventLoop.execute {
                guard let ctx = stateRef.value.contextBox else { return }
                body(ctx)
            }
        }
        let task = runRequestTask {
            do {
                var collected = IntelHTTPInference.Collected()
                var ordered: [IntelInferenceEvent] = []
                for try await event in try await IntelHTTPInference.events(engine: engine, request: request) {
                    try Task.checkCancellation()
                    collected.consume(event)
                    if case .content = event { ordered.append(event) }
                    if case .reasoning = event { ordered.append(event) }
                }
                guard let usage = collected.usage else {
                    throw NSError(
                        domain: "OsaurusProtocolUsage", code: 502,
                        userInfo: [NSLocalizedDescriptionKey: Self.anthropicUsageMissingMessage])
                }
                let finished = collected
                let events = ordered
                onLoop { ctx in
                    writer.setInputTokens(usage.prompt, context: ctx)
                    for event in events {
                        switch event {
                        case .content(let text): writer.writeTextDelta(text, context: ctx)
                        case .reasoning(let text): writer.writeThinkingDelta(text, context: ctx)
                        default: break
                        }
                    }
                    writer.setOutputTokens(usage.completion)
                    for call in finished.toolCalls {
                        writer.writeToolUseBlockStart(
                            toolId: call.callId.isEmpty ? Self.shortId(prefix: "toolu_") : call.callId,
                            toolName: call.name, context: ctx)
                        var remaining = Substring(call.arguments)
                        while !remaining.isEmpty {
                            let chunk = remaining.prefix(512)
                            remaining = remaining.dropFirst(chunk.count)
                            writer.writeToolInputDelta(String(chunk), context: ctx)
                        }
                        writer.writeBlockStop(context: ctx)
                    }
                    writer.writeFinish(stopReason: Self.anthropicStopReason(finished), context: ctx)
                    writer.writeEnd(ctx)
                }
                log(status: 200, body: nil, finish: finished.finishReason, error: nil)
            } catch {
                onLoop { ctx in
                    writer.writeErrorFromThrown(error, context: ctx)
                    writer.writeEnd(ctx)
                }
                log(status: 200, body: nil, finish: .error, error: error.localizedDescription)
            }
        }
        context.channel.closeFuture.whenComplete { _ in task.cancel() }
    }
}

// MARK: - Anthropic SSE writer (upstream)

/// Upstream's `AnthropicSSEResponseWriter`, minus the provider-signed
/// thinking blocks (Intel's engine doesn't surface them) and the Privacy
/// Filter error (`W-privacy-filter`). Stateful: used only on the event loop.
final class AnthropicSSEResponseWriter: @unchecked Sendable {
    private var messageId: String = ""
    private var model: String = ""
    private var inputTokens: Int?
    private var messageStartConfigured = false
    private var hasStartedMessage = false
    private var outputTokens: Int?
    private var cachedInputTokens: Int?
    private var currentBlockIndex: Int = 0
    private var hasStartedTextBlock: Bool = false
    private var hasStartedThinkingBlock: Bool = false

    func writeHeaders(_ context: ChannelHandlerContext, extraHeaders: [(String, String)]? = nil) {
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache, no-transform")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "X-Accel-Buffering", value: "no")
        headers.add(name: "Transfer-Encoding", value: "chunked")
        for (n, v) in extraHeaders ?? [] { headers.add(name: n, value: v) }
        head.headers = headers
        context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        context.flush()
    }

    func writeMessageStart(
        messageId: String,
        model: String,
        inputTokens: Int?,
        context: ChannelHandlerContext,
        deferUntilInput: Bool = false
    ) {
        self.messageId = messageId
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = nil
        self.cachedInputTokens = nil
        self.currentBlockIndex = 0
        self.hasStartedTextBlock = false
        self.hasStartedThinkingBlock = false
        messageStartConfigured = true
        hasStartedMessage = false
        if !deferUntilInput { ensureMessageStart(context: context) }
    }

    func setInputTokens(_ count: Int, context: ChannelHandlerContext) {
        inputTokens = max(0, count)
        ensureMessageStart(context: context)
    }

    private func ensureMessageStart(context: ChannelHandlerContext) {
        guard messageStartConfigured, !hasStartedMessage, let inputTokens else { return }
        hasStartedMessage = true
        let event = MessageStartEvent(id: messageId, model: model, inputTokens: inputTokens)
        writeSSEEvent("message_start", payload: event, context: context)
    }

    func writeTextBlockStart(context: ChannelHandlerContext) {
        guard !hasStartedTextBlock else { return }
        hasStartedTextBlock = true
        let event = ContentBlockStartEvent(index: currentBlockIndex, textBlock: true)
        writeSSEEvent("content_block_start", payload: event, context: context)
    }

    func writeTextDelta(_ text: String, context: ChannelHandlerContext) {
        guard !text.isEmpty else { return }
        if hasStartedThinkingBlock { writeBlockStop(context: context) }
        if !hasStartedTextBlock { writeTextBlockStart(context: context) }
        let event = ContentBlockDeltaEvent(index: currentBlockIndex, text: text)
        writeSSEEvent("content_block_delta", payload: event, context: context)
    }

    func writeBlockStop(context: ChannelHandlerContext) {
        let event = ContentBlockStopEvent(index: currentBlockIndex)
        writeSSEEvent("content_block_stop", payload: event, context: context)
        currentBlockIndex += 1
        hasStartedTextBlock = false
        hasStartedThinkingBlock = false
    }

    func writeThinkingBlockStart(context: ChannelHandlerContext) {
        guard !hasStartedThinkingBlock else { return }
        if hasStartedTextBlock { writeBlockStop(context: context) }
        hasStartedThinkingBlock = true
        let event = ContentBlockStartEvent(thinkingBlockAt: currentBlockIndex)
        writeSSEEvent("content_block_start", payload: event, context: context)
    }

    func writeThinkingDelta(_ thinking: String, context: ChannelHandlerContext) {
        guard !thinking.isEmpty else { return }
        if !hasStartedThinkingBlock { writeThinkingBlockStart(context: context) }
        let event = ContentBlockDeltaEvent(thinkingAt: currentBlockIndex, text: thinking)
        writeSSEEvent("content_block_delta", payload: event, context: context)
    }

    func setOutputTokens(_ tokenCount: Int) {
        outputTokens = max(0, tokenCount)
    }

    func writeToolUseBlockStart(toolId: String, toolName: String, context: ChannelHandlerContext) {
        if hasStartedTextBlock || hasStartedThinkingBlock { writeBlockStop(context: context) }
        let event = ContentBlockStartEvent(index: currentBlockIndex, toolId: toolId, toolName: toolName)
        writeSSEEvent("content_block_start", payload: event, context: context)
    }

    func writeToolInputDelta(_ partialJson: String, context: ChannelHandlerContext) {
        guard !partialJson.isEmpty else { return }
        let event = ContentBlockDeltaEvent(index: currentBlockIndex, partialJson: partialJson)
        writeSSEEvent("content_block_delta", payload: event, context: context)
    }

    func writeMessageDelta(stopReason: String, context: ChannelHandlerContext) {
        guard let inputTokens, let outputTokens else {
            writeError(HTTPHandler.anthropicUsageMissingMessage, context: context)
            return
        }
        let split = AnthropicUsage.split(promptTokens: inputTokens, cachedPromptTokens: cachedInputTokens)
        let event = MessageDeltaEvent(
            stopReason: stopReason, outputTokens: outputTokens, inputTokens: split.input,
            cacheReadInputTokens: split.cacheRead)
        writeSSEEvent("message_delta", payload: event, context: context)
    }

    func writeMessageStop(context: ChannelHandlerContext) {
        writeSSEEvent("message_stop", payload: MessageStopEvent(), context: context)
    }

    func writeError(_ message: String, context: ChannelHandlerContext) {
        writeAnthropicError(message: message, errorType: "api_error", context: context)
    }

    func writeErrorFromThrown(_ error: Error, context: ChannelHandlerContext) {
        writeAnthropicError(
            message: error.localizedDescription, errorType: HTTPHandler.anthropicErrorType(for: error),
            context: context)
    }

    private func writeAnthropicError(message: String, errorType: String, context: ChannelHandlerContext) {
        let error = AnthropicError(message: message, errorType: errorType)
        let encoder = IkigaJSONEncoder()
        var buffer = context.channel.allocator.buffer(capacity: 256)
        buffer.writeString("event: error\ndata: ")
        do {
            try encoder.encodeAndWrite(error, into: &buffer)
            buffer.writeString("\n\n")
        } catch {
            buffer.clear()
            buffer.writeString("event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"")
            buffer.writeString(errorType)
            buffer.writeString("\",\"message\":\"")
            buffer.writeString(message)
            buffer.writeString("\"}}\n\n")
        }
        context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        context.flush()
    }

    func writeFinish(stopReason: String, context: ChannelHandlerContext) {
        guard inputTokens != nil, outputTokens != nil else {
            writeError(HTTPHandler.anthropicUsageMissingMessage, context: context)
            return
        }
        if hasStartedTextBlock || hasStartedThinkingBlock { writeBlockStop(context: context) }
        writeMessageDelta(stopReason: stopReason, context: context)
        writeMessageStop(context: context)
    }

    func writeEnd(_ context: ChannelHandlerContext) {
        let ctx = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
            ctx.value.close(promise: nil)
        }
    }

    private func writeSSEEvent<T: Encodable>(_ eventType: String, payload: T, context: ChannelHandlerContext) {
        if eventType != "message_start", eventType != "error" { ensureMessageStart(context: context) }
        let encoder = IkigaJSONEncoder()
        var buffer = context.channel.allocator.buffer(capacity: 256)
        buffer.writeString("event: ")
        buffer.writeString(eventType)
        buffer.writeString("\ndata: ")
        do {
            try encoder.encodeAndWrite(payload, into: &buffer)
            buffer.writeString("\n\n")
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.flush()
        } catch {
            print("Error encoding Anthropic SSE event: \(error)")
            context.close(promise: nil)
        }
    }
}
