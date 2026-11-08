//
//  IntelReasoningCatalogTests.swift
//  osaurusTests
//
//  `W-cov-reaudit` stage 3b-3 (docs/COV_REAUDIT.md): upstream #1991's live
//  reasoning catalog on Intel. The Codex `/models` catalog's per-model
//  levels and the official OpenAI contract feed
//  `RemoteReasoningCapabilityCatalog` (filled by Intel's
//  `ModelPickerItemCache`), and `ModelProfileRegistry` (upstream's) prefers
//  it over the static profiles. Gemini's route-scoped levels are
//  `IntelGeminiReasoningTests`; the static profiles are upstream's
//  `ModelProfileRegistryTests`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelReasoningCatalogTests {
    private static let codexCatalog = #"""
        {"models":[
          {"slug":"gpt-5.6-terra","visibility":"list","priority":1,
           "default_reasoning_level":"medium",
           "supported_reasoning_levels":[
             {"effort":"low","description":"Fast answers"},
             {"effort":"medium","description":"Balanced"},
             {"effort":"ultra","description":"Deepest"},
             {"effort":"  ","description":"malformed"}
           ]},
          {"slug":"gpt-5-4-thinking","visibility":"list","shell_type":"disabled"}
        ]}
        """#

    @Test func codexCatalogKeepsLevelsInOrderAndDropsMalformedOnes() throws {
        let metadata = try #require(
            OpenAICodexOAuthService.catalogModelMetadata(fromModelsJSON: Data(Self.codexCatalog.utf8)))
        #expect(metadata["gpt-5-4-thinking"] == nil)
        let terra = try #require(metadata["gpt-5.6-terra"])
        #expect(terra.supportedReasoningLevels.map(\.effort) == ["low", "medium", "ultra"])
        #expect(terra.defaultReasoningLevel == "medium")
        let capabilities = try #require(ModelReasoningCapabilities(codex: terra))
        #expect(capabilities.levels.first?.description == "Fast answers")
    }

    @Test func catalogLevelsWinOverTheStaticProfile() throws {
        let saved = RemoteReasoningCapabilityCatalog.snapshot()
        defer { RemoteReasoningCapabilityCatalog.replaceAll(saved) }
        let id = "chatgpt/gpt-5.6-terra"
        RemoteReasoningCapabilityCatalog.replaceAll([
            id: ModelReasoningCapabilities(
                levels: ["low", "medium", "ultra"].map { .init(id: $0) }, defaultLevelId: "medium")
        ])
        let option = try #require(ModelProfileRegistry.options(for: id).first { $0.id == "reasoningEffort" })
        guard case .segmented(let segments) = option.kind else {
            Issue.record("expected segments")
            return
        }
        #expect(segments.map(\.id) == ["low", "medium", "ultra"])
        // A level the catalog offers survives normalization; one it doesn't is dropped.
        #expect(
            ModelProfileRegistry.normalizedOptions(for: id, persisted: ["reasoningEffort": .string("ultra")])
                == ["reasoningEffort": .string("ultra")])
        #expect(
            ModelProfileRegistry.normalizedOptions(for: id, persisted: ["reasoningEffort": .string("max")]).isEmpty)
        // The catalog default is display-only.
        #expect(ModelProfileRegistry.normalizedOptions(for: id, persisted: nil).isEmpty)
        #expect(ModelProfileRegistry.effectiveReasoningEffort(for: id, values: [:]) == "medium")
    }

    @Test func officialOpenAIContractCoversGPT56AndGPT6Only() {
        #expect(ModelPickerItem.officialOpenAIReasoningCapabilities(forModelId: "gpt-5.6-sol") == .officialOpenAIGPT56)
        #expect(
            ModelPickerItem.officialOpenAIReasoningCapabilities(forModelId: "gpt-6-astra") == .officialOpenAIGPT6Astra)
        #expect(ModelPickerItem.officialOpenAIReasoningCapabilities(forModelId: "gpt-60") == nil)
        #expect(ModelPickerItem.officialOpenAIReasoningCapabilities(forModelId: "gpt-5.5") == nil)
        // Astra rejects `none`; the public API never offers Codex's `ultra`.
        #expect(!ModelReasoningCapabilities.officialOpenAIGPT6Astra.levels.contains { $0.id == "none" })
        #expect(!ModelReasoningCapabilities.officialOpenAIGPT56.levels.contains { $0.id == "ultra" })
    }
}
