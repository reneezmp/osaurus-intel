//
//  IntelOutputToolsTests.swift
//  osaurusTests
//
//  W-tools-misc (2026-10-11): upstream's `share_artifact`, `render_chart` and
//  `search_memory` are registered on Intel, with upstream's per-agent opt-ins
//  for the last two.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelOutputToolsTests {
    @Test func outputToolsAreRegisteredBuiltIns() {
        let names = Set(ToolRegistry.shared.openAISpecs().map(\.function.name))
        for name in ["share_artifact", "render_chart", "search_memory"] {
            #expect(names.contains(name), "\(name) is registered")
        }
    }

    @Test func chartAndRecallSwitchesDefaultOffAndRoundTrip() throws {
        let fresh = AgentSettings.defaultDisabled
        #expect(!fresh.renderChartEnabled)
        #expect(!fresh.searchMemoryEnabled)

        var settings = fresh
        settings.renderChartEnabled = true
        settings.searchMemoryEnabled = true
        let back = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.renderChartEnabled)
        #expect(back.searchMemoryEnabled)

        // Settings saved before these switches existed decode as off.
        let legacy = try JSONDecoder().decode(AgentSettings.self, from: Data(#"{"dbEnabled":false}"#.utf8))
        #expect(!legacy.renderChartEnabled)
        #expect(!legacy.searchMemoryEnabled)
    }

    @Test func nonShareResultsPassThrough() async {
        let result = ToolEnvelope.success(tool: "file_read", text: "x")
        #expect(await ChatEngine.processedShareArtifactResult(name: "file_read", result: result) == result)
    }
}
