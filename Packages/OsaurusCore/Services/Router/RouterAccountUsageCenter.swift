import Foundation

struct RouterAccountUsageSnapshot: Equatable, Sendable {
    let requestCount: Int
    let inputTokens: Int
    /// Input tokens the upstream served from its prompt cache (billed at the
    /// cached rate). Subset of `inputTokens`; 0 on pre-cache routers.
    let cachedInputTokens: Int
    let outputTokens: Int
    let spentMicro: Int64
    let creditedMicro: Int64
    let debitedMicro: Int64
    let netTransactionMicro: Int64
}

enum RouterAccountUsageCenter {
    static func snapshot(
        usage: [OsaurusRouterUsageItem],
        transactions: [OsaurusRouterTransactionItem]
    ) -> RouterAccountUsageSnapshot {
        let spent = sum(usage.map(\.costMicro))
        let amounts = transactions.map { value($0.amountMicro) }
        let credited = saturatingSum(amounts.filter { $0 > 0 })
        let debited = saturatingSum(amounts.filter { $0 < 0 }).magnitude
        return RouterAccountUsageSnapshot(
            requestCount: usage.count,
            inputTokens: saturatingSum(usage.map(\.inputTokens)),
            cachedInputTokens: saturatingSum(usage.map(\.cachedInputTokens)),
            outputTokens: saturatingSum(usage.map(\.outputTokens)),
            spentMicro: spent,
            creditedMicro: credited,
            debitedMicro: Int64(clamping: debited),
            netTransactionMicro: saturatingSum(amounts)
        )
    }

    private static func sum(_ values: [String]) -> Int64 {
        saturatingSum(values.map(value))
    }

    private static func value(_ raw: String) -> Int64 {
        Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func saturatingSum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { partial, value in
            let (result, overflow) = partial.addingReportingOverflow(value)
            return overflow ? (value >= 0 ? .max : .min) : result
        }
    }

    private static func saturatingSum(_ values: [Int]) -> Int {
        values.reduce(0) { partial, value in
            let (result, overflow) = partial.addingReportingOverflow(value)
            return overflow ? (value >= 0 ? .max : .min) : result
        }
    }
}
