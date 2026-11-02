//
//  IntelCodexCLIModelsTests.swift
//  OsaurusCoreTests
//
//  `W-server-api` stage 8: the Intel model side of "Use with Codex CLI"
//  (served ids, catalog context windows, Osaurus Router detection). Pure
//  inputs; nothing reads or writes `~/.codex`.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct IntelCodexCLIModelsTests {
    @Test func servedIdPrefix_matchesTheModelsList() {
        #expect(IntelCodexCLIModels.servedIdPrefix(providerName: "Osaurus") == "osaurus")
        #expect(IntelCodexCLIModels.servedIdPrefix(providerName: "My Venice/EU") == "my-venice-eu")
    }

    @Test func routerModels_areRecognisedByTheirProvider() {
        let router = RemoteProvider(
            id: RemoteProviderManager.osaurusRouterProviderId, name: "Osaurus", host: "router.example")
        let other = RemoteProvider(name: "Venice", host: "api.venice.ai")
        #expect(IntelCodexCLIModels.isOsaurusRouterModel("osaurus/qwen3-32b", providers: [router, other]))
        #expect(!IntelCodexCLIModels.isOsaurusRouterModel("venice/llama", providers: [router, other]))
        #expect(!IntelCodexCLIModels.isOsaurusRouterModel("osaurus-like/x", providers: [router, other]))
        #expect(!IntelCodexCLIModels.isOsaurusRouterModel("osaurus/qwen3-32b", providers: [other]))
    }

    @Test func contextWindow_isTheCatalogValue() {
        let items: [ModelPickerItem] = [
            .fromRemoteModel(modelId: "venice/llama", providerName: "Venice", providerId: UUID(), contextLength: 131_072),
            .fromRemoteModel(modelId: "venice/tiny", providerName: "Venice", providerId: UUID()),
        ]
        #expect(IntelCodexCLIModels.contextWindow(for: "venice/llama", items: items) == 131_072)
        #expect(IntelCodexCLIModels.contextWindow(for: "venice/tiny", items: items) == nil)
        #expect(IntelCodexCLIModels.contextWindow(for: "venice/unknown", items: items) == nil)
        #expect(IntelCodexCLIModels.contextWindow(for: "", items: items) == nil)
    }
}
