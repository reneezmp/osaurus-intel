//
//  IntelScheduleConformers.swift
//  OsaurusCore (Intel fork)
//
//  Stubs for the Schedules subsystem restore (M13, Renée 2026-06-03).
//
//  The schedule EXECUTION chain (ScheduleManager → TaskDispatcher →
//  BackgroundTaskManager → SchedulerDatabase) is un-excluded on Intel:
//  it is pure Foundation/Combine/SQLCipher and the agent fires headless
//  through the existing cloud pipeline. The only thing it reaches into
//  that stays amputated is the plugin host. `PluginHostContext` lives in
//  the excluded `Services/Plugin/PluginHostAPI.swift` (MLX/Sandbox host),
//  and `PluginManager` is entirely `#if !OSAURUS_INTEL`-gated. Plugins are
//  amputated on Intel, so nothing consumes task events — these serializers
//  return empty JSON, and cache-invalidation forwards to the real
//  `SessionToolStateStore` (which IS compiled on Intel).
//

import Foundation

#if OSAURUS_INTEL

/// Intel stub for the amputated plugin host's static event surface.
///
/// On Apple Silicon `PluginHostContext` is a `final class` instantiated per
/// loaded plugin; on Intel no plugin ever loads (PluginManager is gated out),
/// so only `BackgroundTaskManager`'s static serialize/invalidate calls remain.
/// Modeled as an `enum` (no instances) returning empty payloads.
enum PluginHostContext {
    static func invalidatePreflightCache(sessionId: String) {
        Task { await SessionToolStateStore.shared.invalidate(sessionId) }
    }

    static func serializeStartedEvent(state: BackgroundTaskState) -> String { "{}" }

    static func serializeActivityEvent(
        kind: BackgroundTaskActivityItem.Kind,
        title: String,
        detail: String?,
        metadata: [String: Any]? = nil
    ) -> String { "{}" }

    static func serializeClarificationEvent(payload: ClarifyPayload) -> String { "{}" }

    static func serializeCompletedEvent(
        success: Bool,
        summary: String,
        sessionId: UUID?,
        taskTitle: String,
        artifacts: [SharedArtifact] = [],
        outputText: String? = nil
    ) -> String { "{}" }

    static func serializeCancelledEvent(taskTitle: String) -> String { "{}" }

    static func serializeDraftEvent(draftJSON: String, taskTitle: String) -> String { "{}" }
}

/// Intel stub for the plugin task-event enum (real one lives in the fully
/// `#if !OSAURUS_INTEL` `Models/Plugin/ExternalPlugin.swift`). Raw values
/// mirror upstream so any persisted/serialized ints stay compatible. Only
/// `BackgroundTaskManager`'s now-gated plugin-notify path references the
/// cases on Intel; no plugin ever consumes them.
enum TaskEventType: Int32 {
    case started = 0
    case activity = 1
    case progress = 2
    case clarification = 3
    case completed = 4
    case failed = 5
    case cancelled = 6
    case output = 7
    case draft = 8
}

/// Intel stub for the storage-migration gate (real one lives in the
/// `#if !OSAURUS_INTEL` `Views/Storage/StorageMigrationOverlay.swift`).
/// Intel opens its databases directly with no cross-store migration phase,
/// so `blockingAwaitReady()` returns immediately. `SchedulerDatabase`
/// (un-excluded in this restore) calls it before its first query.
enum StorageMigrationCoordinator {
    nonisolated static func blockingAwaitReady() {}
}

#endif
