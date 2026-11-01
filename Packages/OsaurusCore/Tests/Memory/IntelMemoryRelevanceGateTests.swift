//
//  IntelMemoryRelevanceGateTests.swift
//  OsaurusCoreTests
//
//  Upstream's memory relevance gate on Intel's layered recall (2026-11-01,
//  after the 1.0.61 (63) Rosy pass): a message with no recall signal gets
//  only the identity overrides; a recall question gets every layer. Runs on
//  an in-memory memory database in the test storage root, no embedder.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct IntelMemoryRelevanceGateTests {
    private func withMemory(_ body: @MainActor @Sendable (_ agent: String) async throws -> Void) async throws {
        try await ChatHistoryTestStorage.run {
            MemoryConfigurationStore.invalidateCache()
            MemoryDatabase.shared.close()
            try MemoryDatabase.shared.openInMemory()
            var config = MemoryConfiguration.default
            config.enabled = true
            config.embeddingProvider = "none"
            config.relevanceGateMode = .heuristic
            MemoryConfigurationStore.save(config)
            defer {
                MemoryDatabase.shared.close()
                MemoryConfigurationStore.invalidateCache()
            }
            let agent = UUID().uuidString
            try MemoryDatabase.shared.saveIdentity(
                Identity(content: "Renée lives in São Paulo.", overrides: ["User's name is Renée"]))
            try MemoryDatabase.shared.insertTranscriptTurn(
                agentId: agent, conversationId: "older-chat", chunkIndex: 0, role: "user",
                content: "Which sites list Switch game files for download?", tokenCount: 10)
            try await body(agent)
        }
    }

    @Test func greetingGetsOnlyTheIdentityOverrides() async throws {
        try await withMemory { agent in
            let section = await MemorySearchService.shared.recall(
                query: "Hello, dearie!", agentId: agent, days: 3650, budgetTokens: 800)
            #expect(section == "### About you\n- User's name is Renée")
        }
    }

    @Test func ordinaryQuestionLeavesOldChatsOut() async throws {
        try await withMemory { agent in
            let section = await MemorySearchService.shared.recall(
                query: "How can I season ground beef? Switch game files", agentId: agent, days: 3650,
                budgetTokens: 800) ?? ""
            #expect(!section.contains("Earlier conversation detail"))
            #expect(!section.contains("São Paulo"))
        }
    }

    @Test func recallQuestionGetsEveryLayer() async throws {
        try await withMemory { agent in
            let section = await MemorySearchService.shared.recall(
                query: "Do you remember the Switch game files sites I asked about?", agentId: agent,
                days: 3650, budgetTokens: 800) ?? ""
            #expect(section.contains("User's name is Renée"))
            #expect(section.contains("São Paulo"))
            #expect(section.contains("Earlier conversation detail"))
        }
    }

    @Test func gateOffRecallsEveryTurn() async throws {
        try await withMemory { agent in
            var config = MemoryConfigurationStore.load()
            config.relevanceGateMode = .off
            MemoryConfigurationStore.save(config)
            let section = await MemorySearchService.shared.recall(
                query: "Hello there, Switch game files", agentId: agent, days: 3650, budgetTokens: 800) ?? ""
            #expect(section.contains("Earlier conversation detail"))
        }
    }

    @Test func gateReadsUpstreamsSignals() {
        #expect(MemorySearchService.recallSection(for: "Hello, dearie!", agentId: nil, identity: nil, mode: .heuristic) == .none)
        #expect(MemorySearchService.recallSection(for: "what's my name?", agentId: nil, identity: nil, mode: .heuristic) == .identity)
        #expect(MemorySearchService.recallSection(for: "did i tell you about the beef recipe?", agentId: nil, identity: nil, mode: .heuristic) == .pinned)
        #expect(MemorySearchService.recallSection(for: "remember the beef recipe", agentId: nil, identity: nil, mode: .heuristic) == .episode)
        #expect(MemorySearchService.recallSection(for: "what did we discuss last week?", agentId: nil, identity: nil, mode: .heuristic) == .episode)
    }
}

@MainActor
struct IntelTrafficLightHoverTests {
    @Test func hoverShowsTheThreeSymbols() throws {
        let strip = IntelTrafficLightStripView(frame: NSRect(x: 0, y: 0, width: 60, height: 18))
        strip.layout()
        let buttons = strip.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 3)
        #expect(buttons.allSatisfy { $0.image == nil })
        let enter = try #require(
            NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        strip.mouseEntered(with: enter)
        #expect(buttons.allSatisfy { $0.image != nil })
        strip.mouseExited(with: enter)
        #expect(buttons.allSatisfy { $0.image == nil })
    }
}
