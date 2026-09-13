import Testing

@testable import OsaurusCore

@Suite("Intel Router account usage center")
struct RouterAccountUsageCenterTests {
    @Test func aggregatesUsageAndWalletMovement() {
        let usage = [
            OsaurusRouterUsageItem(id: "a", requestId: nil, model: "m", provider: "p", inputTokens: 10, outputTokens: 2, costMicro: "100", status: "completed", tokenSource: "provider", createdAt: "2026-09-12T10:00:00Z"),
            OsaurusRouterUsageItem(id: "b", requestId: nil, model: "m", provider: "p", inputTokens: 20, outputTokens: 3, costMicro: "250", status: "completed", tokenSource: "provider", createdAt: "2026-09-12T11:00:00Z")
        ]
        let transactions = [
            OsaurusRouterTransactionItem(id: "t1", amountMicro: "5000", entryType: "topup", refType: nil, refId: nil, createdAt: "2026-09-12T09:00:00Z"),
            OsaurusRouterTransactionItem(id: "t2", amountMicro: "-350", entryType: "usage", refType: nil, refId: nil, createdAt: "2026-09-12T11:00:00Z")
        ]
        let snapshot = RouterAccountUsageCenter.snapshot(usage: usage, transactions: transactions)
        #expect(snapshot.requestCount == 2)
        #expect(snapshot.inputTokens == 30)
        #expect(snapshot.outputTokens == 5)
        #expect(snapshot.spentMicro == 350)
        #expect(snapshot.creditedMicro == 5000)
        #expect(snapshot.debitedMicro == 350)
        #expect(snapshot.netTransactionMicro == 4650)
    }
}
