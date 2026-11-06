//
//  IntelPluginTaskState.swift
//  osaurus
//
//  Upstream's background-task status and task-event serialization
//  (`PluginHostAPI.swift`, which Intel doesn't compile). `GET /tasks/{id}`
//  (`W-server-api` stage 4b, docs/SERVER_API_INTEL.md), plugin
//  `task_status` / `list_active_tasks` and the events delivered to plugins'
//  `on_task_event` (`W-plugin-reliability` stage 2c) use it. All verbatim
//  (`taskStateDict` since `W-background-runs-sync` stage 1 brought
//  upstream's `queued` / `failed` statuses), on Intel's
//  `PluginHostContext` (`IntelPluginHostContext.swift`, whose `jsonString` /
//  `parseJSON` it uses).
//

import Foundation

#if OSAURUS_INTEL

extension PluginHostContext {
    @MainActor
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    @MainActor
    static func taskStateDict(id: UUID, state: BackgroundTaskState) -> [String: Any] {
        var result: [String: Any] = [
            "id": id.uuidString,
            "title": state.taskTitle,
        ]

        if let draft = state.draftText, let parsed = parseJSON(draft) { result["draft"] = parsed }

        // Last assistant content — partial during `.running`, final on
        // `.completed`. Surfaced for both so HTTP pollers and `task_status`
        // callers can read the transcript without loading the session.
        if let output = state.chatSession?.turns.last?.content, !output.isEmpty {
            result["output"] = output
        }

        switch state.status {
        case .queued:
            result["status"] = "queued"
            if let step = state.currentStep { result["current_step"] = step }

        case .running, .waitingForInput:
            // v3: chat tasks always serialize as "running". The
            // `.waitingForInput` enum case is still used internally
            // for UI hints (toast, Activity section) but never exposed via task_status,
            // because clarification is handled inline through the `clarify`
            // agent intercept rather than as an out-of-band state.
            result["status"] = "running"
            if let step = state.currentStep { result["current_step"] = step }

            let activity: [[String: Any]] = state.activityFeed.suffix(20).map { item in
                var entry: [String: Any] = [
                    "kind": Self.activityKindString(item.kind),
                    "title": item.title,
                    "timestamp": isoFormatter.string(from: item.date),
                ]
                if let detail = item.detail { entry["detail"] = detail }
                return entry
            }
            if !activity.isEmpty { result["activity"] = activity }

        case .completed(let summary):
            result["status"] = "completed"
            result["success"] = true
            result["summary"] = summary
            if let execCtx = state.executionContext {
                result["session_id"] = execCtx.id.uuidString
            }

        case .failed(let summary):
            result["status"] = "failed"
            result["success"] = false
            result["summary"] = summary
            if let execCtx = state.executionContext {
                result["session_id"] = execCtx.id.uuidString
            }

        case .cancelled:
            result["status"] = "cancelled"
        }

        return result
    }

    @MainActor
    static func serializeTaskState(id: UUID, state: BackgroundTaskState) -> String {
        jsonString(taskStateDict(id: id, state: state))
    }

    private static func activityKindString(_ kind: BackgroundTaskActivityItem.Kind) -> String {
        switch kind {
        case .tool: "tool"
        case .toolCall: "tool_call"
        case .toolResult: "tool_result"
        case .thinking: "thinking"
        case .writing: "writing"
        case .info: "info"
        case .progress: "progress"
        case .warning: "warning"
        case .success: "success"
        case .error: "error"
        }
    }


    // MARK: - Task Event Serialization

    @MainActor
    static func serializeStartedEvent(state: BackgroundTaskState) -> String {
        jsonString([
            "status": "running",
            "title": state.taskTitle,
        ])
    }

    @MainActor
    static func serializeActivityEvent(
        kind: BackgroundTaskActivityItem.Kind,
        title: String,
        detail: String?,
        metadata: [String: Any]? = nil
    ) -> String {
        var dict: [String: Any] = [
            "kind": activityKindString(kind),
            "title": title,
            "timestamp": isoFormatter.string(from: Date()),
        ]
        if let detail { dict["detail"] = detail }
        if let metadata, !metadata.isEmpty { dict["metadata"] = metadata }
        return jsonString(dict)
    }

    @MainActor
    static func serializeProgressEvent(progress: Double, currentStep: String?, taskTitle: String) -> String {
        var dict: [String: Any] = ["progress": progress, "title": taskTitle]
        if let step = currentStep { dict["current_step"] = step }
        return jsonString(dict)
    }

    /// Serialize the payload for `OSR_TASK_EVENT_CLARIFICATION` (type 3).
    /// Emitted when the agent calls the inline `clarify` tool to pause for
    /// a user response. `options` is omitted entirely when empty so plugins
    /// can use key-presence as the "free-form vs choice" signal.
    @MainActor
    static func serializeClarificationEvent(payload: ClarifyPayload) -> String {
        var dict: [String: Any] = [
            "question": payload.question,
            "allow_multiple": payload.allowMultiple,
        ]
        if !payload.options.isEmpty {
            dict["options"] = payload.options
        }
        return jsonString(dict)
    }

    @MainActor
    static func serializeCompletedEvent(
        success: Bool,
        summary: String,
        sessionId: UUID?,
        taskTitle: String,
        artifacts: [SharedArtifact] = [],
        outputText: String? = nil
    ) -> String {
        var dict: [String: Any] = ["success": success, "summary": summary, "title": taskTitle]
        if let sid = sessionId { dict["session_id"] = sid.uuidString }
        if !artifacts.isEmpty {
            dict["artifacts"] = artifacts.map { serializeArtifactDict($0) }
        }
        if let output = outputText, !output.isEmpty {
            dict["output"] = output
        }
        return jsonString(dict)
    }

    static func serializeArtifactEvent(artifact: SharedArtifact) -> String {
        return jsonString(serializeArtifactDict(artifact))
    }

    /// Intel: internal (upstream private) for the inference callbacks in
    /// `IntelPluginInference.swift`.
    static func serializeArtifactDict(_ artifact: SharedArtifact) -> [String: Any] {
        var dict: [String: Any] = [
            "filename": artifact.filename,
            "mime_type": artifact.mimeType,
            "size": artifact.fileSize,
            "host_path": artifact.hostPath,
            "is_directory": artifact.isDirectory,
        ]
        if let desc = artifact.description { dict["description"] = desc }
        return dict
    }

    static func serializeCancelledEvent(taskTitle: String) -> String {
        jsonString(["title": taskTitle])
    }

    static func serializeOutputEvent(text: String, taskTitle: String) -> String {
        jsonString(["text": text, "title": taskTitle])
    }

    static func serializeDraftEvent(draftJSON: String, taskTitle: String) -> String {
        var dict: [String: Any] = ["title": taskTitle]
        if let draft = parseJSON(draftJSON) { dict["draft"] = draft }
        return jsonString(dict)
    }
}

#endif
