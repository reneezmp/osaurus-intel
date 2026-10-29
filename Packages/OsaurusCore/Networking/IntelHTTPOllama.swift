//
//  IntelHTTPOllama.swift
//  osaurus
//
//  Ollama-compatible `/api/chat` and `/api/generate` on Intel's engine
//  (`W-server-api` stage 2c, docs/SERVER_API_INTEL.md). Upstream's request
//  decoding, NDJSON framing and JSON bodies; one model round through
//  `IntelHTTPInference` (tool calls returned, never run), as in
//  `/chat/completions`.
//

import CoreGraphics
import Foundation
import ImageIO
import NIOCore
import NIOHTTP1
import UniformTypeIdentifiers

extension HTTPHandler {
    // MARK: - Request decoding (upstream)

    /// Explicit Ollama wire aliases (upstream `decodeOllamaChatRequest`):
    /// `options` sampling keys, earlier `thinking` kept as
    /// `reasoning_content`, and `images` carried as image parts. Intel's
    /// request has no `enable_thinking` / `reasoning_effort`, so `think` is
    /// validated and otherwise not passed on.
    static func decodeOllamaChatRequest(_ data: Data) throws -> ChatCompletionRequest {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "OsaurusOllamaRequest", code: 400)
        }
        if let options = object["options"] as? [String: Any] {
            for (source, target) in [
                "num_predict": "max_tokens", "temperature": "temperature",
                "top_p": "top_p", "top_k": "top_k", "min_p": "min_p", "seed": "seed", "stop": "stop",
            ]
            where object[target] == nil {
                object[target] = options[source]
            }
        }
        if let value = object["think"], !(value is NSNull), !(value is String) {
            guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                throw NSError(
                    domain: "OsaurusOllamaRequest", code: 400,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Ollama think must be a boolean, model-defined effort string, or null."
                    ])
            }
        }
        if let stop = object["stop"] as? String { object["stop"] = [stop] }
        if var messages = object["messages"] as? [[String: Any]] {
            for index in messages.indices {
                if messages[index]["reasoning_content"] == nil, let thinking = messages[index]["thinking"] as? String {
                    messages[index]["reasoning_content"] = thinking
                }
                if let images = messages[index]["images"] as? [String], !images.isEmpty {
                    var parts = messages[index]["content"] as? [[String: Any]] ?? []
                    if let text = messages[index]["content"] as? String { parts.insert(["type": "text", "text": text], at: 0) }
                    for encoded in images {
                        guard let bytes = Data(base64Encoded: encoded),
                            let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                            let identifier = CGImageSourceGetType(source),
                            let mime = UTType(identifier as String)?.preferredMIMEType
                        else {
                            throw NSError(
                                domain: "OsaurusOllamaRequest", code: 400,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "An Ollama images entry is not a supported base64 image."
                                ])
                        }
                        parts.append(["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(encoded)"]])
                    }
                    messages[index]["content"] = parts
                }
                messages[index].removeValue(forKey: "images")
                messages[index].removeValue(forKey: "thinking")
            }
            object["messages"] = messages
        }
        return try JSONDecoder().decode(
            ChatCompletionRequest.self,
            from: JSONSerialization.data(withJSONObject: object, options: .osaurusCanonical))
    }

    /// Upstream `/api/generate` request: a prompt, an optional system line.
    static func decodeOllamaGenerateRequest(_ data: Data) throws -> ChatCompletionRequest {
        struct Options: Decodable {
            let num_predict: Int?
            let temperature: Double?
            let top_p: Double?
            let stop: FlexibleStrings?
        }
        struct FlexibleStrings: Decodable {
            let values: [String]
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(String.self) {
                    values = [value]
                } else {
                    values = (try? container.decode([String].self)) ?? []
                }
            }
        }
        struct Generate: Decodable {
            let model: String
            let prompt: String
            let system: String?
            let stream: Bool?
            let options: Options?
        }
        let ollama = try JSONDecoder().decode(Generate.self, from: data)
        var messages: [ChatMessage] = []
        if let system = ollama.system?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
            messages.append(ChatMessage(role: "system", content: system))
        }
        messages.append(ChatMessage(role: "user", content: ollama.prompt))
        return ChatCompletionRequest(
            model: ollama.model,
            messages: messages,
            temperature: ollama.options?.temperature,
            max_tokens: ollama.options?.num_predict.flatMap { $0 > 0 ? $0 : nil },
            stream: ollama.stream,
            top_p: ollama.options?.top_p,
            stop: ollama.options?.stop?.values
        )
    }

    // MARK: - JSON bodies (upstream)

    static func ollamaArguments(from json: String) -> Any {
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return json }
        return object
    }

    static func ollamaChatJSON(
        model: String,
        content: String,
        toolCalls: [StreamingToolHint.ProposedCall] = [],
        done: Bool,
        thinking: String? = nil,
        doneReason: String = "stop"
    ) -> String {
        var message: [String: Any] = ["role": "assistant", "content": content]
        if let thinking, !thinking.isEmpty { message["thinking"] = thinking }
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls.map { call in
                ["function": ["name": call.name, "arguments": ollamaArguments(from: call.arguments)]]
            }
        }
        var object: [String: Any] = [
            "model": model, "created_at": Date().ISO8601Format(), "message": message, "done": done,
        ]
        if done { object["done_reason"] = doneReason }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return #"{"message":{"role":"assistant","content":""},"done":true}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func ollamaGenerateJSON(
        model: String, response: String, done: Bool, thinking: String? = nil, doneReason: String = "stop"
    ) -> String {
        var object: [String: Any] = [
            "model": model, "created_at": Date().ISO8601Format(), "response": response, "done": done,
        ]
        if let thinking, !thinking.isEmpty { object["thinking"] = thinking }
        if done { object["done_reason"] = doneReason }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .osaurusCanonical) else {
            return #"{"done":true}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func ollamaGenerateErrorJSON(_ message: String, type: String = "internal_error") -> String {
        let object: [String: Any] = ["error": ["message": message, "type": type], "done": true]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .osaurusCanonical) else {
            return #"{"error":{"message":"internal error","type":"internal_error"},"done":true}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Routes

    enum OllamaRoute { case chat, generate }

    /// `POST /api/chat` and `POST /api/generate`. Ollama streams unless the
    /// request says `"stream": false`.
    func serveOllama(_ route: OllamaRoute, context: ChannelHandlerContext, head: HTTPRequestHead) {
        let data = requestBodyData()
        let requestBodyString = String(decoding: data, as: UTF8.self)
        let startTime = stateRef.value.requestStartedAt ?? Date()
        let userAgent = head.headers.first(name: "User-Agent")
        let path = route == .chat ? "/chat" : "/generate"

        let decoded = try? (route == .chat ? Self.decodeOllamaChatRequest(data) : Self.decodeOllamaGenerateRequest(data))
        guard let request = decoded, let model = request.model, !model.isEmpty else {
            sendResponse(context: context, status: .badRequest, headers: textHeaders(), body: "Invalid request format")
            return
        }
        stateRef.value.routeLogsItself = true
        let engine = makeInferenceEngine()
        let eventLoop = context.eventLoop
        let stateRef = self.stateRef
        let cors = stateRef.value.corsHeaders

        func log(status: Int, body: String?, finish: RequestLog.FinishReason?, error: String?) {
            logRequest(
                method: "POST", path: path, userAgent: userAgent, requestBody: requestBodyString,
                responseBody: body, responseStatus: status, startTime: startTime, model: model,
                finishReason: finish, errorMessage: error)
        }

        guard request.stream ?? true else {
            runRequestTask {
                do {
                    let collected = try await IntelHTTPInference.collect(engine: engine, request: request)
                    let doneReason = collected.finishReason == .length ? "length" : "stop"
                    let body: String
                    switch route {
                    case .chat:
                        body = Self.ollamaChatJSON(
                            model: model, content: collected.content, toolCalls: collected.toolCalls, done: true,
                            thinking: collected.reasoning, doneReason: doneReason)
                    case .generate:
                        body = Self.ollamaGenerateJSON(
                            model: model, response: collected.content, done: true,
                            thinking: collected.reasoning, doneReason: doneReason)
                    }
                    self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: body)
                    log(status: 200, body: body, finish: collected.finishReason, error: nil)
                } catch {
                    let mapped = Self.inferenceHTTPStatus(for: error)
                    let body = Self.ollamaGenerateErrorJSON(error.localizedDescription, type: mapped.type)
                    self.respondOnLoop(eventLoop, status: mapped.status, headers: self.jsonHeaders(), body: body)
                    log(status: Int(mapped.status.code), body: body, finish: .error, error: error.localizedDescription)
                }
            }
            return
        }

        stateRef.value.isStreaming = true
        let writer = OllamaNDJSONWriter(route: route, model: model)
        writer.writeHeaders(context, extraHeaders: cors)
        let onLoop: @Sendable (@escaping @Sendable (ChannelHandlerContext) -> Void) -> Void = { body in
            eventLoop.execute {
                guard let ctx = stateRef.value.contextBox else { return }
                body(ctx)
            }
        }
        let task = runRequestTask {
            var collected = IntelHTTPInference.Collected()
            do {
                for try await event in try await IntelHTTPInference.events(engine: engine, request: request) {
                    try Task.checkCancellation()
                    collected.consume(event)
                    switch event {
                    case .content(let text): onLoop { writer.writeContent(text, context: $0) }
                    case .reasoning(let text): onLoop { writer.writeThinking(text, context: $0) }
                    case .toolCalls, .stats: break
                    }
                }
                let finished = collected
                // `/api/generate` sends no tools, so a tool call there is an
                // incomplete answer (upstream).
                if route == .generate, !finished.toolCalls.isEmpty {
                    throw NSError(
                        domain: "OsaurusOllamaRequest", code: 500,
                        userInfo: [NSLocalizedDescriptionKey: "The model answered with a tool call."])
                }
                onLoop { ctx in
                    writer.writeDone(
                        reason: finished.finishReason == .length ? "length" : "stop",
                        toolCalls: finished.toolCalls, context: ctx)
                    writer.writeEnd(ctx)
                }
                log(status: 200, body: nil, finish: finished.finishReason, error: nil)
            } catch {
                onLoop { ctx in
                    writer.writeError(
                        error.localizedDescription, type: Self.inferenceHTTPStatus(for: error).type, context: ctx)
                    writer.writeEnd(ctx)
                }
                log(status: 200, body: nil, finish: .error, error: error.localizedDescription)
            }
        }
        context.channel.closeFuture.whenComplete { _ in task.cancel() }
    }
}

// MARK: - NDJSON writer (upstream `NDJSONResponseWriter` /
// `OllamaGenerateNDJSONResponseWriter`)

/// One writer for both Ollama streams: `/api/chat` frames carry a
/// `message`, `/api/generate` frames a `response`. Stateless after init.
final class OllamaNDJSONWriter: @unchecked Sendable {
    let route: HTTPHandler.OllamaRoute
    let model: String

    init(route: HTTPHandler.OllamaRoute, model: String) {
        self.route = route
        self.model = model
    }

    func writeHeaders(_ context: ChannelHandlerContext, extraHeaders: [(String, String)]? = nil) {
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/x-ndjson")
        headers.add(name: "Cache-Control", value: "no-cache, no-transform")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "Transfer-Encoding", value: "chunked")
        for (name, value) in extraHeaders ?? [] { headers.add(name: name, value: value) }
        head.headers = headers
        context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        context.flush()
    }

    private func frame(text: String, thinking: String? = nil, done: Bool) -> [String: Any] {
        var object: [String: Any] = ["model": model, "created_at": Date().ISO8601Format(), "done": done]
        switch route {
        case .chat:
            var message: [String: Any] = ["role": "assistant", "content": text]
            if let thinking { message["thinking"] = thinking }
            object["message"] = message
        case .generate:
            object["response"] = text
            if let thinking { object["thinking"] = thinking }
        }
        return object
    }

    func writeContent(_ text: String, context: ChannelHandlerContext) {
        guard !text.isEmpty else { return }
        write(frame(text: text, done: false), context: context)
    }

    func writeThinking(_ text: String, context: ChannelHandlerContext) {
        guard !text.isEmpty else { return }
        write(frame(text: "", thinking: text, done: false), context: context)
    }

    /// The closing frame: `done_reason`, plus the tool calls on `/api/chat`.
    /// Upstream also reports `prompt_eval_count` / `eval_count` when the
    /// engine measured them; Intel's does not.
    func writeDone(reason: String, toolCalls: [StreamingToolHint.ProposedCall], context: ChannelHandlerContext) {
        var object = frame(text: "", done: true)
        if route == .chat, !toolCalls.isEmpty, var message = object["message"] as? [String: Any] {
            message["tool_calls"] = toolCalls.map { call in
                ["function": ["name": call.name, "arguments": HTTPHandler.ollamaArguments(from: call.arguments)]]
            }
            object["message"] = message
        }
        object["done_reason"] = reason
        write(object, context: context)
    }

    func writeError(_ message: String, type: String, context: ChannelHandlerContext) {
        write(["error": ["message": message, "type": type], "done": true], context: context)
    }

    func writeEnd(_ context: ChannelHandlerContext) {
        let ctx = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
            ctx.value.close(promise: nil)
        }
    }

    private func write(_ object: [String: Any], context: ChannelHandlerContext) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .osaurusCanonical) else { return }
        var buffer = context.channel.allocator.buffer(capacity: data.count + 1)
        buffer.writeBytes(data)
        buffer.writeString("\n")
        SSEResponseWriter.writeBackpressureAware(HTTPServerResponsePart.body(.byteBuffer(buffer)), context: context)
    }
}
