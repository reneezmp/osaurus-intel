import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Activity token provenance", .serialized)
struct ActivityTokenProvenanceTests {
    private func row(for model: String) async throws -> RequestLog {
        // Wait for the actual append/chain operation, not a fixed actor sleep.
        for _ in 0..<200 {
            if let row = InsightsService.shared.logs.first(where: { $0.model == model }), row.seq != nil {
                return row
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("No persisted Insights row for \(model); store error: \(InsightsService.shared.storeError ?? "none")")
        throw CancellationError()
    }

    private func request(model: String, stream: Bool) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: model, messages: [ChatMessage(role: "user", content: "fixture request")],
            temperature: nil, max_tokens: 16, stream: stream, top_p: nil,
            frequency_penalty: nil, presence_penalty: nil, stop: nil, n: nil,
            tools: nil, tool_choice: nil, session_id: nil
        )
    }

    @Test func mixedCountsSurviveLoggingStoreWithholdingAndExports() async throws {
        let model = "provenance-mixed-\(UUID().uuidString)"
        InsightsService.logInference(
            source: .chatUI, model: model, inputTokens: 96, outputTokens: 4,
            inputTokenSource: .estimated, outputTokenSource: .reported,
            durationMs: 1000, temperature: nil, maxTokens: 16,
            requestBody: "fixture request", responseBody: "fixture response",
            egress: EgressInfo(details: ["query": "exercise bounded-details copy"])
        )
        let captured = try await row(for: model)
        let store = ActivityLogStore()
        try store.openInMemory()
        let stored = try store.append(captured)
        #expect(try store.verify().isIntact)
        let persisted = try #require(store.fetch(filter: .empty).first)
        #expect(persisted.inputTokenSource == .estimated)
        #expect(persisted.outputTokenSource == .reported)
        for includeContent in [true, false] {
            let data = try ActivityExportService.render(
                logs: [persisted], options: .init(format: .jsonl, includeContent: includeContent),
                filterDescription: "fixture", verification: try store.verify()
            )
            let line = try #require(String(decoding: data, as: UTF8.self).split(separator: "\n").last)
            let decoded = try ActivityLogStore.decoder.decode(RequestLog.self, from: Data(line.utf8))
            #expect(decoded.inputTokenSource == .estimated)
            #expect(decoded.outputTokenSource == .reported)
            #expect(decoded.hash == stored.hash)
            if !includeContent { #expect(RequestLog.isWithheldContent(decoded.requestBody)) }
        }
        let csv = ActivityExportService.renderCSV([persisted])
        let lines = csv.split(separator: "\n")
        let values = try #require(lines.last).split(separator: ",", omittingEmptySubsequences: false)
        #expect(values[ActivityExportService.csvColumns.firstIndex(of: "input_tokens_source")!] == "estimated")
        #expect(values[ActivityExportService.csvColumns.firstIndex(of: "output_tokens_source")!] == "reported")
        #expect(!csv.contains("fixture request"))
        let markdown = try ActivityExportService.render(
            logs: [persisted], options: .init(format: .markdown, includeContent: false),
            filterDescription: "fixture", verification: try store.verify()
        )
        let report = String(decoding: markdown, as: UTF8.self)
        #expect(report.contains(persisted.inputTokenDescription))
        #expect(report.contains(persisted.outputTokenDescription))
        #expect(!report.contains("fixture request"))
    }

    @Test func legacyAndUnobservedSourcesRemainUnknown() async throws {
        let legacy = RequestLog(source: .chatUI, method: "POST", path: "/fixture", statusCode: 200,
            durationMs: 1000, model: "provenance-unknown-\(UUID().uuidString)", inputTokens: 22, outputTokens: 3)
        let bytes = try ActivityLogStore.canonicalEncoder.encode(legacy)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("inputTokenSource"))
        #expect(!text.contains("outputTokenSource"))
        let decoded = try ActivityLogStore.decoder.decode(RequestLog.self, from: bytes)
        #expect(decoded.inputTokenSource == nil)
        #expect(decoded.outputTokenSource == nil)
        #expect(decoded.withoutContent().inputTokenSource == nil)
        #expect(decoded.inputTokenDescription.contains("Source unknown"))
        let csv = ActivityExportService.renderCSV([legacy])
        #expect(csv.split(separator: "\n").last?.hasSuffix("unknown,unknown") == true)
        InsightsService.shared.log(legacy)
        _ = try await row(for: try #require(legacy.model))
    }

    @Test func reportedZeroIsDistinctFromUnavailableCount() throws {
        let zero = RequestLog(source: .chatUI, method: "POST", path: "/fixture", statusCode: 200,
            durationMs: 1000, inputTokens: 0, outputTokens: nil,
            inputTokenSource: .reported, outputTokenSource: .reported)
        #expect(zero.inputTokenSource == .reported)
        #expect(zero.inputTokenDescription == "0 · Reported")
        #expect(zero.outputTokens == nil)
        #expect(zero.outputTokenSource == nil)
        #expect(zero.outputTokenDescription == "Unknown")
        #expect(zero.tokensPerSecond == nil)
    }
}
