//
//  IntelPrivacyWire.swift
//  osaurus
//
//  Intel (`W-privacy-filter` stage 3): the Privacy Filter's send-path hooks.
//
//  Upstream scrubs inside `RemoteProviderService` (`applyPrivacyOutbound`,
//  one call per model round). Intel does not compile that file: its cloud
//  engine (`CloudChatEngine.swift`) runs the whole agent loop itself and
//  keeps the running conversation as wire dictionaries. This file is the
//  adapter between the two worlds:
//
//    - `preflight` scrubs the request's `[ChatMessage]` once, before the
//      stream exists, so every typed error (blocked send, review canceled)
//      reaches the caller the way upstream's `streamWithTools` throws it.
//    - `scrubRound` re-runs the same pipeline over the round's wire
//      dictionaries (and Responses replay items) so tool results and every
//      later round are scrubbed too, with the same per-session map.
//    - `unscrubArguments` restores placeholders in a tool call's arguments
//      before the tool runs locally.
//
//  Master switch off (upstream's default) means none of this runs: callers
//  check `isActive` first and the send path is byte-for-byte unchanged.
//  Rules only: no model detector exists on this Mac, and no text is sent
//  anywhere to decide what to mask (`docs/W_PRIVACY_FILTER_PLAN.md`).
//

import Foundation

enum IntelPrivacyWire {
    /// Provider id used when the engine has no provider record (the
    /// environment-key fallback): only the master switch applies to it.
    static let noProviderId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// What the pipeline needs to know about one run.
    struct Context: Sendable {
        var providerId: UUID
        var sessionId: String?
        var requestSource: RequestSource
        var reviewMode: PrivacyReviewMode
    }

    /// Whether the filter acts on a send to this provider (master switch and
    /// the provider's override). Cheap: one locked snapshot read.
    static func isActive(providerId: UUID?) -> Bool {
        PrivacyFilterStore.snapshot().isEnabled(forProviderId: providerId ?? noProviderId)
    }

    // MARK: Outbound

    /// The one place the pipeline is called. `reviewCanceled` becomes a
    /// `CancellationError` so the chat applies its normal Stop handling, as
    /// upstream's `applyPrivacyOutbound` does.
    static func scrub(
        _ messages: [ChatMessage], context: Context
    ) async throws -> (messages: [ChatMessage], map: RedactionMap?) {
        do {
            return try await PrivacyFilterPipeline.applyOutbound(
                messages: messages,
                sessionId: context.sessionId,
                providerId: context.providerId,
                requestSource: context.requestSource,
                reviewMode: context.reviewMode
            )
        } catch PrivacyFilterPipelineError.reviewCanceled {
            throw CancellationError()
        }
    }

    /// Scrub a request's messages before the stream is created. Returns the
    /// messages to send and the session map (nil when nothing was scrubbed).
    static func preflight(
        _ messages: [ChatMessage], context: Context
    ) async throws -> (messages: [ChatMessage], map: RedactionMap?) {
        try await scrub(messages, context: context)
    }

    /// Scrub the round's wire dictionaries and Responses replay items in
    /// place. Detection looks at the latest user turn onward (new tool
    /// results included); values approved earlier in the session are
    /// substituted everywhere, so history stays consistent.
    @discardableResult
    static func scrubRound(
        wire: inout [[String: Any]],
        items: inout [[String: Any]],
        context: Context,
        // Runs on the caller's actor: the wire dictionaries are not Sendable.
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> RedactionMap? {
        let wireMessages = wire.map(chatMessage(fromWire:))
        let itemMessages = items.map(chatMessage(fromItem:))
        let combined = wireMessages + itemMessages
        let result = try await scrub(combined, context: context)
        guard result.messages.count == combined.count else {
            // Fail closed: the adapter lost alignment, so nothing is sent.
            throw PrivacyFilterPipelineError.engineUnavailable("wire adapter mismatch")
        }
        for index in wire.indices {
            wire[index] = patched(wire: wire[index], with: result.messages[index])
        }
        for index in items.indices {
            items[index] = patched(item: items[index], with: result.messages[wire.count + index])
        }
        return result.map
    }

    // MARK: Inbound

    /// A tool call's arguments with `[CATEGORY_N]` placeholders turned back
    /// into the user's values, so the tool runs on the real data. Everything
    /// recorded in the history is scrubbed again by the next round's pass.
    static func unscrubArguments(_ arguments: String, map: RedactionMap?) async -> String {
        guard let map, arguments.contains("[") else { return arguments }
        let call = ToolCall(
            id: "privacy", type: "function",
            function: ToolCallFunction(name: "privacy", arguments: arguments))
        let restored = await PrivacyFilterPipeline.unscrubInbound(content: nil, toolCalls: [call], map: map)
        return restored.toolCalls?.first?.function.arguments ?? arguments
    }

    /// Reply text with placeholders restored (the non-streaming one-shot).
    static func unscrub(_ text: String, map: RedactionMap?) async -> String {
        guard let map else { return text }
        return await PrivacyFilterPipeline.unscrubInbound(content: text, toolCalls: nil, map: map).content ?? text
    }

    // MARK: Wire dictionary <-> ChatMessage

    /// The textual view of one chat-completions wire message. Only what the
    /// scrubber reads is carried: text, tool-call arguments, reasoning and
    /// signed thinking. Images and ids stay in the dictionary untouched.
    static func chatMessage(fromWire dict: [String: Any]) -> ChatMessage {
        let role = dict["role"] as? String ?? "user"
        var content: String?
        var parts: [MessageContentPart]?
        if let text = dict["content"] as? String {
            content = text
        } else if let rawParts = dict["content"] as? [[String: Any]] {
            let texts = rawParts.compactMap(textPart(_:))
            if !texts.isEmpty { parts = texts.map { .text($0) } }
        }
        var calls: [ToolCall]?
        if let rawCalls = dict["tool_calls"] as? [[String: Any]], !rawCalls.isEmpty {
            calls = rawCalls.map { raw in
                let function = raw["function"] as? [String: Any]
                return ToolCall(
                    id: raw["id"] as? String ?? "",
                    type: "function",
                    function: ToolCallFunction(
                        name: function?["name"] as? String ?? "",
                        arguments: function?["arguments"] as? String ?? ""))
            }
        }
        var thinking: [JSONValue]?
        if let blocks = dict["anthropic_thinking_blocks"] as? [Any], !blocks.isEmpty,
            JSONSerialization.isValidJSONObject(blocks),
            let data = try? JSONSerialization.data(withJSONObject: blocks)
        {
            thinking = try? JSONDecoder().decode([JSONValue].self, from: data)
        }
        return ChatMessage(
            role: role, content: content, tool_calls: calls,
            tool_call_id: dict["tool_call_id"] as? String,
            reasoning_content: dict["reasoning_content"] as? String,
            contentParts: parts, anthropic_thinking_blocks: thinking)
    }

    /// `wire` with the scrubbed text of `message` written back.
    static func patched(wire dict: [String: Any], with message: ChatMessage) -> [String: Any] {
        var out = dict
        if dict["content"] is String {
            if let content = message.content { out["content"] = content }
        } else if var rawParts = dict["content"] as? [[String: Any]],
            let scrubbed = message.contentParts
        {
            var next = 0
            for index in rawParts.indices where textPart(rawParts[index]) != nil {
                guard next < scrubbed.count else { break }
                if case .text(let text) = scrubbed[next] { rawParts[index]["text"] = text }
                next += 1
            }
            out["content"] = rawParts
        }
        if var rawCalls = dict["tool_calls"] as? [[String: Any]], let calls = message.tool_calls,
            calls.count == rawCalls.count
        {
            for index in rawCalls.indices {
                var function = rawCalls[index]["function"] as? [String: Any] ?? [:]
                function["arguments"] = calls[index].function.arguments
                rawCalls[index]["function"] = function
            }
            out["tool_calls"] = rawCalls
        }
        if dict["reasoning_content"] is String, let reasoning = message.reasoning_content {
            out["reasoning_content"] = reasoning
        }
        return out
    }

    // MARK: Responses item <-> ChatMessage

    /// The textual view of one Responses input item (a replayed tool output,
    /// a function call, a message). Opaque items (encrypted reasoning) map to
    /// a system message, which the scrubber never reads: they only carry
    /// text the model produced from placeholders.
    static func chatMessage(fromItem item: [String: Any]) -> ChatMessage {
        switch item["type"] as? String {
        case "message":
            let role = item["role"] as? String ?? "user"
            if let text = item["content"] as? String {
                return ChatMessage(role: role, content: text)
            }
            let texts = (item["content"] as? [[String: Any]] ?? []).compactMap(textPart(_:))
            return ChatMessage(role: role, contentParts: texts.isEmpty ? nil : texts.map { .text($0) })
        case "function_call_output":
            if let output = item["output"] as? String {
                return ChatMessage(role: "tool", content: output, tool_call_id: item["call_id"] as? String)
            }
            let texts = (item["output"] as? [[String: Any]] ?? []).compactMap(textPart(_:))
            return ChatMessage(
                role: "tool", tool_call_id: item["call_id"] as? String,
                contentParts: texts.isEmpty ? nil : texts.map { .text($0) })
        case "function_call":
            let call = ToolCall(
                id: item["call_id"] as? String ?? "", type: "function",
                function: ToolCallFunction(
                    name: item["name"] as? String ?? "", arguments: item["arguments"] as? String ?? ""))
            return ChatMessage(role: "assistant", tool_calls: [call])
        default:
            return ChatMessage(role: "system", content: "")
        }
    }

    static func patched(item: [String: Any], with message: ChatMessage) -> [String: Any] {
        var out = item
        switch item["type"] as? String {
        case "message":
            if item["content"] is String {
                if let content = message.content { out["content"] = content }
            } else if var parts = item["content"] as? [[String: Any]] {
                out["content"] = patchedParts(&parts, with: message)
            }
        case "function_call_output":
            if item["output"] is String {
                if let content = message.content { out["output"] = content }
            } else if var parts = item["output"] as? [[String: Any]] {
                out["output"] = patchedParts(&parts, with: message)
            }
        case "function_call":
            if let arguments = message.tool_calls?.first?.function.arguments { out["arguments"] = arguments }
        default:
            break
        }
        return out
    }

    // MARK: Helpers

    /// The text of a `text` / `input_text` / `output_text` part.
    private static func textPart(_ part: [String: Any]) -> String? {
        switch part["type"] as? String {
        case "text", "input_text", "output_text": return part["text"] as? String
        default: return nil
        }
    }

    private static func patchedParts(_ parts: inout [[String: Any]], with message: ChatMessage) -> [[String: Any]] {
        guard let scrubbed = message.contentParts else { return parts }
        var next = 0
        for index in parts.indices where textPart(parts[index]) != nil {
            guard next < scrubbed.count else { break }
            if case .text(let text) = scrubbed[next] { parts[index]["text"] = text }
            next += 1
        }
        return parts
    }
}

extension ChatCompletionResponse {
    /// The reply with the Privacy Filter placeholders turned back into the
    /// user's values. `self` when the filter did not run.
    func restoringPlaceholders(map: RedactionMap?) async -> ChatCompletionResponse {
        guard let map else { return self }
        var restored: [Choice] = []
        for choice in choices {
            guard let message = choice.message else {
                restored.append(choice)
                continue
            }
            var content = message.content
            if let text = content { content = await IntelPrivacyWire.unscrub(text, map: map) }
            var reasoning = message.reasoning_content
            if let text = reasoning { reasoning = await IntelPrivacyWire.unscrub(text, map: map) }
            restored.append(
                Choice(
                    index: choice.index,
                    message: ResponseMessage(
                        role: message.role, content: content, tool_calls: message.tool_calls,
                        reasoning_content: reasoning),
                    finish_reason: choice.finish_reason))
        }
        return ChatCompletionResponse(
            id: id, object: object, created: created, model: model, choices: restored, usage: usage)
    }
}
