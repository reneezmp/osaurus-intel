//
//  ChatEngineTestDoubles.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - ChatEngineProtocol mock

struct MockChatEngine: ChatEngineProtocol {
    var deltas: [String] = []
    var completeText: String = ""
    var model: String = "mock"

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for d in deltas { continuation.yield(d) }
            continuation.finish()
        }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        // Intel: the completion response (`CloudChatEngine.swift`) nests its
        // own choice/message types instead of upstream's `ChatChoice` /
        // `ChatMessage`.
        ChatCompletionResponse(
            id: "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))",
            object: nil,
            created: Int(Date().timeIntervalSince1970),
            model: model,
            choices: [.init(
                index: 0,
                message: .init(role: "assistant", content: completeText, tool_calls: nil, reasoning_content: nil),
                finish_reason: "stop"
            )],
            usage: .init(prompt_tokens: 0, completion_tokens: 0, total_tokens: 0)
        )
    }
}

// Intel: upstream's `FakeModelService` is left out — `ModelService` isn't
// compiled on Intel (`Services/Inference/ModelService.swift` is excluded).
