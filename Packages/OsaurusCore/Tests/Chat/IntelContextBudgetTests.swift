//
//  IntelContextBudgetTests.swift
//  osaurusTests
//
//  The composer's context budget on Intel (upstream ring + popover with
//  Intel window resolution; docs/CONTEXT_BUDGET_INTEL.md): upstream's
//  assessment rules and popover utilization values.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelContextBudgetTests {

    private func breakdown(prefix: Int, conversation: Int, input: Int = 0) -> ContextBreakdown {
        var bd = ContextBreakdown()
        bd.context = [.init(id: "persona", label: "System Prompt", tokens: prefix, tint: .purple)]
        bd.messages = [
            .init(id: "conversation", label: "Conversation", tokens: conversation, tint: .blue),
            .init(id: "input", label: "Input", tokens: input, tint: .cyan),
        ]
        return bd
    }

    @Test func usageIsMeasuredAgainstTheUsableBudget() {
        #expect(IntelContextBudget.effectiveBudget(contextWindow: 100_000) == 85_000)
        let low = IntelContextBudget.assess(breakdown: breakdown(prefix: 2_000, conversation: 15_000), contextWindow: 100_000)
        #expect(low.usageRatio == 17_000.0 / 85_000.0)
        #expect(!low.nearLimit && !low.hardOverflow)

        // ≥85% of the usable budget: amber, but history can still be compacted.
        let near = IntelContextBudget.assess(breakdown: breakdown(prefix: 2_000, conversation: 71_000), contextWindow: 100_000)
        #expect(near.nearLimit)
        #expect(!near.hardOverflow)
    }

    @Test func onlyTheNonCompactablePartCanOverflow() {
        // Prefix + response reservation (capped at a quarter of the budget)
        // beyond the usable budget: red.
        let full = IntelContextBudget.assess(
            breakdown: breakdown(prefix: 70_000, conversation: 0, input: 5_000), contextWindow: 100_000,
            maxResponseTokens: 20_000)
        #expect(full.hardOverflow)
        // A huge conversation alone never overflows: compaction can trim it.
        let longChat = IntelContextBudget.assess(
            breakdown: breakdown(prefix: 1_000, conversation: 500_000), contextWindow: 100_000)
        #expect(!longChat.hardOverflow)
        #expect(longChat.nearLimit)
        #expect(IntelContextBudget.cappedResponseReservation(nil, effectiveBudget: 3_400) == 850)
        #expect(IntelContextBudget.assess(breakdown: .zero, contextWindow: 0) == .empty)
    }

    @Test func utilizationNeverInventsALimit() {
        let known = computeContextBudgetUtilization(usedTokens: 30_000, maxTokens: 120_000)
        #expect(known.percent == 25)
        #expect(known.remainingTokens == 90_000)
        let over = computeContextBudgetUtilization(usedTokens: 200, maxTokens: 100)
        #expect(over.fraction == 1 && over.remainingTokens == 0)
        let unknown = computeContextBudgetUtilization(usedTokens: 500, maxTokens: nil)
        #expect(unknown.maxTokens == nil && unknown.percent == nil)
    }

    @Test @MainActor func windowComesFromTheCatalogElseTheContextLengthSetting() {
        let previous = ChatConfiguration.shared.contextLength
        defer { ChatConfiguration.shared.contextLength = previous }
        ChatConfiguration.shared.contextLength = 64_000
        let resolution = IntelContextBudget.resolveWindow(modelId: "someprovider/unknown-model-\(UUID().uuidString)")
        #expect(resolution == .init(tokens: 64_000, source: .userSetting))
        ChatConfiguration.shared.contextLength = nil
        #expect(IntelContextBudget.resolveWindow(modelId: nil) == nil)
    }
}
