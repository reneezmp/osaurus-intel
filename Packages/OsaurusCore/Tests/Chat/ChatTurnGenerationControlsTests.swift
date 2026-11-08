//
//  ChatTurnGenerationControlsTests.swift
//  osaurusTests
//
//  Upstream's (#2101), adapted: Intel's request has no `enable_thinking`;
//  the frozen choice rides `modelOptions` (`ChatTurnGenerationControls`).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Chat turn generation controls")
struct ChatTurnGenerationControlsTests {
    private func request() -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: "JANGQ-AI/Ornith-1.0-9B-JANG_4M",
            messages: [ChatMessage(role: "user", content: "Use three tools")],
            temperature: nil,
            max_tokens: 64,
            stream: true,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: nil
        )
    }

    @Test("explicit Thinking off reaches every reconstructed tool-loop request")
    func explicitOffPropagatesAcrossIterations() {
        let controls = ChatTurnGenerationControls.capture(
            activeModelOptions: ["disableThinking": .bool(true)]
        )

        var requests = [request(), request(), request(), request()]
        for index in requests.indices {
            controls.apply(to: &requests[index])
        }

        #expect(controls.enableThinking == false)
        #expect(
            requests.allSatisfy {
                $0.modelOptions?["disableThinking"]?.boolValue == true
            }
        )
    }

    @Test("explicit Thinking on reaches every reconstructed tool-loop request")
    func explicitOnPropagatesAcrossIterations() {
        let controls = ChatTurnGenerationControls.capture(
            activeModelOptions: ["disableThinking": .bool(false)]
        )

        var requests = [request(), request(), request()]
        for index in requests.indices {
            controls.apply(to: &requests[index])
        }

        #expect(controls.enableThinking == true)
        #expect(
            requests.allSatisfy {
                $0.modelOptions?["disableThinking"]?.boolValue == false
            }
        )
    }

    @Test("unset Thinking preserves the bundle default")
    func unsetPreservesBundleDefault() {
        let controls = ChatTurnGenerationControls.capture(
            activeModelOptions: [:]
        )
        var request = request()
        controls.apply(to: &request)

        #expect(controls.enableThinking == nil)
        #expect(request.modelOptions == nil)
    }

    @Test("non-thinking model options do not synthesize a Thinking override")
    func unrelatedOptionsDoNotSynthesizeThinking() {
        let controls = ChatTurnGenerationControls.capture(
            activeModelOptions: ["customFlag": .string("kept")]
        )
        var request = request()
        controls.apply(to: &request)

        #expect(controls.enableThinking == nil)
        #expect(request.modelOptions?["customFlag"]?.stringValue == "kept")
    }
}
