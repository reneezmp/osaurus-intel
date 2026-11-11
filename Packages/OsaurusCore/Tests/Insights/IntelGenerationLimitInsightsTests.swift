//
//  IntelGenerationLimitInsightsTests.swift
//  osaurusTests
//
//  An inference whose request set no output limit is logged without one,
//  not with a made-up default (upstream #3308).
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Insights output-limit provenance", .serialized)
struct IntelGenerationLimitInsightsTests {
    private func row(for model: String) async throws -> RequestLog {
        for _ in 0..<200 {
            if let row = InsightsService.shared.logs.first(where: { $0.model == model }) { return row }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("No Insights row for \(model)")
        throw CancellationError()
    }

    @Test func absentLimitStaysAbsentAndExplicitLimitIsKept() async throws {
        let none = "limit-none-\(UUID().uuidString)"
        let explicit = "limit-explicit-\(UUID().uuidString)"
        InsightsService.logInference(
            source: .chatUI, model: none, inputTokens: 1, outputTokens: 1, durationMs: 10,
            temperature: nil, maxTokens: nil)
        InsightsService.logInference(
            source: .chatUI, model: explicit, inputTokens: 1, outputTokens: 1, durationMs: 10,
            temperature: nil, maxTokens: 512)
        #expect(try await row(for: none).maxTokens == nil)
        #expect(try await row(for: explicit).maxTokens == 512)
    }
}
