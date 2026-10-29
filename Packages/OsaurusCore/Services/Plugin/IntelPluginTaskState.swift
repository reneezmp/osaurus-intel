//
//  IntelPluginTaskState.swift
//  osaurus
//
//  Upstream's background-task status serialization (`PluginHostAPI.swift`,
//  which Intel doesn't compile: no plugin host). `GET /tasks/{id}` uses it
//  (`W-server-api` stage 4b, docs/SERVER_API_INTEL.md). Verbatim, on
//  Intel's `PluginHostContext` stand-in (`IntelScheduleConformers.swift`).
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
        case .running, .awaitingClarification:
            // Chat tasks always serialize as "running"; clarification is
            // handled inline through the `clarify` agent intercept.
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

        case .completed(let success, let summary):
            result["status"] = success ? "completed" : "failed"
            result["success"] = success
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

    /// Canonical (sorted-keys) JSON; "{}" on failure.
    static func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .osaurusCanonical)
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}

#endif
