//
//  RouterCacheTelemetryDecodingTests.swift
//  osaurusTests
//
//  Cache-aware billing contract between the app and the Osaurus Router
//  (upstream 9b3336d68). Intel adaptation: upstream's BYOK parsers, stats
//  chip, Anthropic TTL and workspace-billing tests target code this target
//  does not compile; Intel covers its own cache-key routing and usage totals.
//
//  Every decode must work both with and without the cache fields: routers
//  deployed before `0046_cache_pricing` omit them, and ledger rows written by
//  older app builds have no columns for them.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Router cache telemetry decoding")
struct RouterCacheTelemetryDecodingTests {

    // MARK: - Summary frame

    @Test func summaryFrame_decodesCacheSplitWhenPresent() throws {
        let json = """
            {"osaurus":{"request_id":"req-1","cost_micro":"1234","status":"completed","token_source":"provider",
             "input_tokens":10000,"output_tokens":300,"cached_input_tokens":8000,"cache_write_tokens":1500,
             "billed_to":"workspace:ws-1"}}
            """
        let event = try JSONDecoder().decode(OsaurusRouterSummaryEvent.self, from: Data(json.utf8))
        #expect(event.osaurus.inputTokens == 10000)
        #expect(event.osaurus.cachedInputTokens == 8000)
        #expect(event.osaurus.cacheWriteTokens == 1500)

        let summary = RouterBillingSummary(event.osaurus)
        #expect(summary.cachedInputTokens == 8000)
        #expect(summary.cacheWriteTokens == 1500)
    }

    @Test func summaryFrame_withoutCacheFieldsDecodesAsZero() throws {
        // Pre-cache router: identical frame minus the split.
        let json = """
            {"osaurus":{"cost_micro":"1234","status":"completed","token_source":"provider","input_tokens":11,"output_tokens":3}}
            """
        let event = try JSONDecoder().decode(OsaurusRouterSummaryEvent.self, from: Data(json.utf8))
        #expect(event.osaurus.cachedInputTokens == 0)
        #expect(event.osaurus.cacheWriteTokens == 0)
        #expect(RouterBillingSummary(event.osaurus).cachedInputTokens == 0)
    }

    @Test func summaryFrame_clampsNegativeCacheCountsToZero() throws {
        let json = """
            {"osaurus":{"cost_micro":"1","status":"completed","token_source":"provider","input_tokens":5,"output_tokens":1,
             "cached_input_tokens":-3,"cache_write_tokens":-1}}
            """
        let event = try JSONDecoder().decode(OsaurusRouterSummaryEvent.self, from: Data(json.utf8))
        #expect(event.osaurus.cachedInputTokens == 0)
        #expect(event.osaurus.cacheWriteTokens == 0)
    }


    // MARK: - RouterBillingSummary persistence (chat turn / hint payload)

    @Test func billingSummary_roundTripsCacheFieldsAndToleratesLegacyPayloads() throws {
        let summary = RouterBillingSummary(
            requestId: "r",
            costMicro: "10",
            status: "completed",
            tokenSource: "provider",
            inputTokens: 100,
            outputTokens: 5,
            cachedInputTokens: 60,
            cacheWriteTokens: 40
        )
        let data = try JSONEncoder().encode(summary)
        let back = try JSONDecoder().decode(RouterBillingSummary.self, from: data)
        #expect(back == summary)

        // Persisted by an older app build (no cache keys at all).
        let legacy = """
            {"costMicro":"10","status":"completed","tokenSource":"provider","inputTokens":100,"outputTokens":5}
            """
        let old = try JSONDecoder().decode(RouterBillingSummary.self, from: Data(legacy.utf8))
        #expect(old.cachedInputTokens == 0)
        #expect(old.cacheWriteTokens == 0)
        #expect(old.inputTokens == 100)
    }

    // MARK: - GET /credits/usage rows

    @Test func usageItem_decodesWithAndWithoutCacheFields() throws {
        let withCache = """
            {"id":"u1","model":"m","provider":"anthropic","input_tokens":1000,"output_tokens":20,
             "cached_input_tokens":900,"cache_write_tokens":50,"cost_micro":"123","status":"completed",
             "token_source":"provider","created_at":"2026-06-13T18:00:00Z"}
            """
        let item = try JSONDecoder().decode(OsaurusRouterUsageItem.self, from: Data(withCache.utf8))
        #expect(item.cachedInputTokens == 900)
        #expect(item.cacheWriteTokens == 50)

        let without = """
            {"id":"u1","model":"m","provider":"venice","input_tokens":1,"output_tokens":2,"cost_micro":"123",
             "status":"completed","token_source":"provider","created_at":"2026-06-13T18:00:00Z"}
            """
        let legacy = try JSONDecoder().decode(OsaurusRouterUsageItem.self, from: Data(without.utf8))
        #expect(legacy.cachedInputTokens == 0)
        #expect(legacy.cacheWriteTokens == 0)
        #expect(legacy.inputTokens == 1)
    }

    @Test func usageResponse_listDecodesMixedRows() throws {
        let json = """
            {"data":[
              {"id":"a","model":"m","provider":"openai","input_tokens":10,"output_tokens":1,"cached_input_tokens":8,"cache_write_tokens":0,"cost_micro":"1","status":"completed","token_source":"provider","created_at":"2026-06-13T18:00:00Z"},
              {"id":"b","model":"m","provider":"venice","input_tokens":10,"output_tokens":1,"cost_micro":"1","status":"completed","token_source":"provider","created_at":"2026-06-13T18:00:00Z"}
            ],"next_cursor":null}
            """
        let response = try JSONDecoder().decode(OsaurusRouterUsageResponse.self, from: Data(json.utf8))
        #expect(response.data.map(\.cachedInputTokens) == [8, 0])
    }

    // MARK: - "N cached" label

    @Test func cachedInputLabel_formatsCountAndRatio() {
        #expect(OsaurusRouter.formatCachedInputLabel(cachedTokens: 0) == nil)
        #expect(OsaurusRouter.formatCachedInputLabel(cachedTokens: -5) == nil)
        #expect(OsaurusRouter.formatCachedInputLabel(cachedTokens: 900) == "900 cached")
        #expect(OsaurusRouter.formatCachedInputLabel(cachedTokens: 3200, inputTokens: 4000) == "3,200 cached · 80%")
        #expect(OsaurusRouter.formatCachedInputLabel(cachedTokens: 1, inputTokens: 3) == "1 cached · 33%")
        // Ratio omitted when the total is unknown, zero, or inconsistent.
        #expect(OsaurusRouter.formatCachedInputLabel(cachedTokens: 10, inputTokens: 0) == "10 cached")
        #expect(OsaurusRouter.formatCachedInputLabel(cachedTokens: 10, inputTokens: 5) == "10 cached")
        #expect(OsaurusRouter.formatCachedInputLabel(cachedTokens: 1_234_567, inputTokens: 1_234_567) == "1,234,567 cached · 100%")
    }

    // MARK: - Ledger (SQLite v3)

    private static let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())

    private func makeEntry(
        requestId: String = "req-1",
        cachedInputTokens: Int = 0,
        cacheWriteTokens: Int = 0
    ) -> RouterBillingEntry {
        RouterBillingEntry(
            id: UUID().uuidString,
            requestId: requestId,
            createdAt: Self.now,
            sessionId: UUID().uuidString,
            turnId: UUID().uuidString,
            model: "anthropic/claude",
            tokenSource: "provider",
            inputTokens: 5000,
            outputTokens: 30,
            cachedInputTokens: cachedInputTokens,
            cacheWriteTokens: cacheWriteTokens,
            costMicro: "1500",
            status: "completed",
            outcome: .pending,
            appVersion: "1.2.3"
        )
    }

    @Test func ledger_roundTripsCacheColumns() throws {
        let db = RouterBillingDatabase()
        try db.openInMemory()
        let entry = makeEntry(cachedInputTokens: 4500, cacheWriteTokens: 200)
        try db.insert(entry)
        let back = try #require(try db.findByRequestId("req-1"))
        #expect(back == entry)
        #expect(back.cachedInputTokens == 4500)
        #expect(back.cacheWriteTokens == 200)
        #expect(try db.recent(limit: 10).first?.cachedInputTokens == 4500)
    }

    @Test func ledger_upsertByRequestIdReplacesCacheSplit() throws {
        let db = RouterBillingDatabase()
        try db.openInMemory()
        _ = try db.upsertByRequestId(makeEntry(cachedInputTokens: 0))
        let updated = try db.upsertByRequestId(makeEntry(cachedInputTokens: 4000, cacheWriteTokens: 10))
        #expect(updated.cachedInputTokens == 4000)
        #expect(updated.cacheWriteTokens == 10)
        #expect(try db.findByRequestId("req-1")?.cachedInputTokens == 4000)
        #expect(try db.count() == 1)
    }

    @Test func ledger_v2RowsMigrateToV3WithZeroCacheCounts() throws {
        let db = RouterBillingDatabase()
        try db.openInMemory(upToSchemaVersion: 2)
        #expect(try db.schemaVersionForTesting() == 2)
        // Seed a row exactly as a v2 build would have written it.
        try db.executeForTesting(
            """
            INSERT INTO router_billing (entry_id, request_id, created_at, session_id, turn_id, model,
                token_source, input_tokens, output_tokens, cost_micro, status, outcome, app_version)
            VALUES ('legacy-1', 'req-legacy', \(Self.now.timeIntervalSince1970), NULL, NULL, 'm',
                'provider', 77, 8, '900', 'completed', 'rendered', '1.0.0')
            """
        )

        try db.migrateToLatestForTesting()
        #expect(try db.schemaVersionForTesting() == 3)

        let legacy = try #require(try db.findByRequestId("req-legacy"))
        #expect(legacy.inputTokens == 77)
        #expect(legacy.outputTokens == 8)
        #expect(legacy.cachedInputTokens == 0)
        #expect(legacy.cacheWriteTokens == 0)
        #expect(legacy.outcome == .rendered)

        // New rows written after the migration carry the split alongside the
        // legacy row.
        try db.insert(makeEntry(requestId: "req-new", cachedInputTokens: 60, cacheWriteTokens: 5))
        let rows = try db.recent(limit: 10)
        #expect(rows.count == 2)
        #expect(rows.first { $0.requestId == "req-new" }?.cachedInputTokens == 60)
        #expect(rows.first { $0.requestId == "req-legacy" }?.cachedInputTokens == 0)
    }

    @Test func ledger_entryClampsNegativeCacheCounts() {
        let entry = makeEntry(cachedInputTokens: -1, cacheWriteTokens: -9)
        #expect(entry.cachedInputTokens == 0)
        #expect(entry.cacheWriteTokens == 0)
    }

    @Test func ledgerFacade_recordsCacheSplitFromSummary() throws {
        let db = RouterBillingDatabase()
        try db.openInMemory()
        let ledger = RouterBillingLedger(database: db)
        let summary = RouterBillingSummary(
            requestId: "req-facade",
            costMicro: "42",
            status: "completed",
            tokenSource: "provider",
            inputTokens: 900,
            outputTokens: 10,
            cachedInputTokens: 800,
            cacheWriteTokens: 100
        )
        let entryId = ledger.record(summary: summary, sessionId: UUID(), turnId: UUID(), model: "m")
        #expect(entryId != nil)
        let stored = try #require(try db.findByRequestId("req-facade"))
        #expect(stored.cachedInputTokens == 800)
        #expect(stored.cacheWriteTokens == 100)
    }
}

@Suite("Intel prompt-cache routing")
struct IntelPromptCacheRoutingTests {

    private func provider(_ type: RemoteProviderType, host: String) -> RemoteProvider {
        var p = RemoteProvider(name: "P", host: host, providerProtocol: .https, providerType: type)
        p.enabled = true
        return p
    }

    @Test func allowlistedProvidersGetASessionCacheKey() {
        for (type, host) in [
            (RemoteProviderType.osaurusRouter, "router.osaurus.ai"),
            (.azureOpenAI, "example.openai.azure.com"),
            (.openaiLegacy, "api.openai.com"),
            (.openaiLegacy, "openrouter.ai"),
        ] {
            var body: [String: Any] = [:]
            ChatEngine.applyPromptCacheRouting(
                provider: provider(type, host: host), sessionId: "abc", into: &body)
            #expect(body["prompt_cache_key"] as? String == "osaurus-session-abc", "\(type) \(host)")
        }
    }

    @Test func genericGatewaysAndOneOffRequestsGetNoUnknownFields() {
        var gateway: [String: Any] = [:]
        ChatEngine.applyPromptCacheRouting(
            provider: provider(.openaiLegacy, host: "api.deepseek.com"), sessionId: "abc", into: &gateway)
        #expect(gateway.isEmpty)

        var oneOff: [String: Any] = [:]
        ChatEngine.applyPromptCacheRouting(
            provider: provider(.osaurusRouter, host: "router.osaurus.ai"), sessionId: nil, into: &oneOff)
        #expect(oneOff.isEmpty)
    }

    @Test func openRouterAlsoGetsStickySessionRouting() {
        var body: [String: Any] = [:]
        ChatEngine.applyPromptCacheRouting(
            provider: provider(.openaiLegacy, host: "openrouter.ai"), sessionId: "abc", into: &body)
        #expect(body["session_id"] as? String == "abc")

        var router: [String: Any] = [:]
        ChatEngine.applyPromptCacheRouting(
            provider: provider(.osaurusRouter, host: "router.osaurus.ai"), sessionId: "abc", into: &router)
        #expect(router["session_id"] == nil)
    }

    @Test func usageCenterSumsCachedInput() throws {
        let rows = [
            OsaurusRouterUsageItem(
                id: "1", requestId: nil, model: "m", provider: "p", inputTokens: 1_000, outputTokens: 5,
                cachedInputTokens: 800, costMicro: "10", status: "completed", tokenSource: "provider",
                createdAt: "2026-09-25T00:00:00Z"),
            OsaurusRouterUsageItem(
                id: "2", requestId: nil, model: "m", provider: "p", inputTokens: 500, outputTokens: 5,
                costMicro: "10", status: "completed", tokenSource: "provider",
                createdAt: "2026-09-25T00:00:00Z"),
        ]
        let snapshot = RouterAccountUsageCenter.snapshot(usage: rows, transactions: [])
        #expect(snapshot.inputTokens == 1_500)
        #expect(snapshot.cachedInputTokens == 800)
    }
}
