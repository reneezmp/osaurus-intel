import Testing

@testable import OsaurusCore

@Suite("Intel seeded tool allowlist")
struct IntelSeededToolAllowlistTests {
    @Test("removed tools are denied after an allowlist has been seeded")
    func removedToolIsDeniedIndependentlyOfDiscoveryMode() {
        #expect(!ToolRegistry.isAdmittedBySeededAllowlist(
            name: "removed_tool",
            enabledToolNames: ["kept_tool"],
            runtimeManagedToolNames: []
        ))
        #expect(ToolRegistry.isAdmittedBySeededAllowlist(
            name: "kept_tool",
            enabledToolNames: ["kept_tool"],
            runtimeManagedToolNames: []
        ))
    }

    @Test("mounted folder tools and built-in Orchestrator tools keep their explicit admission")
    func explicitExceptionsRemainAdmitted() {
        #expect(ToolRegistry.isAdmittedBySeededAllowlist(
            name: "file_read",
            enabledToolNames: [],
            runtimeManagedToolNames: ["file_read"]
        ))
        for name in ToolRegistry.orchestratorOnlyToolNames {
            #expect(ToolRegistry.isAdmittedBySeededAllowlist(
                name: name,
                enabledToolNames: [],
                runtimeManagedToolNames: []
            ))
        }
    }
}
