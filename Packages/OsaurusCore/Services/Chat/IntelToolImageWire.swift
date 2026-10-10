//
//  IntelToolImageWire.swift
//  OsaurusCore — Intel fork
//
//  Tool-result images on Intel's wire dicts (W-agent-loop-tools,
//  2026-10-10). Upstream builds `ChatMessage`s through
//  `ToolResultMediaBridge.toolMessage` / `collapsingOlderImages` /
//  `hoistingToolImagesToUserMessages`; Intel's engine keeps its running
//  conversation as OpenAI wire dicts, so these are the same rules on dicts:
//
//  - a `file_read` (or MCP) image envelope becomes a tool message whose
//    content is `[text envelope, image_url…]` when the model takes images;
//  - only the newest `ToolResultMediaBridge.maxLiveImages` tool messages keep
//    their images; older ones collapse to text plus the upstream note;
//  - wires whose tool role is text-only (OpenAI-compatible, Responses,
//    Gemini) get the images hoisted into ONE user message after the run of
//    tool messages, introduced by upstream's `hoistedImageIntro`. Anthropic
//    keeps them inside `tool_result`.
//

import Foundation

enum IntelToolImageWire {
    /// The tool message for `result`, carrying its staged images when the
    /// model accepts images.
    static func toolMessage(callId: String, toolName: String, result: String, imagesEnabled: Bool) -> [String: Any] {
        var message: [String: Any] = ["role": "tool", "tool_call_id": callId, "content": result]
        guard imagesEnabled else { return message }
        let images = ToolResultMediaBridge.attachments(toolName: toolName, result: result).loadImages()
        guard !images.isEmpty else { return message }
        message["content"] =
            [["type": "text", "text": result]]
            + images.map { ["type": "image_url", "image_url": ["url": MessageContentPart.imageDataURL($0)]] }
        return message
    }

    /// Image data URLs carried by a tool message's parts.
    static func imageParts(_ message: [String: Any]) -> [[String: Any]] {
        guard message["role"] as? String == "tool", let parts = message["content"] as? [[String: Any]] else {
            return []
        }
        return parts.filter { $0["type"] as? String == "image_url" }
    }

    private static func textOnly(_ message: [String: Any], note: String? = nil) -> [String: Any] {
        var out = message
        let text = IntelAnthropicMessagesAdapter.text(of: message["content"]) ?? ""
        out["content"] = note.map { text + "\n" + $0 } ?? text
        return out
    }

    /// Upstream `collapsingOlderImages`, then (unless the wire keeps images
    /// inside tool results) upstream `hoistingToolImagesToUserMessages`.
    static func preparedForSend(_ messages: [[String: Any]], keepsImagesInToolResults: Bool) -> [[String: Any]] {
        let imageIndices = messages.indices.filter { !imageParts(messages[$0]).isEmpty }
        var out = messages
        if imageIndices.count > ToolResultMediaBridge.maxLiveImages {
            for index in imageIndices.dropLast(ToolResultMediaBridge.maxLiveImages) {
                out[index] = textOnly(messages[index], note: ToolResultMediaBridge.collapsedImageNote)
            }
        }
        guard !keepsImagesInToolResults, out.contains(where: { !imageParts($0).isEmpty }) else { return out }

        var hoisted: [[String: Any]] = []
        var pending: [[String: Any]] = []
        func flush() {
            guard !pending.isEmpty else { return }
            hoisted.append([
                "role": "user",
                "content": [["type": "text", "text": ToolResultMediaBridge.hoistedImageIntro]] + pending,
            ])
            pending = []
        }
        for (index, message) in out.enumerated() {
            if message["role"] as? String == "tool" {
                let images = imageParts(message)
                hoisted.append(images.isEmpty ? message : textOnly(message))
                pending.append(contentsOf: images)
                let nextIsTool = index + 1 < out.count && out[index + 1]["role"] as? String == "tool"
                if !nextIsTool { flush() }
            } else {
                flush()
                hoisted.append(message)
            }
        }
        flush()
        return hoisted
    }
}
