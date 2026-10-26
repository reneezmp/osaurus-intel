//
//  IntelModelSelectionAfterDiscoveryTests.swift
//  osaurusTests
//
//  Intel: upstream #3200 (and ChatSession's earlier manual-pick rule)
//  against Intel's picker refresh. When provider models arrive after a
//  chat opened, the user's pick and a restored chat's saved model must
//  outrank the agent default.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct IntelModelSelectionAfterDiscoveryTests {

    private let provider = UUID()

    private func items(_ ids: String...) -> [ModelPickerItem] {
        ids.map { ModelPickerItem(id: $0, displayName: $0, source: .remote(providerName: "P", providerId: provider)) }
    }

    @Test func restoredChatKeepsItsModelOverTheAgentDefault() {
        let selected = ChatSession.modelAfterDiscovery(
            manual: nil,
            restored: "p/model-b",
            agentDefault: "p/model-a",
            previous: "p/model-a",
            among: items("p/model-a", "p/model-b")
        )
        #expect(selected == "p/model-b")
    }

    @Test func manualPickOutranksRestoredAndDefault() {
        let selected = ChatSession.modelAfterDiscovery(
            manual: "p/model-c",
            restored: "p/model-b",
            agentDefault: "p/model-a",
            previous: nil,
            among: items("p/model-a", "p/model-b", "p/model-c")
        )
        #expect(selected == "p/model-c")
    }

    @Test func unavailableChoicesFallThroughInOrder() {
        let list = items("p/model-a", "p/model-d")
        #expect(
            ChatSession.modelAfterDiscovery(
                manual: "p/gone", restored: "p/also-gone", agentDefault: "p/model-a",
                previous: "p/model-d", among: list) == "p/model-a")
        #expect(
            ChatSession.modelAfterDiscovery(
                manual: nil, restored: nil, agentDefault: "p/gone",
                previous: "p/model-d", among: list) == "p/model-d")
        #expect(
            ChatSession.modelAfterDiscovery(
                manual: nil, restored: nil, agentDefault: nil, previous: nil, among: list)
                == list.firstChatCapable?.id)
    }

    @Test func bareRestoredIdResolvesToItsProviderRow() {
        let selected = ChatSession.modelAfterDiscovery(
            manual: nil,
            restored: "model-b",
            agentDefault: "p/model-a",
            previous: nil,
            among: items("p/model-a", "p/model-b")
        )
        #expect(selected == "p/model-b")
    }
}
