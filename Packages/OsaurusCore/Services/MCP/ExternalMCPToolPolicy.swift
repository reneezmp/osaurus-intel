//
//  ExternalMCPToolPolicy.swift
//  OsaurusCore
//
//  Visibility and execution rules for tools exposed to external MCP callers
//  (the `osaurus mcp` stdio proxy and the `/mcp/*` HTTP bridge).
//

import Foundation

enum ExternalMCPToolPolicy {
    nonisolated static func isToolVisibleToExternalMCP(name: String, enabled: Bool) -> Bool {
        enabled && !ToolRegistry.externallyDeniedToolNames.contains(name)
    }

    nonisolated static func externalMCPDenialMessage(for name: String) -> String? {
        guard ToolRegistry.externallyDeniedToolNames.contains(name) else { return nil }
        return "'\(name)' is not available to external callers. "
            + "App-only tools can only run from the Osaurus app."
    }

    @MainActor
    static func executeToolAsExternalMCP(
        name: String, argumentsJSON: String, harnessAgentId: UUID? = nil
    ) async throws -> String {
        guard ToolRegistry.shared.isGlobalEnabled(name) else {
            throw NSError(
                domain: "ToolRegistry",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey: "Tool '\(name)' is disabled in Osaurus settings."
                ]
            )
        }
        return try await ChatExecutionContext.$isExternalSurface.withValue(true) {
            try await ChatExecutionContext.$denyUnapprovedToolPrompts.withValue(true) {
                // A live harness token proves which agent's chat this is; bind
                // it for this call (attribution, not trust).
                try await ChatExecutionContext.$currentAgentId.withValue(harnessAgentId) {
                    try await ChatExecutionContext.$harnessTokenAgentId.withValue(harnessAgentId) {
                        try await ToolRegistry.shared.execute(name: name, argumentsJSON: argumentsJSON)
                    }
                }
            }
        }
    }
}
