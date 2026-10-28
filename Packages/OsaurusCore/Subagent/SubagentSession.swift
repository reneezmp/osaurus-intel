//
//  SubagentSession.swift
//  OsaurusCore — Subagent framework
//
//  The shared host every nested subagent funnels through. Generalized from
//  computer_use's scaffolding so spawn / image / computer_use
//  share ONE lifecycle:
//
//    recursion guard → scope ids → resolve model (reject-before-evict)
//      → permission → register feed + interrupt → process-wide admission
//      (local runs serialize, remote fan out) → [optional handoff]
//      → run kind → normalize to a compact ToolEnvelope → defer cleanup
//      → telemetry
//
//  The host is driven entirely through `any SubagentKind`, which is also the
//  deterministic test seam: a scripted kind exercises the full control flow
//  model-free (no tokens) in CI.
//

import Foundation
import os

private let subagentLog = Logger(subsystem: "ai.osaurus", category: "Subagent")

/// Lightweight run-outcome telemetry for the subagent family. Kept as a log
/// hook so the host stays dependency-free; richer `FeatureTelemetry` rows are
/// emitted by individual kinds where they already exist (computer_use).
enum SubagentTelemetry {
    /// Some delegated surfaces report completion counts but no prompt count.
    /// Keep absent measurements distinct from a measured zero in diagnostics.
    static func usageDescription(_ usage: [String: Any]?) -> String {
        guard let usage else { return "" }
        let prompt = (usage["prompt_tokens"] as? Int).map(String.init) ?? "unknown"
        let completion = (usage["completion_tokens"] as? Int).map(String.init) ?? "unknown"
        var description = " promptTokens=\(prompt) completionTokens=\(completion)"
        if let tps = usage["tokens_per_second"] as? Double {
            description += String(format: " tokPerSec=%.1f", tps)
        }
        return description
    }

    static func record(
        kindId: String,
        success: Bool,
        elapsed: TimeInterval,
        usage: [String: Any]? = nil,
        phases: [(phase: String, seconds: Double)] = []
    ) {
        var extra = usageDescription(usage)
        if !phases.isEmpty {
            let joined = phases.map { String(format: "%@=%.2fs", $0.phase, $0.seconds) }
                .joined(separator: " ")
            extra += " phases[\(joined)]"
        }
        subagentLog.info(
            "subagent run kind=\(kindId, privacy: .public) success=\(success, privacy: .public) elapsed=\(elapsed, format: .fixed(precision: 2), privacy: .public)s\(extra, privacy: .public)"
        )
    }
}

/// A subagent run after target resolution and permission, but before admission,
/// handoff, or model execution. Batched spawn uses this split to validate every
/// target before the first local model can unload/load, then groups prepared
/// jobs by canonical model identity.
struct PreparedSubagentRun: Sendable {
    let kind: any SubagentKind
    let tool: String
    let scope: SubagentScope
    let resolved: ResolvedModel
    let handoff: any SubagentHandoff
    /// True when `handoff` came from `kind.makeHandoff()`. Direct text spawns
    /// refresh that kind-owned value after a queued admission; explicit test
    /// and caller overrides remain authoritative.
    let handoffIsKindOwned: Bool

    init(
        kind: any SubagentKind,
        tool: String,
        scope: SubagentScope,
        resolved: ResolvedModel,
        handoff: any SubagentHandoff,
        handoffIsKindOwned: Bool = false
    ) {
        self.kind = kind
        self.tool = tool
        self.scope = scope
        self.resolved = resolved
        self.handoff = handoff
        self.handoffIsKindOwned = handoffIsKindOwned
    }

    var admissionClass: SubagentAdmissionClass {
        kind.admissionClass(resolved)
    }

    var admissionModelKey: String? {
        SubagentSession.canonicalAdmissionModelKey(resolved)
    }

    /// Upstream reads the spawn kind's prepared plan for batch capacity;
    /// Intel has no spawn kind yet (`W-subagents`) and no local runs.
    var textResidencyPlan: ResidencyPlan? { nil }
}

enum SubagentPreparationResult: Sendable {
    case ready(PreparedSubagentRun)
    /// Already-normalized ToolEnvelope JSON.
    case failure(String)
}

/// Presentation/interrupt plumbing for one prepared run. Normal single-worker
/// calls let the host create and register these values. A `spawn_agent` wave
/// (several calls in one message) supplies an unregistered child feed and the
/// wave's shared interrupt token so one visible parent row owns Stop while
/// sibling runs remain isolated.
struct SubagentRunPresentation: Sendable {
    let feed: SubagentFeed
    let interrupt: InterruptToken
    let registerWithUI: Bool
    let finishFeed: Bool

    init(
        feed: SubagentFeed,
        interrupt: InterruptToken,
        registerWithUI: Bool,
        finishFeed: Bool = true
    ) {
        self.feed = feed
        self.interrupt = interrupt
        self.registerWithUI = registerWithUI
        self.finishFeed = finishFeed
    }
}

public enum SubagentSession {
    /// Active-kind recursion guard. Set while ANY subagent kind runs so a
    /// nested subagent call refuses (generalizes the per-tool delegation
    /// guards into one guard for the whole family). Carries the running kind's
    /// id for the message.
    @TaskLocal public static var activeKindId: String?

    /// True when a subagent kind is currently running on this task tree.
    public static var isActive: Bool { activeKindId != nil }

    /// Run any subagent kind end to end and return a canonical envelope.
    /// `handoff` overrides the kind's own `makeHandoff()` (used by tests).
    public static func run(
        _ kind: any SubagentKind,
        tool: String,
        handoff: SubagentHandoff? = nil
    ) async -> String {
        switch await prepare(kind, tool: tool, handoff: handoff) {
        case .failure(let envelope):
            return envelope
        case .ready(let prepared):
            return await runPrepared(prepared)
        }
    }

    /// Spawn compatibility tools need their feed + Stop token visible while
    /// target resolution and an `.ask` permission panel are still in flight.
    /// The ordinary host historically registered those only after preparation,
    /// which meant a direct spawn panel had no run-owned Stop path.
    ///
    /// This is deliberately opt-in (spawn_agent only) so kinds
    /// whose existing presentation contract starts after preparation do not
    /// change behavior.
    static func runWithVisiblePreparation(
        _ kind: any SubagentKind,
        tool: String
    ) async -> String {
        let scope = SubagentScope.current()
        let feed = SubagentFeed(
            toolCallId: scope.toolCallId,
            kindId: kind.capability.id,
            title: kind.feedTitle,
            agentId: scope.agentId,
            parentSessionId: scope.sessionId,
            suppressActivityMirror: kind.suppressActivityMirror
        )
        let interrupt = InterruptToken()
        SubagentFeedRegistry.shared.register(feed)
        SubagentInterruptCenter.shared.register(interrupt, for: scope.toolCallId)
        defer {
            SubagentInterruptCenter.shared.unregister(scope.toolCallId)
            SubagentFeedRegistry.shared.unregister(toolCallId: scope.toolCallId)
        }

        feed.emitPhase("validating target")
        switch await prepare(
            kind,
            tool: tool,
            scope: scope,
            interrupt: interrupt
        ) {
        case .failure(let envelope):
            feed.finish(
                success: false,
                summary: ToolEnvelope.failureMessage(envelope)
            )
            return envelope
        case .ready(let prepared):
            return await runPrepared(
                prepared,
                presentation: SubagentRunPresentation(
                    feed: feed,
                    interrupt: interrupt,
                    registerWithUI: false
                )
            )
        }
    }

    // Intel (docs/SUBAGENTS_INTEL.md): background spawn dispatch and its
    // report-back (`SubagentReportBack`) come with the spawn kind.
    #if !OSAURUS_INTEL
    /// `background: true` spawn dispatch. Validation, model resolution, and
    /// the permission verdict all run INLINE — a bad target or a denial
    /// fails this tool call immediately, exactly like the synchronous path.
    /// Only the execution detaches: the prepared run continues in an
    /// unstructured task that outlives the parent turn, and this call
    /// returns an acknowledgment envelope at once.
    ///
    /// The pre-registered feed drives the Activity row (via
    /// `SubagentBackgroundTaskBridge`) and the interrupt token backs its
    /// Stop control. The terminal digest never travels this tool call's
    /// result channel — `SubagentReportBack` delivers it to the launching
    /// session as a follow-up turn once that session is idle.
    ///
    /// A LOCAL-model helper defers its start until the parent's current
    /// stream ends: its residency handoff may evict the parent's resident
    /// model, which must never happen mid-reply. `localStartGate` overrides
    /// that wait in tests.
    static func dispatchInBackground(
        _ kind: any SubagentKind,
        tool: String,
        localStartGate: (@Sendable () async -> Void)? = nil
    ) async -> String {
        let scope = SubagentScope.current()
        let parentSession = ChatExecutionContext.currentChatSessionBox
        let feed = SubagentFeed(
            toolCallId: scope.toolCallId,
            kindId: kind.capability.id,
            title: kind.feedTitle,
            agentId: scope.agentId,
            parentSessionId: scope.sessionId,
            suppressActivityMirror: kind.suppressActivityMirror
        )
        let interrupt = InterruptToken()
        SubagentFeedRegistry.shared.register(feed)
        SubagentInterruptCenter.shared.register(interrupt, for: scope.toolCallId)

        feed.emitPhase("validating target")
        let prepared: PreparedSubagentRun
        switch await prepare(kind, tool: tool, scope: scope, interrupt: interrupt) {
        case .failure(let envelope):
            feed.finish(success: false, summary: ToolEnvelope.failureMessage(envelope))
            SubagentInterruptCenter.shared.unregister(scope.toolCallId)
            SubagentFeedRegistry.shared.unregister(toolCallId: scope.toolCallId)
            return envelope
        case .ready(let ready):
            prepared = ready
        }

        let title = kind.feedTitle
        let needsLocalGate = prepared.resolved.isLocal
        feed.emitPhase("dispatched", detail: "running in background")

        // Unstructured on purpose: the helper must survive the parent
        // turn's task tree (this tool call returns the ack and its task
        // ends). `runPrepared` rebinds every scope task-local from
        // `prepared.scope`, and `activeKindId` is task-tree scoped, so the
        // parent turn can keep dispatching while this runs.
        Task {
            if needsLocalGate {
                if let localStartGate {
                    await localStartGate()
                } else {
                    await SubagentReportBack.waitUntilParentStreamEnds(
                        parentSession,
                        orInterrupted: interrupt
                    )
                }
            }
            let completedEnvelope = await runPrepared(
                prepared,
                presentation: SubagentRunPresentation(
                    feed: feed,
                    interrupt: interrupt,
                    registerWithUI: false
                )
            )
            SubagentInterruptCenter.shared.unregister(scope.toolCallId)
            SubagentFeedRegistry.shared.unregister(toolCallId: scope.toolCallId)
            // The feed's terminal status IS the canonical digest —
            // `runPrepared` finishes it with the compact summary on both
            // the success and failure paths.
            let success: Bool
            let summary: String
            if case .finished(let ok, let digest) = feed.currentStatus() {
                success = ok
                summary = digest
            } else {
                success = false
                summary = "Helper run ended without a result."
            }
            await SubagentReportBack.deliver(
                title: title,
                success: success,
                summary: summary,
                completedEnvelope: completedEnvelope,
                to: parentSession
            )
        }

        return backgroundAck(tool: tool, helper: title, sessionId: kind.plannedSessionId)
    }
    #endif

    /// The acknowledgment a `background: true` spawn returns. Carries the
    /// worker's `session_id` when the kind knows it ahead of the run (a
    /// delegated agent or workspace worker), so the parent can `continue`
    /// with it or name it before the report-back arrives.
    public static func backgroundAck(tool: String, helper: String, sessionId: UUID?) -> String {
        var result: [String: Any] = [
            "dispatched": true,
            "background": true,
            "helper": helper,
            "note":
                "The helper is running in the background. Its result will arrive as a "
                + "follow-up message in this conversation — do not wait, poll, or "
                + "re-dispatch the same task. Tell the user the helper will report back.",
        ]
        if let sessionId {
            result["session_id"] = sessionId.uuidString
        }
        return ToolEnvelope.success(tool: tool, result: result)
    }

    /// Whether `envelope` is a background acknowledgment (as opposed to a
    /// settled `spawn_result` or a failure).
    public static func isBackgroundAck(_ envelope: String) -> Bool {
        guard ToolEnvelope.isSuccess(envelope),
            let payload = ToolEnvelope.resultPayload(envelope) as? [String: Any]
        else { return false }
        return payload["dispatched"] as? Bool == true && payload["background"] as? Bool == true
    }

    /// Resolve and authorize a kind without admitting it or changing model
    /// residency. This is the reject-before-load boundary used by both the
    /// single spawn and the wave gate.
    static func prepare(
        _ kind: any SubagentKind,
        tool: String,
        handoff: (any SubagentHandoff)? = nil,
        scope explicitScope: SubagentScope? = nil,
        interrupt: InterruptToken? = nil
    ) async -> SubagentPreparationResult {
        func cancellationEnvelope(_ message: String) -> String {
            let userInterrupted = interrupt?.isInterrupted == true
            return ToolEnvelope.failure(
                kind: userInterrupted ? .userDenied : .executionError,
                message:
                    userInterrupted
                    ? "Run was stopped by the user. \(message)"
                    : message,
                tool: tool,
                retryable: false,
                metadata: ["cancelled": true]
            )
        }
        if interrupt?.isInterrupted == true || Task.isCancelled {
            return .failure(
                cancellationEnvelope(
                    "Target preparation did not complete."
                )
            )
        }

        // One recursion guard for the whole subagent family: a running
        // subagent (of any kind) cannot start another.
        if let active = activeKindId {
            return .failure(ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "\(tool) cannot be called from inside a running subagent (\(active)). "
                    + "Finish the current subagent and return its result first.",
                tool: tool,
                retryable: false,
                metadata: ["recursion": true]
            ))
        }

        let scope = explicitScope ?? SubagentScope.current()

        // Resolve + validate the model BEFORE any residency eviction.
        let resolved: ResolvedModel
        let resolution = OwnedSubagentOperation {
            try await kind.resolveModel(scope)
        }
        do {
            resolved = try await resolution.value(
                cancellationRequested: { interrupt?.isInterrupted == true }
            )
        } catch is CancellationError {
            return .failure(
                cancellationEnvelope(
                    "Target resolution did not complete."
                )
            )
        } catch {
            return .failure(envelope(for: error, tool: tool))
        }
        if interrupt?.isInterrupted == true || Task.isCancelled {
            return .failure(
                cancellationEnvelope(
                    "Target resolution did not complete."
                )
            )
        }

        // Permission (policy gate / interactive prompt / rich gate). Own and
        // drain the operation exactly like target resolution so a visible Stop
        // during an AppKit prompt cancels/dismisses it instead of leaving an
        // unowned continuation behind.
        let permissionOperation = OwnedSubagentOperation {
            await kind.permission(scope, resolved)
        }
        let decision: SubagentDecision
        do {
            decision = try await permissionOperation.value(
                cancellationRequested: { interrupt?.isInterrupted == true }
            )
        } catch {
            return .failure(
                cancellationEnvelope(
                    "Target authorization did not complete."
                )
            )
        }
        switch decision {
        case .allow:
            break
        case .denied(let reason):
            return .failure(
                ToolEnvelope.failure(
                    kind: .rejected,
                    message: reason,
                    tool: tool,
                    retryable: false
                )
            )
        case .userDenied(let reason):
            return .failure(ToolEnvelope.failure(
                kind: .userDenied,
                message: reason,
                tool: tool,
                retryable: false
            ))
        case .unavailable(let reason):
            return .failure(ToolEnvelope.failure(
                kind: .unavailable,
                message: reason,
                tool: tool,
                retryable: true
            ))
        }
        if interrupt?.isInterrupted == true || Task.isCancelled {
            return .failure(
                cancellationEnvelope(
                    "Target authorization did not complete."
                )
            )
        }

        // An interactive permission panel is an asynchronous authority
        // boundary. Kinds backed by mutable allow-lists/settings can re-read
        // those values here, still before admission or model residency changes.
        let revalidation = OwnedSubagentOperation {
            try await kind.revalidateAfterPermission(
                scope,
                approved: resolved
            )
        }
        let revalidated: ResolvedModel
        do {
            revalidated = try await revalidation.value(
                cancellationRequested: { interrupt?.isInterrupted == true }
            )
        } catch is CancellationError {
            return .failure(
                cancellationEnvelope(
                    "Post-authorization validation did not complete."
                )
            )
        } catch {
            return .failure(envelope(for: error, tool: tool))
        }
        if interrupt?.isInterrupted == true || Task.isCancelled {
            return .failure(
                cancellationEnvelope(
                    "Post-authorization validation did not complete."
                )
            )
        }

        return .ready(
            PreparedSubagentRun(
                kind: kind,
                tool: tool,
                scope: scope,
                resolved: revalidated,
                handoff: handoff ?? kind.makeHandoff(),
                handoffIsKindOwned: handoff == nil
            )
        )
    }

    /// Execute a previously resolved/authorized run.
    ///
    /// Intel (docs/SUBAGENTS_INTEL.md): upstream's body also schedules local
    /// MLX models on the GPU (admission slots, batch capacity, residency
    /// handoffs, cache snapshots). Every Intel subagent is remote, so this is
    /// upstream's remote path only: feed + interrupt registration, the
    /// execution-authority check, the scope task-locals and recursion guard,
    /// the kind's handoff around its run, and the same envelope, feed and
    /// telemetry on both outcomes. The parameters upstream uses for batching
    /// are kept so callers compile; `skipAdmission` has nothing to skip.
    static func runPrepared(
        _ prepared: PreparedSubagentRun,
        presentation suppliedPresentation: SubagentRunPresentation? = nil,
        skipAdmission: Bool = false,
        handoffOverride: (any SubagentHandoff)? = nil,
        captureProcessCacheSnapshot: Bool = true
    ) async -> String {
        if let active = activeKindId {
            return ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "\(prepared.tool) cannot be called from inside a running subagent (\(active)). "
                    + "Finish the current subagent and return its result first.",
                tool: prepared.tool,
                retryable: false,
                metadata: ["recursion": true]
            )
        }

        let presentation =
            suppliedPresentation
            ?? SubagentRunPresentation(
                feed: SubagentFeed(
                    toolCallId: prepared.scope.toolCallId,
                    kindId: prepared.kind.capability.id,
                    title: prepared.kind.feedTitle,
                    agentId: prepared.scope.agentId,
                    parentSessionId: prepared.scope.sessionId,
                    suppressActivityMirror: prepared.kind.suppressActivityMirror
                ),
                interrupt: InterruptToken(),
                registerWithUI: true
            )
        let feed = presentation.feed
        let interrupt = presentation.interrupt

        if presentation.registerWithUI {
            SubagentFeedRegistry.shared.register(feed)
            SubagentInterruptCenter.shared.register(interrupt, for: prepared.scope.toolCallId)
        }
        defer {
            if presentation.registerWithUI {
                SubagentInterruptCenter.shared.unregister(prepared.scope.toolCallId)
                SubagentFeedRegistry.shared.unregister(toolCallId: prepared.scope.toolCallId)
            }
        }

        // Close the prepare→run race for kinds whose run authority is mutable.
        do {
            try await prepared.kind.validateExecutionAuthority(
                prepared.scope,
                resolved: prepared.resolved
            )
        } catch {
            let envelope = envelope(for: error, tool: prepared.tool)
            if presentation.finishFeed {
                feed.finish(success: false, summary: ToolEnvelope.failureMessage(envelope))
            }
            return envelope
        }
        if interrupt.isInterrupted || Task.isCancelled {
            let envelope = ToolEnvelope.failure(
                kind: interrupt.isInterrupted ? .userDenied : .executionError,
                message: interrupt.isInterrupted
                    ? "Run was stopped by the user before execution began."
                    : "Run was cancelled before execution began.",
                tool: prepared.tool,
                retryable: false,
                metadata: ["cancelled": true]
            )
            if presentation.finishFeed {
                feed.finish(success: false, summary: ToolEnvelope.failureMessage(envelope))
            }
            return envelope
        }

        let effectiveHandoff = handoffOverride ?? prepared.handoff
        let started = Date()

        // Run under the recursion guard, wrapped by the handoff, with the
        // prepared child scope bound explicitly (upstream).
        do {
            let result = try await ChatExecutionContext.$currentSessionId.withValue(
                prepared.scope.sessionId
            ) {
                try await ChatExecutionContext.$currentAgentId.withValue(prepared.scope.agentId) {
                    try await ChatExecutionContext.$currentReasoningEffort.withValue(
                        prepared.scope.reasoningEffort
                    ) {
                        try await ChatExecutionContext.$currentEnableThinking.withValue(
                            prepared.scope.enableThinking
                        ) {
                            try await ChatExecutionContext.$currentToolCallId.withValue(
                                prepared.scope.toolCallId
                            ) {
                                try await SubagentSession.$activeKindId.withValue(
                                    prepared.kind.capability.id
                                ) {
                                    try await effectiveHandoff.around(
                                        scope: prepared.scope,
                                        resolved: prepared.resolved,
                                        feed: feed
                                    ) {
                                        try await prepared.kind.run(
                                            prepared.scope,
                                            prepared.resolved,
                                            feed: feed,
                                            interrupt: interrupt
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }

            var payload = result.payload
            let phases = Self.residencyPhaseTimings(events: feed.currentEvents(), endedAt: Date())
            if !phases.isEmpty {
                payload["residency"] = [
                    "phases": Dictionary(
                        uniqueKeysWithValues: phases.map { ($0.phase, ($0.seconds * 100).rounded() / 100) }
                    ),
                    "phase_order": phases.map(\.phase),
                ]
            }
            if presentation.finishFeed {
                feed.finish(success: true, summary: result.summary ?? "")
            }
            SubagentTelemetry.record(
                kindId: prepared.kind.capability.id,
                success: true,
                elapsed: Date().timeIntervalSince(started),
                usage: payload["usage"] as? [String: Any],
                phases: phases
            )
            return ToolEnvelope.success(tool: prepared.tool, result: payload)
        } catch {
            let env: String
            if error is CancellationError {
                env = ToolEnvelope.failure(
                    kind: interrupt.isInterrupted ? .userDenied : .executionError,
                    message: interrupt.isInterrupted ? "Run was stopped by the user." : "Run was cancelled.",
                    tool: prepared.tool,
                    retryable: false,
                    metadata: ["cancelled": true]
                )
            } else {
                env = envelope(for: error, tool: prepared.tool)
            }
            if presentation.finishFeed {
                feed.finish(success: false, summary: ToolEnvelope.failureMessage(env))
            }
            SubagentTelemetry.record(
                kindId: prepared.kind.capability.id,
                success: false,
                elapsed: Date().timeIntervalSince(started),
                phases: Self.residencyPhaseTimings(events: feed.currentEvents(), endedAt: Date())
            )
            return env
        }
    }

    static let timedPhaseTitles: Set<String> = [
        "waiting for local GPU",
        "waiting_for_chat_idle",
        "unloading_chat_models",
        "chat_model_not_loaded",
        "handing_off_to_delegate",
        "releasing_delegate_model",
        "restoring_chat_models",
        "restoring_chat_models_retry",
        "coexisting",
    ]

    /// Derive phase durations from a feed's event timeline: a timed phase
    /// lasts until the NEXT event of any kind (or `endedAt` for the last
    /// event). Pure — unit-testable with synthetic events.
    static func residencyPhaseTimings(
        events: [SubagentActivityEvent],
        endedAt: Date
    ) -> [(phase: String, seconds: Double)] {
        var timings: [(phase: String, seconds: Double)] = []
        for (index, event) in events.enumerated() {
            guard event.kind == .phase, timedPhaseTitles.contains(event.title) else { continue }
            let end = index + 1 < events.count ? events[index + 1].timestamp : endedAt
            let seconds = max(0, end.timeIntervalSince(event.timestamp))
            timings.append((phase: event.title, seconds: seconds))
        }
        return timings
    }

    /// Map a thrown error to the canonical failure envelope. `SubagentError`
    /// carries its own kind/retryable; anything else falls back to
    /// `ToolEnvelope.fromError`.
    static func envelope(for error: Error, tool: String) -> String {
        if let se = error as? SubagentError { return se.envelope(tool: tool) }
        return ToolEnvelope.fromError(error, tool: tool)
    }

    /// Canonical local identity for the admission gate. This path runs for
    /// every spawned/tool worker and therefore must remain pure: model
    /// discovery can synchronously scan every configured model root and would
    /// starve unrelated actor work (including Stop delivery) when many workers
    /// start together. A known stable id wins. An id-less fallback keeps the
    /// complete model string instead of truncating it to a basename: two
    /// installed bundles from different organizations must never share
    /// admission or a handoff.
    ///
    /// Production local Text workers carry the canonical installed id from
    /// resolution, so full and short spellings of the same bundle still group
    /// together without filesystem discovery in this pure hot path.
    static func canonicalAdmissionModelKey(_ resolved: ResolvedModel) -> String? {
        guard resolved.isLocal else { return nil }
        let identity = resolved.id ?? resolved.name
        let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}
