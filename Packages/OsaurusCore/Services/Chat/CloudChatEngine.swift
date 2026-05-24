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

        let (asyncBytes, _) = try await URLSession.shared.bytes(for: urlRequest)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await line in asyncBytes.lines {
                        guard line.hasPrefix("data: "), !Task.isCancelled else { continue }
                        let dataStr = String(line.dropFirst(6))
                        if dataStr == "[DONE]" { break }

                        guard let chunkData = dataStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any] else { continue }

                        if let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(content)
                        }
                    }
                    continuation.finish()
                } catch {
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
