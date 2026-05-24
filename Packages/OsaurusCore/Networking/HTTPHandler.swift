//
//  HTTPHandler.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//  Intel fork — cloud proxy with SSE streaming. M4 milestone.
//

import Foundation
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix

// MARK: - OpenAI-compatible types

struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String?
    let tool_calls: [ToolCall]?
    let tool_call_id: String?
    let reasoning_content: String?

    init(role: String, content: String? = nil, tool_calls: [ToolCall]? = nil,
         tool_call_id: String? = nil, reasoning_content: String? = nil) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.reasoning_content = reasoning_content
    }
}

struct ToolCall: Codable, Sendable {
    let id: String?
    let type: String?
    let function: ToolCallFunction?
    var geminiThoughtSignature: String? = nil
}

struct ToolCallFunction: Codable, Sendable {
    let name: String?
    let arguments: String?
}

struct ChatCompletionRequest: Codable, Sendable {
    let model: String?
    let messages: [ChatMessage]
    var temperature: Double?
    var max_tokens: Int?
    var stream: Bool?
    var top_p: Double?
    var stream_options: StreamOptions? = nil
    var frequency_penalty: Double?
    var presence_penalty: Double?
    var stop: [String]?
    var n: Int?
    var tools: [Tool]?
    var tool_choice: ToolChoiceOption?
    var session_id: String?
    var samplingParametersAreImplicit: Bool = false
    var modelOptions: [String: ModelOptionValue]? = nil

    private enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, max_tokens, top_p
        case stream_options, frequency_penalty, presence_penalty, stop, n
        case tools, tool_choice, session_id
    }

    var ttftTrace: TTFTTrace? = nil
}

struct StreamOptions: Codable, Sendable {
    let include_usage: Bool?
}

struct ChatCompletionChunk: Codable, Sendable {
    let id: String?
    let object: String?
    let created: Int?
    let model: String?
    let choices: [ChunkChoice]?
    let usage: UsageInfo?
}

struct ChunkChoice: Codable, Sendable {
    let index: Int?
    let delta: ChunkDelta?
    let finish_reason: String?
}

struct ChunkDelta: Codable, Sendable {
    let role: String?
    let content: String?
    let reasoning_content: String?
    let tool_calls: [ToolCall]?
}

struct UsageInfo: Codable, Sendable {
    let prompt_tokens: Int?
    let completion_tokens: Int?
    let total_tokens: Int?
}

struct OpenAIModel: Codable, Sendable {
    let id: String
    let object: String
    let created: Int
    let owned_by: String

    init(id: String) {
        self.id = id
        self.object = "model"
        self.created = Int(Date().timeIntervalSince1970)
        self.owned_by = "deepseek"
    }
}

struct ModelsResponse: Codable, Sendable {
    let object: String
    let data: [OpenAIModel]
}

// MARK: - HTTP Handler

private final class SendableBool: @unchecked Sendable {
    private var _value: Bool
    private let _lock = NSLock()
    init(_ value: Bool) { _value = value }
    var value: Bool {
        get { _lock.withLock { _value } }
        set { _lock.withLock { _value = newValue } }
    }
}

final class HTTPHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let configuration: ServerConfiguration
    private let apiKeyValidatorProvider: @Sendable () -> APIKeyValidator
    private var apiKeyValidator: APIKeyValidator { apiKeyValidatorProvider() }
    private let trustLoopback: Bool
    private let _isChannelActive = SendableBool(false)

    private let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()
    private let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    final class RequestState {
        var requestHead: HTTPRequestHead?
        var requestBodyBuffer: ByteBuffer?
        var isStreaming = false
        var streamingDone = false
        var contextBox: ChannelHandlerContext?
    }
    let stateRef: NIOLoopBound<RequestState>

    init(
        configuration: ServerConfiguration,
        apiKeyValidator: APIKeyValidator = .empty,
        apiKeyValidatorProvider: (@Sendable () -> APIKeyValidator)? = nil,
        eventLoop: EventLoop,
        trustLoopback: Bool = true
    ) {
        self.configuration = configuration
        self.apiKeyValidatorProvider = apiKeyValidatorProvider ?? { apiKeyValidator }
        self.trustLoopback = trustLoopback
        self.stateRef = NIOLoopBound(RequestState(), eventLoop: eventLoop)
    }

    func channelActive(context: ChannelHandlerContext) {
        _isChannelActive.value = true
        stateRef.value.contextBox = context
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        _isChannelActive.value = false
        stateRef.value.contextBox = nil
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            stateRef.value.requestHead = head
            stateRef.value.requestBodyBuffer = context.channel.allocator.buffer(capacity: 0)
            stateRef.value.isStreaming = false
            stateRef.value.streamingDone = false

        case .body(var buffer):
            if stateRef.value.requestBodyBuffer != nil {
                stateRef.value.requestBodyBuffer!.writeBuffer(&buffer)
            }

        case .end:
            guard let head = stateRef.value.requestHead else {
                sendEmptyResponse(context: context, status: .badRequest)
                return
            }

            handleRequest(context: context, head: head)
        }
    }

    // MARK: - Request Dispatch

    private func handleRequest(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let path = Router.normalizeStatic(head.uri)

        switch (head.method, path) {
        case (.GET, "/health"):
            serveHealth(context: context)
        case (.GET, "/"):
            serveRoot(context: context)
        case (.GET, "/models"):
            serveModels(context: context)
        case (.POST, "/chat/completions"):
            serveChatCompletions(context: context)
        case (.POST, "/mcp"):
            serveMCP(context: context)
        default:
            var router = Router(context: context, handler: self)
            let bodyBuffer = stateRef.value.requestBodyBuffer ?? context.channel.allocator.buffer(capacity: 0)
            let (status, headers, body) = router.route(method: head.method.rawValue, path: head.uri, bodyBuffer: bodyBuffer)
            sendResponse(context: context, status: status, headers: headers, body: body)
        }
    }

    // MARK: - Health / Root

    private func serveHealth(context: ChannelHandlerContext) {
        let body = #"{"status":"healthy","timestamp":"\#(ISO8601DateFormatter().string(from: Date()))"}"#
        sendResponse(context: context, status: .ok, headers: jsonHeaders(), body: body)
    }

    private func serveRoot(context: ChannelHandlerContext) {
        let body = "Osaurus (Intel) is running! \u{1F995}"
        sendResponse(context: context, status: .ok, headers: textHeaders(), body: body)
    }

    // MARK: - Models

    private func serveModels(context: ChannelHandlerContext) {
        let models = [
            "deepseek-v4-pro",
            "deepseek-v4-flash",
        ].map { OpenAIModel(id: $0) }
        let resp = ModelsResponse(object: "list", data: models)
        if let data = try? jsonEncoder.encode(resp), let json = String(data: data, encoding: .utf8) {
            sendResponse(context: context, status: .ok, headers: jsonHeaders(), body: json)
        } else {
            sendEmptyResponse(context: context, status: .internalServerError)
        }
    }

    // MARK: - Chat Completions (Cloud Proxy)

    private func serveChatCompletions(context: ChannelHandlerContext) {
        guard let bodyBuffer = stateRef.value.requestBodyBuffer,
              let bodyData = bodyBuffer.getBytes(at: 0, length: bodyBuffer.readableBytes).map({ Data($0) }) else {
            sendJSONError(context: context, status: .badRequest, message: "Empty request body")
            return
        }

        guard let request = try? jsonDecoder.decode(ChatCompletionRequest.self, from: bodyData) else {
            sendJSONError(context: context, status: .badRequest, message: "Invalid JSON body")
            return
        }

        let shouldStream = request.stream ?? false
        let model = request.model ?? "deepseek-v4-pro"

        guard let apiKey = DeepSeekAPIKeyStore.shared.load() else {
            sendJSONError(context: context, status: .internalServerError, message: "DEEPSEEK_API_KEY not set")
            return
        }

        if shouldStream {
            serveChatCompletionsStreaming(context: context, request: request, model: model, apiKey: apiKey)
        } else {
            serveChatCompletionsNonStreaming(context: context, request: request, model: model, apiKey: apiKey)
        }
    }

    // MARK: - MCP

    private func serveMCP(context: ChannelHandlerContext) {
        guard let bodyBuffer = stateRef.value.requestBodyBuffer,
              let bodyData = bodyBuffer.getBytes(at: 0, length: bodyBuffer.readableBytes).map({ Data($0) }) else {
            sendJSONError(context: context, status: .badRequest, message: "Empty body")
            return
        }

        guard let head = stateRef.value.requestHead else {
            sendEmptyResponse(context: context, status: .badRequest)
            return
        }

        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            headers[name] = value
        }

        let mcpRequest = HTTPRequest(
            method: "POST",
            headers: headers,
            body: bodyData,
            path: "/mcp"
        )

        let eventLoop = context.eventLoop
        let stateRef = self.stateRef

        Task {
            let response = await MCPBridge.shared.handleMCPRequest(mcpRequest)

            eventLoop.execute {
                guard let ctx = stateRef.value.contextBox else { return }
                switch response {
                case .data(let data, _):
                    if let json = String(data: data, encoding: .utf8) {
                        self.sendResponse(context: ctx, status: .ok, headers: self.jsonHeaders(), body: json)
                    } else {
                        self.sendEmptyResponse(context: ctx, status: .internalServerError)
                    }
                case .error(let code, _, _, _):
                    if let body = response.bodyData, let json = String(data: body, encoding: .utf8) {
                        self.sendResponse(context: ctx, status: HTTPResponseStatus(statusCode: code), headers: self.jsonHeaders(), body: json)
                    } else {
                        self.sendEmptyResponse(context: ctx, status: HTTPResponseStatus(statusCode: code))
                    }
                case .accepted:
                    self.sendEmptyResponse(context: ctx, status: .accepted)
                case .ok:
                    self.sendEmptyResponse(context: ctx, status: .ok)
                case .stream:
                    self.sendJSONError(context: ctx, status: .notImplemented, message: "SSE MCP not supported")
                default:
                    self.sendEmptyResponse(context: ctx, status: .internalServerError)
                }
            }
        }
    }

    // MARK: - Streaming

    private func serveChatCompletionsStreaming(
        context: ChannelHandlerContext,
        request: ChatCompletionRequest,
        model: String,
        apiKey: String
    ) {
        stateRef.value.isStreaming = true
        sendSSEHeaders(context: context)

        var urlRequest = URLRequest(url: URL(string: "https://api.deepseek.com/v1/chat/completions")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 300

        var body: [String: Any] = [
            "model": model,
            "messages": request.messages.map { msg -> [String: Any] in
                var m: [String: Any] = ["role": msg.role]
                if let content = msg.content { m["content"] = content }
                return m
            },
            "stream": true,
        ]
        if let maxTokens = request.max_tokens { body["max_tokens"] = maxTokens }

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            sendSSEError(context: context, message: "Failed to encode request")
            return
        }
        urlRequest.httpBody = httpBody

        let eventLoop = context.eventLoop
        let stateRef = self.stateRef

        Task {
            do {
                let (asyncBytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 502
                    eventLoop.execute {
                        guard let ctx = stateRef.value.contextBox else { return }
                        self.sendSSEError(context: ctx, message: "Upstream returned \(status)")
                    }
                    return
                }

                for try await line in asyncBytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let dataStr = String(line.dropFirst(6))
                    let isDone = dataStr == "[DONE]"
                    let sseLine = isDone ? "data: [DONE]\n\n" : "data: \(dataStr)\n\n"

                    eventLoop.execute {
                        guard let ctx = stateRef.value.contextBox else { return }
                        self.writeSSELine(context: ctx, line: sseLine)
                    }

                    if isDone { break }
                }

                eventLoop.execute {
                    guard let ctx = stateRef.value.contextBox else { return }
                    self.sendSSEEnd(context: ctx)
                }
            } catch {
                eventLoop.execute {
                    guard let ctx = stateRef.value.contextBox else { return }
                    self.sendSSEError(context: ctx, message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Non-streaming (Agentic with tool calls)

    private func serveChatCompletionsNonStreaming(
        context: ChannelHandlerContext,
        request: ChatCompletionRequest,
        model: String,
        apiKey: String
    ) {
        let eventLoop = context.eventLoop
        let stateRef = self.stateRef

        Task {
            let result = await runAgentLoop(messages: request.messages, model: model, apiKey: apiKey)

            eventLoop.execute {
                guard let ctx = stateRef.value.contextBox else { return }
                switch result {
                case .success(let json):
                    self.sendResponse(context: ctx, status: .ok, headers: self.jsonHeaders(), body: json)
                case .failure(let message):
                    self.sendJSONError(context: ctx, status: .internalServerError, message: message)
                }
            }
        }
    }

    private enum AgentResult {
        case success(String)
        case failure(String)
    }

    private func runAgentLoop(messages: [ChatMessage], model: String, apiKey: String, maxTurns: Int = 5) async -> AgentResult {
        var conversation: [[String: Any]] = messages.map { msg in
            var m: [String: Any] = ["role": msg.role]
            if let content = msg.content { m["content"] = content }
            return m
        }

        let tools = MCPBridge.shared.getToolsForOpenAI()

        for _ in 0..<maxTurns {
            var body: [String: Any] = [
                "model": model,
                "messages": conversation,
                "stream": false,
                "tools": tools,
            ]

            guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
                return .failure("Failed to encode request body")
            }

            var urlRequest = URLRequest(url: URL(string: "https://api.deepseek.com/v1/chat/completions")!)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            urlRequest.timeoutInterval = 300
            urlRequest.httpBody = httpBody

            let data: Data
            do {
                data = try await URLSession.shared.data(for: urlRequest).0
            } catch {
                return .failure("Upstream request failed: \(error.localizedDescription)")
            }

            guard let responseJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = responseJSON["choices"] as? [[String: Any]],
                  let choice = choices.first else {
                if let errStr = String(data: data, encoding: .utf8) {
                    return .success(errStr)
                }
                return .failure("Invalid response from upstream")
            }

            let finishReason = choice["finish_reason"] as? String

            guard finishReason == "tool_calls",
                  let message = choice["message"] as? [String: Any],
                  let toolCalls = message["tool_calls"] as? [[String: Any]] else {
                // No tool calls — final response
                if let jsonStr = String(data: data, encoding: .utf8) {
                    return .success(jsonStr)
                }
                return .failure("Failed to stringify response")
            }

            // Append assistant message to conversation
            conversation.append(message)

            // Execute each tool call
            for tc in toolCalls {
                guard let function = tc["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }

                let argsStr = function["arguments"] as? String ?? "{}"
                let argsData = argsStr.data(using: .utf8) ?? Data()
                let argsJson = (try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]) ?? [:]

                // Convert to MCP.Value
                var mcpArgs: [String: MCP.Value] = [:]
                for (k, v) in argsJson {
                    switch v {
                    case let s as String: mcpArgs[k] = .string(s)
                    case let n as Double: mcpArgs[k] = .double(n)
                    case let n as Int: mcpArgs[k] = .double(Double(n))
                    case let b as Bool: mcpArgs[k] = .bool(b)
                    default: break
                    }
                }

                let (result, _) = await MCPBridge.shared.callTool(name: name, arguments: mcpArgs)

                conversation.append([
                    "role": "tool",
                    "tool_call_id": tc["id"] as? String ?? name,
                    "content": result,
                ])
            }
        }

        return .failure("Max agent turns (\(maxTurns)) reached without final answer")
    }

    // MARK: - SSE Helpers

    private func writeSSELine(context: ChannelHandlerContext, line: String) {
        var buf = context.channel.allocator.buffer(capacity: line.utf8.count)
        buf.writeString(line)
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
    }

    private func sendSSEEnd(context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func sendSSEError(context: ChannelHandlerContext, message: String) {
        let errJSON = "{\"error\":{\"message\":\"\(message)\"}}"
        writeSSELine(context: context, line: "data: \(errJSON)\n\n")
        writeSSELine(context: context, line: "data: [DONE]\n\n")
        sendSSEEnd(context: context)
    }

    // MARK: - Response Helpers

    private func sendResponse(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        headers: [(String, String)],
        body: String
    ) {
        var responseHeaders = HTTPHeaders()
        for (name, value) in headers {
            responseHeaders.add(name: name, value: value)
        }
        responseHeaders.add(name: "content-length", value: String(body.utf8.count))
        responseHeaders.add(name: "connection", value: "keep-alive")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: responseHeaders)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func sendSSEHeaders(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "text/event-stream")
        headers.add(name: "cache-control", value: "no-cache")
        headers.add(name: "connection", value: "keep-alive")
        headers.add(name: "x-accel-buffering", value: "no")

        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.writeAndFlush(wrapOutboundOut(.head(head)), promise: nil)
    }

    private func sendEmptyResponse(context: ChannelHandlerContext, status: HTTPResponseStatus) {
        let head = HTTPResponseHead(version: .http1_1, status: status)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func sendJSONError(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
        let body = "{\"error\":{\"message\":\"\(message)\"}}"
        let hs: [(String, String)] = [("Content-Type", "application/json; charset=utf-8")]
        sendResponse(context: context, status: status, headers: hs, body: body)
    }

    private func jsonHeaders() -> [(String, String)] {
        [("Content-Type", "application/json; charset=utf-8")]
    }

    private func textHeaders() -> [(String, String)] {
        [("Content-Type", "text/plain; charset=utf-8")]
    }
}

// MARK: - API Key Store

final class DeepSeekAPIKeyStore: @unchecked Sendable {
    static let shared = DeepSeekAPIKeyStore()
    private init() {}

    func load() -> String? {
        ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
    }
}
