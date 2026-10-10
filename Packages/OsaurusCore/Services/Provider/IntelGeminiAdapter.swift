//
//  IntelGeminiAdapter.swift
//  OsaurusCore — Intel fork
//
//  Google Gemini `streamGenerateContent` for Intel's cloud engine
//  (W-provider-wire-formats, 2026-10-10), translated at both edges like
//  `IntelAnthropicMessagesAdapter`:
//
//  - `makeRequest` follows upstream `toGeminiRequest`: system →
//    `systemInstruction`; user text and `image_url` data parts →
//    `inlineData`; assistant tool calls → `functionCall` parts (with the
//    call's `thoughtSignature`, which newer Gemini models require back within
//    the turn); tool results batched into one user content of
//    `functionResponse` parts; tool schemas cleaned with upstream's
//    `geminiCompatibleSchema` rules; `tool_choice` → `toolConfig`.
//    **Intel difference:** `functionResponse.name` is the called function's
//    name, looked up from the preceding call. Upstream passes the
//    `tool_call_id` there (a random `gemini-…` id), which Gemini matches
//    against function names.
//  - `IntelGeminiSSETranslator` turns response chunks into OpenAI `data:`
//    lines. Thought parts are skipped (as upstream). Each function call
//    becomes a complete `tool_calls` delta with a generated id and the
//    signature in `gemini_thought_signature`. A `SAFETY` finish fails the
//    stream.
//

import Foundation

enum IntelGeminiAdapter {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Extra key carried on an OpenAI-shaped tool call so the engine can
    /// replay the Gemini thought signature (Intel's wire dicts only).
    static let thoughtSignatureKey = "gemini_thought_signature"

    /// `models/gemini-2.5-pro` (as `/models` lists it) and `gemini-2.5-pro`
    /// both address the same model.
    static func bareModel(_ model: String) -> String {
        model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
    }

    /// `<base>/models/<model>:streamGenerateContent?alt=sse` from the
    /// provider's `/models` endpoint URL.
    static func streamURL(modelsEndpoint: String, model: String) -> String {
        let base = modelsEndpoint.hasSuffix("/") ? String(modelsEndpoint.dropLast()) : modelsEndpoint
        return "\(base)/\(bareModel(model)):streamGenerateContent?alt=sse"
    }

    static func makeRequest(chatCompletions body: [String: Any]) throws -> [String: Any] {
        let messages = body["messages"] as? [[String: Any]] ?? []
        var contents: [[String: Any]] = []
        var system: [String] = []
        var pendingResponses: [[String: Any]] = []
        var functionNameByCallId: [String: String] = [:]

        func flush() {
            guard !pendingResponses.isEmpty else { return }
            contents.append(["role": "user", "parts": pendingResponses])
            pendingResponses = []
        }

        for message in messages {
            let role = message["role"] as? String ?? "user"
            switch role {
            case "system", "developer":
                if let text = IntelAnthropicMessagesAdapter.text(of: message["content"]), !text.isEmpty {
                    system.append(text)
                }
            case "user":
                flush()
                var parts: [[String: Any]] = []
                if let text = IntelAnthropicMessagesAdapter.text(of: message["content"]), !text.isEmpty {
                    parts.append(["text": text])
                }
                for url in IntelAnthropicMessagesAdapter.imageURLs(of: message["content"]) {
                    if let inline = inlineData(fromDataURL: url) { parts.append(["inlineData": inline]) }
                }
                if !parts.isEmpty { contents.append(["role": "user", "parts": parts]) }
            case "assistant":
                flush()
                var parts: [[String: Any]] = []
                if let text = IntelAnthropicMessagesAdapter.text(of: message["content"]), !text.isEmpty {
                    parts.append(["text": text])
                }
                for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                    let function = call["function"] as? [String: Any] ?? [:]
                    let name = function["name"] as? String ?? ""
                    if let id = call["id"] as? String { functionNameByCallId[id] = name }
                    let args =
                        ((function["arguments"] as? String)?.data(using: .utf8)).flatMap {
                            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                        } ?? [:]
                    var part: [String: Any] = ["functionCall": ["name": name, "args": args]]
                    if let signature = call[thoughtSignatureKey] as? String, !signature.isEmpty {
                        part["thoughtSignature"] = signature
                    }
                    parts.append(part)
                }
                if !parts.isEmpty { contents.append(["role": "model", "parts": parts]) }
            case "tool":
                guard let callId = message["tool_call_id"] as? String else { continue }
                let content = IntelAnthropicMessagesAdapter.text(of: message["content"]) ?? ""
                let response: [String: Any] =
                    (content.data(using: .utf8).flatMap {
                        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                    }) ?? ["result": content]
                pendingResponses.append([
                    "functionResponse": ["name": functionNameByCallId[callId] ?? callId, "response": response]
                ])
            default:
                flush()
                if let text = IntelAnthropicMessagesAdapter.text(of: message["content"]), !text.isEmpty {
                    contents.append(["role": "user", "parts": [["text": text]]])
                }
            }
        }
        flush()

        var request: [String: Any] = ["contents": contents]
        if !system.isEmpty { request["systemInstruction"] = ["parts": [["text": system.joined(separator: "\n")]]] }
        if let tools = body["tools"] as? [[String: Any]], !tools.isEmpty {
            let declarations: [[String: Any]] = tools.compactMap { tool in
                guard let function = tool["function"] as? [String: Any], let name = function["name"] as? String
                else { return nil }
                var declaration: [String: Any] = ["name": name]
                if let description = function["description"] as? String { declaration["description"] = description }
                if let parameters = function["parameters"] { declaration["parameters"] = compatibleSchema(parameters) }
                return declaration
            }
            request["tools"] = [["functionDeclarations": declarations]]
        }
        if let choice = body["tool_choice"] {
            let mode: String
            switch choice {
            case let value as String:
                mode = value == "none" ? "NONE" : value == "required" ? "ANY" : "AUTO"
            case is [String: Any]:
                mode = "ANY"
            default:
                mode = "AUTO"
            }
            request["toolConfig"] = ["functionCallingConfig": ["mode": mode]]
        }
        var generation: [String: Any] = [:]
        if let temperature = body["temperature"] { generation["temperature"] = temperature }
        if let maxTokens = (body["max_tokens"] ?? body["max_completion_tokens"]) as? Int {
            generation["maxOutputTokens"] = maxTokens
        }
        if let topP = body["top_p"] { generation["topP"] = topP }
        if let stop = body["stop"] { generation["stopSequences"] = stop }
        if !generation.isEmpty { request["generationConfig"] = generation }
        return request
    }

    /// `data:<mime>;base64,<data>` → `{mimeType, data}` (upstream reads data
    /// URLs only; http images are not fetched).
    static func inlineData(fromDataURL url: String) -> [String: Any]? {
        guard url.hasPrefix("data:"), let semicolon = url.firstIndex(of: ";"), let comma = url.firstIndex(of: ",")
        else { return nil }
        let mimeType = String(url[url.index(url.startIndex, offsetBy: 5) ..< semicolon])
        let data = String(url[url.index(after: comma)...])
        guard !data.isEmpty else { return nil }
        return ["mimeType": mimeType, "data": data]
    }

    // MARK: - Schema (upstream `geminiCompatibleSchema`)

    static let unsupportedSchemaKeys: Set<String> = [
        "additionalProperties",
        "$ref", "$defs", "$schema", "$id", "definitions",
        "const", "oneOf", "allOf", "not", "if", "then", "else",
        "patternProperties", "propertyNames",
        "contentEncoding", "contentMediaType",
        "default", "examples", "title", "readOnly", "writeOnly",
        "pattern", "multipleOf", "uniqueItems",
        "exclusiveMinimum", "exclusiveMaximum",
        "minLength", "maxLength",
    ]

    static func compatibleSchema(_ value: Any) -> Any {
        if let array = value as? [Any] { return array.map(compatibleSchema) }
        guard let object = value as? [String: Any] else { return value }
        var sanitized: [String: Any] = [:]
        for (key, child) in object where !unsupportedSchemaKeys.contains(key) {
            sanitized[key] = compatibleSchema(child)
        }
        // `type: ["string", "null"]` → `type: "string"` + `nullable: true`.
        if let types = sanitized["type"] as? [Any] {
            let names = types.compactMap { $0 as? String }
            let scalars = names.filter { $0 != "null" }
            if names.count == types.count, names.contains("null"), scalars.count == 1 {
                sanitized["type"] = scalars[0]
                sanitized["nullable"] = true
            }
        }
        // `properties` / `required` without a type mean an object.
        if sanitized["type"] == nil, sanitized["properties"] != nil || sanitized["required"] != nil {
            sanitized["type"] = "object"
        }
        // …and are only valid on objects.
        if let type = sanitized["type"] as? String, type.lowercased() != "object" {
            sanitized["properties"] = nil
            sanitized["required"] = nil
        }
        // `required` may only name declared properties.
        if let required = sanitized["required"] as? [Any] {
            let declared = Set((sanitized["properties"] as? [String: Any])?.keys.map { $0 } ?? [])
            let filtered = required.compactMap { $0 as? String }.filter { declared.contains($0) }
            if filtered.count < required.count {
                sanitized["required"] = filtered.isEmpty ? nil : filtered
            }
        }
        return sanitized
    }
}

/// Gemini `streamGenerateContent?alt=sse` chunks → OpenAI `data:` lines.
struct IntelGeminiSSETranslator {
    private var toolCount = 0
    private var promptTokens = 0
    private var completionTokens = 0

    mutating func translate(_ line: String) throws -> [String] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
            let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        if let error = chunk["error"] as? [String: Any] {
            throw IntelGeminiAdapter.Failure(message: error["message"] as? String ?? "Gemini stream error")
        }
        var out: [String] = []
        // Usage rides on chunks (Gemini sends no `[DONE]`); the engine keeps
        // the latest frame.
        if let usage = chunk["usageMetadata"] as? [String: Any] {
            promptTokens = usage["promptTokenCount"] as? Int ?? promptTokens
            completionTokens = usage["candidatesTokenCount"] as? Int ?? completionTokens
            out.append(Self.line(["usage": ["prompt_tokens": promptTokens, "completion_tokens": completionTokens]]))
        }
        let candidate = (chunk["candidates"] as? [[String: Any]])?.first
        for part in (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? [] {
            if part["thought"] as? Bool == true { continue }
            if let text = part["text"] as? String, !text.isEmpty, toolCount == 0 {
                out.append(Self.chunk(delta: ["content": text]))
            } else if let call = part["functionCall"] as? [String: Any] {
                let args = call["args"] ?? [String: Any]()
                let argsData =
                    (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data("{}".utf8)
                var toolCall: [String: Any] = [
                    "index": toolCount,
                    "id": "gemini-\(UUID().uuidString.prefix(8))",
                    "type": "function",
                    "function": [
                        "name": call["name"] as? String ?? "",
                        "arguments": String(decoding: argsData, as: UTF8.self),
                    ],
                ]
                if let signature = part["thoughtSignature"] as? String ?? call["thoughtSignature"] as? String {
                    toolCall[IntelGeminiAdapter.thoughtSignatureKey] = signature
                }
                toolCount += 1
                out.append(Self.chunk(delta: ["tool_calls": [toolCall]]))
            }
        }
        if candidate?["finishReason"] as? String == "SAFETY" {
            throw IntelGeminiAdapter.Failure(message: "Content blocked by safety settings.")
        }
        return out
    }

    private static func chunk(delta: [String: Any]) -> String {
        line(["choices": [["index": 0, "delta": delta]]])
    }

    private static func line(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return "data: " + String(decoding: data, as: UTF8.self)
    }
}
