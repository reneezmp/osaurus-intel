//
//  IntelGeminiAdapterTests.swift
//  osaurusTests
//
//  W-provider-wire-formats (2026-10-10): the Gemini generateContent
//  translation in front of Intel's cloud engine.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelGeminiAdapterTests {
    @Test func historyBecomesContentsWithFunctionParts() throws {
        let out = try IntelGeminiAdapter.makeRequest(chatCompletions: [
            "model": "models/gemini-3-pro",
            "max_tokens": 1000,
            "messages": [
                ["role": "system", "content": "be brief"],
                ["role": "user", "content": [
                    ["type": "text", "text": "what is this?"],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]],
                ]],
                [
                    "role": "assistant", "content": "",
                    "tool_calls": [[
                        "id": "gemini-1234abcd", "type": "function",
                        "function": ["name": "weather", "arguments": #"{"city":"Paris"}"#],
                        IntelGeminiAdapter.thoughtSignatureKey: "sig-1",
                    ]],
                ],
                ["role": "tool", "tool_call_id": "gemini-1234abcd", "content": "sunny"],
            ],
            "tools": [[
                "type": "function",
                "function": [
                    "name": "weather",
                    "parameters": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": ["city": ["type": ["string", "null"], "title": "City"]],
                        "required": ["city", "ghost"],
                    ],
                ],
            ]],
            "tool_choice": "auto",
        ])
        #expect(((out["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String == "be brief")
        #expect((out["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int == 1000)
        let contents = try #require(out["contents"] as? [[String: Any]])
        #expect(contents.map { $0["role"] as? String } == ["user", "model", "user"])
        let userParts = try #require(contents[0]["parts"] as? [[String: Any]])
        #expect(userParts[0]["text"] as? String == "what is this?")
        #expect((userParts[1]["inlineData"] as? [String: Any])?["mimeType"] as? String == "image/png")
        let callPart = try #require((contents[1]["parts"] as? [[String: Any]])?.first)
        #expect(callPart["thoughtSignature"] as? String == "sig-1")
        #expect(((callPart["functionCall"] as? [String: Any])?["args"] as? [String: Any])?["city"] as? String == "Paris")
        // Intel: the response names the function, not the call id.
        let response = try #require(((contents[2]["parts"] as? [[String: Any]])?.first)?["functionResponse"] as? [String: Any])
        #expect(response["name"] as? String == "weather")
        #expect((response["response"] as? [String: Any])?["result"] as? String == "sunny")
        // Schema cleaned with upstream's rules.
        let declaration = try #require(
            ((out["tools"] as? [[String: Any]])?.first?["functionDeclarations"] as? [[String: Any]])?.first)
        let schema = try #require(declaration["parameters"] as? [String: Any])
        #expect(schema["additionalProperties"] == nil)
        #expect(schema["required"] as? [String] == ["city"])
        let city = try #require((schema["properties"] as? [String: Any])?["city"] as? [String: Any])
        #expect(city["type"] as? String == "string")
        #expect(city["nullable"] as? Bool == true)
        #expect(city["title"] == nil)
        #expect(((out["toolConfig"] as? [String: Any])?["functionCallingConfig"] as? [String: Any])?["mode"] as? String == "AUTO")
    }

    @Test func streamURLDropsTheModelsPrefix() {
        #expect(
            IntelGeminiAdapter.streamURL(
                modelsEndpoint: "https://generativelanguage.googleapis.com/v1beta/models", model: "models/gemini-3-pro")
                == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro:streamGenerateContent?alt=sse")
    }

    @Test func chunksBecomeOpenAILines() throws {
        var translator = IntelGeminiSSETranslator()
        var lines: [String] = []
        lines += try translator.translate(
            #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":"thinking…","thought":true},{"text":"Let me check."}]}}]}"#)
        lines += try translator.translate(
            #"data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"weather","args":{"city":"Paris"}},"thoughtSignature":"sig-9"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":20,"candidatesTokenCount":5}}"#)
        let frames: [[String: Any]] = lines.compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8)) as? [String: Any]
        }
        func delta(_ frame: [String: Any]) -> [String: Any]? {
            ((frame["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any]
        }
        #expect(delta(frames[0])?["content"] as? String == "Let me check.")
        #expect((frames[1]["usage"] as? [String: Any])?["prompt_tokens"] as? Int == 20)
        let call = try #require((delta(frames[2])?["tool_calls"] as? [[String: Any]])?.first)
        #expect((call["id"] as? String)?.hasPrefix("gemini-") == true)
        #expect((call["function"] as? [String: Any])?["arguments"] as? String == #"{"city":"Paris"}"#)
        #expect(call[IntelGeminiAdapter.thoughtSignatureKey] as? String == "sig-9")
    }

    @Test func safetyFinishFails() {
        var translator = IntelGeminiSSETranslator()
        #expect(throws: IntelGeminiAdapter.Failure.self) {
            _ = try translator.translate(#"data: {"candidates":[{"finishReason":"SAFETY"}]}"#)
        }
    }
}
