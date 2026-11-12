//
//  IntelAnthropicMessagesAdapter.swift
//  OsaurusCore — Intel fork
//
//  Anthropic Messages API for Intel's cloud engine (W-provider-wire-formats,
//  2026-10-10). The engine builds an OpenAI chat-completions body and parses
//  OpenAI SSE chunks; upstream's `RemoteProviderService` instead builds a
//  native Messages request (`toAnthropicRequest`) and parses Anthropic
//  events, and it is excluded on Intel. This adapter translates at both
//  edges so the engine's tool loop, approvals and logging stay one path:
//
//  - `makeRequest` follows upstream `toAnthropicRequest`: system → `system`;
//    tool results batched into one user message of `tool_result` blocks;
//    assistant tool calls → `tool_use` blocks; `image_url` parts → image
//    blocks (base64 or URL); `max_tokens` 4096 by default; sampler knobs
//    omitted for the Claude generations that reject them; top-level
//    `cache_control` (1 h after a human turn, 5 m after a tool result).
//  - `IntelAnthropicSSETranslator` turns Messages stream events into OpenAI
//    `data:` chunk lines (text, `reasoning_content` from thinking, streamed
//    `tool_calls`, a final usage frame, `[DONE]`). It also keeps each
//    `thinking` / `redacted_thinking` block whole, with its signature, and
//    hands it on as an `anthropic_thinking_block` delta field; `makeRequest`
//    replays those blocks ahead of the assistant's text and tool calls
//    (upstream `RemoteAnthropicNativeStream` / `anthropic_thinking_blocks`,
//    #3203; `W-anthropic-thinking-replay`).
//

import Foundation

enum IntelAnthropicMessagesAdapter {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Upstream `RemoteProviderService.emptyToolResultMarker`.
    static let emptyToolResultMarker = "(no output)"
    static let defaultMaxTokens = 4096

    /// Claude generations that reject `temperature` / `top_p` (upstream's
    /// list in `toAnthropicRequest`).
    static let knobDeprecatingClaudePrefixes = [
        "claude-fable", "claude-mythos",
        "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8",
        "claude-sonnet-4-6", "claude-sonnet-5", "claude-opus-5",
        // Confirmed live (upstream #3229).
        "claude-haiku-5",
    ]

    /// - Parameters:
    ///   - capabilities: the provider's Models API capability contract for
    ///     this model (`AnthropicModelCatalog`), which decides `thinking` /
    ///     `output_config.effort` and sampler support (upstream #3229). Nil
    ///     when uncatalogued: no thinking field, and the prefix list decides
    ///     the samplers.
    ///   - effort: the raw picker value, or `AnthropicReasoningContract.offLevelId`
    ///     when thinking is switched off.
    static func makeRequest(
        chatCompletions body: [String: Any],
        capabilities: AnthropicModelCapabilities? = nil,
        effort: String? = nil
    ) throws -> [String: Any] {
        guard let model = body["model"] as? String, !model.isEmpty else {
            throw Failure(message: "Anthropic request needs a model")
        }
        let messages = body["messages"] as? [[String: Any]] ?? []
        var system: [String] = []
        var out: [[String: Any]] = []
        var pendingResults: [[String: Any]] = []

        func flush() {
            guard !pendingResults.isEmpty else { return }
            out.append(["role": "user", "content": pendingResults])
            pendingResults = []
        }

        for message in messages {
            let role = message["role"] as? String ?? "user"
            switch role {
            case "system", "developer":
                flush()
                if let text = text(of: message["content"]), hasMeaningfulText(text) { system.append(text) }
            case "user":
                flush()
                var blocks = imageURLs(of: message["content"]).compactMap(imageBlock(fromImageURL:))
                if let text = text(of: message["content"]), hasMeaningfulText(text) {
                    blocks.append(["type": "text", "text": text])
                }
                if blocks.count == 1, blocks[0]["type"] as? String == "text", let text = blocks[0]["text"] {
                    out.append(["role": "user", "content": text])
                } else if !blocks.isEmpty {
                    out.append(["role": "user", "content": blocks])
                }
            case "assistant":
                flush()
                // Signed thinking goes back first, as upstream's
                // `toAnthropicRequest` does.
                var blocks: [[String: Any]] = replayableThinkingBlocks(of: message["anthropic_thinking_blocks"])
                if let text = text(of: message["content"]), hasMeaningfulText(text) {
                    blocks.append(["type": "text", "text": text])
                }
                for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                    let function = call["function"] as? [String: Any] ?? [:]
                    let arguments = function["arguments"] as? String ?? ""
                    let input =
                        (arguments.data(using: .utf8).flatMap {
                            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                        }) ?? [:]
                    blocks.append([
                        "type": "tool_use",
                        "id": call["id"] as? String ?? "",
                        "name": function["name"] as? String ?? "",
                        "input": input,
                    ])
                }
                if !blocks.isEmpty { out.append(["role": "assistant", "content": blocks]) }
            case "tool":
                guard let callId = message["tool_call_id"] as? String else { continue }
                let resultText = text(of: message["content"]).flatMap { hasMeaningfulText($0) ? $0 : nil }
                    ?? emptyToolResultMarker
                let images = imageURLs(of: message["content"]).compactMap(imageBlock(fromImageURL:))
                let content: Any =
                    images.isEmpty ? resultText : ([["type": "text", "text": resultText]] + images)
                pendingResults.append(["type": "tool_result", "tool_use_id": callId, "content": content])
            default:
                flush()
            }
        }
        flush()

        var request: [String: Any] = [
            "model": model,
            "messages": out,
            "max_tokens": (body["max_tokens"] as? Int) ?? (body["max_completion_tokens"] as? Int)
                ?? defaultMaxTokens,
        ]
        if !system.isEmpty { request["system"] = system.joined(separator: "\n") }
        if let stream = body["stream"] as? Bool { request["stream"] = stream }
        if let tools = body["tools"] as? [[String: Any]], !tools.isEmpty {
            let stream = body["stream"] as? Bool ?? false
            request["tools"] = tools.compactMap { tool -> [String: Any]? in
                guard let function = tool["function"] as? [String: Any], let name = function["name"] as? String
                else { return nil }
                var schema = function["parameters"] as? [String: Any] ?? ["type": "object"]
                if schema["properties"] == nil { schema["properties"] = [String: Any]() }
                var out: [String: Any] = ["name": name, "input_schema": schema]
                if let description = function["description"] as? String { out["description"] = description }
                if stream { out["eager_input_streaming"] = true }
                return out
            }
        }
        let maxTokens = request["max_tokens"] as? Int ?? defaultMaxTokens
        let reasoning = AnthropicReasoningContract.wireControls(
            capabilities: capabilities, effort: effort, maxTokens: maxTokens)
        if let thinking = reasoning?.thinking {
            var wire: [String: Any] = ["type": thinking.type]
            if let budget = thinking.budget_tokens { wire["budget_tokens"] = budget }
            if let display = thinking.display { wire["display"] = display }
            request["thinking"] = wire
        }
        if let effort = reasoning?.effort { request["output_config"] = ["effort": effort] }
        if let choice = body["tool_choice"] {
            switch choice {
            case let mode as String:
                switch mode {
                case "none": request["tool_choice"] = ["type": "none"]
                // Manual `enabled` thinking rejects forced tool use.
                case "required": request["tool_choice"] = [
                    "type": reasoning?.isManualThinking == true ? "auto" : "any"
                ]
                default: request["tool_choice"] = ["type": "auto"]
                }
            case let object as [String: Any]:
                if let name = (object["function"] as? [String: Any])?["name"] as? String {
                    request["tool_choice"] =
                        reasoning?.isManualThinking == true ? ["type": "auto"] : ["type": "tool", "name": name]
                }
            default:
                break
            }
        }
        let bare = model.lowercased().split(separator: "/").last.map(String.init) ?? model.lowercased()
        // Thinking is incompatible with temperature/top_k changes on every
        // Claude model; catalogued models answer from their capabilities,
        // the prefix list covers uncatalogued ones.
        let thinkingActive = ["adaptive", "enabled"].contains(reasoning?.thinking?.type ?? "")
        let deprecatesSamplerKnobs =
            thinkingActive
            || AnthropicReasoningContract.acceptsSamplerKnobs(capabilities).map { !$0 }
                ?? knobDeprecatingClaudePrefixes.contains { bare.hasPrefix($0) }
        if !deprecatesSamplerKnobs {
            if let temperature = body["temperature"] { request["temperature"] = temperature }
            if let topP = body["top_p"] { request["top_p"] = topP }
        }
        if let stop = body["stop"] { request["stop_sequences"] = stop }
        // Upstream `AnthropicCacheControl.forConversation(lastMessageRole:)`.
        let lastRole = messages.last?["role"] as? String
        request["cache_control"] = lastRole == "tool" ? ["type": "ephemeral"] : ["type": "ephemeral", "ttl": "1h"]
        return request
    }

    // MARK: - Thinking blocks

    /// The `thinking` / `redacted_thinking` blocks of a wire message, in the
    /// shape the Messages API takes back. Upstream decodes each stored block
    /// as an `AnthropicContentBlock` and keeps only those two cases. Intel
    /// also drops a `thinking` block that has no signature: the API refuses
    /// an unsigned one, which would fail the whole request.
    static func replayableThinkingBlocks(of raw: Any?) -> [[String: Any]] {
        guard let blocks = raw as? [[String: Any]] else { return [] }
        return blocks.filter { block in
            switch block["type"] as? String {
            case "thinking":
                return (block["signature"] as? String)?.isEmpty == false
                    && block["thinking"] is String
            case "redacted_thinking":
                return block["data"] is String
            default:
                return false
            }
        }
    }

    /// `JSONValue` blocks (as stored on a turn or a `ChatMessage`) as wire
    /// dictionaries.
    static func wireThinkingBlocks(_ blocks: [JSONValue]?) -> [[String: Any]] {
        (blocks ?? []).compactMap { block in
            guard case .object = block, let data = try? JSONEncoder().encode(block) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    /// A wire thinking block as a `JSONValue`.
    static func jsonValue(ofThinkingBlock block: [String: Any]) -> JSONValue? {
        guard JSONSerialization.isValidJSONObject(block),
            let data = try? JSONSerialization.data(withJSONObject: block)
        else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// `messages` with the Anthropic-only `anthropic_thinking_blocks` field
    /// removed, for wires that would reject an unknown key.
    static func strippingThinkingBlocks(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.map { message in
            guard message["anthropic_thinking_blocks"] != nil else { return message }
            var copy = message
            copy.removeValue(forKey: "anthropic_thinking_blocks")
            return copy
        }
    }

    // MARK: - Content helpers

    /// Text of a chat `content` value: the string, or its text parts joined.
    static func text(of content: Any?) -> String? {
        if let string = content as? String { return string }
        guard let parts = content as? [[String: Any]] else { return nil }
        let texts = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        return texts.isEmpty ? nil : texts.joined()
    }

    static func imageURLs(of content: Any?) -> [String] {
        guard let parts = content as? [[String: Any]] else { return [] }
        return parts.compactMap { part in
            guard part["type"] as? String == "image_url" else { return nil }
            return (part["image_url"] as? [String: Any])?["url"] as? String
        }
    }

    /// Upstream `anthropicImageBlock(fromImageUrl:)`.
    static func imageBlock(fromImageURL url: String) -> [String: Any]? {
        if url.hasPrefix("data:") {
            let afterScheme = url.dropFirst("data:".count)
            guard let comma = afterScheme.firstIndex(of: ",") else { return nil }
            let mediaType = afterScheme[..<comma].split(separator: ";").first.map(String.init) ?? "image/png"
            let base64 = String(afterScheme[afterScheme.index(after: comma)...])
            guard !base64.isEmpty else { return nil }
            return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": base64]]
        }
        if url.hasPrefix("http://") || url.hasPrefix("https://") {
            return ["type": "image", "source": ["type": "url", "url": url]]
        }
        return nil
    }

    static func hasMeaningfulText(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Anthropic Messages SSE → OpenAI chat-completions `data:` lines.
struct IntelAnthropicSSETranslator {
    private var eventName: String?
    /// Content-block index → tool-call index (tool calls count from 0).
    private var toolIndexByBlock: [Int: Int] = [:]
    private var inputTokens = 0
    private var outputTokens = 0
    /// Content-block index → the `thinking` / `redacted_thinking` block being
    /// assembled (text and `signature_delta` accumulate on it).
    private var thinkingByBlock: [Int: [String: Any]] = [:]
    private var emittedThinking: Set<Int> = []

    /// Feed one raw SSE line; returns the OpenAI lines it produces.
    mutating func translate(_ line: String) throws -> [String] {
        if line.hasPrefix("event:") {
            eventName = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            return []
        }
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
            let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let type = event["type"] as? String ?? eventName ?? ""
        switch type {
        case "message_start":
            if let usage = (event["message"] as? [String: Any])?["usage"] as? [String: Any] {
                // Upstream `anthropicInputAccounting`: cached reads and writes
                // are part of the prompt.
                inputTokens =
                    (usage["input_tokens"] as? Int ?? 0) + (usage["cache_read_input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                outputTokens = usage["output_tokens"] as? Int ?? 0
            }
            return []
        case "content_block_start":
            if let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any],
                ["thinking", "redacted_thinking"].contains(block["type"] as? String)
            {
                thinkingByBlock[index] = block
                if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                    return [Self.chunk(delta: ["reasoning_content": thinking])]
                }
                return []
            }
            guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any],
                block["type"] as? String == "tool_use"
            else { return [] }
            let toolIndex = toolIndexByBlock.count
            toolIndexByBlock[index] = toolIndex
            return [
                Self.chunk(delta: [
                    "tool_calls": [[
                        "index": toolIndex,
                        "id": block["id"] as? String ?? "",
                        "type": "function",
                        "function": ["name": block["name"] as? String ?? "", "arguments": ""],
                    ]]
                ])
            ]
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
                return [Self.chunk(delta: ["content": text])]
            case "thinking_delta":
                guard let thinking = delta["thinking"] as? String, !thinking.isEmpty else { return [] }
                if let index = event["index"] as? Int {
                    var block = thinkingByBlock[index] ?? ["type": "thinking"]
                    block["thinking"] = (block["thinking"] as? String ?? "") + thinking
                    thinkingByBlock[index] = block
                }
                return [Self.chunk(delta: ["reasoning_content": thinking])]
            case "signature_delta":
                guard let index = event["index"] as? Int, let signature = delta["signature"] as? String
                else { return [] }
                var block = thinkingByBlock[index] ?? ["type": "thinking"]
                block["signature"] = (block["signature"] as? String ?? "") + signature
                thinkingByBlock[index] = block
                return []
            case "input_json_delta":
                guard let index = event["index"] as? Int, let toolIndex = toolIndexByBlock[index],
                    let partial = delta["partial_json"] as? String, !partial.isEmpty
                else { return [] }
                return [Self.chunk(delta: ["tool_calls": [["index": toolIndex, "function": ["arguments": partial]]]])]
            default:
                return []
            }
        case "content_block_stop":
            guard let index = event["index"] as? Int else { return [] }
            return emitThinking(index)
        case "message_delta":
            if let usage = event["usage"] as? [String: Any], let output = usage["output_tokens"] as? Int {
                outputTokens = output
            }
            // The output cap ended the message: say so in the OpenAI shape, so
            // a tool call cut off mid-arguments is refused (upstream #2108).
            if (event["delta"] as? [String: Any])?["stop_reason"] as? String == "max_tokens" {
                return [Self.line(["choices": [["index": 0, "delta": [String: Any](), "finish_reason": "length"]]])]
            }
            return []
        case "message_stop":
            // Any block whose stop event never came (upstream flushes the
            // rest here).
            let leftovers = thinkingByBlock.keys.sorted().flatMap { emitThinking($0) }
            return leftovers + [
                Self.line([
                    "usage": ["prompt_tokens": inputTokens, "completion_tokens": outputTokens]
                ]),
                "data: [DONE]",
            ]
        case "error":
            let error = event["error"] as? [String: Any]
            throw IntelAnthropicMessagesAdapter.Failure(
                message: (error?["message"] as? String) ?? "Anthropic stream error")
        default:
            return []
        }
    }

    /// The finished thinking block at `index`, once, as an
    /// `anthropic_thinking_block` delta field.
    private mutating func emitThinking(_ index: Int) -> [String] {
        guard let block = thinkingByBlock[index], emittedThinking.insert(index).inserted else { return [] }
        return [Self.chunk(delta: ["anthropic_thinking_block": block])]
    }

    private static func chunk(delta: [String: Any]) -> String {
        line(["choices": [["index": 0, "delta": delta]]])
    }

    private static func line(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return "data: " + String(decoding: data, as: UTF8.self)
    }
}

/// In-band hand-off of a captured Anthropic thinking block from the cloud
/// engine to the chat, on the same `\u{FFFE}` sentinel as the other hints so
/// generic filters drop it from visible text. The chat stores the block on
/// the assistant turn (`ChatTurn.anthropicThinkingBlocks`) and sends it back
/// with the turn on the next request.
enum StreamingAnthropicThinkingHint: Sendable {
    private static let prefix = "\u{FFFE}anthropic-thinking:"

    static func encode(_ block: JSONValue) -> String {
        let data = (try? JSONEncoder().encode(block)) ?? Data("{}".utf8)
        return prefix + String(decoding: data, as: UTF8.self)
    }

    static func decode(_ delta: String) -> JSONValue? {
        guard delta.hasPrefix(prefix) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(delta.dropFirst(prefix.count).utf8))
    }
}
