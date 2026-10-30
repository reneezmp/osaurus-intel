//
//  ModelPickerTabTests.swift
//  osaurusTests
//
//  Covers the tab grouping used by the model picker's horizontal provider
//  tabs: a single "Local" tab (Foundation first, then on-device models
//  sorted by name) followed by one tab per remote provider in the order
//  providers first appear in the options array.
//
//  Intel (2026-10-30, `W-server-api` stage 5b): upstream's grouping cases,
//  which `GET /models/picker` relies on. The duplicate-id case (it builds
//  the picker table's `ModelPickerRow`) and the committed-tab and
//  local-source filter cases test upstream's picker UI, which Intel's
//  picker doesn't use.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ModelPickerTabTests {

    private func localModel(id: String, name: String) -> ModelPickerItem {
        ModelPickerItem(id: id, displayName: name, source: .local)
    }

    // MARK: - Local tab composition

    @Test func localTab_putsFoundationFirstThenLocalsSortedByName() {
        let items: [ModelPickerItem] = [
            localModel(id: "mlx/zeta", name: "Zeta"),
            localModel(id: "mlx/alpha", name: "Alpha"),
            .foundation(),
            localModel(id: "mlx/mid", name: "Mid"),
        ]

        let tabs = items.groupedByTab()
        #expect(tabs.count == 1)

        let local = tabs[0]
        #expect(local.key == "local")
        #expect(local.title == "Local")
        #expect(local.models.map(\.id) == ["foundation", "mlx/alpha", "mlx/mid", "mlx/zeta"])
    }

    @Test func localTab_omittedWhenNoLocalOrFoundationModels() {
        let providerId = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(modelId: "openai/gpt-4o", providerName: "OpenAI", providerId: providerId)
        ]

        let tabs = items.groupedByTab()
        #expect(tabs.count == 1)
        #expect(tabs[0].key == "remote-\(providerId.uuidString)")
    }

    // MARK: - Provider tab ordering

    @Test func providerTabs_followFirstAppearanceOrder_afterLocal() {
        let openAIId = UUID()
        let anthropicId = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(modelId: "anthropic/claude-opus-4", providerName: "Anthropic", providerId: anthropicId),
            .foundation(),
            .fromRemoteModel(modelId: "openai/gpt-4o", providerName: "OpenAI", providerId: openAIId),
            .fromRemoteModel(modelId: "anthropic/claude-haiku-4.5", providerName: "Anthropic", providerId: anthropicId),
        ]

        let tabs = items.groupedByTab()
        #expect(tabs.map(\.title) == ["Local", "Anthropic", "OpenAI"])
        #expect(tabs[0].key == "local")
        #expect(tabs[1].key == "remote-\(anthropicId.uuidString)")
        #expect(tabs[2].key == "remote-\(openAIId.uuidString)")
    }

    @Test func providerTabs_pinOsaurusAfterLocal_preservingOtherProviderOrder() {
        let openAIId = UUID()
        let osaurusId = RemoteProviderManager.osaurusRouterProviderId
        let anthropicId = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(modelId: "openai/gpt-4o", providerName: "OpenAI", providerId: openAIId),
            .fromRemoteModel(modelId: "anthropic/claude-opus-4", providerName: "Anthropic", providerId: anthropicId),
            .foundation(),
            .fromRemoteModel(modelId: "osaurus/llama-3.3", providerName: "Osaurus", providerId: osaurusId),
        ]

        let tabs = items.groupedByTab()
        #expect(tabs.map(\.title) == ["Local", "Osaurus", "OpenAI", "Anthropic"])
    }

    @Test func providerTab_modelsSortedByDisplayName() {
        let providerId = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(modelId: "x/grok-4.3", providerName: "xAI", providerId: providerId),
            .fromRemoteModel(modelId: "x/grok-2", providerName: "xAI", providerId: providerId),
            .fromRemoteModel(modelId: "x/grok-3", providerName: "xAI", providerId: providerId),
        ]

        let tabs = items.groupedByTab()
        #expect(tabs.count == 1)
        #expect(tabs[0].models.map(\.displayName) == ["grok-2", "grok-3", "grok-4.3"])
    }

    // MARK: - Edge cases

    @Test func emptyOptions_yieldNoTabs() {
        let items: [ModelPickerItem] = []
        #expect(items.groupedByTab().isEmpty)
    }

    @Test func emptyTabs_areOmitted() {
        // Only foundation: a single Local tab, no remote tabs.
        let items: [ModelPickerItem] = [.foundation()]
        let tabs = items.groupedByTab()
        #expect(tabs.map(\.key) == ["local"])
        #expect(tabs[0].models.map(\.id) == ["foundation"])
    }
}
