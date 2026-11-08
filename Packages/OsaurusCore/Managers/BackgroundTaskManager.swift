//
//  BackgroundTaskManager.swift
//  osaurus
//
//  Single owner of all backgrounded work — dispatched chat tasks (from
//  schedules, shortcuts, plugins, HTTP, watchers). Drives NotchView,
//  provides completion signaling, and handles lazy window creation.
//

import Combine
import Foundation

/// Durable metadata for a user-owned terminal run tab (upstream
/// `RetainedActivityTabRecord`). The live chat session is deliberately not
/// encoded; chat history stays the canonical transcript store and is loaded
/// when the tab is selected. Intel: no inbound-run field
/// (`W-workspaces-sharing`); `contextPreview` is optional so records written
/// before 2026-11 (no preview) still decode.
private struct RetainedActivityTabRecord: Codable {
    enum TerminalKind: String, Codable {
        case completed
        case failed
        case cancelled
    }

    let id: UUID
    let title: String
    let agentId: UUID
    let kind: TerminalKind
    let summary: String?
    let createdAt: Date
    let source: SessionSource
    let sourcePluginId: String?
    let externalSessionKey: String?
    let contextPreview: [BackgroundTaskContextMessage]?

    @MainActor
    init?(state: BackgroundTaskState) {
        switch state.status {
        case .completed(let value):
            kind = .completed
            summary = value
        case .failed(let value):
            kind = .failed
            summary = value
        case .cancelled:
            kind = .cancelled
            summary = nil
        case .queued, .running, .waitingForInput:
            return nil
        }
        id = state.id
        title = state.taskTitle
        agentId = state.agentId
        createdAt = state.createdAt
        source = state.source
        sourcePluginId = state.sourcePluginId
        externalSessionKey = state.externalSessionKey
        contextPreview = state.contextPreview
    }

    var status: BackgroundTaskStatus {
        switch kind {
        case .completed: return .completed(summary: summary ?? "Chat completed")
        case .failed: return .failed(summary: summary ?? "Chat failed")
        case .cancelled: return .cancelled
        }
    }
}

// MARK: - Background Task Manager

/// Single owner of all backgrounded chat tasks (dispatched).
@MainActor
public final class BackgroundTaskManager: ObservableObject {
    public static let shared = BackgroundTaskManager()

    // MARK: - Published State

    /// All background tasks keyed by task ID
    @Published public private(set) var backgroundTasks: [UUID: BackgroundTaskState] = [:]

    /// Activity-visible tasks (`showToast == true`) not currently attached
    /// to a chat window, sorted by status priority then recency (upstream).
    /// Background runs surface as tabs of their agent, so no view lists this
    /// directly; it backs `closeAgentTaskGroup` and tests. Recomputed only
    /// when the task set or a task's observable state changes.
    public private(set) var sortedToastTasks: [BackgroundTaskState] = []

    // MARK: - Private State

    /// Combined cancellables for each task (session + state observers)
    private var taskObservers: [UUID: Set<AnyCancellable>] = [:]

    /// Continuations for callers awaiting task completion (e.g. ScheduleManager)
    private var completionContinuations: [UUID: CheckedContinuation<DispatchResult, Never>] = [:]

    /// Tracks the number of turns already processed per chat task so we only log new tool calls.
    private var chatTurnCounts: [UUID: Int] = [:]

    /// Scheduled auto-finalize timers for completed/cancelled tasks
    private var autoFinalizeTasks: [UUID: Task<Void, Never>] = [:]

    /// Production managers persist terminal run tabs across relaunches
    /// (upstream). Test processes never read or write them, so suites can't
    /// leak records into each other through the shared manager.
    private let persistsRetainedTabs: Bool
    /// Upstream: holds the idle-sleep assertion while runs are active. Nil in
    /// test processes so tests never change the host's power state.
    private let powerManager: AgentRunPowerManager?
    private let retainedTabsDefaults: UserDefaults
    private static let retainedTabsDefaultsKey = "retainedNotchTabs.v1"

    /// Tasks whose dispatch() hasn't returned to the plugin yet; events are
    /// buffered in `heldTaskEvents` until `releaseEventsForDispatch` flushes them.
    private var dispatchHoldTasks: Set<UUID> = []
    private var heldTaskEvents: [UUID: [(type: TaskEventType, json: String)]] = [:]

    /// Tasks for which `ChatSession.isStreaming` has flipped to `true` at
    /// least once. Guards `markCompleted` against the synchronous initial
    /// `(false, nil)` tuple that `Publishers.CombineLatest` emits the instant
    /// `observeChatTask` subscribes (well before `ChatSession.send`'s async
    /// Task body runs). See `handleChatStreamingChange`.
    private var streamingObserved: Set<UUID> = []

    /// Background-task id keyed by the chat window currently bound to it.
    /// Populated by `detachChatWindow` and by `openTaskWindow`; consulted
    /// by `ChatWindowManager` in `windowWillClose` to decide whether to
    /// skip `cleanup()` (which would otherwise call `session.stop()` and
    /// kill the in-flight stream).
    private var taskIdByWindow: [UUID: UUID] = [:]

    /// FIFO admission queue: task ids accepted while the configured
    /// concurrency limits were saturated, in submission order. Each id has a
    /// matching deferred start closure in `pendingStarts`. Promoted by
    /// `pumpQueue()` whenever a running task stops consuming its slot.
    private var queuedOrder: [UUID] = []

    /// Deferred start work for queued tasks, keyed by task id.
    private var pendingStarts: [UUID: @MainActor () async -> Void] = [:]

    /// Subject for batching view updates with throttling
    private let viewUpdateSubject = PassthroughSubject<Void, Never>()
    private var viewUpdateCancellable: AnyCancellable?

    // MARK: - Initialization

    private init(
        persistsRetainedTabs: Bool = !OsaurusPaths.isTestProcess,
        retainedTabsDefaults: UserDefaults = .standard,
        powerManager: AgentRunPowerManager? = OsaurusPaths.isTestProcess ? nil : .shared
    ) {
        self.powerManager = powerManager
        self.persistsRetainedTabs = persistsRetainedTabs
        self.retainedTabsDefaults = retainedTabsDefaults
        viewUpdateCancellable =
            viewUpdateSubject
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                guard let self else { return }
                // A task's own state (status / createdAt-relative ordering)
                // may have changed, so refresh the cached ordering before
                // driving the throttled view update.
                self.recomputeSortedToastTasks()
                self.objectWillChange.send()
            }
        restoreRetainedTabs()
    }

    // MARK: - Toast Ordering

    /// Status ordering for the Activity list: awaiting input first, then
    /// running, then queued, then terminal states. Lower sorts earlier.
    private static func statusSortPriority(_ status: BackgroundTaskStatus) -> Int {
        switch status {
        case .waitingForInput: return 0
        case .running: return 1
        case .queued: return 2
        case .completed: return 3
        case .failed: return 3
        case .cancelled: return 4
        }
    }

    /// Rebuild `sortedToastTasks` from the current task set (upstream).
    /// Intel: no subagent-mirror filter (`W-subagents`).
    private func recomputeSortedToastTasks() {
        sortedToastTasks =
            backgroundTasks.values
            // Headless dispatchers opt out by setting `showToast = false`.
            .filter { $0.showToast }
            // A task attached to a live chat window surfaces its state in
            // that window, so completion never double-announces.
            .filter { !isTaskAttachedToWindow($0.id) }
            .sorted { a, b in
                let ap = Self.statusSortPriority(a.status), bp = Self.statusSortPriority(b.status)
                if ap != bp { return ap < bp }
                return a.createdAt > b.createdAt
            }
        refreshPowerAssertion()
    }

    /// Upstream: re-evaluate idle-sleep prevention after task state or the
    /// keep-awake preference changes.
    func refreshPowerAssertion() {
        powerManager?.update(for: backgroundTasks.values.map(\.status))
    }

    var isPreventingIdleSystemSleep: Bool {
        powerManager?.isPreventingIdleSystemSleep ?? false
    }

    // MARK: - Public API

    /// Check if a task ID corresponds to a background task
    public func isBackgroundTask(_ id: UUID) -> Bool {
        backgroundTasks[id] != nil
    }

    /// Get background task state by ID
    public func taskState(for id: UUID) -> BackgroundTaskState? {
        backgroundTasks[id]
    }

    /// Rename an Activity session and its canonical persisted conversation.
    /// There is intentionally no Activity-only alias: the same title appears in
    /// the tab, the Chat window, and the conversation sidebar (upstream).
    @discardableResult
    public func renameTask(_ id: UUID, title: String) -> Bool {
        guard let state = backgroundTasks[id] else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        state.taskTitle = trimmed
        if let session = state.chatSession {
            session.title = trimmed
            session.save()
        }
        ChatSessionsManager.shared.rename(id: id, title: trimmed)
        persistRetainedTabs()
        recomputeSortedToastTasks()
        objectWillChange.send()
        return true
    }

    /// Fires when a run that belongs in a tab strip registers (upstream).
    public let taskRegistered = PassthroughSubject<BackgroundTaskState, Never>()

    /// Whether a task belongs in a chat window's tab strip: user-visible.
    /// (Upstream also excludes subagent mirrors, which Intel doesn't have.)
    private static func isTabWorthy(_ state: BackgroundTaskState) -> Bool {
        state.showToast
    }

    /// Every registered run a freshly opened chat window should surface as
    /// a tab, oldest first. Headless (`showToast == false`) runs excluded.
    public func tasksForTabs() -> [BackgroundTaskState] {
        backgroundTasks.values
            .filter(Self.isTabWorthy)
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The registry task whose run `session` displays, if any: the live
    /// instance itself, or the task whose id is the session's persisted id
    /// (dispatch task id == session id by construction). Upstream.
    func task(owning session: ChatSession) -> BackgroundTaskState? {
        if let live = backgroundTasks.values.first(where: { $0.chatSession === session }) {
            return live
        }
        guard let sessionId = session.sessionId else { return nil }
        return backgroundTasks[sessionId]
    }

    /// The live (active) registry task currently driving the given persisted
    /// session id, if any (upstream). On Intel these are dispatched runs:
    /// schedules, watchers and the Orchestrator's delegations.
    public func liveTask(forSessionId sessionId: UUID) -> BackgroundTaskState? {
        backgroundTasks.values.first { state in
            state.status.isActive && state.chatSession?.sessionId == sessionId
        }
    }

    /// Sessions of all still-active registry tasks.
    func activeTaskSessions() -> [ChatSession] {
        backgroundTasks.values.compactMap { state in
            guard state.status.isActive else { return nil }
            return state.chatSession
        }
    }

    /// Background-task id (if any) the given window is bound to. Returns
    /// nil for plain chat windows that were never detached.
    public func taskId(forWindowId windowId: UUID) -> UUID? {
        taskIdByWindow[windowId]
    }

    /// Whether this window is bound to a still-tracked background task.
    /// False if the window was never detached or its task already finalized.
    public func isWindowDetachedToBackground(windowId: UUID) -> Bool {
        guard let id = taskIdByWindow[windowId] else { return false }
        return backgroundTasks[id] != nil
    }

    /// Whether any live chat window is currently bound to (viewing) this
    /// task. Attached tasks surface their state in the window instead of
    /// the Activity list / toast.
    func isTaskAttachedToWindow(_ taskId: UUID) -> Bool {
        taskIdByWindow.contains { windowId, boundTask in
            boundTask == taskId && ChatWindowManager.shared.windowExists(id: windowId)
        }
    }

    /// Bind a window to a task so closing/switching that window is treated
    /// as detaching the view rather than stopping execution, and so the
    /// Activity list stops double-reporting a chat the user can already see.
    public func bindWindow(_ windowId: UUID, toTask taskId: UUID) {
        taskIdByWindow[windowId] = taskId
        recomputeSortedToastTasks()
        viewUpdateSubject.send()
    }

    /// Remove a window's task binding (window closed or switched to another
    /// chat). The task itself is untouched; if it is still active it
    /// resurfaces in the Activity list.
    public func unbindWindow(_ windowId: UUID) {
        guard taskIdByWindow.removeValue(forKey: windowId) != nil else { return }
        recomputeSortedToastTasks()
        viewUpdateSubject.send()
    }

    /// Adopt a live in-flight `ChatSession` into the registry so its
    /// execution lifecycle is owned here, independent of any window. Reuses
    /// the existing instance verbatim (no new session, no disk hydration) so
    /// all publishers keep firing uninterrupted (upstream).
    ///
    /// Returns the task id, or nil if the session isn't streaming. If the
    /// session is already registry-owned, returns the existing task id.
    /// Intel: no `LiveChatSessionRegistry` shared-session guard (Intel has
    /// no co-owned sessions).
    @discardableResult
    func adoptSession(_ session: ChatSession, windowId: UUID? = nil) -> UUID? {
        // Already tracked? Just (re)bind the window.
        if let existing = backgroundTasks.values.first(where: { $0.chatSession === session }) {
            if let windowId { taskIdByWindow[windowId] = existing.id }
            return existing.id
        }
        // Adoptable while executing OR paused on a clarify prompt — a run
        // waiting for input is still alive and must survive the view going
        // away. (The clarify observer installed below immediately replays
        // the pause into `.waitingForInput`.)
        guard session.isStreaming || session.awaitingClarify != nil else { return nil }

        // Persist before adopting so the sidebar and `openTaskWindow` reload
        // path both see a real saved row for this session.
        session.save()

        let context = ExecutionContext(adopting: session)
        let state = BackgroundTaskState(
            id: context.id,
            taskTitle: session.title,
            agentId: context.agentId,
            chatSession: session,
            executionContext: context,
            status: .running,
            currentStep: "Running...",
            source: .chat,
            sourcePluginId: nil,
            externalSessionKey: nil,
            showToast: true
        )
        registerTask(state)
        observeChatTask(state, session: session)
        if let windowId { taskIdByWindow[windowId] = state.id }
        recomputeSortedToastTasks()
        return state.id
    }

    /// Detach a streaming chat window's session into a background task so
    /// the user can close the window without killing the in-flight stream.
    /// The detached task comes back as a tab of its agent in the next window
    /// that opens, and can be re-opened via `openTaskWindow(_:)`.
    ///
    /// No-op if the window doesn't exist, isn't streaming, or was already
    /// detached.
    public func detachChatWindow(windowId: UUID) {
        guard taskIdByWindow[windowId] == nil,
            let session = ChatWindowManager.shared.windowState(id: windowId)?.session
        else { return }
        if let taskId = adoptSession(session, windowId: windowId) {
            print("[BackgroundTaskManager] Detached chat window \(windowId) as task \(taskId)")
        }
    }

    /// Bring a background task on screen: as a tab of its agent (upstream
    /// `revealTask`). The tab keeps the run's live session; closing a
    /// finished run's tab dismisses the task.
    public func openTaskWindow(_ backgroundId: UUID) {
        guard backgroundTasks[backgroundId] != nil else { return }
        cancelAutoFinalize(backgroundId)
        ChatWindowManager.shared.revealTask(backgroundId)
    }

    /// Remove a background task from management, cancelling all observers and timers.
    public func finalizeTask(_ backgroundId: UUID) {
        guard let state = backgroundTasks[backgroundId] else { return }

        // Ensure plugins always receive a terminal event before cleanup.
        if state.status.isActive, state.sourcePluginId != nil {
            state.status = .cancelled
            emitPluginEvent(
                state,
                type: .cancelled,
                json: PluginHostContext.serializeCancelledEvent(taskTitle: state.taskTitle)
            )
            if let runId = state.agentRunId {
                do {
                    try SchedulerDatabase.shared.recordRunEnd(runId: runId, status: .cancelled)
                } catch {
                    print("[BackgroundTaskManager] recordRunEnd (finalize/cancel) failed for run \(runId): \(error)")
                }
                state.agentRunId = nil
            }
        }

        dispatchHoldTasks.remove(backgroundId)
        if let events = heldTaskEvents.removeValue(forKey: backgroundId) {
            for event in events {
                emitPluginEvent(state, type: event.type, json: event.json)
            }
        }

        resumeCompletion(for: backgroundId, result: resultFromState(state))
        cancelAutoFinalize(backgroundId)

        taskObservers[backgroundId]?.forEach { $0.cancel() }
        taskObservers.removeValue(forKey: backgroundId)
        chatTurnCounts.removeValue(forKey: backgroundId)
        streamingObserved.remove(backgroundId)
        // Drop any window→task bindings pointing here so a still-open
        // window's close path stops thinking the task is alive.
        taskIdByWindow = taskIdByWindow.filter { $0.value != backgroundId }
        // Drop any deferred start so a finalized queued task can't launch.
        queuedOrder.removeAll { $0 == backgroundId }
        pendingStarts.removeValue(forKey: backgroundId)

        state.releaseReferences()

        backgroundTasks.removeValue(forKey: backgroundId)
        persistRetainedTabs()
        recomputeSortedToastTasks()
        pumpQueue()
    }

    /// Cancel all active background tasks. Called during app termination.
    /// Queued requests are cancelled FIRST: cancelling a running task frees
    /// its slot and pumps the queue, so doing it the other way around would
    /// briefly promote (and start) queued work mid-shutdown.
    public func cancelAllTasks() {
        for queuedId in queuedOrder {
            cancelTask(queuedId)
        }
        for (id, state) in backgroundTasks where state.status.isActive {
            cancelTask(id)
        }
    }

    /// Update a task's running token / cost counters and cancel the
    /// task when either dimension crosses its configured ceiling (spec
    /// §11.3). Safe to call from any actor — we hop to MainActor
    /// internally because `BackgroundTaskState` is `@MainActor`.
    ///
    /// Streaming engines call this after each provider chunk. When the
    /// per-chunk USD cost isn't known, callers may pass nil and rely
    /// on token counts alone.
    public func recordUsage(
        backgroundId: UUID,
        tokensInDelta: Int = 0,
        tokensOutDelta: Int = 0,
        costUSDDelta: Double = 0
    ) {
        guard let state = backgroundTasks[backgroundId] else { return }
        state.tokensIn += max(0, tokensInDelta)
        state.tokensOut += max(0, tokensOutDelta)
        state.costUSD += max(0, costUSDDelta)
        if let reason = state.budgetExceededReason() {
            state.budgetExhaustedReason = reason
            print("[BackgroundTaskManager] budget exhausted (\(reason)) — cancelling \(backgroundId)")
            cancelTask(backgroundId)
        }
    }

    /// Cancel a background task (queued or running)
    public func cancelTask(_ backgroundId: UUID) {
        guard let state = backgroundTasks[backgroundId] else { return }
        // Intel: no subagent-mirror or inbound-run branches (`W-subagents`,
        // `W-workspaces-sharing`).
        finishChatCancellation(state, stopSession: true)
    }

    /// Shared terminal path for Activity Stop and the delegated chat's own
    /// Stop button. The latter has already stopped the session; do not enter
    /// its cleanup a second time from the synchronous streaming observer.
    private func finishChatCancellation(_ state: BackgroundTaskState, stopSession: Bool) {
        let backgroundId = state.id
        // A queued task never started — drop its deferred start so a later
        // pump can't resurrect it.
        queuedOrder.removeAll { $0 == backgroundId }
        pendingStarts.removeValue(forKey: backgroundId)

        // stop() synchronously publishes isStreaming=false. Mark cancellation
        // first so the streaming observer cannot resume a waiter with
        // .completed and promote its buffered partial answer to success.
        state.status = .cancelled
        if stopSession { state.chatSession?.stop() }
        state.captureContextPreview()
        #if OSAURUS_INTEL
        IntelTaskBanner.shared.cancelled(id: backgroundId)
        #endif
        // Mirror the markCompleted finalisation for the agent_runs row
        // so cancelled runs don't sit in `running` forever in the
        // Activity tab.
        if let runId = state.agentRunId {
            let cancelError = state.budgetExhaustedReason.map { "Budget exhausted: \($0)" }
            Self.writeRunTrace(
                runId: runId,
                state: state,
                status: .cancelled,
                endedAt: Date(),
                errorMessage: cancelError
            )
            do {
                try SchedulerDatabase.shared.recordRunEnd(
                    runId: runId,
                    status: .cancelled,
                    tokensIn: state.tokensIn > 0 ? state.tokensIn : nil,
                    tokensOut: state.tokensOut > 0 ? state.tokensOut : nil,
                    costUSD: state.costUSD > 0 ? state.costUSD : nil,
                    error: cancelError
                )
            } catch {
                print("[BackgroundTaskManager] recordRunEnd (cancel) failed for run \(runId): \(error)")
            }
            state.agentRunId = nil
        }
        resumeCompletion(for: backgroundId, result: .cancelled)
        emitPluginEvent(
            state,
            type: .cancelled,
            json: PluginHostContext.serializeCancelledEvent(taskTitle: state.taskTitle)
        )
        // Intel: no `releaseResidencyAndRearmChatWarmup` (upstream's model
        // residency release, not on Intel).
        scheduleAutoFinalize(backgroundId)
        persistRetainedTabs()
        recomputeSortedToastTasks()
        pumpQueue()
    }

    /// Close an Activity agent group: cancel every active (running / queued /
    /// waiting) Activity-visible task for the agent and finalize the whole
    /// group atomically. Terminal tasks in the group are finalized without
    /// a cancel pass (upstream).
    ///
    /// The group's deferred queued starts are dropped up front:
    /// `cancelTask` pumps the queue after each cancellation, and a running
    /// task's freed slot must not briefly promote (and start) this agent's
    /// own queued work mid-close.
    public func closeAgentTaskGroup(agentId: UUID) {
        let ids = sortedToastTasks.filter { $0.agentId == agentId }.map(\.id)
        guard !ids.isEmpty else { return }

        for id in ids {
            queuedOrder.removeAll { $0 == id }
            pendingStarts.removeValue(forKey: id)
        }
        for id in ids where backgroundTasks[id]?.status.isActive == true {
            cancelTask(id)
        }
        for id in ids {
            finalizeTask(id)
        }
    }

    /// Submit a quick reply straight into a task's retained `ChatSession`,
    /// using the same canonical send path as the chat window (upstream).
    /// For a `.waitingForInput` task this answers the pending clarify prompt
    /// (`send` clears `awaitingClarify` and resumes the loop); for a
    /// `.completed` task it starts a follow-up turn and revives the session
    /// before terminal cleanup dehydrates it.
    ///
    /// Returns false when the task is missing, its session is gone, the
    /// text is empty, or the task is not in a replyable state (running /
    /// queued work takes input via the chat window; failed / cancelled
    /// runs are view-only).
    @discardableResult
    public func submitQuickReply(_ backgroundId: UUID, text: String) -> Bool {
        guard let state = backgroundTasks[backgroundId] else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        switch state.status {
        case .waitingForInput, .completed:
            break
        case .queued, .running, .failed, .cancelled:
            return false
        }

        // A completed task is already on its terminal-cleanup timer; a
        // follow-up revives the run, so stop dehydration before dispatching.
        cancelAutoFinalize(backgroundId)
        let wasRetained = state.chatSession == nil
        guard let context = state.executionContext ?? hydrateRetainedTask(state),
            let session = state.chatSession
        else { return false }
        if taskObservers[backgroundId] == nil {
            observeChatTask(state, session: session)
        }
        if wasRetained {
            state.status = .running
            state.currentStep = "Preparing follow-up..."
            persistRetainedTabs()
            recomputeSortedToastTasks()
            Task { @MainActor in
                await context.prepare()
                session.send(trimmed)
            }
            return true
        }
        // Headless conversations follow the agent's current default model
        // on every turn (no-op for window chats); the retained branch above
        // gets the same treatment via `context.prepare()`.
        session.applyAgentDefaultModelForDispatch()
        // `send` clears any clarify pause and starts the next run; the
        // streaming observer transitions the task back to `.running`, so no
        // status write is needed here.
        session.send(trimmed)
        return true
    }

    /// Soft-stop a running task by cancelling its current stream.
    ///
    /// When `message` is non-empty, the trimmed content is appended to the
    /// session as a `user`-role turn before the stream is cancelled. The
    /// model picks the message up on the next user turn — i.e. when the
    /// user opens the chat window, when the plugin dispatches a follow-up,
    /// or when the session is otherwise resumed. This is the documented
    /// behavior of `dispatch_interrupt` on the v3 surface.
    ///
    /// Empty / whitespace-only messages just cancel the stream, matching
    /// the original soft-stop semantics. The chat task can always be
    /// resumed by the user opening its window and sending a follow-up.
    public func interruptTask(_ backgroundId: UUID, message: String?) {
        guard let state = backgroundTasks[backgroundId], state.status.isActive else { return }
        if let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            // Inject as a user-role turn so the next user-driven completion
            // round (which the user or another dispatch will trigger) sees
            // it as part of the conversation history.
            state.chatSession?.appendInterruptMessage(trimmed)
        }
        // Programmatic redirect, not the user's Stop button: the interrupt
        // turn itself is the transcript record, so no cancelled marker
        // (upstream).
        state.chatSession?.stop(preservesCancelledMarker: false)
    }

    /// Emit a draft event to the originating plugin.
    func emitDraftEvent(_ state: BackgroundTaskState, draftJSON: String) {
        emitPluginEvent(
            state,
            type: .draft,
            json: PluginHostContext.serializeDraftEvent(draftJSON: draftJSON, taskTitle: state.taskTitle)
        )
    }

    // MARK: - Dispatch

    /// Dispatch a chat task for background execution.
    /// External-surface flag bound around the dispatched run (upstream).
    /// Widen-only: a request marked external, or a dispatch issued from an
    /// already-external context, runs external.
    nonisolated static func resolvedExternalSurface(for request: DispatchRequest) -> Bool {
        request.externalSurface || ChatExecutionContext.isExternalSurface
    }

    public func dispatchChat(_ request: DispatchRequest) async -> DispatchHandle? {
        // Background dispatch is an external surface (schedules, watchers,
        // self-scheduled wakes, plugins): built-in agents (the Default agent)
        // are only reachable from the in-app Chat (upstream
        // `BuiltInAgentGuard`). Plugins dispatch as the calling chat's agent
        // (`PluginHostContext.dispatch`), so they get no exemption.
        if !request.allowsBuiltInAgent,
            Agent.rejectBuiltInForExternalSurface(request.agentId, source: "background/dispatchChat") != nil
        {
            return nil
        }
        guard isDispatchRequestValid(source: request.source, agentId: request.agentId) else { return nil }

        // The reattach lookup below opens the chat-history DB, which needs the
        // storage key. On a cold-start race the launch prewarm may not have
        // landed yet, and `db.open()` would run the keychain read synchronously
        // on the main actor and hang the UI. Warm it off the cooperative
        // executor first so the open hits the in-memory cache. Idempotent.
        try? await StorageKeyManager.shared.prewarmCurrentKeyOffCooperativeExecutor()

        // Opt-in conversation grouping: when `external_session_key` is set
        // and a non-active matching session exists, reattach to it so the
        // new prompt becomes the next turn instead of starting a fresh row.
        let reattach = lookupReattachableSession(for: request)
        let context: ExecutionContext
        if let existing = reattach {
            // Same folder resolution as a fresh context (upstream #2701).
            let folder = Self.resolveDispatchFolder(for: request)
            context = ExecutionContext(
                reattaching: existing,
                folderBookmark: folder?.bookmark,
                folderPath: folder?.path
            )
        } else {
            context = createContext(for: request)
        }
        // Admission (upstream): capacity available → start immediately;
        // saturated → register as `.queued` and defer the start until
        // `pumpQueue()` promotes it (FIFO). Either way the request is
        // registered before execution so `awaitCompletion` always finds the
        // task.
        let startsImmediately = hasExecutionCapacity(agentId: request.agentId)

        let state = BackgroundTaskState(
            id: context.id,
            taskTitle: context.title ?? "Chat",
            agentId: context.agentId,
            chatSession: context.chatSession,
            executionContext: context,
            status: startsImmediately ? .running : .queued,
            currentStep: startsImmediately ? "Running..." : "Queued",
            source: request.source,
            sourcePluginId: request.sourcePluginId,
            externalSessionKey: request.externalSessionKey,
            showToast: request.showToast
        )

        // Plugin-originated dispatches buffer their `.started` event until
        // the trampoline returns, so the plugin's `on_task_event` callback
        // doesn't fire before its `dispatch()` C call has unwound. Hold here
        // (now that we know the real task id, which may differ from
        // `request.id` after a reattach) and let the trampoline release.
        if request.sourcePluginId != nil {
            holdEventsForDispatch(taskId: context.id)
        }
        registerTask(state)
        observeChatTask(state, session: context.chatSession)

        // Pre-seed the per-run budget caps from `Agent.settings.limits`
        // (spec §11.3). `tokensIn/Out` and `costUSD` start at 0 and are
        // updated mid-stream by `recordUsage(...)`; the dispatcher
        // cancels the task once either threshold is crossed.
        if let agent = AgentManager.shared.agent(for: context.agentId) {
            state.runTokensLimit = agent.settings.limits.runTokensLimit
            state.runCostUSDLimit = agent.settings.limits.runCostUSDLimit
        }

        // The actual execution start (upstream). Runs immediately when a slot
        // is available, or later from `pumpQueue()` when queued. Everything
        // that marks a run as "started" (folder preparation, the
        // `agent_runs` row, the task-local bindings, `context.start`) lives
        // here so a queued request has no execution side effects until
        // promoted. A queued closure runs in pumpQueue's task, not the
        // invoker's.
        let startWork: @MainActor () async -> Void = { [weak state] in
            guard let state, state.status.isActive else { return }
            await context.prepare()
            guard state.status.isActive else { return }

            #if !OSAURUS_INTEL
            // `requestedToolNames` is populated only for plugin-sourced
            // dispatches (validated against the calling plugin's manifest).
            // Gated out on Intel: `SessionToolStateStore.appendLoadedTools`
            // lives in the excluded preflight subsystem.
            if !request.requestedToolNames.isEmpty {
                await SessionToolStateStore.shared.appendLoadedTools(
                    context.id.uuidString,
                    names: request.requestedToolNames,
                    fallbackAlwaysLoadedNames: nil
                )
            }
            #endif

            // Agent DB run logging (spec §1.4 + §8). Only DB-enabled agents
            // get an `agent_runs` row + a bound `currentRunId`; for the
            // default agent and any user-created agent that hasn't opted
            // in, this is a no-op so the existing dispatch surface keeps
            // the same behavior and the same overhead.
            var boundRunId: UUID? = nil
            var boundActor: String = "user"
            if AgentManager.shared.effectiveDBEnabled(for: context.agentId) {
                let triggerKind = Self.triggerKind(for: request.source)
                // `triggerPayload` is intentionally minimal: persisting the
                // full prompt here would duplicate ChatHistoryDatabase data
                // and inflate the scheduler DB. We surface the dispatch
                // source + external key so the Activity tab can tag the
                // row with what woke it.
                let triggerPayload = Self.triggerPayload(for: request)
                do {
                    try SchedulerDatabase.shared.open()
                    let runId = try SchedulerDatabase.shared.recordRunStart(
                        agentId: context.agentId,
                        triggerKind: triggerKind,
                        triggerPayload: triggerPayload,
                        instructions: request.prompt
                    )
                    boundRunId = runId
                    state.agentRunId = runId
                    boundActor = "agent"
                } catch {
                    print(
                        "[BackgroundTaskManager] recordRunStart failed for agent "
                            + "\(context.agentId): \(error)"
                    )
                }
            }

            // Bind the run-id + actor + background-task id for the entire
            // chat task. `chatSession.send` creates an unstructured
            // `Task { @MainActor in ... }` inside `ExecutionContext.start`
            // — unstructured Tasks inherit task locals captured at the
            // moment of creation, so any `db_*` tool call or streaming
            // producer dispatched from the inference loop picks these up
            // without needing per-call wiring. `currentBackgroundId` is
            // the same `BackgroundTaskState.id` we just registered, so
            // streaming layers can call `recordUsage(backgroundId:)` for
            // mid-stream budget enforcement (spec §11.3).
            // Upstream: `isExternalSurface` is rebound from the request so the
            // external tool policy holds for the whole run. Widen-only.
            let externalSurface = Self.resolvedExternalSurface(for: request)
            await ChatExecutionContext.$isExternalSurface.withValue(externalSurface) {
                await ChatExecutionContext.$currentRunId.withValue(boundRunId) {
                    await ChatExecutionContext.$currentRunActor.withValue(boundActor) {
                        await ChatExecutionContext.$currentBackgroundId.withValue(context.id) {
                            await context.start(prompt: request.prompt)
                        }
                    }
                }
            }
        }

        if startsImmediately {
            await startWork()
        } else {
            queuedOrder.append(context.id)
            pendingStarts[context.id] = startWork
            state.appendActivity(kind: .info, title: "Queued — waiting for a free slot")
            print("[BackgroundTaskManager] Queued chat task \(context.id) (capacity saturated)")
        }

        let reattachNote = reattach == nil ? "" : " (reattached to session \(context.id))"
        print("[BackgroundTaskManager] Dispatched chat task: \(request.title ?? "untitled")\(reattachNote)")
        // Return the resolved task id (may differ from request.id after a
        // reattach) so callers awaiting completion poll the actual live task.
        return DispatchHandle(id: context.id, request: request)
    }

    /// Returns an existing persisted session for this dispatch when the
    /// request opts into grouping via `external_session_key`. Skips reattach
    /// if a live in-memory task is already driving that session, to avoid
    /// double-stream into the same `ChatSession`.
    private func lookupReattachableSession(for request: DispatchRequest) -> ChatSessionData? {
        guard request.reattachSession,
            let key = request.externalSessionKey,
            !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let agentId = request.agentId

        let liveDuplicate = backgroundTasks.values.contains { state in
            guard state.status.isActive,
                state.externalSessionKey == key,
                state.source == request.source
            else { return false }
            // For plugin-sourced dispatches also require the same plugin id
            // so two plugins that happen to use the same key don't collide.
            if request.source == .plugin {
                return state.sourcePluginId == request.sourcePluginId
            }
            return true
        }
        if liveDuplicate { return nil }

        let db = ChatHistoryDatabase.shared
        // ChatHistoryDatabase.findSession opens lazily via shared singleton;
        // ensure it's initialised so the lookup doesn't no-op on cold start.
        do { try db.open() } catch {
            print("[BackgroundTaskManager] Failed to open chat history db for reattach: \(error)")
            return nil
        }

        // Plugin source has a guaranteed sourcePluginId; HTTP / scheduler /
        // watcher dispatches don't, so fall back to the source-based index.
        let metadata: ChatSessionData?
        if request.source == .plugin, let pluginId = request.sourcePluginId {
            metadata = db.findSession(pluginId: pluginId, externalKey: key, agentId: agentId)
        } else {
            metadata = db.findSession(source: request.source, externalKey: key, agentId: agentId)
        }
        guard let metadata else { return nil }
        // findSession returns metadata only; hydrate turns for ChatSession.load.
        return db.loadSession(id: metadata.id)
    }

    // MARK: - Completion Signaling

    /// Await completion of a background task. Suspends until the task completes, is cancelled, finalized, or times out.
    /// A 30-minute timeout prevents indefinite hangs if a task never reaches a terminal state.
    public func awaitCompletion(_ id: UUID, timeoutSeconds: UInt64 = 1800) async -> DispatchResult {
        if let state = backgroundTasks[id], !state.status.isActive {
            return resultFromState(state)
        }
        guard backgroundTasks[id] != nil else {
            return .failed("Background task not found")
        }

        // Start a watchdog that will resume the continuation with a timeout error
        // if the task doesn't complete within the deadline.
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            completionContinuations.removeValue(forKey: id)?.resume(returning: .failed("Background task timed out"))
        }

        let result = await withCheckedContinuation { continuation in
            completionContinuations[id] = continuation
        }

        timeoutTask.cancel()
        return result
    }

    // MARK: - Private: Dispatch Helpers

    private static let maxTasksPerAgent = 5

    /// Structural validity of a dispatch request. Capacity is NOT checked
    /// here — a valid request that arrives while the limits are saturated is
    /// accepted and queued rather than rejected.
    private func isDispatchRequestValid(source: SessionSource, agentId: UUID?) -> Bool {
        // Plugin / sandbox callers must supply an agentId. Without one, the
        // per-agent cap would be silently skipped — letting a single
        // sandboxed plugin saturate every slot. The bridge always provides
        // an id post-fix, so a nil here is a programmer error.
        if source == .plugin, agentId == nil {
            print("[BackgroundTaskManager] Refusing plugin dispatch without agentId")
            return false
        }
        return true
    }

    /// Whether an execution slot is free under both the user-configurable
    /// global limit and the per-agent limit. Only slot-consuming statuses
    /// count: queued tasks haven't started, and tasks waiting for input
    /// released their slot. (Upstream also skips subagent mirrors and
    /// inbound shared runs, which Intel doesn't have yet.)
    private func hasExecutionCapacity(agentId: UUID?) -> Bool {
        let globalLimit = ToastManager.shared.configuration.maxConcurrentTasks
        let slotted = backgroundTasks.values.filter { $0.status.consumesExecutionSlot }

        guard slotted.count < globalLimit else { return false }

        if let agentId {
            let agentCount = slotted.filter { $0.agentId == agentId }.count
            guard agentCount < Self.maxTasksPerAgent else { return false }
        }

        return true
    }

    /// Promote queued tasks into free execution slots, oldest first. A task
    /// whose agent is still at its per-agent cap is skipped so it doesn't
    /// head-of-line block work for other agents; it stays queued in place.
    private func pumpQueue() {
        while true {
            // Drop stale entries (cancelled/finalized while queued).
            queuedOrder.removeAll { backgroundTasks[$0]?.status != .queued }

            guard
                let nextId = queuedOrder.first(where: { id in
                    guard let state = backgroundTasks[id] else { return false }
                    return hasExecutionCapacity(agentId: state.agentId)
                }),
                let state = backgroundTasks[nextId],
                let startWork = pendingStarts.removeValue(forKey: nextId)
            else { return }

            queuedOrder.removeAll { $0 == nextId }
            // Claim the slot synchronously so a second pump in the same
            // runloop tick can't over-admit past the limit.
            state.status = .running
            state.currentStep = "Running..."
            state.appendActivity(kind: .info, title: "Started")
            recomputeSortedToastTasks()
            #if OSAURUS_INTEL
            IntelTaskBanner.shared.promoted(id: nextId)
            #endif
            print("[BackgroundTaskManager] Promoted queued task \(nextId)")
            Task { @MainActor in
                await startWork()
            }
        }
    }

    /// Register a new task state and log an initial activity entry.
    private func registerTask(_ state: BackgroundTaskState) {
        // A grouped dispatch reuses the task id, but not the previous run's
        // completion observation or terminal cleanup timer. An initial false
        // streaming publication must not complete the new run prematurely.
        cancelAutoFinalize(state.id)
        taskObservers.removeValue(forKey: state.id)?.forEach { $0.cancel() }
        streamingObserved.remove(state.id)
        backgroundTasks[state.id] = state
        persistRetainedTabs()
        recomputeSortedToastTasks()
        state.appendActivity(kind: .info, title: "Running in background")
        emitPluginEvent(state, type: .started, json: PluginHostContext.serializeStartedEvent(state: state))
        // Upstream #2630: a user-visible run surfaces as a tab of its agent
        // in the frontmost chat window (`ChatWindowManager` listens).
        if Self.isTabWorthy(state), state.chatSession != nil {
            taskRegistered.send(state)
        }

        #if OSAURUS_INTEL
        // M13 follow-up (Renée 2026-06-04): surface non-interactive background
        // runs (schedules, HTTP/watcher dispatches) since the upstream NotchView
        // indicator is amputated. A toast announces the start; the menu-bar
        // status-card row tracks it through completion. `.chat` is a detached
        // interactive window the user already sees, so skip those.
        if state.source != .chat {
            let queued = state.status == .queued
            IntelTaskBanner.shared.started(id: state.id, title: state.taskTitle, queued: queued)
            let agentName = AgentManager.shared.agents.first { $0.id == state.agentId }?.name
            let who = (agentName?.isEmpty == false) ? agentName! : "An agent"
            _ = ToastManager.shared.info(
                queued ? "\(who) queued a task" : "\(who) started a task",
                message: queued
                    ? "\(state.taskTitle) starts when a run slot frees up — track it in the menu-bar card"
                    : "\(state.taskTitle) — track it in the menu-bar card",
                timeout: 8
            )
        }
        #endif
    }

    #if DEBUG
        /// Test-only: insert a pre-built `BackgroundTaskState` directly so
        /// regression tests can exercise `observeChatTask` without spinning up
        /// a real `ExecutionContext` + MLX-backed engine.
        func registerTaskForTesting(_ state: BackgroundTaskState) {
            backgroundTasks[state.id] = state
            recomputeSortedToastTasks()
        }

        /// Test-only: register through the production `registerTask` path
        /// (initial activity entry + `taskRegistered` signal), for tests
        /// that pin what chat windows get told about.
        func registerTaskThroughProductionPathForTesting(_ state: BackgroundTaskState) {
            registerTask(state)
        }

        func hasPendingAutoFinalizeForTesting(_ id: UUID) -> Bool {
            autoFinalizeTasks[id] != nil
        }

        /// Test-only (upstream): register a task through the same admission
        /// gate `dispatchChat` uses — it starts immediately when capacity is
        /// available, or lands in the FIFO queue with its start deferred
        /// until `pumpQueue()` promotes it.
        func admitTaskForTesting(
            _ state: BackgroundTaskState,
            start: @escaping @MainActor () async -> Void
        ) {
            if hasExecutionCapacity(agentId: state.agentId) {
                state.status = .running
                backgroundTasks[state.id] = state
                recomputeSortedToastTasks()
                Task { @MainActor in await start() }
            } else {
                state.status = .queued
                state.currentStep = "Queued"
                backgroundTasks[state.id] = state
                queuedOrder.append(state.id)
                pendingStarts[state.id] = start
                recomputeSortedToastTasks()
            }
        }

        /// Test-only (upstream): run a queue promotion pass.
        func pumpQueueForTesting() {
            pumpQueue()
        }

        /// Test-only (upstream): whether a dispatch for `agentId` would be
        /// admitted right now (global + per-agent slot limits).
        func hasExecutionCapacityForTesting(agentId: UUID?) -> Bool {
            hasExecutionCapacity(agentId: agentId)
        }

        /// Test-only (upstream): an isolated manager with no power manager and
        /// no retained-tab persistence.
        static func makeForTesting() -> BackgroundTaskManager {
            BackgroundTaskManager(persistsRetainedTabs: false, powerManager: nil)
        }

        /// Test-only (upstream): an isolated manager with an injected power
        /// manager and no retained-tab persistence.
        static func makeForTesting(powerManager: AgentRunPowerManager) -> BackgroundTaskManager {
            BackgroundTaskManager(persistsRetainedTabs: false, powerManager: powerManager)
        }

        /// Test-only (upstream): an isolated manager that persists retained
        /// tabs to `defaults` instead of the user's.
        static func makeForTestingRetaining(defaults: UserDefaults) -> BackgroundTaskManager {
            BackgroundTaskManager(persistsRetainedTabs: true, retainedTabsDefaults: defaults)
        }

        /// Test-only (upstream): run the 15 s dehydrate step now.
        func dehydrateTaskForTesting(_ id: UUID) {
            dehydrateTerminalTask(id)
        }

        func isTaskDehydratedForTesting(_ id: UUID) -> Bool {
            guard let state = backgroundTasks[id] else { return false }
            return state.chatSession == nil && !state.status.isActive
        }
    #endif

    /// Rebuild the live execution context of a retained (dehydrated)
    /// terminal task so a window can show its transcript again. Returns the
    /// existing context for live tasks; nil when the chat history row is gone.
    public func executionContextForReveal(_ taskId: UUID) -> ExecutionContext? {
        guard let state = backgroundTasks[taskId] else { return nil }
        return state.executionContext ?? hydrateRetainedTask(state)
    }

    private func createContext(for request: DispatchRequest) -> ExecutionContext {
        let folder = Self.resolveDispatchFolder(for: request)
        return ExecutionContext(
            id: request.id,
            agentId: request.agentId ?? Agent.defaultId,
            title: request.title,
            folderBookmark: folder?.bookmark,
            folderPath: folder?.path,
            source: request.source,
            sourcePluginId: request.sourcePluginId,
            externalSessionKey: request.externalSessionKey
        )
    }

    /// The folder a dispatch runs in (upstream #2701): the request's own
    /// folder when it names one (a Watcher's watched folder, a Schedule's
    /// folder, a plugin's `folder_bookmark`), else the target agent's
    /// Default Working Folder, so schedules and watchers created without a
    /// folder, delegation and `/agents/{id}/dispatch` work where the agent's
    /// chats do. Nil when neither is set.
    static func resolveDispatchFolder(
        for request: DispatchRequest
    ) -> (bookmark: Data?, path: String?)? {
        if request.folderBookmark != nil || request.folderPath?.isEmpty == false {
            return (request.folderBookmark, request.folderPath)
        }
        guard let agentId = request.agentId, agentId != Agent.defaultId,
            let agent = AgentManager.shared.agent(for: agentId)
        else { return nil }
        let path = agent.workingFolderPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard agent.workingFolderBookmark != nil || path?.isEmpty == false else { return nil }
        return (agent.workingFolderBookmark, path?.isEmpty == false ? path : nil)
    }

    // MARK: - Private: Completion Helpers

    private func resultFromState(_ state: BackgroundTaskState) -> DispatchResult {
        switch state.status {
        case .completed:
            return .completed(sessionId: state.executionContext?.chatSession.sessionId)
        case .failed(let summary):
            return .failed(summary)
        case .cancelled:
            return .cancelled
        default:
            return .failed("Task ended unexpectedly")
        }
    }

    private func resumeCompletion(for id: UUID, result: DispatchResult) {
        completionContinuations.removeValue(forKey: id)?.resume(returning: result)
    }

    /// Map a dispatch source to the audit-trail trigger kind we persist
    /// in `agent_runs`. Spec §16 leaves room for finer breakdowns; this
    /// is the minimal mapping that's stable for Phase 1.
    private static func triggerKind(for source: SessionSource) -> AgentRunTriggerKind {
        switch source {
        case .chat, .plugin, .http, .imported: return .user
        case .schedule: return .recurringSchedule
        case .watcher: return .watcher
        case .selfSchedule: return .schedule
        }
    }

    /// Compact JSON describing what dispatched this run. Skips the
    /// prompt itself (already in ChatHistoryDatabase) and the plugin
    /// secrets — just the source + grouping key the Activity tab
    /// surfaces.
    private static func triggerPayload(for request: DispatchRequest) -> String? {
        var fields: [String: String] = ["source": request.source.rawValue]
        if let pluginId = request.sourcePluginId, !pluginId.isEmpty {
            fields["plugin_id"] = pluginId
        }
        if let key = request.externalSessionKey, !key.isEmpty {
            fields["external_session_key"] = key
        }
        guard let data = try? JSONEncoder().encode(fields),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    /// Mark a task as completed and signal callers.
    /// The toast persists until the user views it or dismisses manually.
    private func markCompleted(_ state: BackgroundTaskState, success: Bool, summary: String) {
        state.status = success ? .completed(summary: summary) : .failed(summary: summary)
        state.currentStep = nil
        state.captureContextPreview()
        state.executionContext?.chatSession.save()

        #if OSAURUS_INTEL
        // Flip the menu-bar card row to its terminal state (guards on a matching
        // id, so it's a no-op for tasks that never raised a banner).
        IntelTaskBanner.shared.finished(id: state.id, success: success)
        #endif
        // Close out the scheduler `agent_runs` row, if one was opened
        // for this task. `recordRunEnd` is a single UPDATE so the cost
        // is negligible; failure to write only forfeits the audit
        // trail entry, never the task's completion signal.
        if let runId = state.agentRunId {
            let endStatus: AgentRunStatus = success ? .success : .error
            let errorMessage: String? = success ? nil : summary
            // Persist the per-run JSON trace BEFORE we null out
            // `agentRunId` so subsequent retries/observers can't
            // accidentally write it twice (spec §1.8).
            Self.writeRunTrace(
                runId: runId,
                state: state,
                status: endStatus,
                endedAt: Date(),
                errorMessage: errorMessage
            )
            do {
                try SchedulerDatabase.shared.recordRunEnd(
                    runId: runId,
                    status: endStatus,
                    tokensIn: state.tokensIn > 0 ? state.tokensIn : nil,
                    tokensOut: state.tokensOut > 0 ? state.tokensOut : nil,
                    costUSD: state.costUSD > 0 ? state.costUSD : nil,
                    error: errorMessage
                )
            } catch {
                print("[BackgroundTaskManager] recordRunEnd failed for run \(runId): \(error)")
            }
            state.agentRunId = nil
        }
        resumeCompletion(for: state.id, result: resultFromState(state))

        let eventType: TaskEventType = success ? .completed : .failed
        let outputText = state.chatSession?.turns.last?.content
        let json = PluginHostContext.serializeCompletedEvent(
            success: success,
            summary: summary,
            sessionId: state.executionContext?.id,
            taskTitle: state.taskTitle,
            outputText: outputText
        )
        emitPluginEvent(state, type: eventType, json: json)
        recomputeSortedToastTasks()
        // Upstream: release the live session after 15 s (visible runs stay
        // as retained tabs; headless ones finalize). Intel never scheduled
        // this for completions, so finished runs held their session until a
        // tab closed.
        scheduleAutoFinalize(state.id)
        persistRetainedTabs()
        recomputeSortedToastTasks()
        pumpQueue()
    }

    // MARK: - Private: Run-Trace Persistence

    /// Capture the terminal state of a chat task as a `RunTrace` and
    /// write it to disk under `~/.osaurus/agents/<id>/runs/<run_id>.json`
    /// (spec §1.8). Static + MainActor so the call site doesn't need
    /// to hop actors; the actual file write is synchronous but
    /// best-effort — failures are logged and swallowed.
    private static func writeRunTrace(
        runId: UUID,
        state: BackgroundTaskState,
        status: AgentRunStatus,
        endedAt: Date,
        errorMessage: String?
    ) {
        let turns: [RunTrace.Turn] = (state.chatSession?.turns ?? []).map { turn in
            let callSnapshots: [RunTrace.ToolCallSnapshot]? = turn.toolCalls.flatMap {
                $0.isEmpty
                    ? nil
                    : $0.map {
                        RunTrace.ToolCallSnapshot(
                            id: $0.id,
                            name: $0.function.name,
                            arguments: $0.function.arguments
                        )
                    }
            }
            return RunTrace.Turn(
                id: turn.id,
                role: turn.role.rawValue,
                content: turn.content,
                thinking: turn.thinkingIsEmpty ? nil : turn.thinking,
                toolCalls: callSnapshots,
                toolCallId: turn.toolCallId,
                toolResults: turn.toolResults.isEmpty ? nil : turn.toolResults
            )
        }
        let trace = RunTrace(
            runId: runId,
            agentId: state.agentId,
            sessionId: state.id.uuidString,
            triggerSource: state.source.rawValue,
            status: status.rawValue,
            startedAt: state.createdAt,
            endedAt: endedAt,
            tokensIn: state.tokensIn > 0 ? state.tokensIn : nil,
            tokensOut: state.tokensOut > 0 ? state.tokensOut : nil,
            costUSD: state.costUSD > 0 ? state.costUSD : nil,
            errorMessage: errorMessage,
            turns: turns
        )
        RunTraceWriter.write(trace)
    }

    // MARK: - Private: Plugin Event Emission

    /// Emit a unified task lifecycle event to the originating plugin.
    /// If the task's dispatch() call hasn't returned yet, the event is
    /// buffered and will be flushed by `releaseEventsForDispatch`.
    private func emitPluginEvent(_ state: BackgroundTaskState, type: TaskEventType, json: String) {
        guard let pluginId = state.sourcePluginId else { return }

        if dispatchHoldTasks.contains(state.id) {
            heldTaskEvents[state.id, default: []].append((type: type, json: json))
            return
        }

        if let loaded = PluginManager.shared.loadedPlugin(for: pluginId),
            loaded.plugin.hasTaskEventHandler
        {
            loaded.plugin.notifyTaskEvent(
                taskId: state.id.uuidString,
                eventType: type,
                eventJSON: json,
                agentId: state.agentId
            )
        }
    }

    // MARK: - Dispatch Event Gating

    /// Begin holding task events for a dispatch in flight. Call on the main
    /// actor *before* `TaskDispatcher.dispatch` so the hold is in place before
    /// `registerTask` emits the `.started` event.
    func holdEventsForDispatch(taskId: UUID) {
        dispatchHoldTasks.insert(taskId)
    }

    /// Release held events after the dispatch() C call has returned to the
    /// plugin. Flushes all buffered events in order via `emitPluginEvent`.
    func releaseEventsForDispatch(taskId: UUID) {
        dispatchHoldTasks.remove(taskId)
        if let events = heldTaskEvents.removeValue(forKey: taskId),
            let state = backgroundTasks[taskId]
        {
            for event in events {
                emitPluginEvent(state, type: event.type, json: event.json)
            }
        }
    }

    // MARK: - Private: Auto-Finalize

    /// After 15 seconds, release live resources for a terminal task. Visible
    /// runs remain as durable lightweight records (retained tabs) until the
    /// user closes their tab; headless tasks still finalize completely.
    /// Upstream. The record is persisted right away, so quitting inside the
    /// 15 s still keeps the tab.
    private func scheduleAutoFinalize(_ taskId: UUID) {
        cancelAutoFinalize(taskId)
        persistRetainedTabs()
        autoFinalizeTasks[taskId] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            guard let state = backgroundTasks[taskId], !state.status.isActive else { return }
            guard !dispatchHoldTasks.contains(taskId) else { return }
            if state.showToast {
                dehydrateTerminalTask(taskId)
            } else {
                finalizeTask(taskId)
            }
        }
    }

    // MARK: - Private: Retained Run Tabs (upstream)

    private func restoreRetainedTabs() {
        guard persistsRetainedTabs,
            let data = retainedTabsDefaults.data(forKey: Self.retainedTabsDefaultsKey),
            let records = try? JSONDecoder().decode([RetainedActivityTabRecord].self, from: data)
        else { return }
        for record in records {
            backgroundTasks[record.id] = BackgroundTaskState(
                retainedId: record.id,
                taskTitle: record.title,
                agentId: record.agentId,
                status: record.status,
                createdAt: record.createdAt,
                source: record.source,
                sourcePluginId: record.sourcePluginId,
                externalSessionKey: record.externalSessionKey,
                contextPreview: record.contextPreview ?? []
            )
        }
        recomputeSortedToastTasks()
    }

    private func persistRetainedTabs() {
        guard persistsRetainedTabs else { return }
        let records = backgroundTasks.values
            .filter { $0.showToast && $0.status.isTerminal }
            .compactMap(RetainedActivityTabRecord.init(state:))
            .sorted { $0.createdAt < $1.createdAt }
        guard !records.isEmpty else {
            retainedTabsDefaults.removeObject(forKey: Self.retainedTabsDefaultsKey)
            return
        }
        if let data = try? JSONEncoder().encode(records) {
            retainedTabsDefaults.set(data, forKey: Self.retainedTabsDefaultsKey)
        }
    }

    /// Release the live session and Combine observers while leaving a
    /// lightweight, persisted terminal tab (upstream). A window already
    /// showing the run keeps its own reference, so the visible tab is
    /// untouched; the registry simply stops holding the session.
    private func dehydrateTerminalTask(_ taskId: UUID) {
        guard let state = backgroundTasks[taskId], state.status.isTerminal else { return }
        state.captureContextPreview()
        cancelAutoFinalize(taskId)
        taskObservers[taskId]?.forEach { $0.cancel() }
        taskObservers.removeValue(forKey: taskId)
        chatTurnCounts.removeValue(forKey: taskId)
        streamingObserved.remove(taskId)
        taskIdByWindow = taskIdByWindow.filter { $0.value != taskId }
        state.releaseReferences()
        persistRetainedTabs()
        recomputeSortedToastTasks()
        objectWillChange.send()
    }

    /// Rebuild a live execution context from the canonical chat-history row.
    /// Called only after an explicit reply/open action on a dehydrated tab
    /// (upstream).
    private func hydrateRetainedTask(_ state: BackgroundTaskState) -> ExecutionContext? {
        if let context = state.executionContext { return context }
        // A window tab may still hold the live instance of this conversation
        // after terminal cleanup dropped the registry's reference. Reuse that
        // exact object: hydrating a second copy from disk would route
        // follow-up turns into an instance the visible tab never observes,
        // and let tab-close save the stale transcript over them.
        if let shown = ChatWindowManager.shared.session(forSessionId: state.id) {
            let context = ExecutionContext(adopting: shown)
            state.restoreReferences(context: context)
            return context
        }
        // Intel: chat history is `ChatSessionsManager` (per-session JSON,
        // full transcripts in memory); there is no `ChatSessionStore`, and
        // Intel's `ChatHistoryDatabase` is a stub.
        guard var sessionData = ChatSessionsManager.shared.session(for: state.id) else { return nil }
        // The retained record is the user's latest explicit rename.
        if sessionData.title != state.taskTitle {
            sessionData.title = state.taskTitle
            ChatSessionsManager.shared.rename(id: state.id, title: state.taskTitle)
        }
        let context = ExecutionContext(reattaching: sessionData)
        state.restoreReferences(context: context)
        state.taskTitle = sessionData.title
        return context
    }

    private func cancelAutoFinalize(_ taskId: UUID) {
        autoFinalizeTasks[taskId]?.cancel()
        autoFinalizeTasks.removeValue(forKey: taskId)
    }

    // MARK: - Private: Chat Observation

    /// Internal (rather than private) so regression tests can drive the
    /// streaming observer directly. Production callers go through `dispatchChat`.
    func observeChatTask(_ state: BackgroundTaskState, session: ChatSession) {
        var cancellables = Set<AnyCancellable>()
        let taskId = state.id

        // Snapshot current turn count so we don't replay history
        chatTurnCounts[taskId] = session.turns.count

        // Forward state changes with throttling
        state.objectWillChange
            .sink { [weak self] _ in self?.viewUpdateSubject.send() }
            .store(in: &cancellables)

        // Streaming state + error drive running/completed/failed transitions.
        Publishers.CombineLatest(
            session.$isStreaming,
            session.$lastStreamError
        )
        .sink { [weak self] isStreaming, lastError in
            self?.handleChatStreamingChange(taskId: taskId, isStreaming: isStreaming, lastError: lastError)
        }
        .store(in: &cancellables)

        // Observe turn count changes for tool call activity.
        // Map to count + removeDuplicates avoids processing when only content within
        // existing turns changes (e.g. streaming text into an assistant turn).
        session.$turns
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] newCount in
                self?.handleChatTurnCountChange(taskId: taskId, newCount: newCount, session: session)
            }
            .store(in: &cancellables)

        // Observe clarify pause state. Both the chat-layer intercept
        // (which sets `awaitingClarify`) and the resume path in
        // `ChatSession.send(...)` (which clears it) run on the main
        // actor before `isStreaming` flips, so the clarify update
        // always reaches `handleChatClarifyChange` ahead of the
        // streaming-end tick — that ordering gates the COMPLETED
        // suppression in `handleChatStreamingChange`.
        session.$awaitingClarify
            .removeDuplicates()
            .sink { [weak self] payload in
                self?.handleChatClarifyChange(taskId: taskId, payload: payload)
            }
            .store(in: &cancellables)

        taskObservers[taskId] = cancellables
    }

    private func handleChatStreamingChange(taskId: UUID, isStreaming: Bool, lastError: String?) {
        guard let state = backgroundTasks[taskId] else { return }

        if isStreaming {
            streamingObserved.insert(taskId)
            state.status = .running
            state.currentStep = "Running..."
            #if OSAURUS_INTEL
            IntelTaskBanner.shared.resumed(id: taskId)
            #endif
        } else if state.status == .running, streamingObserved.contains(taskId) {
            defer { pumpQueue() }
            if state.chatSession?.stopRequested == true {
                finishChatCancellation(state, stopSession: false)
                return
            }
            // Belt-and-suspenders: if the streaming-end tick somehow
            // races ahead of the clarify sink, inspect the live session
            // before tripping the terminal branch. The `.running` guard
            // above already excludes the normal post-bridge case.
            if state.chatSession?.awaitingClarify != nil { return }
            if let lastError {
                markCompleted(state, success: false, summary: lastError)
            } else {
                markCompleted(state, success: true, summary: "Chat completed")
            }
        }
    }

    /// Bridge `ChatSession.awaitingClarify` into the per-task plugin event
    /// surface. Setting a payload transitions the task to
    /// `.waitingForInput` and emits `OSR_TASK_EVENT_CLARIFICATION`.
    /// Clearing it is a no-op here — the next streaming tick is the
    /// single writer for the `.running` transition.
    private func handleChatClarifyChange(taskId: UUID, payload: ClarifyPayload?) {
        guard let state = backgroundTasks[taskId], let payload else { return }
        state.status = .waitingForInput
        state.currentStep = "Waiting for clarification"
        #if OSAURUS_INTEL
        IntelTaskBanner.shared.waiting(id: taskId)
        #endif
        emitPluginEvent(
            state,
            type: .clarification,
            json: PluginHostContext.serializeClarificationEvent(payload: payload)
        )
        // Waiting requests stay alive but release their execution slot so
        // queued work isn't starved by a task idling on the user.
        pumpQueue()
    }

    /// Scan newly added turns for tool calls and record them as activity.
    ///
    /// Tool calls are appended to an existing assistant turn *before* the tool-result
    /// and next-assistant turns are added. By the time the turn count changes, the
    /// assistant turn we previously scanned (empty at the time) now has `toolCalls`.
    /// To catch them, we also re-check the turn immediately before the new range.
    private func handleChatTurnCountChange(taskId: UUID, newCount: Int, session: ChatSession) {
        guard let state = backgroundTasks[taskId] else { return }

        let previousCount = chatTurnCounts[taskId] ?? 0
        guard newCount > previousCount else { return }

        // `$turns` emits on willSet, so `session.turns` still holds the OLD
        // array here while `newCount` describes the incoming one. A session
        // load that replaces a long history with a shorter array can leave
        // `previousCount` past the readable bounds — clamp both ends or the
        // range constructor traps.
        let turns = session.turns
        let scanEnd = min(newCount, turns.count)
        let scanStart = min(max(0, previousCount - 1), scanEnd)
        for turn in turns[scanStart ..< scanEnd] {
            if let toolCalls = turn.toolCalls {
                for call in toolCalls {
                    state.appendActivity(kind: .tool, title: "Tool", detail: call.function.name)
                    emitPluginEvent(
                        state,
                        type: .activity,
                        json: PluginHostContext.serializeActivityEvent(
                            kind: .tool,
                            title: "Tool",
                            detail: call.function.name
                        )
                    )
                }
            }
        }

        chatTurnCounts[taskId] = newCount
    }
}
