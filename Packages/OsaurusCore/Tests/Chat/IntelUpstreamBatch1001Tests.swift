//
//  IntelUpstreamBatch1001Tests.swift
//  osaurusTests
//
//  Upstream commits after `b023f2c1e` ported to Intel
//  (docs/UPSTREAM_AUDIT_2026-10-01.md): #2959 response metrics in Inspect
//  response. #2954, #2961 and #2963 carry upstream's own tests
//  (`ProcessInputValidationTests`, `NotesToolsTests`,
//  `ChatWindowStateInspectorTests`).
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct IntelUpstreamBatch1001Tests {

    @Test("Response metrics are one line the Inspect menu splits; the row keeps only the warning")
    func responseMetricsMoveIntoInspect() {
        let text = NativeStatsView.statsText(
            ttft: 0.42, tokensPerSecond: 31.25, tokenCount: 120, totalDuration: 12.34)
        #expect(text.components(separatedBy: " \u{2022} ") == ["Worked for 12.3s", "TTFT 0.42s", "31.2 tok/s", "120 tokens"])
        #expect(NativeStatsView.statsText(ttft: nil, tokensPerSecond: nil, tokenCount: 1) == "1 token")

        let row = NativeStatsView()
        row.configure(ttft: 0.42, tokensPerSecond: 31, tokenCount: 120, totalDuration: 5, theme: LightTheme())
        #expect(row.subviews.compactMap { ($0 as? NSTextField)?.stringValue } == [""])
        row.configure(ttft: nil, tokensPerSecond: nil, tokenCount: nil, unclosedReasoning: true, theme: LightTheme())
        #expect(row.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.first?.hasPrefix("⚠") == true)
    }
}
