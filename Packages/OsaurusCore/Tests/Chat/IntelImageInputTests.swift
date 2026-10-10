//
//  IntelImageInputTests.swift
//  osaurusTests
//
//  Images reach cloud models (2026-10-10): Intel's `ChatMessage` used to drop
//  image data, so no picture was ever sent. Covers the message model, the
//  wire encoding, the Codex translation and the text-only fallback.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelImageInputTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
    private static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0, 1])

    @Test func imageInitializerKeepsTheImagesWithTheirType() {
        let message = ChatMessage(role: "user", text: "what is this?", imageData: [Self.png, Self.jpeg])
        #expect(message.content == "what is this?")
        #expect(message.hasMediaParts)
        #expect(message.imageUrls.count == 2)
        #expect(message.imageUrls[0].hasPrefix("data:image/png;base64,"))
        #expect(message.imageUrls[1].hasPrefix("data:image/jpeg;base64,"))
        #expect(!ChatMessage(role: "user", text: "plain", imageData: []).hasMediaParts)
    }

    @Test func messagesRoundTripStringAndPartsContent() throws {
        let decoder = JSONDecoder()
        let plain = try decoder.decode(ChatMessage.self, from: Data(#"{"role":"user","content":"hi"}"#.utf8))
        #expect(plain.content == "hi")
        #expect(plain.contentParts == nil)

        let vision = try decoder.decode(
            ChatMessage.self,
            from: Data(
                #"{"role":"user","content":[{"type":"text","text":"look"},{"type":"image_url","image_url":{"url":"https://example.com/a.png"}}]}"#
                    .utf8))
        #expect(vision.content == "look")
        #expect(vision.imageUrls == ["https://example.com/a.png"])

        let encoded = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(vision)) as? [String: Any])
        let parts = try #require(encoded["content"] as? [[String: Any]])
        #expect(parts.count == 2)
        let reencodedPlain = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        #expect(reencodedPlain["content"] as? String == "hi")
    }

    @Test func wirePartsMatchOpenAIShapes() {
        #expect(ChatEngine.wirePart(.text("a"))["type"] as? String == "text")
        let image = ChatEngine.wirePart(.imageUrl(url: "data:image/png;base64,AA==", detail: "low"))
        #expect(image["type"] as? String == "image_url")
        #expect((image["image_url"] as? [String: Any])?["url"] as? String == "data:image/png;base64,AA==")
        #expect((image["image_url"] as? [String: Any])?["detail"] as? String == "low")
    }

    @Test func codexTakesImagesAsInputImageParts() throws {
        let body: [String: Any] = [
            "model": "gpt-5",
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "describe"],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,AA=="]],
                ],
            ]],
        ]
        let request = try IntelCodexResponsesAdapter.makeRequest(chatCompletions: body)
        let input = try #require(request["input"] as? [[String: Any]])
        let parts = try #require(input.first?["content"] as? [[String: Any]])
        #expect(parts[0]["type"] as? String == "input_text")
        #expect(parts[1]["type"] as? String == "input_image")
        #expect(parts[1]["image_url"] as? String == "data:image/png;base64,AA==")
    }

    @Test func textOnlyRejectionsAreRecognised() {
        #expect(IntelImageInputFallback.isImageInputRejection(
            #"{"error":{"message":"Failed to deserialize the JSON body into the target type: messages[0]: unknown variant `image_url`, expected `text`"}}"#))
        #expect(IntelImageInputFallback.isImageInputRejection("user message content must be a string"))
        #expect(IntelImageInputFallback.isImageInputRejection("This model does not support image input"))
        #expect(!IntelImageInputFallback.isImageInputRejection("Invalid API key"))
        #expect(!IntelImageInputFallback.isImageInputRejection("max_tokens is too large"))
    }

    @Test func strippingKeepsTextAndLeavesANote() {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "be brief"],
            ["role": "user", "content": [
                ["type": "text", "text": "what is this?"],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64,AA=="]],
            ]],
        ]
        #expect(IntelImageInputFallback.containsImages(messages))
        let stripped = IntelImageInputFallback.strippingImages(messages)
        #expect(!IntelImageInputFallback.containsImages(stripped))
        #expect(stripped[0]["content"] as? String == "be brief")
        #expect(stripped[1]["content"] as? String == "what is this?\n" + IntelImageInputFallback.omittedImageNote)
    }

    @Test func rejectionsAreRememberedPerProviderAndModel() {
        IntelImageInputFallback.reset()
        defer { IntelImageInputFallback.reset() }
        #expect(!IntelImageInputFallback.isRejected(provider: "DeepSeek", model: "deepseek-v4-pro"))
        IntelImageInputFallback.recordRejection(provider: "DeepSeek", model: "deepseek-v4-pro")
        #expect(IntelImageInputFallback.isRejected(provider: "deepseek", model: "DeepSeek-V4-Pro"))
        #expect(!IntelImageInputFallback.isRejected(provider: "OpenRouter", model: "deepseek-v4-pro"))
    }
}
