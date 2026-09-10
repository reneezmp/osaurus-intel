//
//  WebSearchToolTests.swift
//  OsaurusCoreTests
//
//  Tool-surface contracts for native search: `web_search` is an always-loaded
//  built-in (and part of the Default-agent baseline), `search_and_extract` is
//  a dynamic native tool, the `category` enum only appears in the schema when
//  the user's providers serve more than plain web, the per-agent
//  `webSearchEnabled` gate strips both tools in `resolveTools` (while loaded
//  tools survive), and the weak-caller argument sanitizers never fail a call
//  over a malformed value.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct WebSearchToolTests {

    // MARK: - Registration

    @Test func webSearchIsAnAlwaysLoadedBuiltIn() {
        let registry = ToolRegistry.shared
        #expect(registry.openAISpecs().contains { $0.function.name == "web_search" })
        #expect(registry.builtInToolNames.contains("web_search"))
    }

    @Test func searchAndExtractIsRegistered() {
        let registry = ToolRegistry.shared
        #expect(registry.openAISpecs().contains { $0.function.name == "search_and_extract" })
    }

    // MARK: - Dynamic category enum

    private func categoryEnum(of tool: WebSearchTool) -> [String]? {
        guard case .object(let root)? = tool.parameters,
            case .object(let properties)? = root["properties"],
            case .object(let category)? = properties["category"],
            case .array(let values)? = category["enum"]
        else { return nil }
        return values.compactMap {
            if case .string(let s) = $0 { return s }
            return nil
        }
    }

    @Test func categoryIsOpenAndSchemaIsStable() throws {
        #expect(categoryEnum(of: WebSearchTool()) == nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(
            try encoder.encode(WebSearchTool().parameters)
                == encoder.encode(WebSearchTool().parameters)
        )
    }

    // MARK: - Agent gating in resolveTools

    @Test func enablingWebSearchKeepsBothTools() {
        let tools = SystemPromptComposer.filteringWebSearchTools(
            ToolRegistry.shared.openAISpecs(), enabled: true)
        let names = Set(tools.map { $0.function.name })
        #expect(names.contains("web_search"))
        #expect(names.contains("search_and_extract"))
    }

    @Test func disablingWebSearchStripsBothTools() {
        let tools = SystemPromptComposer.filteringWebSearchTools(
            ToolRegistry.shared.openAISpecs(), enabled: false)
        let names = Set(tools.map { $0.function.name })
        #expect(!names.contains("web_search"))
        #expect(!names.contains("search_and_extract"))
    }

    @Test func agentSettingDefaultsOffAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(AgentSettings.self, from: Data("{}".utf8))
        #expect(legacy.webSearchEnabled == false)

        var enabled = AgentSettings.defaultDisabled
        enabled.webSearchEnabled = true
        let decoded = try JSONDecoder().decode(
            AgentSettings.self,
            from: JSONEncoder().encode(enabled)
        )
        #expect(decoded.webSearchEnabled == true)
    }

    // MARK: - Weak-caller argument sanitization

    @Test func timeRangeVariantsNormalize() {
        var warnings: [String] = []
        #expect(WebSearchArgs.sanitizeTimeRange("week", warnings: &warnings) == "w")
        #expect(WebSearchArgs.sanitizeTimeRange("D", warnings: &warnings) == "d")
        #expect(WebSearchArgs.sanitizeTimeRange(" month ", warnings: &warnings) == "m")
        #expect(WebSearchArgs.sanitizeTimeRange("year", warnings: &warnings) == "y")
        #expect(warnings.isEmpty)
        #expect(WebSearchArgs.sanitizeTimeRange("fortnight", warnings: &warnings) == nil)
        #expect(warnings.count == 1)
        // Absent / non-string values are silently nil, not warned.
        warnings = []
        #expect(WebSearchArgs.sanitizeTimeRange(nil, warnings: &warnings) == nil)
        #expect(WebSearchArgs.sanitizeTimeRange(7, warnings: &warnings) == nil)
        #expect(warnings.isEmpty)
    }

    @Test func unknownCategoryFallsBackToWebWithWarning() {
        var warnings: [String] = []
        let available = ["web", "news"]
        #expect(
            WebSearchArgs.sanitizeCategory("news", available: available, warnings: &warnings)
                == "news")
        #expect(warnings.isEmpty)
        // Synonyms local models produce map onto available categories.
        #expect(
            WebSearchArgs.sanitizeCategory("articles", available: available, warnings: &warnings)
                == "news")
        #expect(warnings.isEmpty)
        // Unknown category: fall back to web + warning, never an error.
        #expect(
            WebSearchArgs.sanitizeCategory("videos", available: available, warnings: &warnings)
                == "web")
        #expect(warnings.count == 1)
        // Synonym for an UNAVAILABLE category also falls back.
        warnings = []
        #expect(
            WebSearchArgs.sanitizeCategory("photos", available: available, warnings: &warnings)
                == "web")
        #expect(warnings.count == 1)
    }

    @Test func regionValidatesXxYyFormat() {
        var warnings: [String] = []
        #expect(WebSearchArgs.sanitizeRegion("US-EN", warnings: &warnings) == "us-en")
        #expect(warnings.isEmpty)
        #expect(WebSearchArgs.sanitizeRegion("america", warnings: &warnings) == nil)
        #expect(warnings.count == 1)
    }

    @Test func snippetsAreTruncatedInThePayload() {
        let longSnippet = String(repeating: "a", count: 1000)
        let outcome = SearchEngineOutcome(
            hits: [
                SearchHit(title: "T", url: "https://x.example", snippet: longSnippet, engine: "e")
            ],
            provider: "e",
            attempts: []
        )
        let payload = WebSearchResultFormatter.resultsPayload(
            request: SearchRequest(query: "q"),
            outcome: outcome
        )
        let results = payload["results"] as? [[String: Any]]
        let snippet = results?.first?["snippet"] as? String
        #expect((snippet?.count ?? 0) <= WebSearchResultFormatter.maxSnippetLength + 1)
    }

    @Test func noResultsHintDependsOnProviderConfiguration() {
        let withProvider = WebSearchResultFormatter.noResultsHint(hasConfiguredAPIProvider: true)
        let without = WebSearchResultFormatter.noResultsHint(hasConfiguredAPIProvider: false)
        #expect(withProvider.contains("API keys"))
        #expect(without.contains("add a free search provider"))
    }
}
