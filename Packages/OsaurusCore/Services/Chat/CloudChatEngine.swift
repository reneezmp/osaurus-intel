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

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        guard let apiKey = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] else {
            throw EngineError(message: "DEEPSEEK_API_KEY not set")
        }

        NSLog("[CloudChatEngine] Starting streamChat — model=\(request.model ?? model), messages=\(request.messages.count)")

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
            "stream": true,
        ]

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        NSLog("[CloudChatEngine] Request body: model=\(request.model ?? model)")

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        if let httpResp = response as? HTTPURLResponse {
            NSLog("[CloudChatEngine] HTTP status: \(httpResp.statusCode)")
        } else {
            NSLog("[CloudChatEngine] Response is not HTTP — type: \(type(of: response))")
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var chunkCount = 0
                    for try await line in asyncBytes.lines {
                        guard line.hasPrefix("data: "), !Task.isCancelled else { continue }
                        let dataStr = String(line.dropFirst(6))
                        if dataStr == "[DONE]" {
                            NSLog("[CloudChatEngine] Received [DONE] after \(chunkCount) content chunks")
                            break
                        }

                        guard let chunkData = dataStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any] else { continue }

                        // DeepSeek's Max-reasoning mode (and other
                        // OpenAI-compatible providers like Qwen / vLLM)
                        // streams the thought process on a sibling
                        // `reasoning_content` field. Wrap it in the
                        // `StreamingReasoningHint` sentinel so the
                        // `ChatView` decode site routes it into
                        // `ChatTurn.thinking` (which `BlockMemoizer`
                        // surfaces as the Think panel).
                        if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                            chunkCount += 1
                            continuation.yield(StreamingReasoningHint.encode(reasoning))
                        }
                        if let content = delta["content"] as? String, !content.isEmpty {
                            chunkCount += 1
                            continuation.yield(content)
                        }
                    }
                    NSLog("[CloudChatEngine] Stream finished — \(chunkCount) chunks yielded")
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
