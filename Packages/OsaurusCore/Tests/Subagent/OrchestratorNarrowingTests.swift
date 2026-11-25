//
//  OrchestratorNarrowingTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  W-subagents stage 5: once `spawn_agent` is offered, the Orchestrator's
//  folder surface narrows to `file_read` / `file_search` (upstream
//  `orchestratorExcludedToolNames`) and its prompt says where deliverables
//  go. With no runnable target it keeps its full folder tools.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Orchestrator folder narrowing (stage 5)", .serialized)
struct OrchestratorNarrowingTests {
    private static let folderTools: Set<String> = [
        "file_read", "file_search", "file_tree", "file_write", "file_edit", "file_copy", "file_undo",
        "file_operation_history", "shell_run", "git_status", "git_diff", "git_commit", "detect_pii",
        "redact_file",
    ]

    @Test func onlyReadAndSearchSurviveAndShareArtifactGoes() {
        for name in Self.folderTools {
            let excluded = ToolRegistry.orchestratorExcludesWhenDelegating(name, folderToolNames: Self.folderTools)
            #expect(excluded == !["file_read", "file_search"].contains(name), "\(name)")
        }
        #expect(ToolRegistry.orchestratorExcludesWhenDelegating("share_artifact", folderToolNames: []))
        // Tools outside the folder surface are never touched.
        #expect(!ToolRegistry.orchestratorExcludesWhenDelegating("web_search", folderToolNames: Self.folderTools))
        #expect(!ToolRegistry.orchestratorExcludesWhenDelegating("osaurus_config", folderToolNames: Self.folderTools))
    }

    @Test func deliverablesLineIsHonestAboutTheFolder() {
        let withFolder = IntelOrchestratorPrompt.deliverablesLine(folderReadable: true)
        #expect(withFolder.contains("`artifact_paths`"))
        #expect(withFolder.contains("`file_read`"))
        #expect(withFolder.contains("never write"))
        let without = IntelOrchestratorPrompt.deliverablesLine(folderReadable: false)
        #expect(without.contains("No working folder is set"))
        #expect(without.contains("Folder chip"))
        #expect(!without.contains("`file_read`"))
    }

    @Test func promptCarriesTheLineOnlyWhileSpawnIsOffered() {
        let spawn = IntelOrchestratorPrompt.compose(
            agentID: Agent.defaultId, editablePrompt: "", spawnAgentAvailable: true, folderReadable: true)
        #expect(spawn.contains("Deliverables live in the working folder"))
        let noFolder = IntelOrchestratorPrompt.compose(
            agentID: Agent.defaultId, editablePrompt: "", spawnAgentAvailable: true, folderReadable: false)
        #expect(noFolder.contains("No working folder is set on this chat"))
        let legacy = IntelOrchestratorPrompt.compose(
            agentID: Agent.defaultId, editablePrompt: "", spawnAgentAvailable: false, folderReadable: true)
        #expect(!legacy.contains("Deliverables live in the working folder"))
    }
}
