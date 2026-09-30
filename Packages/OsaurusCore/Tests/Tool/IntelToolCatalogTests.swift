//
//  IntelToolCatalogTests.swift
//  OsaurusCoreTests
//
//  Tools & MCP on Intel (upstream #2950 step 3 + `W-tool-catalog-ui`):
//  registry availability, the registry-backed exposure snapshot, tab
//  deep links, and the Auto-Allow decision (docs/SETTINGS_REDESIGN_INTEL.md).
//

import Foundation
import Testing

@testable import OsaurusCore

/// `@MainActor`: registry lookups reach `folderToolNames`, which asserts the
/// main actor (tests trap with signal 5 otherwise).
@Suite("Intel Tools & MCP catalog")
@MainActor
struct IntelToolCatalogTests {

    @Test func autoAllowSkipsTheCardExceptForPerCallTools() {
        #expect(ToolApprovalSettings.skipsApprovalCard(perCallRequired: false, autoAllowAll: true))
        #expect(!ToolApprovalSettings.skipsApprovalCard(perCallRequired: true, autoAllowAll: true))
        #expect(!ToolApprovalSettings.skipsApprovalCard(perCallRequired: false, autoAllowAll: false))
        #expect(ToolApprovalSettings.autoAllowAllDefaultsKey == "chatAutoAllowAllTools")
    }

    /// Deleting Knowledge documents keeps asking even with Auto-Allow on.
    @Test func deleteKnowledgeStillCountsAsPerCall() {
        #expect(ToolRegistry.shared.requiresPerCallApproval("delete_knowledge"))
        #expect(!ToolRegistry.shared.requiresPerCallApproval("write_knowledge"))
    }

    @Test func availabilityExplainsRegisteredAndMissingTools() {
        let missing = ToolRegistry.shared.availability(forTool: "no_such_tool_xyz")
        #expect(missing.reasonCodes == [.notRegistered])

        let builtIn = ToolRegistry.shared.availability(forTool: ToolRegistry.speakToolName)
        #expect(builtIn.reasonCodes.contains(.alreadyLoaded) || builtIn.reasonCodes.contains(.permissionBlocked))
        #expect(builtIn.runtime != nil)
    }

    @Test func entryLookupMatchesTheListedTool() throws {
        let entry = try #require(ToolRegistry.shared.entry(named: ToolRegistry.speakToolName))
        #expect(entry.name == ToolRegistry.speakToolName)
        #expect(ToolRegistry.shared.entry(named: "no_such_tool_xyz") == nil)
    }

    @Test func exposureSnapshotClassifiesBuiltInsAndUnknowns() async {
        let diagnostic = await ToolIndexService.shared.exposureDiagnostic(
            forToolNames: [ToolRegistry.speakToolName, "no_such_tool_xyz", "capabilities"])
        let rows = Dictionary(uniqueKeysWithValues: diagnostic.rows.map { ($0.toolName, $0) })
        #expect(rows[ToolRegistry.speakToolName]?.source == .builtIn)
        #expect(rows[ToolRegistry.speakToolName]?.registered == true)
        #expect(rows["no_such_tool_xyz"]?.registered == false)
        #expect(rows["no_such_tool_xyz"]?.searchReasonCodes.contains(.notRegistered) == true)
        #expect(rows["capabilities"]?.searchReasonCodes.contains(.excludedCapabilityInfrastructure) == true)
    }

    @Test func toolsTabsResolveOldAndNewNames() {
        #expect(ToolsTab.resolved(from: "Services") == .services)
        #expect(ToolsTab.resolved(from: "Remote") == .services)  // Intel's old MCP tab
        #expect(ToolsTab.resolved(from: "Available") == .all)  // Intel's old default tab
        #expect(ToolsTab.resolved(from: "Sandbox") == .all)
        #expect(ToolsTab.resolved(from: "plugins") == .nativePlugins)
        #expect(ToolsTab.resolved(from: "nonsense") == nil)
        #expect(ToolsTab.allCases.first == .services)
    }

    @Test func tabIsCalledToolsAndMCP() {
        #expect(ManagementTab.tools.label == L("Tools & MCP"))
        let hits = SettingsSearchIndex.search("auto-allow")
        #expect(hits.first?.id == "tools.autoAllowAll")
        #expect(hits.first?.subTab == "All")
    }
}
