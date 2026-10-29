//
//  TaskStateDictTests.swift
//  OsaurusCoreTests
//
//  Upstream's `TaskStateDictTests` (from `PluginHostAPITests.swift`, which
//  Intel excludes: no plugin host). `GET /tasks/{id}` serializes with it
//  (`W-server-api` stage 4b).
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct TaskStateDictTests {

    private func parse(_ json: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }

    @Test
    @MainActor
    func runningTaskIncludesTitleAndStep() {
        let context = ExecutionContext(agentId: Agent.defaultId, title: "Build feature")
        let state = BackgroundTaskState(
            id: UUID(),
            taskTitle: "Build feature",
            agentId: Agent.defaultId,
            chatSession: context.chatSession,
            executionContext: context,
            currentStep: "Writing code"
        )
        let dict = PluginHostContext.taskStateDict(id: state.id, state: state)
        #expect(dict["title"] as? String == "Build feature")
        #expect(dict["status"] as? String == "running")
        #expect(dict["current_step"] as? String == "Writing code")
    }

    @Test
    @MainActor
    func taskStateDictIncludesDraft() {
        let context = ExecutionContext(agentId: Agent.defaultId, title: "Build feature")
        let state = BackgroundTaskState(
            id: UUID(),
            taskTitle: "Build feature",
            agentId: Agent.defaultId,
            chatSession: context.chatSession,
            executionContext: context
        )
        state.draftText = "{\"text\":\"working...\"}"
        let dict = PluginHostContext.taskStateDict(id: state.id, state: state)
        let draft = dict["draft"] as? [String: Any]
        #expect(draft?["text"] as? String == "working...")
    }

    @Test
    @MainActor
    func completedTaskIncludesTitleAndSummary() {
        let context = ExecutionContext(agentId: Agent.defaultId, title: "Deploy app")
        let state = BackgroundTaskState(
            id: UUID(),
            taskTitle: "Deploy app",
            agentId: Agent.defaultId,
            chatSession: context.chatSession,
            executionContext: context,
            status: .completed(success: true, summary: "All done")
        )
        let dict = PluginHostContext.taskStateDict(id: state.id, state: state)
        #expect(dict["title"] as? String == "Deploy app")
        #expect(dict["status"] as? String == "completed")
        #expect(dict["success"] as? Bool == true)
        #expect(dict["summary"] as? String == "All done")
    }
}
