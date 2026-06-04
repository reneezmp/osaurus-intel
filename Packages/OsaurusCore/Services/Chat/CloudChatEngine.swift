//
//  CloudChatEngine.swift
//  OsaurusCore
//
//  M10 Phase 1: cloud-backed ChatEngine for Intel fork.
//  Replaces the excluded ChatEngine.swift and ChatEngineProtocol.swift.
//

#if OSAURUS_INTEL

import Foundation

// MARK: - Protocol (mirrors excluded ChatEngineProtocol.swift)

protocol ChatEngineProtocol: Sendable {
    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error>
    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse
}

// MARK: - Response type (mirrors excluded OpenAIAPI.swift)

struct ChatCompletionResponse: Codable, Sendable {
    let id: String?
    let object: String?
    let created: Int?
    let model: String?
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Codable, Sendable {
        let index: Int?
        let message: ResponseMessage?
        let finish_reason: String?
    }

    struct ResponseMessage: Codable, Sendable {
        let role: String?
        let content: String?
        let tool_calls: [ToolCall]?
        let reasoning_content: String?
    }

    struct Usage: Codable, Sendable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
    }
}

// MARK: - Cloud Chat Engine

actor ChatEngine: Sendable, ChatEngineProtocol {
    private let model: String
    private let apiBase: String

    init(
        source: InferenceSource = .httpAPI,
        model: String = "deepseek-v4-pro"
    ) {
        self.model = model
        self.apiBase = "https://api.deepseek.com/v1/chat/completions"
    }

    /// Accumulates one streamed tool call across DeepSeek's incremental
    /// `delta.tool_calls` fragments (id + name arrive first, arguments stream
    /// in pieces, keyed by `index`).
    private struct PartialToolCall {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    /// Serialize a ChatMessage into the OpenAI-compatible request shape,
    /// INCLUDING `tool_calls` (assistant) and `tool_call_id` (tool results) —
    /// the original Intel engine dropped both, so multi-turn tool context was
    /// lost. (M12 Gap 3.)
    private func encodeMessage(_ msg: ChatMessage) -> [String: Any] {
        var m: [String: Any] = ["role": msg.role]
        m["content"] = msg.content ?? ""
        if let calls = msg.tool_calls, !calls.isEmpty {
            m["tool_calls"] = calls.map { call -> [String: Any] in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.function.name,
                        "arguments": call.function.arguments,
                    ],
                ]
            }
        }
        if let tcid = msg.tool_call_id { m["tool_call_id"] = tcid }
        return m
    }

    /// OpenAI-compatible `tools` array from the request's tool specs. The
    /// JSON-Schema `parameters` come through `JSONValue.anyValue`.
    private func encodeTools(_ tools: [Tool]?) -> [[String: Any]]? {
        guard let tools, !tools.isEmpty else { return nil }
        return tools.map { tool in
            var fn: [String: Any] = ["name": tool.function.name]
            if let desc = tool.function.description { fn["description"] = desc }
            if let params = tool.function.parameters { fn["parameters"] = params.anyValue }
            return ["type": "function", "function": fn]
        }
    }

    private func applyReasoningMode(_ request: ChatCompletionRequest, into body: inout [String: Any]) {
        // DSV4 reasoning-mode translation (see RemoteProviderService.dsv4RemoteEffort).
        let effort = request.modelOptions?["reasoningEffort"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch effort {
        case "instruct", "chat", "none", "no_think", "nothink", "off", "disabled", "false":
            body["thinking"] = ["type": "disabled"]
        case .some(let nonEmpty) where !nonEmpty.isEmpty:
            body["reasoning_effort"] = nonEmpty
        case .some, .none:
            body["thinking"] = ["type": "disabled"]
        }
    }

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        guard let apiKey = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] else {
            throw EngineError(message: "DEEPSEEK_API_KEY not set")
        }

        NSLog("[CloudChatEngine] Starting streamChat — model=\(request.model ?? model), messages=\(request.messages.count), tools=\(request.tools?.count ?? 0)")

        let toolSpecs = encodeTools(request.tools)
        let resolvedModel = request.model ?? model

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // Running conversation as wire dicts. We append the
                    // assistant tool-call message + tool-result messages after
                    // each tool round so the continuation request carries the
                    // full context. (M12 Gap 3 — engine-side agent loop, since
                    // the upstream RemoteProviderService tool path is amputated
                    // on Intel.)
                    var wireMessages = request.messages.map { self.encodeMessage($0) }
                    let maxToolRounds = 12
                    var round = 0
                    var totalChunks = 0

                    while round < maxToolRounds {
                        round += 1

                        var body: [String: Any] = [
                            "model": resolvedModel,
                            "messages": wireMessages,
                            "stream": true,
                        ]
                        if let toolSpecs {
                            body["tools"] = toolSpecs
                            body["tool_choice"] = "auto"
                        }
                        self.applyReasoningMode(request, into: &body)

                        var urlRequest = URLRequest(url: URL(string: self.apiBase)!)
                        urlRequest.httpMethod = "POST"
                        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                        urlRequest.timeoutInterval = 300
                        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
                        NSLog("[CloudChatEngine] Request body: model=\(resolvedModel) round=\(round) tools=\(toolSpecs?.count ?? 0)")

                        let (asyncBytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                        if let httpResp = response as? HTTPURLResponse {
                            NSLog("[CloudChatEngine] HTTP status: \(httpResp.statusCode)")
                        }

                        var assistantContent = ""
                        var partials: [Int: PartialToolCall] = [:]
                        var announcedNames: Set<Int> = []

                        for try await line in asyncBytes.lines {
                            guard line.hasPrefix("data: "), !Task.isCancelled else { continue }
                            let dataStr = String(line.dropFirst(6))
                            if dataStr == "[DONE]" { break }

                            guard let chunkData = dataStr.data(using: .utf8),
                                let json = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
                                let choices = json["choices"] as? [[String: Any]],
                                let delta = choices.first?["delta"] as? [String: Any]
                            else { continue }

                            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                                totalChunks += 1
                                continuation.yield(StreamingReasoningHint.encode(reasoning))
                            }
                            if let content = delta["content"] as? String, !content.isEmpty {
                                totalChunks += 1
                                assistantContent += content
                                continuation.yield(content)
                            }
                            // Accumulate streamed tool calls (M12 Gap 3).
                            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                                for tc in tcs {
                                    let idx = tc["index"] as? Int ?? 0
                                    var partial = partials[idx] ?? PartialToolCall()
                                    if let id = tc["id"] as? String, !id.isEmpty { partial.id = id }
                                    if let fn = tc["function"] as? [String: Any] {
                                        if let n = fn["name"] as? String, !n.isEmpty { partial.name += n }
                                        if let a = fn["arguments"] as? String { partial.arguments += a }
                                    }
                                    partials[idx] = partial
                                    // Surface the pending tool name once so the
                                    // chat shows a "calling …" chip while args
                                    // stream / the tool runs.
                                    if !partial.name.isEmpty, !announcedNames.contains(idx) {
                                        announcedNames.insert(idx)
                                        continuation.yield(StreamingToolHint.encode(partial.name))
                                    }
                                }
                            }
                        }

                        // No tools requested this round → the assistant's final
                        // answer has streamed; we're done.
                        if partials.isEmpty {
                            NSLog("[CloudChatEngine] Stream finished — \(totalChunks) chunks, \(round) round(s), no tool calls")
                            continuation.finish()
                            return
                        }

                        // Echo the assistant's tool-call message into the
                        // continuation context.
                        let orderedCalls = partials.sorted { $0.key < $1.key }.map { $0.value }
                        wireMessages.append([
                            "role": "assistant",
                            "content": assistantContent,
                            "tool_calls": orderedCalls.map { call in
                                [
                                    "id": call.id,
                                    "type": "function",
                                    "function": ["name": call.name, "arguments": call.arguments],
                                ]
                            },
                        ])

                        // Execute each tool, surface the result card, and feed
                        // the result back as a tool message.
                        for call in orderedCalls {
                            let callId = call.id.isEmpty ? "call_\(UUID().uuidString.prefix(20))" : call.id
                            let result: String
                            do {
                                result = try await ToolRegistry.shared.execute(
                                    name: call.name,
                                    argumentsJSON: call.arguments
                                )
                            } catch {
                                result = ToolEnvelope.fromError(error, tool: call.name)
                            }
                            continuation.yield(
                                StreamingToolHint.encodeDone(
                                    callId: callId,
                                    name: call.name,
                                    arguments: call.arguments,
                                    result: result
                                )
                            )
                            wireMessages.append([
                                "role": "tool",
                                "tool_call_id": callId,
                                "content": result,
                            ])
                        }
                        // Loop: send the continuation request with tool results.
                    }

                    NSLog("[CloudChatEngine] Tool loop hit max rounds (\(maxToolRounds))")
                    continuation.finish()
                } catch {
                    NSLog("[CloudChatEngine] Stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        guard let apiKey = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] else {
            throw EngineError(message: "DEEPSEEK_API_KEY not set")
        }

        var urlRequest = URLRequest(url: URL(string: apiBase)!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 300

        let body: [String: Any] = [
            "model": request.model ?? model,
            "messages": request.messages.map { msg -> [String: Any] in
                var m: [String: Any] = ["role": msg.role]
                if let content = msg.content { m["content"] = content }
                return m
            },
            "stream": false,
        ]

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: urlRequest)
        return try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    }

    struct EngineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

#endif
