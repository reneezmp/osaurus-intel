//
//  IntelRouterWire.swift
//  OsaurusCore — Intel fork
//
//  Stage 5d row 31 (upstream Classic `routerWireCompatibleMessages`,
//  `routerMessagesDroppingUnsupportedAssistantPrefill`,
//  `routerUserWireMessage`), on Intel's wire dictionaries.
//
//  The Router fans one OpenAI-compatible request out to many upstreams, so it
//  gets the strictest shared history shape:
//    - a trailing assistant message with no tool calls (a prefill) is dropped;
//    - assistant `content` is always a string;
//    - user audio and video parts are always removed (no Router upstream maps
//      them); image parts are removed when the model does not advertise image
//      input (`OsaurusRouterModel.supportsVision`), which spares the 400 on the
//      first image turn;
//    - every removal leaves one visible text notice, so neither the model nor
//      the user is told something shipped that did not. A message left with
//      no media collapses to a plain string.
//  Tool-result pairing (upstream's other two steps) is already covered by
//  `ChatEngine.sanitizeToolSequence`.
//

import Foundation

enum IntelRouterWire {
    /// Whether the Router catalog says `modelId` accepts images. Upstream
    /// keeps the vision set pushed from the catalog (`routerVisionModelIds`)
    /// and starts empty, so a model not in the catalog yet is treated as
    /// text-only. Test seam; the default reads `routerModelMetadata`.
    nonisolated(unsafe) static var catalogSupportsImageInput: @Sendable (String) async -> Bool = { modelId in
        await MainActor.run { RemoteProviderManager.shared.routerModelMetadata[modelId]?.supportsVision ?? false }
    }

    static func compatibleMessages(
        _ messages: [[String: Any]], modelSupportsImageInput: Bool
    ) -> [[String: Any]] {
        var wire = messages
        if let last = wire.last, isUnsupportedAssistantPrefill(last) { wire.removeLast() }
        return wire.map { message in
            switch (message["role"] as? String)?.lowercased() {
            case "assistant": return assistantWireMessage(message)
            case "user": return userWireMessage(message, modelSupportsImageInput: modelSupportsImageInput)
            default: return message
            }
        }
    }

    private static func isUnsupportedAssistantPrefill(_ message: [String: Any]) -> Bool {
        (message["role"] as? String)?.lowercased() == "assistant"
            && ((message["tool_calls"] as? [Any])?.isEmpty ?? true)
            && message["tool_call_id"] == nil
    }

    private static func assistantWireMessage(_ message: [String: Any]) -> [String: Any] {
        var out = message
        if let parts = message["content"] as? [[String: Any]] {
            out["content"] = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else if !(message["content"] is String) {
            out["content"] = ""
        }
        return out
    }

    private static func userWireMessage(
        _ message: [String: Any], modelSupportsImageInput: Bool
    ) -> [String: Any] {
        guard let parts = message["content"] as? [[String: Any]] else { return message }
        var kept: [[String: Any]] = []
        var removedKinds: [String] = []
        for part in parts {
            switch part["type"] as? String {
            case "image_url":
                if modelSupportsImageInput { kept.append(part) } else { removedKinds.append("image") }
            case "input_audio": removedKinds.append("audio")
            case "video_url": removedKinds.append("video")
            default: kept.append(part)
            }
        }
        guard !removedKinds.isEmpty else { return message }
        let summary = removedMediaSummary(removedKinds)
        let notice = "[Osaurus: \(summary) removed — not supported by this model on Osaurus Router]"
        NSLog("[CloudChatEngine] Router wire: removed unsupported user media (\(summary))")
        var out = message
        let hasRemainingMedia = kept.contains { ($0["type"] as? String) != "text" }
        if hasRemainingMedia {
            out["content"] = kept + [["type": "text", "text": notice]]
        } else {
            let texts = kept.compactMap { $0["text"] as? String }
            out["content"] = (texts + [notice]).joined(separator: "\n")
        }
        return out
    }

    /// "1 image attachment", "1 audio attachment and 2 image attachments".
    static func removedMediaSummary(_ kinds: [String]) -> String {
        var counts: [String: Int] = [:]
        for kind in kinds { counts[kind, default: 0] += 1 }
        return counts.sorted { $0.key < $1.key }
            .map { kind, count in "\(count) \(kind) attachment\(count == 1 ? "" : "s")" }
            .joined(separator: " and ")
    }
}
