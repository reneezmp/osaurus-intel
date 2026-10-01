//
//  IntelContextBudget.swift
//  osaurus
//
//  Intel's context-budget math for the composer's ring chip and its popover
//  (upstream `AgentLoopBudget.resolveContextWindowResolutionSync` + `assess`
//  + `ContextBudgetManager.safetyMargin`, which Intel doesn't compile;
//  docs/CONTEXT_BUDGET_INTEL.md).
//
//  Same rules as upstream: usage is measured against the EFFECTIVE budget
//  (window × 85%), the chip turns amber at ≥85% of that, and red when the
//  part compaction can't trim (system prompt, tools, memory, input) plus the
//  response reservation no longer fits. Intel differences: the window comes
//  from the model catalog, else Settings › Conversation › Context Length
//  (the same resolution Intel's compaction suggestion uses), and a red chip
//  never blocks a send (see `isUserSetting`).
//

import Foundation

enum IntelContextBudget {

    /// Usable share of the window (upstream `ContextBudgetManager.safetyMargin`).
    static let safetyMargin: Double = 0.85

    /// Where the window in force came from (upstream `ContextWindowSource`).
    enum WindowSource: Equatable, Sendable {
        /// The model catalog reported the model's maximum.
        case modelCatalog
        /// Settings › Conversation › Context Length, because the catalog
        /// doesn't know this model (most cloud models). Upstream labels its
        /// user cap the same way: "Your context limit".
        case userSetting
    }

    struct WindowResolution: Equatable, Sendable {
        let tokens: Int
        let source: WindowSource
    }

    /// Upstream `AgentLoopBudget.Assessment`.
    struct Assessment: Equatable, Sendable {
        /// Estimated next-send tokens over the effective budget; nil when the
        /// breakdown is empty.
        var usageRatio: Double?
        /// At or beyond 85% of the effective budget.
        var nearLimit: Bool
        /// The non-compactable prefix plus the response reservation exceeds
        /// the effective budget.
        var hardOverflow: Bool

        static let empty = Assessment(usageRatio: nil, nearLimit: false, hardOverflow: false)
    }

    /// Breakdown entries history compaction can trim (upstream list).
    static let compactableEntryIds: Set<String> = ["conversation", "output", "compacted", "summary"]

    /// Response reservation when the agent sets no max tokens (upstream).
    static let defaultResponseReservation = 4096

    /// The model catalog's window, else the Context Length setting.
    @MainActor
    static func resolveWindow(modelId: String?) -> WindowResolution? {
        if let modelId, let ctx = ModelInfo.load(modelId: modelId)?.model.contextLength, ctx > 0 {
            return WindowResolution(tokens: ctx, source: .modelCatalog)
        }
        if let setting = ChatConfiguration.shared.contextLength, setting > 0 {
            return WindowResolution(tokens: setting, source: .userSetting)
        }
        return nil
    }

    static func effectiveBudget(contextWindow: Int) -> Int {
        Int(Double(contextWindow) * safetyMargin)
    }

    /// Upstream `cappedResponseReservation`: at most a quarter of the
    /// effective budget, so small windows aren't gated by the reservation.
    static func cappedResponseReservation(_ maxResponseTokens: Int?, effectiveBudget: Int) -> Int {
        min(maxResponseTokens ?? defaultResponseReservation, max(0, effectiveBudget / 4))
    }

    /// Upstream `AgentLoopBudget.assess`, unchanged.
    static func assess(
        breakdown: ContextBreakdown,
        contextWindow: Int,
        maxResponseTokens: Int? = nil,
        nearLimitThreshold: Double = 0.85
    ) -> Assessment {
        guard contextWindow > 0 else { return .empty }
        let effective = effectiveBudget(contextWindow: contextWindow)
        guard effective > 0 else { return .empty }
        let total = breakdown.total
        let ratio: Double? = total > 0 ? Double(total) / Double(effective) : nil
        let compactable = breakdown.messages
            .filter { compactableEntryIds.contains($0.id) }
            .reduce(0) { $0 + $1.tokens }
        let reservation = cappedResponseReservation(maxResponseTokens, effectiveBudget: effective)
        let nonCompactable = max(0, total - compactable) + reservation
        return Assessment(
            usageRatio: ratio,
            nearLimit: (ratio ?? 0) >= nearLimitThreshold,
            hardOverflow: nonCompactable > effective
        )
    }
}

/// Popover window-usage values (upstream, verbatim).
struct ContextBudgetUtilization: Equatable {
    let usedTokens: Int
    let maxTokens: Int?
    let fraction: Double?
    let percent: Int?
    let remainingTokens: Int?
}

/// Normalizes the popover's window-usage values in one pure, testable place.
/// Invalid/unknown ceilings remain absent rather than implying a false limit.
/// Upstream, verbatim.
func computeContextBudgetUtilization(
    usedTokens: Int,
    maxTokens: Int?
) -> ContextBudgetUtilization {
    let used = max(0, usedTokens)
    guard let maxTokens, maxTokens > 0 else {
        return ContextBudgetUtilization(
            usedTokens: used,
            maxTokens: nil,
            fraction: nil,
            percent: nil,
            remainingTokens: nil
        )
    }

    let fraction = min(Double(used) / Double(maxTokens), 1)
    return ContextBudgetUtilization(
        usedTokens: used,
        maxTokens: maxTokens,
        fraction: fraction,
        percent: Int((fraction * 100).rounded()),
        remainingTokens: max(0, maxTokens - used)
    )
}
