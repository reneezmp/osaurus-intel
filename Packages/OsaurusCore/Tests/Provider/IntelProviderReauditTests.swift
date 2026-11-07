//
//  IntelProviderReauditTests.swift
//  osaurusTests
//
//  `W-cov-reaudit` stage 3a (docs/COV_REAUDIT.md): provider fixes Intel's
//  own copies were missing.
//  - #2464 / #2463 / #2416: known windows for the official OpenAI host, the
//    xAI OAuth catalog and Codex's live catalog.
//  - #2108: a tool call the output cap cut off is refused, and Anthropic's
//    `max_tokens` stop reaches the engine as `finish_reason: length`.
//  - #2415: transport failures that should be retried when the network
//    returns are told apart from terminal ones.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct IntelProviderContextWindowTests {
    @Test func officialOpenAITableUsesTheLongestPrefix() {
        #expect(ModelPickerItem.officialOpenAIContextWindow(forModelId: "gpt-5.6") == 1_050_000)
        #expect(ModelPickerItem.officialOpenAIContextWindow(forModelId: "gpt-5.2-2026-01-01") == 400_000)
        #expect(ModelPickerItem.officialOpenAIContextWindow(forModelId: "gpt-5-mini") == 400_000)
        #expect(ModelPickerItem.officialOpenAIContextWindow(forModelId: "openai/gpt-4o") == 128_000)
        #expect(ModelPickerItem.officialOpenAIContextWindow(forModelId: "llama-3") == nil)
    }

    @Test func knownWindowsAreScopedToTheirProvider() {
        #expect(
            ModelPickerItem.knownProviderContextWindow(
                providerType: .openaiLegacy, authType: .apiKey, host: "api.openai.com", modelId: "gpt-4.1")
                == 1_047_576)
        // An OpenAI-compatible proxy's ids aren't OpenAI's to trust.
        #expect(
            ModelPickerItem.knownProviderContextWindow(
                providerType: .openaiLegacy, authType: .apiKey, host: "openrouter.ai", modelId: "gpt-4.1")
                == nil)
        #expect(
            ModelPickerItem.knownProviderContextWindow(
                providerType: .openaiLegacy, authType: .xaiOAuth, host: "api.x.ai", modelId: "grok-4.6")
                == 500_000)
    }
}

@Suite
struct IntelOutputLimitedToolCallTests {
    @Test func messageNamesTheCallAndTheBytesReceived() {
        let message = ChatEngine.outputLimitToolCallMessage([(name: "file_write", argumentBytes: 120)])
        #expect(message.contains("'file_write'"))
        #expect(message.contains("received 120 bytes"))
        #expect(message.contains("Max Tokens"))
    }

    @Test func anthropicMaxTokensStopBecomesFinishReasonLength() throws {
        var translator = IntelAnthropicSSETranslator()
        let lines = try translator.translate(
            #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":4096}}"#)
        let json = try #require(lines.first.flatMap { line -> [String: Any]? in
            guard line.hasPrefix("data: "), let data = line.dropFirst(6).data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        })
        let choice = (json["choices"] as? [[String: Any]])?.first
        #expect(choice?["finish_reason"] as? String == "length")
    }

    @Test func anthropicNaturalStopEmitsNothing() throws {
        var translator = IntelAnthropicSSETranslator()
        let lines = try translator.translate(
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":10}}"#)
        #expect(lines.isEmpty)
    }
}

@Suite
@MainActor
struct IntelProviderRecoveryClassificationTests {
    @Test func offlineAndTimeoutsAreTransient() {
        #expect(RemoteProviderManager.isTransientConnectError(URLError(.notConnectedToInternet)))
        #expect(RemoteProviderManager.isTransientConnectError(URLError(.timedOut)))
        #expect(RemoteProviderManager.isTransientConnectError(
            NSError(domain: NSURLErrorDomain, code: URLError.cannotFindHost.rawValue)))
    }

    @Test func badURLsAndOtherErrorsAreNot() {
        #expect(!RemoteProviderManager.isTransientConnectError(URLError(.badURL)))
        #expect(!RemoteProviderManager.isTransientConnectError(URLError(.userAuthenticationRequired)))
        #expect(!RemoteProviderManager.isTransientConnectError(CancellationError()))
    }
}
