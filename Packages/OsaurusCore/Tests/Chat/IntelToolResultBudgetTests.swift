//
//  IntelToolResultBudgetTests.swift
//  osaurusTests
//
//  Context estimates count a tool result once, not twice (upstream #3259):
//  the assistant `toolResults` display mirror versus the explicit tool turn.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct IntelToolResultBudgetTests {
    private let payload = String(repeating: "r", count: 4000)

    private func assistant(_ results: [String: String]) -> ChatTurn {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.toolCalls = results.keys.sorted().map {
            ToolCall(id: $0, type: "function", function: .init(name: "read", arguments: "{}"))
        }
        turn.toolResults = results
        return turn
    }

    private func result(_ id: String?, _ content: String) -> ChatTurn {
        let turn = ChatTurn(role: .tool, content: content)
        turn.toolCallId = id
        return turn
    }

    @Test func explicitResultCountsOnceAlongsideItsDisplayMirror() {
        let turn = assistant(["a": payload])
        let explicit = result("a", payload)
        let estimate = ContextBudgetManager.estimateTokens(for: [turn, explicit])
        turn.toolResults = [:]
        #expect(estimate == ContextBudgetManager.estimateTokens(for: [turn, explicit]))
    }

    @Test func legacyResultWithoutAnExplicitTurnStillCounts() {
        let turn = assistant(["a": payload])
        let estimate = ContextBudgetManager.estimateTokens(for: [turn])
        turn.toolResults = [:]
        #expect(estimate == ContextBudgetManager.estimateTokens(for: [turn]) + 1000)
    }

    @Test func parallelResultsDeduplicateOnlyTheirOwnCallIDs() {
        let turn = assistant(["a": payload, "b": payload])
        let explicit = result("a", payload)
        let estimate = ContextBudgetManager.estimateTokens(for: [turn, explicit])
        turn.toolResults = [:]
        #expect(estimate == ContextBudgetManager.estimateTokens(for: [turn, explicit]) + 1000)
    }

    @Test func completeParallelResultsEachCountOnce() {
        let turn = assistant(["a": payload, "b": payload])
        let results = [result("a", payload), result("b", payload)]
        let estimate = ContextBudgetManager.estimateTokens(for: [turn] + results)
        turn.toolResults = [:]
        #expect(estimate == ContextBudgetManager.estimateTokens(for: [turn] + results))
    }

    @Test func explicitResultIsAuthoritativeWhenTheDisplayMirrorDiffers() {
        let turn = assistant(["a": payload])
        let explicit = result("a", "short result")
        let estimate = ContextBudgetManager.estimateTokens(for: [turn, explicit])
        turn.toolResults = [:]
        #expect(estimate == ContextBudgetManager.estimateTokens(for: [turn, explicit]))
    }

    @Test func unrelatedResultCannotHideAnEqualDisplayPayload() {
        let turn = assistant(["a": payload])
        let explicit = result("b", payload)
        let estimate = ContextBudgetManager.estimateTokens(for: [turn, explicit])
        turn.toolResults = [:]
        #expect(estimate == ContextBudgetManager.estimateTokens(for: [turn, explicit]) + 1000)
    }

    @Test func reusedCallIDInAnotherBatchCannotHideALegacyResult() {
        let earlier = assistant(["a": payload])
        let later = assistant(["a": payload])
        let explicit = result("a", payload)
        #expect(ContextBudgetManager.estimateTokens(for: [earlier, later, explicit])
            == ContextBudgetManager.estimateTokens(for: [earlier])
                + ContextBudgetManager.estimateTokens(for: [later, explicit]))
    }

    @Test func missingOrEmptyResultIDCannotHideALegacyResult() {
        for id: String? in [nil, ""] {
            let turn = assistant(["": payload])
            let explicit = result(id, payload)
            let estimate = ContextBudgetManager.estimateTokens(for: [turn, explicit])
            turn.toolResults = [:]
            #expect(estimate == ContextBudgetManager.estimateTokens(for: [turn, explicit]) + 1000)
        }
    }

    @Test func interveningUserTurnEndsTheResultBatch() {
        let turn = assistant(["a": payload])
        let explicit = result("a", payload)
        let user = ChatTurn(role: .user, content: "next")
        #expect(ContextBudgetManager.estimateTokens(for: [turn, user, explicit])
            == ContextBudgetManager.estimateTokens(for: [turn])
                + ContextBudgetManager.estimateTokens(for: [user, explicit]))
    }

    @Test func settingToolCallIdBumpsTheEstimateRevision() {
        let turn = ChatTurn(role: .tool, content: "x")
        let before = ChatTurn.tokenEstimateRevision
        turn.toolCallId = "call-1"
        #expect(ChatTurn.tokenEstimateRevision != before)
    }
}
