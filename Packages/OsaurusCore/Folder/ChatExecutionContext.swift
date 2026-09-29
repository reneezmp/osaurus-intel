//
//  ChatExecutionContext.swift
//  osaurus
//
//  TaskLocal context populated by the chat engine before dispatching every
//  tool call so per-session state (the agent todo, file-operation undo
//  log, method telemetry, etc.) can be addressed by the active session.
//

import Foundation

/// TaskLocal storage carrying the active chat session / agent / batch ids
/// down through tool execution. The chat engine seeds these in
/// `ChatSession.send` (and equivalent headless paths) so any tool reading
/// them picks up the right scope without an explicit parameter.
/// Mutable marker shared by every tool execution in one canonical agent-loop
/// run. The visible Todo remains session-scoped, but terminal semantics must
/// not be: an unchecked checklist from a previous user turn cannot turn an
/// unrelated later `complete` call into a blocked completion.
///
/// Intel: `ChatSession` creates one scope per run and binds it around the
/// engine stream, so the tools `CloudChatEngine` executes inherit it. Task-group children inherit the TaskLocal
/// reference, and the lock makes simultaneous sibling calls safe.
final class AgentTodoRunScope: @unchecked Sendable {
    private let lock = NSLock()
    private var wroteTodo = false
    /// Tools other than the loop-control ones that have actually STARTED this
    /// run. The Todo tool reads this to tell real progress apart from a model
    /// simply asserting it: in osaurus#2439 a model went from 2/7 to 7/7
    /// checked with nothing but `todo` calls in between, and the tool echoed
    /// "Todo updated: 7/7 complete" back into context, where the model then
    /// cited it as evidence the writes had happened.
    private var substantiveToolCalls = 0
    /// `substantiveToolCalls` as of the previous accepted `todo` write.
    private var toolCallsAtLastTodo = 0

    /// Loop-control tools. Calling these is bookkeeping, never task progress,
    /// so they must not count as work toward a newly checked item.
    static let loopControlToolNames: Set<String> = [
        "todo", "complete", "clarify", "share_artifact", PromptWorkingFolderTool.toolName,
    ]

    var hasCurrentRunTodo: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wroteTodo
    }

    func markTodoWritten() {
        lock.lock()
        wroteTodo = true
        lock.unlock()
    }

    func recordToolExecution(name: String) {
        guard !Self.loopControlToolNames.contains(name) else { return }
        lock.lock()
        substantiveToolCalls += 1
        lock.unlock()
    }

    /// Whether any non-loop-control tool has run since the previous `todo`
    /// write, snapshotting the counter for the next comparison. Called once
    /// per accepted `todo` write.
    func consumeToolWorkSinceLastTodo() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let didWork = substantiveToolCalls > toolCallsAtLastTodo
        toolCallsAtLastTodo = substantiveToolCalls
        return didWork
    }
}

public enum ChatExecutionContext {
    /// The current chat session id whose tool calls are running. Tools that
    /// need per-conversation state (todo store, file-op undo log, method
    /// telemetry) key off this.
    @TaskLocal public static var currentSessionId: String?

    /// The current batch ID for grouped operations (nil for non-batch operations).
    @TaskLocal public static var currentBatchId: UUID?

    /// The agent ID whose context is active for the current execution.
    @TaskLocal public static var currentAgentId: UUID?

    /// The project that owns the active chat, when one is selected. Knowledge
    /// tools union this project's explicitly shared collections with the
    /// running agent's own grants.
    @TaskLocal public static var currentProjectId: UUID?

    /// Trusted host-folder root for the chat executing this turn. Folder
    /// tools resolve this value at call time, which keeps simultaneous chats
    /// with different folders from cross-routing filesystem operations.
    @TaskLocal public static var currentFolderRoot: URL?

    /// Knowledge authorization follows a spawned agent when a child run
    /// temporarily overrides the normal execution agent. The override is
    /// intentionally separate from `currentAgentId`, which remains the
    /// identity used by the surrounding chat/runtime bookkeeping.
    @TaskLocal static var knowledgeGrantAgentIdOverride: UUID?

    /// The agent identity used by Knowledge tools for grant resolution.
    static var knowledgeAgentId: UUID? {
        knowledgeGrantAgentIdOverride ?? currentAgentId
    }

    /// Assistant turn dispatching the current tool call. Used by `speak`
    /// to bind TTS playback to the right message bubble
    @TaskLocal public static var currentAssistantTurnId: UUID?

    /// Specific tool invocation id. Used by `speak` so the inline card
    /// can swap its check for a spinner while its audio plays
    @TaskLocal public static var currentToolCallId: String?

    /// The current `agent_runs.id` row (`SchedulerDatabase`) so every
    /// mutation done by `db.*` tools or scheduling tools can stamp its
    /// originating run on the `_changelog` audit trail (spec §1.4,
    /// §8). Bound by `BackgroundTaskManager.dispatchChat` for any
    /// dispatched chat (chat / schedule / watcher / self-scheduled
    /// triggers). `nil` for paths that didn't go through dispatch
    /// (e.g. direct UI edits via `RowEditorSheet`) — the bridge
    /// stamps `_changelog.run_id` as NULL in that case but actor
    /// resolution is independent (see `currentRunActor`).
    @TaskLocal public static var currentRunId: UUID?

    /// String tag identifying who's "driving" the current execution.
    /// One of "agent" (an inference loop), "user" (UI edit), "system"
    /// (background job), or "migration" (migration runner). Used by
    /// `LocalAgentBridge` when stamping `_changelog.actor` on writes
    /// that go through the bridge. When `nil`, `LocalAgentBridge`
    /// falls back to `agent` — UI paths that want `user` stamping
    /// must bind this explicitly.
    @TaskLocal public static var currentRunActor: String?

    /// The current `BackgroundTaskState.id` for the running chat task,
    /// so streaming producers (chat engine, HTTP SSE relay, plugin
    /// host bridge) can forward token-usage deltas into
    /// `BackgroundTaskManager.recordUsage(...)` for mid-stream budget
    /// enforcement (spec §11.3). Bound by
    /// `BackgroundTaskManager.dispatchChat` alongside `currentRunId`.
    @TaskLocal public static var currentBackgroundId: UUID?

    /// The attended chat running this tool call, bound by `ChatSession` only
    /// when it offered `prompt_working_folder` (upstream #2918). Nil for
    /// background dispatches, delegated children and every other surface.
    @TaskLocal static var currentChatSessionBox: WeakChatSessionBox?

    /// Per-run todo bookkeeping (upstream): lets `todo` tell real progress
    /// from assertion and scopes `complete`'s unchecked-item check to the run.
    @TaskLocal static var agentTodoRunScope: AgentTodoRunScope?
}
