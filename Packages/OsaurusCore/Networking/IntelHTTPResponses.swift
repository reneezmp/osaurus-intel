//
//  IntelHTTPResponses.swift
//  osaurus
//
//  OpenAI Responses API (`POST /responses`) on Intel's engine (`W-server-api`
//  stage 2e, docs/SERVER_API_INTEL.md). Upstream's wire types
//  (`OpenResponsesAPI.swift`, trimmed), its Chat Completions projection,
//  `previous_response_id` continuation and the portable half of its
//  `OpenResponsesSSEWriter`; one model round through `IntelHTTPInference`.
//
//  Left out: upstream's native provider-event proxy (its Responses engine
//  forwards a provider's own Responses events), local prefill progress, and
//  structured `text.format` output, which Intel's request can't carry yet
//  and the route therefore refuses instead of ignoring.
//

import Foundation
import IkigaJSON
import NIOCore
import NIOHTTP1

/// `previous_response_id` transcripts (upstream `OpenResponsesContextStore`):
/// the last 128 responses, each tied to its model.
final class OpenResponsesContextStore: @unchecked Sendable {
    private struct Entry {
        let model: String
        let messages: [ChatMessage]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    private let maxEntries = 128

    func transcript(for responseId: String?, model: String) throws -> [ChatMessage] {
        guard let responseId, !responseId.isEmpty else { return [] }
        return try lock.withLock {
            guard let entry = entries[responseId], entry.model == model else {
                throw NSError(
                    domain: "OsaurusResponsesContext", code: 404,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The previous response is unavailable for this model. Send the complete input history to continue."
                    ])
            }
            return entry.messages
        }
    }

    func store(responseId: String, model: String, messages: [ChatMessage]) {
        guard !responseId.isEmpty, !messages.isEmpty else { return }
        lock.withLock {
            if entries[responseId] == nil { insertionOrder.append(responseId) }
            entries[responseId] = Entry(model: model, messages: messages)
            while insertionOrder.count > maxEntries {
                entries.removeValue(forKey: insertionOrder.removeFirst())
            }
        }
    }
}

extension HTTPHandler {
    static let openResponsesContextStore = OpenResponsesContextStore()

    /// Upstream: earlier turns go after the current system lines and before
    /// the current input; per-request instructions don't carry over.
    static func applyOpenResponsesContext(
        to request: ChatCompletionRequest, previousResponseId: String?
    ) throws -> ChatCompletionRequest {
        let model = request.model ?? ""
        let previous = try openResponsesContextStore.transcript(for: previousResponseId, model: model)
        guard !previous.isEmpty else { return request }
        let system = request.messages.filter { $0.role.lowercased() == "system" }
        let rest = request.messages.filter { $0.role.lowercased() != "system" }
        var copy = ChatCompletionRequest(
            model: request.model, messages: system + previous + rest, temperature: request.temperature,
            max_tokens: request.max_tokens, stream: request.stream, top_p: request.top_p,
            stop: request.stop, tools: request.tools, tool_choice: request.tool_choice,
            session_id: request.session_id)
        copy.stream_options = request.stream_options
        return copy
    }

    static func storeOpenResponsesContext(
        responseId: String, model: String, request: ChatCompletionRequest,
        assistant: ChatMessage, perRequestInstructions: String?
    ) {
        var input = request.messages
        if let perRequestInstructions, input.first?.role == "system", input.first?.content == perRequestInstructions {
            input.removeFirst()
        }
        openResponsesContextStore.store(responseId: responseId, model: model, messages: input + [assistant])
    }

    /// Upstream's mapping, minus the MLX runtime errors Intel never throws.
    static func openResponsesErrorCode(for error: Error) -> String {
        if error is CancellationError { return "request_cancelled" }
        if (error as NSError).domain == "OsaurusToolChoice" { return "invalid_request_error" }
        if let engineError = error as? ChatEngine.EngineError, engineError.isUnknownModel { return "model_not_found" }
        return "api_error"
    }

    /// The assistant message a finished round adds to the conversation.
    static func assistantMessage(_ collected: IntelHTTPInference.Collected) -> ChatMessage {
        let calls = collected.toolCalls.map {
            ToolCall(
                id: IntelHTTPInference.callId($0), type: "function",
                function: ToolCallFunction(name: $0.name, arguments: $0.arguments))
        }
        return ChatMessage(
            role: "assistant", content: collected.content.isEmpty ? nil : collected.content,
            tool_calls: calls.isEmpty ? nil : calls, tool_call_id: nil,
            reasoning_content: collected.reasoning.isEmpty ? nil : collected.reasoning)
    }

    /// Upstream's non-streaming `response` object for one round.
    static func openResponsesBody(
        _ collected: IntelHTTPInference.Collected, responseId: String, model: String, createdAt: Int,
        metadata: [String: String]?
    ) -> OpenResponsesResponse {
        let incomplete = collected.finishReason == .length
        let itemStatus: OpenResponsesItemStatus = incomplete ? .incomplete : .completed
        var output: [OpenResponsesOutputItem] = []
        if !collected.reasoning.isEmpty {
            output.append(
                .reasoning(
                    OpenResponsesReasoningItem(
                        id: "rs_" + responseId, status: itemStatus,
                        summary: [OpenResponsesReasoningSummaryText(text: collected.reasoning)])))
        }
        if !collected.content.isEmpty || collected.toolCalls.isEmpty {
            output.append(
                .message(
                    OpenResponsesOutputMessage(
                        id: "msg_" + responseId, status: itemStatus,
                        content: [.outputText(OpenResponsesOutputText(text: collected.content))])))
        }
        for call in collected.toolCalls {
            output.append(
                .functionCall(
                    OpenResponsesFunctionCall(
                        id: "fc_" + shortId(prefix: ""), status: itemStatus,
                        callId: IntelHTTPInference.callId(call), name: call.name, arguments: call.arguments)))
        }
        return OpenResponsesResponse(
            id: responseId, createdAt: createdAt, status: incomplete ? .incomplete : .completed, model: model,
            output: output,
            usage: collected.usage.map { OpenResponsesUsage(inputTokens: $0.prompt, outputTokens: $0.completion) },
            metadata: metadata, incompleteReason: incomplete ? "max_output_tokens" : nil)
    }

    func serveOpenResponses(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let data = requestBodyData()
        let requestBodyString = String(decoding: data, as: UTF8.self)
        let startTime = stateRef.value.requestStartedAt ?? Date()
        let userAgent = head.headers.first(name: "User-Agent")

        func reject(_ status: HTTPResponseStatus, _ message: String) {
            let response = OpenResponsesErrorResponse(code: "invalid_request_error", message: message)
            let body = (try? JSONEncoder.osaurusCanonical().encode(response)).map { String(decoding: $0, as: UTF8.self) }
                ?? "{}"
            sendResponse(context: context, status: status, headers: jsonHeaders(), body: body)
        }

        let openReq: OpenResponsesRequest
        do {
            openReq = try JSONDecoder().decode(OpenResponsesRequest.self, from: data)
        } catch {
            reject(.badRequest, "Invalid request format: \(error.localizedDescription)")
            return
        }
        if let format = openReq.text?.format, format.type != "text" {
            reject(.badRequest, "Structured output (text.format '\(format.type)') is not supported by this server yet.")
            return
        }
        let request: ChatCompletionRequest
        do {
            request = try Self.applyOpenResponsesContext(
                to: openReq.toChatCompletionRequest(), previousResponseId: openReq.previous_response_id)
        } catch {
            reject((error as NSError).domain == "OsaurusResponsesContext" ? .notFound : .badRequest, error.localizedDescription)
            return
        }

        stateRef.value.routeLogsItself = true
        let responseId = Self.shortId(prefix: "resp_")
        let model = openReq.model
        let createdAt = Int(Date().timeIntervalSince1970)
        let instructions = openReq.instructions
        let metadata = openReq.metadata
        let engine = makeInferenceEngine()
        let eventLoop = context.eventLoop
        let stateRef = self.stateRef
        let cors = stateRef.value.corsHeaders

        func log(status: Int, body: String?, finish: RequestLog.FinishReason?, error: String?) {
            logRequest(
                method: "POST", path: "/responses", userAgent: userAgent, requestBody: requestBodyString,
                responseBody: body, responseStatus: status, startTime: startTime, model: model,
                finishReason: finish, errorMessage: error)
        }

        guard openReq.stream ?? false else {
            runRequestTask {
                do {
                    let collected = try await IntelHTTPInference.collect(engine: engine, request: request)
                    let response = Self.openResponsesBody(
                        collected, responseId: responseId, model: model, createdAt: createdAt, metadata: metadata)
                    Self.storeOpenResponsesContext(
                        responseId: responseId, model: model, request: request,
                        assistant: Self.assistantMessage(collected), perRequestInstructions: instructions)
                    let body = String(decoding: try JSONEncoder.osaurusCanonical().encode(response), as: UTF8.self)
                    self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: body)
                    log(status: 200, body: body, finish: collected.finishReason, error: nil)
                } catch {
                    let status = Self.inferenceHTTPStatus(for: error).status
                    let response = OpenResponsesErrorResponse(
                        code: Self.openResponsesErrorCode(for: error), message: error.localizedDescription)
                    let body = (try? JSONEncoder.osaurusCanonical().encode(response)).map {
                        String(decoding: $0, as: UTF8.self)
                    } ?? "{}"
                    self.respondOnLoop(eventLoop, status: status, headers: self.jsonHeaders(), body: body)
                    log(status: Int(status.code), body: body, finish: .error, error: error.localizedDescription)
                }
            }
            return
        }

        stateRef.value.isStreaming = true
        let writer = OpenResponsesSSEWriter()
        writer.writeHeaders(context, extraHeaders: cors)
        writer.writeResponseCreated(responseId: responseId, model: model, context: context)
        writer.writeResponseInProgress(context: context)
        let onLoop: @Sendable (@escaping @Sendable (ChannelHandlerContext) -> Void) -> Void = { body in
            eventLoop.execute {
                guard let ctx = stateRef.value.contextBox else { return }
                body(ctx)
            }
        }
        let itemId = "msg_" + responseId
        let reasoningItemId = "rs_" + responseId
        let messageItemOpen = NSLockedValue(false)
        let task = runRequestTask {
            var collected = IntelHTTPInference.Collected()
            do {
                for try await event in try await IntelHTTPInference.events(engine: engine, request: request) {
                    try Task.checkCancellation()
                    collected.consume(event)
                    switch event {
                    case .content(let text):
                        onLoop { ctx in
                            writer.writeReasoningItemDone(context: ctx)
                            if !messageItemOpen.withLock({ $0 }) {
                                messageItemOpen.withLock { $0 = true }
                                writer.writeMessageItemAdded(itemId: itemId, context: ctx)
                                writer.writeContentPartAdded(context: ctx)
                            }
                            writer.writeTextDelta(text, context: ctx)
                        }
                    case .reasoning(let text):
                        onLoop { writer.writeReasoningDelta(text, itemId: reasoningItemId, context: $0) }
                    case .toolCalls, .stats, .usage:
                        break
                    }
                }
                let finished = collected
                Self.storeOpenResponsesContext(
                    responseId: responseId, model: model, request: request,
                    assistant: Self.assistantMessage(finished), perRequestInstructions: instructions)
                let incomplete = finished.finishReason == .length
                let itemStatus: OpenResponsesItemStatus = incomplete ? .incomplete : .completed
                onLoop { ctx in
                    writer.writeReasoningItemDone(status: itemStatus, context: ctx)
                    if messageItemOpen.withLock({ $0 }) {
                        writer.writeTextDone(context: ctx)
                        writer.writeMessageItemDone(status: itemStatus, context: ctx)
                    }
                    for call in finished.toolCalls {
                        let callId = IntelHTTPInference.callId(call)
                        writer.writeFunctionCallItemAdded(
                            itemId: "fc_" + Self.shortId(prefix: ""), callId: callId, name: call.name, context: ctx)
                        var remaining = Substring(call.arguments)
                        while !remaining.isEmpty {
                            let chunk = remaining.prefix(512)
                            remaining = remaining.dropFirst(chunk.count)
                            writer.writeFunctionCallArgumentsDelta(callId: callId, delta: String(chunk), context: ctx)
                        }
                        writer.writeFunctionCallArgumentsDone(callId: callId, context: ctx)
                        writer.writeFunctionCallItemDone(callId: callId, name: call.name, status: itemStatus, context: ctx)
                    }
                    if let usage = finished.usage {
                        writer.setInputTokens(usage.prompt)
                        writer.setOutputTokens(usage.completion)
                    }
                    writer.writeResponseTerminal(
                        status: incomplete ? .incomplete : .completed,
                        incompleteReason: incomplete ? "max_output_tokens" : nil,
                        metadata: metadata, context: ctx)
                    writer.writeEnd(ctx)
                }
                log(status: 200, body: nil, finish: finished.finishReason, error: nil)
            } catch {
                onLoop { ctx in
                    writer.writeErrorFromThrown(error, context: ctx)
                    writer.writeEnd(ctx)
                }
                log(status: 200, body: nil, finish: error is CancellationError ? .cancelled : .error,
                    error: error.localizedDescription)
            }
        }
        context.channel.closeFuture.whenComplete { _ in task.cancel() }
    }
}

// MARK: - Open Responses SSE writer (upstream, portable half)

/// Upstream's `OpenResponsesSSEWriter` without the native provider-event
/// proxy, prefill progress and Privacy Filter error. Stateful: used only on
/// the event loop.
final class OpenResponsesSSEWriter: @unchecked Sendable {
    private var responseId: String = ""
    private var model: String = ""
    private var createdAt: Int = 0
    private var inputTokens: Int?
    private var outputTokens: Int?
    private var completedOutput: [OpenResponsesOutputItem] = []
    private var completedOutputIDs: Set<String> = []
    private var sequenceNumber: Int = 0
    private var currentItemId: String = ""
    private var currentOutputIndex: Int = 0
    private var accumulatedText: String = ""
    private var reasoningItemId: String = ""
    private var reasoningOutputIndex: Int = 0
    private var reasoningSummaryIndex: Int = 0
    private var accumulatedReasoning: String = ""
    private var hasOpenReasoningItem: Bool = false

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

    private func nextSequenceNumber() -> Int {
        sequenceNumber += 1
        return sequenceNumber
    }

    func writeResponseCreated(responseId: String, model: String, context: ChannelHandlerContext) {
        self.responseId = responseId
        self.createdAt = Int(Date().timeIntervalSince1970)
        self.model = model
        let response = OpenResponsesResponse(
            id: responseId, createdAt: createdAt, status: .inProgress, model: model, output: [], usage: nil)
        writeSSEEvent(
            "response.created", payload: ResponseCreatedEvent(sequenceNumber: nextSequenceNumber(), response: response),
            context: context)
    }

    func writeResponseInProgress(context: ChannelHandlerContext) {
        let response = OpenResponsesResponse(
            id: responseId, createdAt: createdAt, status: .inProgress, model: model, output: [], usage: nil)
        writeSSEEvent(
            "response.in_progress",
            payload: ResponseInProgressEvent(sequenceNumber: nextSequenceNumber(), response: response), context: context)
    }

    func writeMessageItemAdded(itemId: String, context: ChannelHandlerContext) {
        currentItemId = itemId
        let event = OutputItemAddedEvent(
            sequenceNumber: nextSequenceNumber(), outputIndex: currentOutputIndex,
            item: .message(OpenResponsesOutputMessage(id: itemId, status: .inProgress, content: [])))
        writeSSEEvent("response.output_item.added", payload: event, context: context)
    }

    func writeContentPartAdded(context: ChannelHandlerContext) {
        let event = ContentPartAddedEvent(
            sequenceNumber: nextSequenceNumber(), itemId: currentItemId, outputIndex: currentOutputIndex,
            contentIndex: 0, part: .outputText(OpenResponsesOutputText(text: "")))
        writeSSEEvent("response.content_part.added", payload: event, context: context)
    }

    func writeReasoningItemAdded(itemId: String, context: ChannelHandlerContext) {
        guard !hasOpenReasoningItem else { return }
        reasoningItemId = itemId
        reasoningOutputIndex = currentOutputIndex
        reasoningSummaryIndex = 0
        accumulatedReasoning = ""
        hasOpenReasoningItem = true
        let event = OutputItemAddedEvent(
            sequenceNumber: nextSequenceNumber(), outputIndex: reasoningOutputIndex,
            item: .reasoning(OpenResponsesReasoningItem(id: itemId, status: .inProgress, summary: [])))
        writeSSEEvent("response.output_item.added", payload: event, context: context)
    }

    func writeReasoningDelta(_ text: String, itemId: String, context: ChannelHandlerContext) {
        guard !text.isEmpty else { return }
        if !hasOpenReasoningItem { writeReasoningItemAdded(itemId: itemId, context: context) }
        accumulatedReasoning += text
        let event = ReasoningSummaryTextDeltaEvent(
            sequenceNumber: nextSequenceNumber(), itemId: reasoningItemId, outputIndex: reasoningOutputIndex,
            summaryIndex: reasoningSummaryIndex, delta: text)
        writeSSEEvent("response.reasoning_summary_text.delta", payload: event, context: context)
    }

    func writeReasoningItemDone(status: OpenResponsesItemStatus = .completed, context: ChannelHandlerContext) {
        guard hasOpenReasoningItem else { return }
        let doneEvent = ReasoningSummaryTextDoneEvent(
            sequenceNumber: nextSequenceNumber(), itemId: reasoningItemId, outputIndex: reasoningOutputIndex,
            summaryIndex: reasoningSummaryIndex, text: accumulatedReasoning)
        writeSSEEvent("response.reasoning_summary_text.done", payload: doneEvent, context: context)
        let finalItem = OpenResponsesReasoningItem(
            id: reasoningItemId, status: status, summary: [OpenResponsesReasoningSummaryText(text: accumulatedReasoning)])
        let itemDone = OutputItemDoneEvent(
            sequenceNumber: nextSequenceNumber(), outputIndex: reasoningOutputIndex, item: .reasoning(finalItem))
        writeSSEEvent("response.output_item.done", payload: itemDone, context: context)
        if completedOutputIDs.insert(reasoningItemId).inserted { completedOutput.append(.reasoning(finalItem)) }
        hasOpenReasoningItem = false
        currentOutputIndex += 1
    }

    func writeTextDelta(_ text: String, context: ChannelHandlerContext) {
        guard !text.isEmpty else { return }
        accumulatedText += text
        let event = OutputTextDeltaEvent(
            sequenceNumber: nextSequenceNumber(), itemId: currentItemId, outputIndex: currentOutputIndex,
            contentIndex: 0, delta: text)
        writeSSEEvent("response.output_text.delta", payload: event, context: context)
    }

    func setInputTokens(_ count: Int) { inputTokens = max(0, count) }
    func setOutputTokens(_ tokenCount: Int) { outputTokens = max(0, tokenCount) }

    func writeTextDone(context: ChannelHandlerContext) {
        let event = OutputTextDoneEvent(
            sequenceNumber: nextSequenceNumber(), itemId: currentItemId, outputIndex: currentOutputIndex,
            contentIndex: 0, text: accumulatedText)
        writeSSEEvent("response.output_text.done", payload: event, context: context)
    }

    func writeMessageItemDone(status: OpenResponsesItemStatus = .completed, context: ChannelHandlerContext) {
        let messageItem = OpenResponsesOutputMessage(
            id: currentItemId, status: status, content: [.outputText(OpenResponsesOutputText(text: accumulatedText))])
        let event = OutputItemDoneEvent(
            sequenceNumber: nextSequenceNumber(), outputIndex: currentOutputIndex, item: .message(messageItem))
        writeSSEEvent("response.output_item.done", payload: event, context: context)
        if completedOutputIDs.insert(currentItemId).inserted { completedOutput.append(.message(messageItem)) }
        currentOutputIndex += 1
    }

    func writeFunctionCallItemAdded(itemId: String, callId: String, name: String, context: ChannelHandlerContext) {
        currentItemId = itemId
        accumulatedText = ""
        let functionCall = OpenResponsesFunctionCall(
            id: itemId, status: .inProgress, callId: callId, name: name, arguments: "")
        let event = OutputItemAddedEvent(
            sequenceNumber: nextSequenceNumber(), outputIndex: currentOutputIndex, item: .functionCall(functionCall))
        writeSSEEvent("response.output_item.added", payload: event, context: context)
    }

    func writeFunctionCallArgumentsDelta(callId: String, delta: String, context: ChannelHandlerContext) {
        guard !delta.isEmpty else { return }
        accumulatedText += delta
        let event = FunctionCallArgumentsDeltaEvent(
            sequenceNumber: nextSequenceNumber(), itemId: currentItemId, outputIndex: currentOutputIndex,
            callId: callId, delta: delta)
        writeSSEEvent("response.function_call_arguments.delta", payload: event, context: context)
    }

    func writeFunctionCallArgumentsDone(callId: String, context: ChannelHandlerContext) {
        let event = FunctionCallArgumentsDoneEvent(
            sequenceNumber: nextSequenceNumber(), itemId: currentItemId, outputIndex: currentOutputIndex,
            callId: callId, arguments: accumulatedText)
        writeSSEEvent("response.function_call_arguments.done", payload: event, context: context)
    }

    func writeFunctionCallItemDone(
        callId: String, name: String, status: OpenResponsesItemStatus = .completed, context: ChannelHandlerContext
    ) {
        let functionCall = OpenResponsesFunctionCall(
            id: currentItemId, status: status, callId: callId, name: name, arguments: accumulatedText)
        let event = OutputItemDoneEvent(
            sequenceNumber: nextSequenceNumber(), outputIndex: currentOutputIndex, item: .functionCall(functionCall))
        writeSSEEvent("response.output_item.done", payload: event, context: context)
        if completedOutputIDs.insert(currentItemId).inserted { completedOutput.append(.functionCall(functionCall)) }
        currentOutputIndex += 1
    }

    /// Authoritative usage only; missing counts stay absent (upstream).
    private var reportedUsage: OpenResponsesUsage? {
        guard let inputTokens, let outputTokens else { return nil }
        return .init(inputTokens: inputTokens, outputTokens: outputTokens)
    }

    func writeResponseTerminal(
        status: OpenResponsesStatus, incompleteReason: String? = nil, metadata: [String: String]? = nil,
        context: ChannelHandlerContext
    ) {
        let response = OpenResponsesResponse(
            id: responseId, createdAt: createdAt, status: status, model: model, output: completedOutput,
            usage: reportedUsage, metadata: metadata, incompleteReason: incompleteReason)
        let name = "response." + status.rawValue
        struct Terminal: Encodable {
            let type: String
            let sequence_number: Int
            let response: OpenResponsesResponse
        }
        writeSSEEvent(
            name, payload: Terminal(type: name, sequence_number: nextSequenceNumber(), response: response),
            context: context)
    }

    func writeErrorFromThrown(_ error: Error, context: ChannelHandlerContext) {
        let response = OpenResponsesResponse(
            id: responseId, createdAt: createdAt, status: .failed, model: model, output: [], usage: nil)
        let event = ResponseFailedEvent(
            sequenceNumber: nextSequenceNumber(), response: response,
            error: OpenResponsesError(
                code: HTTPHandler.openResponsesErrorCode(for: error), message: error.localizedDescription))
        writeSSEEvent("response.failed", payload: event, context: context)
    }

    func writeEnd(_ context: ChannelHandlerContext) {
        var tail = context.channel.allocator.buffer(capacity: 16)
        tail.writeString("data: [DONE]\n\n")
        context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(tail))), promise: nil)
        let ctx = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
            ctx.value.close(promise: nil)
        }
    }

    private func writeSSEEvent<T: Encodable>(_ eventType: String, payload: T, context: ChannelHandlerContext) {
        let encoder = IkigaJSONEncoder()
        var buffer = context.channel.allocator.buffer(capacity: 512)
        buffer.writeString("event: ")
        buffer.writeString(eventType)
        buffer.writeString("\ndata: ")
        do {
            try encoder.encodeAndWrite(payload, into: &buffer)
            buffer.writeString("\n\n")
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.flush()
        } catch {
            print("Error encoding Open Responses SSE event: \(error)")
            context.close(promise: nil)
        }
    }
}
