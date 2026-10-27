//
//  IntelGeminiReasoningTests.swift
//  osaurusTests
//
//  Upstream #3115 on Intel's own paths: the picker profile, the composer's
//  route check, the engine's wire gate and the native `thinkingConfig`.
//  Upstream's equivalents test `ModelPickerItemCache.remoteModelItems` and
//  `RemoteChatRequest.toGeminiRequest`, which Intel doesn't compile.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelGeminiReasoningTests {

    // MARK: Picker profile

    @Test func profileOffersEachModelsOwnLevels() throws {
        func levels(_ modelId: String) -> [String]? {
            guard
                let option = ModelProfileRegistry.options(for: modelId).first(where: { $0.id == "reasoningEffort" }),
                case .segmented(let segments) = option.kind
            else { return nil }
            return segments.map(\.id)
        }
        #expect(levels("google/gemini-3-pro-preview") == ["low", "high"])
        #expect(levels("openrouter/google/gemini-3.8-flash") == ["low", "medium", "high"])
        #expect(levels("google/gemini-3.6-flash") == ["minimal", "low", "medium", "high"])
        #expect(levels("google/gemini-3-pro-image-preview") == nil)
        #expect(levels("google/gemini-2.0-flash") == nil)
        #expect(ModelProfileRegistry.profile(for: "google/gemini-2.5-pro") is GeminiReasoningProfile.Type)
    }

    @Test func defaultIsDisplayOnly() {
        #expect(ModelProfileRegistry.defaults(for: "openrouter/google/gemini-3.8-flash")["reasoningEffort"] == .string("medium"))
        #expect(ModelProfileRegistry.defaults(for: "google/gemini-2.5-pro").isEmpty)
        #expect(
            ModelProfileRegistry.inlineReasoningSuffixLabel(for: "google/gemini-3-pro-preview", values: [:]) == "High")
        // Nothing is synthesized into a request without an explicit choice.
        #expect(ModelProfileRegistry.normalizedOptions(for: "google/gemini-3-pro-preview", persisted: nil).isEmpty)
        #expect(
            ModelProfileRegistry.normalizedOptions(
                for: "google/gemini-3-pro-preview", persisted: ["reasoningEffort": .string("low")])
                == ["reasoningEffort": .string("low")])
    }

    // MARK: Composer route check

    @Test func composerOffersEffortOnlyOnForwardingRoutes() {
        let providers = [
            RemoteProvider(name: "OpenRouter", host: "openrouter.ai"),
            RemoteProvider(name: "Google", host: "generativelanguage.googleapis.com", providerType: .gemini),
            RemoteProvider(name: "Proxy", host: "litellm.internal"),
            RemoteProvider(name: "Off", host: "openrouter.ai", enabled: false),
        ]
        func offers(_ id: String) -> Bool {
            IntelGeminiReasoningRoute.offersEffort(forModelId: id, providers: providers)
        }
        #expect(offers("openrouter/google/gemini-3.8-flash"))
        #expect(offers("google/gemini-3-pro-preview"))
        #expect(!offers("proxy/gemini-3.8-flash"))
        #expect(!offers("off/google/gemini-3.8-flash"), "a disabled provider owns nothing")
        #expect(!offers("gemini-3.8-flash"), "an unqualified id has no known route")
        // Other models are left to their own profiles.
        #expect(offers("proxy/gpt-6"))
        #expect(offers("proxy/deepseek-flash"))
    }

    // MARK: Engine wire gate

    @Test func engineSendsOnlyDocumentedEffortsOnForwardingRoutes() {
        #expect(GeminiReasoningContract.wireAccepts(
            effort: "high", modelId: "gemini-3-pro-preview", providerType: .gemini,
            host: "generativelanguage.googleapis.com"))
        #expect(!GeminiReasoningContract.wireAccepts(
            effort: "medium", modelId: "gemini-3-pro-preview", providerType: .gemini,
            host: "generativelanguage.googleapis.com"), "3 Pro documents no medium")
        #expect(GeminiReasoningContract.wireAccepts(
            effort: "low", modelId: "google/gemini-3.8-flash", providerType: .openaiLegacy, host: "openrouter.ai"))
        #expect(!GeminiReasoningContract.wireAccepts(
            effort: "low", modelId: "gemini-3.8-flash", providerType: .openaiLegacy, host: "litellm.internal"))
        #expect(!GeminiReasoningContract.wireAccepts(
            effort: "low", modelId: "gemini-3.8-flash", providerType: nil, host: ""))
        // Non-Gemini models are unaffected.
        #expect(GeminiReasoningContract.wireAccepts(
            effort: "xhigh", modelId: "gpt-6", providerType: .openaiLegacy, host: "litellm.internal"))
    }

    // MARK: Native thinkingConfig (upstream's RemoteChatRequestEncodingTests cases)

    private func generationConfig(model: String, effort: String?, maxTokens: Int? = nil) throws -> [String: Any]? {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "hi"]],
        ]
        if let effort { body["reasoning_effort"] = effort }
        if let maxTokens { body["max_tokens"] = maxTokens }
        let request = try IntelGeminiAdapter.makeRequest(chatCompletions: body)
        return request["generationConfig"] as? [String: Any]
    }

    @Test func geminiRequestMapsReasoningEffortIntoThinkingConfig() throws {
        let level = try generationConfig(model: "gemini-3.8-flash", effort: "high")?["thinkingConfig"] as? [String: Any]
        #expect(level?["thinkingLevel"] as? String == "high")
        #expect(level?["thinkingBudget"] == nil)

        let budget = try generationConfig(model: "gemini-2.5-flash", effort: "low")?["thinkingConfig"] as? [String: Any]
        #expect(budget?["thinkingBudget"] as? Int == 1024)
        #expect(budget?["thinkingLevel"] == nil)
    }

    @Test func geminiRequestOmitsThinkingConfigWhenEffortUnsupported() throws {
        for (model, effort) in [("gemini-3-pro-preview", "medium"), ("gemini-2.0-flash", "high"), ("gemini-3.8-flash", nil)] {
            let config = try generationConfig(model: model, effort: effort, maxTokens: 256)
            #expect(config?["thinkingConfig"] == nil, "\(model) \(effort ?? "nil")")
        }
        #expect(try generationConfig(model: "gemini-3.8-flash", effort: nil) == nil)
    }
}
