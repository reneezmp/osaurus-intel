import Foundation
import Testing

@testable import OsaurusCore

/// A canonical chat rename updates the retained Activity task's title and the
/// persisted retained-tab record (upstream #3351). Intel's
/// `ChatSessionsManager.rename` calls `synchronizeCanonicalTitle`; this
/// exercises the retained-registry side directly (Intel has no
/// `renameQuietly`, and no `ChatSessionStore.load`).
@Suite(.serialized)
@MainActor
struct IntelRetainedChatTitleSynchronizationTests {
    @Test func canonicalTitleUpdatesRetainedStateAndPersistedRecord() async throws {
        let suiteName = "IntelRetainedChatTitleSynchronizationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = BackgroundTaskManager.makeForTestingRetaining(defaults: defaults)
        let id = UUID()
        let context = ExecutionContext(id: id, agentId: Agent.defaultId)
        context.chatSession.chatEngineFactory = { MockChatEngine() }
        context.chatSession.title = "Original retained title"
        context.chatSession.turns = [
            ChatTurn(role: .user, content: "Keep this transcript"),
            ChatTurn(role: .assistant, content: "The retained result"),
        ]
        let state = BackgroundTaskState(
            id: id,
            taskTitle: "Original retained title",
            agentId: Agent.defaultId,
            chatSession: context.chatSession,
            executionContext: context,
            status: .completed(summary: "Chat completed")
        )
        manager.registerTaskForTesting(state)
        manager.dehydrateTaskForTesting(id)
        #expect(await Task.detached { manager.flushRetainedTabWrites() }.value)

        manager.synchronizeCanonicalTitle(id, title: "Renamed through Chat UI")
        #expect(state.taskTitle == "Renamed through Chat UI")
        #expect(await Task.detached { manager.flushRetainedTabWrites() }.value)

        let relaunched = BackgroundTaskManager.makeForTestingRetaining(defaults: defaults)
        #expect(relaunched.taskState(for: id)?.taskTitle == "Renamed through Chat UI")

        manager.finalizeTask(id)
        #expect(await Task.detached { manager.flushRetainedTabWrites() }.value)
    }

    @Test func unknownTaskIsIgnored() {
        let manager = BackgroundTaskManager.makeForTesting()
        manager.synchronizeCanonicalTitle(UUID(), title: "Nobody owns this")
        #expect(manager.taskState(for: UUID()) == nil)
    }
}
