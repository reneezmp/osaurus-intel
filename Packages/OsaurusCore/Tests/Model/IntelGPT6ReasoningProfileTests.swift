//
//  IntelGPT6ReasoningProfileTests.swift
//  osaurusTests
//
//  Upstream a0aaa945d, Intel slice: GPT-6 Astra gets its own effort
//  surface (no none/minimal) and reasoning models never receive temperature.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelGPT6ReasoningProfileTests {

    @Test func astraUsesTheGPT6ProfileWithoutMinimal() throws {
        for id in ["gpt-6-astra", "openai/gpt-6-astra", "gpt-6", "gpt-6.1"] {
            let profile = try #require(ModelProfileRegistry.profile(for: id))
            #expect(ObjectIdentifier(profile) == ObjectIdentifier(OpenAIGPT6ReasoningProfile.self), "\(id)")
        }
        let segments = OpenAIGPT6ReasoningProfile.options.first.flatMap { option -> [String]? in
            if case .segmented(let items) = option.kind { return items.map(\.id) }
            return nil
        }
        #expect(segments == ["low", "medium", "high", "xhigh"])
    }

    @Test func fusedSuffixAndOlderFamiliesAreNotGPT6() {
        #expect(!OpenAIGPT6ReasoningProfile.matches(modelId: "gpt-60"))
        #expect(!OpenAIGPT6ReasoningProfile.matches(modelId: "gpt-5.5"))
        #expect(
            ModelProfileRegistry.profile(for: "gpt-5.5").map(ObjectIdentifier.init)
                == ObjectIdentifier(OpenAIReasoningProfile.self))
    }

    @Test func reasoningModelsDropTemperatureOthersKeepIt() {
        #expect(ChatEngine.rejectsSamplingTemperature(modelId: "gpt-6-astra"))
        #expect(ChatEngine.rejectsSamplingTemperature(modelId: "o3"))
        #expect(!ChatEngine.rejectsSamplingTemperature(modelId: "deepseek-v4-pro"))
        #expect(!ChatEngine.rejectsSamplingTemperature(modelId: "qwen-3-8-max"))
    }

    @Test func codexDiscoveryAcceptsGPT6CodenameSlugs() {
        let pattern = OpenAICodexOAuthService.codexSlugPattern
        for slug in ["gpt-6-astra", "gpt-5.6-terra", "gpt-5.4-codex"] {
            #expect(slug.range(of: pattern, options: .regularExpression) != nil, "\(slug)")
        }
        for slug in ["gpt-5-4-thinking", "gpt-4o"] {
            #expect(slug.range(of: pattern, options: .regularExpression) == nil, "\(slug)")
        }
        #expect(OpenAICodexOAuthService.supportedModels.contains("gpt-6-astra"))
    }
}
