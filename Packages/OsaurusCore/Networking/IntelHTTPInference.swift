//
//  IntelHTTPInference.swift
//  osaurus
//
//  The local API's inference routes on Intel's engine (`W-server-api`
//  stage 2, docs/SERVER_API_INTEL.md).
//
//  Upstream's routes read typed `ResponsesGenerationEvent`s from its engine.
//  Intel's `ChatEngine` streams strings with in-band markers (reasoning,
//  stats, proposed tool calls), so `IntelHTTPInference` turns them into the
//  same few events. API requests run with `stopAtToolCalls`: the engine
//  hands the model's tool calls back to the client instead of running them,
//  as upstream's server does.
//
//  `SSEResponseWriter` is upstream's OpenAI Chat Completions stream writer
//  (`Models/Chat/ResponseWriters.swift`, excluded on Intel), minus the
//  phone-run recorder, agent tool traces, Router billing relay and
//  artifacts chunk, which arrive with their routes.
//

import Foundation
import IkigaJSON
import NIOCore
import NIOHTTP1

/// One step of an API inference stream.
enum IntelInferenceEvent: Sendable, Equatable {
    case content(String)
    case reasoning(String)
    /// The calls the model proposed this round (not run).
    case toolCalls([StreamingToolHint.ProposedCall])
    case stats(tokenCount: Int, tokensPerSecond: Double, stopReason: String?)
    /// Provider-measured usage (Intel's `StreamingUsageHint`).
    case usage(promptTokens: Int, completionTokens: Int)
}

/// Intel: the provider's measured token counts, sent once at the end of an
/// API request's stream (`ChatCompletionRequest.reportsUsage`). Starts with
/// `\u{FFFE}` like every in-band hint, so text filters skip it.
enum StreamingUsageHint {
    private static let prefix = "\u{FFFE}usage:"

    static func encode(promptTokens: Int, completionTokens: Int) -> String {
        "\(prefix)\(promptTokens);\(completionTokens)"
    }

    static func decode(_ delta: String) -> (promptTokens: Int, completionTokens: Int)? {
        guard delta.hasPrefix(prefix) else { return nil }
        let parts = delta.dropFirst(prefix.count).split(separator: ";")
        guard parts.count == 2, let prompt = Int(parts[0]), let completion = Int(parts[1]) else { return nil }
        return (max(0, prompt), max(0, completion))
    }
}

enum IntelHTTPInference {
    /// Classify one engine delta. `nil` for markers the API has no use for
    /// (tool progress of a run the engine performed itself).
    static func classify(_ delta: String) -> IntelInferenceEvent? {
        if let calls = StreamingToolHint.decodeProposed(delta) { return .toolCalls(calls) }
        if let reasoning = StreamingReasoningHint.decode(delta) {
            return reasoning.isEmpty ? nil : .reasoning(reasoning)
        }
        if let usage = StreamingUsageHint.decode(delta) {
            return .usage(promptTokens: usage.promptTokens, completionTokens: usage.completionTokens)
        }
        if let stats = StreamingStatsHint.decode(delta) {
            return .stats(tokenCount: stats.tokenCount, tokensPerSecond: stats.tokensPerSecond, stopReason: stats.stopReason)
        }
        if StreamingToolHint.isSentinel(delta) { return nil }
        return delta.isEmpty ? nil : .content(delta)
    }

    /// The API's request to the engine: the client's own messages and tools,
    /// one model round, tool calls returned rather than run.
    static func engineRequest(_ request: ChatCompletionRequest) -> ChatCompletionRequest {
        var request = request
        request.stopAtToolCalls = true
        request.reportsUsage = true
        return request
    }

    /// Typed events from the engine's string stream.
    static func events(
        engine: any ChatEngineProtocol,
        request: ChatCompletionRequest
    ) async throws -> AsyncThrowingStream<IntelInferenceEvent, Error> {
        let stream = try await engine.streamChat(request: engineRequest(request))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await delta in stream {
                        try Task.checkCancellation()
                        if let event = classify(delta) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A whole response, for the non-streaming routes.
    struct Collected: Sendable, Equatable {
        var content = ""
        var reasoning = ""
        var toolCalls: [StreamingToolHint.ProposedCall] = []
        var completionTokens: Int?
        var stopReason: String?
        /// Provider-measured usage; `nil` when the provider reported none.
        var usage: (prompt: Int, completion: Int)?

        static func == (lhs: Collected, rhs: Collected) -> Bool {
            lhs.content == rhs.content && lhs.reasoning == rhs.reasoning && lhs.toolCalls == rhs.toolCalls
                && lhs.completionTokens == rhs.completionTokens && lhs.stopReason == rhs.stopReason
                && lhs.usage?.prompt == rhs.usage?.prompt && lhs.usage?.completion == rhs.usage?.completion
        }

        /// Upstream's finish reasons: tool calls win, then a length stop.
        var finishReason: RequestLog.FinishReason {
            if !toolCalls.isEmpty { return .toolCalls }
            if stopReason == "length" || stopReason == "max_tokens" { return .length }
            return .stop
        }

        mutating func consume(_ event: IntelInferenceEvent) {
            switch event {
            case .content(let text): content += text
            case .reasoning(let text): reasoning += text
            case .toolCalls(let calls): toolCalls = calls
            case .stats(let count, _, let stop):
                completionTokens = count
                stopReason = stop
            case .usage(let prompt, let completion):
                usage = (prompt, completion)
            }
        }
    }

    static func collect(
        engine: any ChatEngineProtocol,
        request: ChatCompletionRequest
    ) async throws -> Collected {
        var collected = Collected()
        for try await event in try await events(engine: engine, request: request) {
            try Task.checkCancellation()
            collected.consume(event)
        }
        return collected
    }

    /// Call id the API reports: the provider's, else a fresh `call_` id
    /// (upstream `writeOpenAIToolCallSSE`).
    static func callId(_ call: StreamingToolHint.ProposedCall) -> String {
        call.callId.isEmpty ? HTTPHandler.shortId(prefix: "call_") : call.callId
    }

    /// Prompt-token estimate (upstream `estimatePromptTokens`): characters
    /// over four, tool calls included.
    static func estimatePromptTokens(_ messages: [ChatMessage]) -> Int {
        let totalChars = messages.reduce(0) { sum, msg in
            var chars = msg.content?.count ?? 0
            if let calls = msg.tool_calls {
                for call in calls {
                    chars += call.function.name.count + call.function.arguments.count + 16
                }
            }
            return sum + chars
        }
        return max(1, totalChars / 4)
    }
}

// MARK: - OpenAI SSE writer (upstream)

/// Stateless, so it may be used from a request's task and the event loop.
final class SSEResponseWriter: @unchecked Sendable {
    func writeHeaders(_ context: ChannelHandlerContext, extraHeaders: [(String, String)]? = nil) {
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache, no-transform")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "X-Accel-Buffering", value: "no")
        headers.add(name: "Transfer-Encoding", value: "chunked")
        if let extraHeaders {
            for (n, v) in extraHeaders { headers.add(name: n, value: v) }
        }
        head.headers = headers
        context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        context.flush()
    }

    func writeRole(
        _ role: String,
        model: String,
        responseId: String,
        created: Int,
        prefixHash: String? = nil,
        context: ChannelHandlerContext
    ) {
        var chunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: model,
            choices: [StreamChoice(index: 0, delta: DeltaContent(role: role, content: ""), finish_reason: nil)],
            system_fingerprint: nil
        )
        chunk.prefix_hash = prefixHash
        writeSSEChunk(chunk, context: context)
    }

    func writeContent(_ content: String, model: String, responseId: String, created: Int, context: ChannelHandlerContext) {
        guard !content.isEmpty else { return }
        let chunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: model,
            choices: [StreamChoice(index: 0, delta: DeltaContent(content: content), finish_reason: nil)],
            system_fingerprint: nil
        )
        writeSSEChunk(chunk, context: context)
    }

    func writeReasoning(_ content: String, model: String, responseId: String, created: Int, context: ChannelHandlerContext) {
        guard !content.isEmpty else { return }
        let chunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: model,
            choices: [StreamChoice(index: 0, delta: DeltaContent(reasoning_content: content), finish_reason: nil)],
            system_fingerprint: nil
        )
        writeSSEChunk(chunk, context: context)
    }

    func writeToolCallStart(
        callId: String,
        functionName: String,
        index: Int = 0,
        model: String,
        responseId: String,
        created: Int,
        context: ChannelHandlerContext
    ) {
        let delta = DeltaContent(
            role: nil,
            content: nil,
            refusal: nil,
            tool_calls: [
                DeltaToolCall(
                    index: index,
                    id: callId,
                    type: "function",
                    function: DeltaToolCallFunction(name: functionName, arguments: nil)
                )
            ]
        )
        let chunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: model,
            choices: [StreamChoice(index: 0, delta: delta, finish_reason: nil)],
            system_fingerprint: nil
        )
        writeSSEChunk(chunk, context: context)
    }

    func writeToolCallArgumentsDelta(
        callId: String,
        index: Int,
        argumentsChunk: String,
        model: String,
        responseId: String,
        created: Int,
        context: ChannelHandlerContext
    ) {
        guard !argumentsChunk.isEmpty else { return }
        let delta = DeltaContent(
            role: nil,
            content: nil,
            refusal: nil,
            tool_calls: [
                DeltaToolCall(
                    index: index,
                    id: nil,
                    type: nil,
                    function: DeltaToolCallFunction(name: nil, arguments: argumentsChunk)
                )
            ]
        )
        let chunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: model,
            choices: [StreamChoice(index: 0, delta: delta, finish_reason: nil)],
            system_fingerprint: nil
        )
        writeSSEChunk(chunk, context: context)
    }

    /// One proposed call as a start chunk plus 1 KB argument deltas
    /// (upstream `writeOpenAIToolCallSSE`).
    func writeToolCall(
        _ call: StreamingToolHint.ProposedCall,
        index: Int,
        model: String,
        responseId: String,
        created: Int,
        context: ChannelHandlerContext
    ) {
        let callId = IntelHTTPInference.callId(call)
        writeToolCallStart(
            callId: callId, functionName: call.name, index: index,
            model: model, responseId: responseId, created: created, context: context)
        var remaining = Substring(call.arguments)
        while !remaining.isEmpty {
            let chunk = remaining.prefix(1024)
            remaining = remaining.dropFirst(chunk.count)
            writeToolCallArgumentsDelta(
                callId: callId, index: index, argumentsChunk: String(chunk),
                model: model, responseId: responseId, created: created, context: context)
        }
    }

    func writeFinishWithReason(_ reason: String, model: String, responseId: String, created: Int, context: ChannelHandlerContext) {
        let chunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: model,
            choices: [StreamChoice(index: 0, delta: DeltaContent(), finish_reason: reason)],
            system_fingerprint: nil
        )
        writeSSEChunk(chunk, context: context)
    }

    /// The OpenAI `stream_options.include_usage` final chunk.
    func writeUsageChunk(
        promptTokens: Int,
        completionTokens: Int,
        tokensPerSecond: Double? = nil,
        model: String,
        responseId: String,
        created: Int,
        context: ChannelHandlerContext
    ) {
        var chunk = ChatCompletionChunk(
            id: responseId,
            created: created,
            model: model,
            choices: [],
            system_fingerprint: nil
        )
        chunk.usage = Usage(
            prompt_tokens: promptTokens,
            completion_tokens: completionTokens,
            total_tokens: promptTokens + completionTokens,
            tokens_per_second: tokensPerSecond
        )
        writeSSEChunk(chunk, context: context)
    }

    func writeStructuredError(message: String, type: String, code: String?, context: ChannelHandlerContext) {
        let encoder = IkigaJSONEncoder()
        var buffer = context.channel.allocator.buffer(capacity: 256)
        buffer.writeString("data: ")
        do {
            let err = OpenAIError(
                error: OpenAIError.ErrorDetail(message: message, type: type, param: nil, code: code)
            )
            try encoder.encodeAndWrite(err, into: &buffer)
            buffer.writeString("\n\n")
        } catch {
            buffer.clear()
            buffer.writeString("data: {\"error\":{\"message\":\"")
            buffer.writeString(message)
            buffer.writeString("\",\"type\":\"")
            buffer.writeString(type)
            buffer.writeString("\"}}\n\n")
        }
        context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        context.flush()
    }

    /// Upstream `writeErrorFromThrown`, minus the Privacy Filter case
    /// (`W-privacy-filter`).
    func writeErrorFromThrown(_ error: Error, context: ChannelHandlerContext) {
        if error is CancellationError {
            writeStructuredError(
                message: L("This send was stopped before it reached the model. Nothing was sent. Try again."),
                type: "request_cancelled",
                code: "request_cancelled",
                context: context
            )
            return
        }
        writeStructuredError(
            message: error.localizedDescription,
            type: HTTPHandler.openAIErrorType(for: error),
            code: nil,
            context: context
        )
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

    /// SSE comment line used as a keepalive heartbeat.
    func writePing(_ context: ChannelHandlerContext) {
        var buf = context.channel.allocator.buffer(capacity: 16)
        buf.writeString(": ping\n\n")
        context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf))), promise: nil)
        context.flush()
    }

    private func writeSSEChunk(_ chunk: some Encodable, context: ChannelHandlerContext) {
        let encoder = IkigaJSONEncoder()
        var buffer = context.channel.allocator.buffer(capacity: 256)
        buffer.writeString("data: ")
        do {
            try encoder.encodeAndWrite(chunk, into: &buffer)
            buffer.writeString("\n\n")
            Self.writeBackpressureAware(HTTPServerResponsePart.body(.byteBuffer(buffer)), context: context)
        } catch {
            print("Error encoding SSE chunk: \(error)")
            context.close(promise: nil)
        }
    }

    /// Backpressure-aware body write (upstream): a failed write closes the
    /// channel so the route's disconnect hook stops generation.
    static func writeBackpressureAware(_ part: HTTPServerResponsePart, context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenFailure { _ in
            context.close(promise: nil)
        }
        context.write(NIOAny(part), promise: promise)
        if context.channel.isWritable {
            context.flush()
        }
    }
}

// MARK: - Protocol errors (upstream `HTTPProtocolErrors.swift`, Intel subset)

extension HTTPHandler {
    /// Wire flavor for the JSON error body (upstream).
    enum HTTPErrorFlavor {
        /// `{"error":{"message":"...","type":"<type>"}}`
        case openai(type: String)
        /// `{"type":"error","error":{"type":"<errorType>","message":"..."}}`
        case anthropic(errorType: String)
        /// `{"error":{"type":"error","code":"<code>","message":"..."}}`
        case openResponses(code: String)
        /// Ollama-compatible envelope with the terminal bit.
        case ollama(type: String)
    }

    static func errorBody(_ flavor: HTTPErrorFlavor, message: String) -> String {
        let escaped = escapeJSONString(message)
        switch flavor {
        case .openai(let type):
            return #"{"error":{"message":"\#(escaped)","type":"\#(type)"}}"#
        case .anthropic(let errorType):
            return #"{"type":"error","error":{"type":"\#(errorType)","message":"\#(escaped)"}}"#
        case .openResponses(let code):
            return #"{"error":{"type":"error","code":"\#(code)","message":"\#(escaped)"}}"#
        case .ollama(let type):
            return #"{"error":{"message":"\#(escaped)","type":"\#(type)"},"done":true}"#
        }
    }

    /// Upstream's mapping, minus the MLX runtime errors Intel never throws.
    static func openAIErrorType(for error: Error) -> String {
        if error is CancellationError { return "request_cancelled" }
        if (error as NSError).domain == "OsaurusToolChoice" { return "invalid_request_error" }
        return "internal_error"
    }

    /// HTTP status for an engine failure: upstream answers an unknown model
    /// 404 and other engine errors 503; anything else 500 (499 when the
    /// client went away).
    static func inferenceHTTPStatus(for error: Error) -> (status: HTTPResponseStatus, type: String) {
        if let engineError = error as? ChatEngine.EngineError {
            return engineError.isUnknownModel
                ? (.notFound, "invalid_request_error") : (.serviceUnavailable, "service_unavailable")
        }
        if error is CancellationError {
            return (HTTPResponseStatus(statusCode: 499, reasonPhrase: "Client Closed Request"), "request_cancelled")
        }
        return (.internalServerError, openAIErrorType(for: error))
    }

    /// `prefix` + 24 (or `length`) hex characters of a fresh UUID (upstream).
    static func shortId(prefix: String, length: Int = 24) -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return prefix + String(raw.prefix(length))
    }

    static func escapeJSONString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }
}
