//
//  MCPCanonicalToolNameTests.swift
//  osaurusTests
//
//  MCP tools are exposed provider-prefixed (`xyz_abc`), but the server's own
//  instructions and tool descriptions cite the canonical name (`abc`). A
//  model following them used to dead-end on tool_not_found (#2856). Intel
//  adaptation: the cloud engine maps a canonical name only to the ONE tool
//  offered in this turn, so the not-offered rejection, permission policy and
//  approval still run on the resolved name. The description hint names the
//  exposed tool and maps cited siblings (ported verbatim).
//

import Foundation
import MCP
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct MCPCanonicalToolNameTests {

    private func envelope(_ result: String) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: result.data(using: .utf8)!) as? [String: Any]
    }

    private func mcpTool(_ name: String, description: String = "fixture") -> MCP.Tool {
        MCP.Tool(name: name, description: description, inputSchema: ["type": "object"])
    }

    private func register(
        _ tool: MCPProviderTool
    ) {
        ToolRegistry.shared.registerMCPTool(tool)
        ToolRegistry.shared.setEnabled(true, for: tool.name)
    }

    private func cleanup(_ tools: [MCPProviderTool]) {
        for tool in tools {
            ToolRegistry.shared.setEnabled(false, for: tool.name)
        }
        ToolRegistry.shared.unregister(names: tools.map(\.name))
    }

    // MARK: - Offered-scope resolution (Intel)

    private func offered(_ tools: [MCPProviderTool]) -> [OsaurusCore.Tool] {
        tools.map { $0.asOpenAITool() }
    }

    @Test
    func canonicalNameResolvesToTheSingleOfferedProvider() {
        let tool = MCPProviderTool(mcpTool: mcpTool("canonical_probe_abc"), providerId: UUID(), providerName: "Probe")
        register(tool)
        defer { cleanup([tool]) }
        #expect(tool.name == "probe_canonical_probe_abc")
        #expect(
            ChatEngine.resolvedOfferedToolName("canonical_probe_abc", offered: offered([tool]))
                == "probe_canonical_probe_abc"
        )
    }

    @Test
    func canonicalNameIsNotResolvedToAnUnofferedTool() {
        let tool = MCPProviderTool(mcpTool: mcpTool("canonical_probe_hidden"), providerId: UUID(), providerName: "Probe")
        register(tool)
        defer { cleanup([tool]) }
        // Registered but not offered this turn: stays unresolved, so the
        // engine rejects it as not offered.
        #expect(ChatEngine.resolvedOfferedToolName("canonical_probe_hidden", offered: []) == "canonical_probe_hidden")
        #expect(ChatEngine.resolvedOfferedToolName("canonical_probe_hidden", offered: nil) == "canonical_probe_hidden")
    }

    @Test
    func ambiguousCanonicalNameIsNotGuessed() {
        let a = MCPProviderTool(mcpTool: mcpTool("canonical_probe_dup"), providerId: UUID(), providerName: "Alpha")
        let b = MCPProviderTool(mcpTool: mcpTool("canonical_probe_dup"), providerId: UUID(), providerName: "Beta")
        register(a)
        register(b)
        defer { cleanup([a, b]) }
        #expect(ChatEngine.resolvedOfferedToolName("canonical_probe_dup", offered: offered([a, b])) == "canonical_probe_dup")
        // Only one of the two offered: that one is unambiguous.
        #expect(ChatEngine.resolvedOfferedToolName("canonical_probe_dup", offered: offered([a])) == a.name)
    }

    @Test
    func offeredExactNameIsNeverRewritten() {
        let tool = MCPProviderTool(mcpTool: mcpTool("canonical_probe_exact"), providerId: UUID(), providerName: "Probe")
        register(tool)
        defer { cleanup([tool]) }
        #expect(ChatEngine.resolvedOfferedToolName(tool.name, offered: offered([tool])) == tool.name)
    }

    // MARK: - Description hint

    @Test
    func descriptionNamesTheExposedToolAndMapsCitedSiblings() {
        let providerId = UUID()
        let tool = MCPProviderTool(
            mcpTool: mcpTool(
                "create_page",
                description: "Creates a page. Call search first to find the parent; then use get_page to verify."
            ),
            providerId: providerId,
            providerName: "Notion",
            siblingToolNames: ["search", "get_page", "create_page", "searchable_index"]
        )
        #expect(tool.description.hasPrefix("Exposed as `notion_create_page` (server name `create_page`)."))
        #expect(tool.description.contains("`search` is `notion_search`"))
        #expect(tool.description.contains("`get_page` is `notion_get_page`"))
        // Self is never listed as a sibling; an uncited sibling is not listed.
        #expect(!tool.description.contains("`create_page` is"))
        #expect(!tool.description.contains("searchable_index"))
        // The original text survives after the hint.
        #expect(tool.description.hasSuffix("then use get_page to verify."))
    }

    @Test
    func descriptionHintSurvivesTruncationAndIsAbsentWhenUnprefixed() {
        let long = String(repeating: "x", count: MCPProviderTool.maxDescriptionLength + 50)
        let prefixed = MCPProviderTool(
            mcpTool: mcpTool("big", description: long),
            providerId: UUID(),
            providerName: "Srv"
        )
        #expect(prefixed.description.hasPrefix("Exposed as `srv_big` (server name `big`). "))
        #expect(prefixed.description.hasSuffix("..."))

        let bare = MCPProviderTool(
            mcpTool: mcpTool("big", description: "plain"),
            providerId: UUID(),
            providerName: "Srv",
            prefixWithProvider: false
        )
        #expect(bare.description == "plain")
    }

    @Test
    func wholeWordSiblingMatchIgnoresSubstrings() {
        #expect(MCPProviderTool.mentionsWholeWord("search", in: "run search then stop"))
        #expect(MCPProviderTool.mentionsWholeWord("search", in: "search"))
        #expect(MCPProviderTool.mentionsWholeWord("search", in: "call `search`."))
        #expect(!MCPProviderTool.mentionsWholeWord("search", in: "use search_issues"))
        #expect(!MCPProviderTool.mentionsWholeWord("search", in: "well researched"))
        #expect(!MCPProviderTool.mentionsWholeWord("", in: "anything"))
    }
}
