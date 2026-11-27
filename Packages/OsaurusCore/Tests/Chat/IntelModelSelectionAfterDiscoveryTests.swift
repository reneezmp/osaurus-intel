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

    // MARK: - Claude Code is never the automatic default

    private var claude: [ModelPickerItem] {
        ClaudeCodeModel.allCases.map {
            ModelPickerItem(
                id: $0.pickerId, displayName: $0.displayName,
                source: .remote(providerName: "Claude Code", providerId: UUID()))
        }
    }

    private func discovered(
        manual: String? = nil, restored: String? = nil, agentDefault: String? = nil,
        previous: String? = nil, among list: [ModelPickerItem]
    ) -> String? {
        ChatSession.modelAfterDiscovery(
            manual: manual, restored: restored, agentDefault: agentDefault, previous: previous, among: list)
    }

    @Test func automaticDefaultSkipsClaudeCodeWhenAnotherProviderExists() {
        let list = claude + items("p/model-a")
        // An agent default nobody serves (Intel's built-in fallback id) must
        // not land on the first row.
        #expect(discovered(agentDefault: "deepseek-v4-pro", among: list) == "p/model-a")
        #expect(discovered(among: list) == "p/model-a")
        #expect(!ChatSession.needsModelChoice(selected: nil, among: list))
    }

    @Test func nothingIsSelectedWithOnlyClaudeCode() {
        #expect(discovered(agentDefault: "deepseek-v4-pro", among: claude) == nil)
        #expect(claude.automaticDefault == nil)
        #expect(ChatSession.needsModelChoice(selected: nil, among: claude))
        #expect(!ChatSession.needsModelChoice(selected: "claude-code/sonnet", among: claude))
        // An embedding model is not a chat model to fall back on either.
        let list = claude + items("p/text-embedding-3-small")
        #expect(discovered(among: list) == nil)
        // No models at all keeps the ordinary "add a provider" path.
        #expect(!ChatSession.needsModelChoice(selected: nil, among: []))
    }

    @Test func chosenClaudeCodeModelsAreKept() {
        let list = claude + items("p/model-a")
        let opus = "claude-code/opus"
        #expect(discovered(manual: opus, agentDefault: "p/model-a", among: list) == opus)
        #expect(discovered(restored: opus, agentDefault: "p/model-a", among: list) == opus)
        #expect(discovered(agentDefault: opus, among: list) == opus)
        #expect(discovered(previous: opus, among: list) == opus)
        #expect(discovered(agentDefault: opus, among: claude) == opus)
    }

    /// A new chat's first selection (cached picker items) follows the same rule.
    @Test func newChatDoesNotStartOnClaudeCode() {
        let session = ChatSession()
        session.pickerItems = claude + items("p/model-a")
        session.selectedModel = nil
        session.applyInitialModelSelection()
        #expect(session.selectedModel?.hasPrefix("claude-code/") != true)

        session.pickerItems = claude
        session.selectedModel = nil
        session.applyInitialModelSelection()
        #expect(session.selectedModel == nil)
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
