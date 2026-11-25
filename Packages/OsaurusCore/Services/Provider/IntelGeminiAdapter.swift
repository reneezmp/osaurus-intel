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
//    `reasoning_effort` → `generationConfig.thinkingConfig` through
//    `GeminiReasoningContract` (upstream #3115, 2026-10-27).
//    **Intel difference:** `functionResponse.name` is the called function's
//    name, looked up from the preceding call. Upstream passes the
//    `tool_call_id` there (a random `gemini-…` id), which Gemini matches
//    against function names.
//  - `IntelGeminiSSETranslator` turns response chunks into OpenAI `data:`
//    lines. Thought parts are skipped (as upstream). Each function call
//    becomes a complete `tool_calls` delta with a generated id and the
//    signature in `gemini_thought_signature`. A `SAFETY` finish fails the
//    stream; `MAX_TOKENS` becomes `finish_reason: "length"` (row 27), so a
//    cut reply shows the output-limit notice and a call cut mid-arguments is
//    refused.
//  - Image models (Nano Banana, row 29; upstream `geminiImageGenerateContent`)
//    use the non-streaming `generateContent` URL with `responseModalities`
//    and `imageConfig` from the model options. The translator accepts that
//    single JSON body (`wholeBody`) and turns inline image parts into the
//    same data-URI markdown upstream writes (`image|ts:SIG` alt text), which
//    `makeRequest` converts back to `inlineData` parts on the next turn.
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

    /// Image-capable chat models (upstream `isImageCapableModel`).
    static func isImageCapableModel(_ modelName: String) -> Bool {
        Gemini31FlashImageProfile.matches(modelId: modelName) || GeminiProImageProfile.matches(modelId: modelName)
            || GeminiFlashImageProfile.matches(modelId: modelName)
    }

    /// `<base>/models/<model>:generateContent` (upstream
    /// `geminiImageGenerateContent`: image models don't stream).
    static func generateURL(modelsEndpoint: String, model: String) -> String {
        let base = modelsEndpoint.hasSuffix("/") ? String(modelsEndpoint.dropLast()) : modelsEndpoint
        return "\(base)/\(bareModel(model)):generateContent"
    }

    /// `<base>/models/<model>:streamGenerateContent?alt=sse` from the
    /// provider's `/models` endpoint URL.
    static func streamURL(modelsEndpoint: String, model: String) -> String {
        let base = modelsEndpoint.hasSuffix("/") ? String(modelsEndpoint.dropLast()) : modelsEndpoint
        return "\(base)/\(bareModel(model)):streamGenerateContent?alt=sse"
    }

    static func makeRequest(
        chatCompletions body: [String: Any], modelOptions: [String: ModelOptionValue]? = nil
    ) throws -> [String: Any] {
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
                    // Upstream `extractInlineImages`: an image the model made
                    // earlier goes back as `inlineData` (with its signature).
                    parts.append(contentsOf: inlineImageParts(from: text))
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
        // Agent generation overrides (upstream #3226): `topK` and `seed`.
        if let topK = body["top_k"] { generation["topK"] = topK }
        if let seed = body["seed"] { generation["seed"] = seed }
        if let stop = body["stop"] { generation["stopSequences"] = stop }
        // JSON mode (upstream `toGeminiRequest`): `response_format` json_object
        // becomes `responseMimeType`.
        if let format = body["response_format"] as? [String: Any], (format["type"] as? String) == "json_object" {
            generation["responseMimeType"] = "application/json"
        }
        // Upstream #3115: the picker's effort becomes Gemini's native thinking
        // control, `thinkingLevel` on Gemini 3 and a `thinkingBudget` on 2.5;
        // an effort the model doesn't document sends nothing.
        if let model = body["model"] as? String,
            let thinking = GeminiReasoningContract.thinkingConfig(
                forModelId: model, effort: body["reasoning_effort"] as? String)
        {
            generation["thinkingConfig"] = thinking
        }
        // Row 29 (upstream `toGeminiRequest`): image models ask for image
        // output and take the picker's aspect ratio and resolution.
        if let model = body["model"] as? String, isImageCapableModel(model) {
            generation["responseModalities"] =
                modelOptions?["outputType"]?.stringValue == "imageOnly" ? ["IMAGE"] : ["TEXT", "IMAGE"]
            let ratio = modelOptions?["aspectRatio"]?.stringValue
            let size = modelOptions?["imageSize"]?.stringValue
            var imageConfig: [String: Any] = [:]
            if let ratio, ratio != "auto" { imageConfig["aspectRatio"] = ratio }
            if let size, size != "auto" { imageConfig["imageSize"] = size }
            if !imageConfig.isEmpty { generation["imageConfig"] = imageConfig }
        }
        if !generation.isEmpty { request["generationConfig"] = generation }
        return request
    }

    // MARK: - Inline images in history (upstream `imageMarkdown` / `extractInlineImages`)

    /// Markdown for an inline image, the thought signature in the alt text.
    static func imageMarkdown(mimeType: String, data: String, thoughtSignature: String?) -> String {
        let alt = thoughtSignature.map { "image|ts:\($0)" } ?? "image"
        return "\n\n![\(alt)](data:\(mimeType);base64,\(data))\n\n"
    }

    /// Splits assistant text into `text` and `inlineData` parts, recovering the
    /// signature from `image|ts:SIG` alt text. Text without a data-URI image
    /// is one `text` part, unchanged.
    static func inlineImageParts(from text: String) -> [[String: Any]] {
        let pattern = #"!\[([^\]]*)\]\(data:([^;]+);base64,([^)]+)\)"#
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern),
            case let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)),
            !matches.isEmpty
        else { return [["text": text]] }
        var parts: [[String: Any]] = []
        var lastEnd = 0
        for match in matches {
            if match.range.location > lastEnd {
                let before = ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(["text": before]) }
            }
            let alt = ns.substring(with: match.range(at: 1))
            var part: [String: Any] = [
                "inlineData": [
                    "mimeType": ns.substring(with: match.range(at: 2)), "data": ns.substring(with: match.range(at: 3)),
                ]
            ]
            if alt.hasPrefix("image|ts:") { part["thoughtSignature"] = String(alt.dropFirst("image|ts:".count)) }
            parts.append(part)
            lastEnd = match.range.location + match.range.length
        }
        if lastEnd < ns.length {
            let after = ns.substring(from: lastEnd)
            if !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(["text": after]) }
        }
        return parts.isEmpty ? [["text": text]] : parts
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
    /// Image models answer `generateContent` with one JSON body instead of an
    /// SSE stream: lines are gathered until they parse (row 29).
    private let wholeBody: Bool
    private var bodyBuffer = ""

    init(wholeBody: Bool = false) { self.wholeBody = wholeBody }

    mutating func translate(_ line: String) throws -> [String] {
        let payload: String
        if wholeBody {
            bodyBuffer += line
            guard bodyBuffer.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("}") else { return [] }
            payload = bodyBuffer
        } else {
            guard line.hasPrefix("data:") else { return [] }
            payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        }
        guard let data = payload.data(using: .utf8),
            let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        bodyBuffer = ""
        return try translate(chunk: chunk)
    }

    private mutating func translate(chunk: [String: Any]) throws -> [String] {
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
            } else if let inline = part["inlineData"] as? [String: Any],
                let mime = inline["mimeType"] as? String, let b64 = inline["data"] as? String, toolCount == 0
            {
                // Row 29: an image the model made, as the markdown upstream writes.
                out.append(
                    Self.chunk(
                        delta: [
                            "content": IntelGeminiAdapter.imageMarkdown(
                                mimeType: mime, data: b64, thoughtSignature: part["thoughtSignature"] as? String)
                        ]))
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
        // Row 27 (upstream `handleGeminiEvent`): the output cap is `length` in
        // the OpenAI vocabulary, so the engine shows its output-limit notice
        // and refuses a tool call cut off mid-arguments.
        if candidate?["finishReason"] as? String == "MAX_TOKENS" {
            out.append(Self.line(["choices": [["index": 0, "delta": [String: Any](), "finish_reason": "length"]]]))
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
