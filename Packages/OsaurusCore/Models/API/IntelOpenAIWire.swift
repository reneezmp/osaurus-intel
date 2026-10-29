//
//  IntelOpenAIWire.swift
//  osaurus
//
//  Upstream's OpenAI streaming and error wire types (`Models/API/OpenAIAPI.swift`,
//  excluded on Intel because its request / message types diverge from
//  Intel's engine). Copied verbatim so the local API server's chunks are
//  byte-for-byte upstream's (`W-server-api` stage 2, docs/SERVER_API_INTEL.md).
//  `ToolChoiceOption` is upstream's too, replacing Intel's synthesized-Codable
//  enum, which could not decode `"tool_choice": "auto"`.
//

import Foundation

/// Token usage information
struct Usage: Codable, Sendable {
    let prompt_tokens: Int
    let completion_tokens: Int
    let total_tokens: Int
    let tokens_per_second: Double?
    /// OpenAI Chat Completions prompt-cache split (`cached_tokens` is the
    /// subset of `prompt_tokens` served from the prompt cache at the
    /// discounted rate). Also emitted by Azure, OpenRouter, xAI, DeepSeek
    /// (`prompt_cache_hit_tokens` is NOT mapped here). Optional and omitted
    /// when nil so the server-side writers keep their exact wire bytes.
    var prompt_tokens_details: PromptTokensDetails? = nil

    struct PromptTokensDetails: Codable, Sendable, Equatable {
        var cached_tokens: Int? = nil
        var audio_tokens: Int? = nil

        init(cached_tokens: Int? = nil, audio_tokens: Int? = nil) {
            self.cached_tokens = cached_tokens
            self.audio_tokens = audio_tokens
        }
    }

    init(
        prompt_tokens: Int,
        completion_tokens: Int,
        total_tokens: Int,
        tokens_per_second: Double? = nil,
        prompt_tokens_details: PromptTokensDetails? = nil
    ) {
        self.prompt_tokens = prompt_tokens
        self.completion_tokens = completion_tokens
        self.total_tokens = total_tokens
        self.tokens_per_second = tokens_per_second
        self.prompt_tokens_details = prompt_tokens_details
    }

    /// `prompt_tokens_details` for a local response whose prompt prefix was
    /// restored from the runtime's prefix cache: `cached_tokens` clamped to
    /// `[0, promptTokens]`. `nil` (field omitted, wire unchanged) for a cold
    /// prompt.
    static func cachedPromptDetails(_ cachedTokens: Int?, promptTokens: Int) -> PromptTokensDetails? {
        guard let cachedTokens, cachedTokens > 0 else { return nil }
        return PromptTokensDetails(cached_tokens: min(cachedTokens, max(0, promptTokens)))
    }

    /// Provider-reported prompt-cache hits, clamped to `[0, prompt_tokens]`.
    /// `nil` when the provider sent no `prompt_tokens_details.cached_tokens`.
    var cachedPromptTokens: Int? {
        guard let cached = prompt_tokens_details?.cached_tokens else { return nil }
        return min(max(0, cached), max(0, prompt_tokens))
    }
}

// MARK: - Streaming Response Structures

/// Delta content for streaming
struct DeltaContent: Codable, Sendable {
    let role: String?
    let content: String?
    let refusal: String?
    /// Incremental tool_calls information (OpenAI-compatible)
    let tool_calls: [DeltaToolCall]?
    /// Reasoning/thinking text streamed in a separate channel by OpenAI-compatible
    /// providers (DeepSeek, Qwen, Together, vLLM). Absent on providers that only
    /// emit content. The stream parser wraps these chunks with synthetic `<think>`
    /// tags so the rest of the pipeline can route them as reasoning.
    let reasoning_content: String?

    init(
        role: String? = nil,
        content: String? = nil,
        refusal: String? = nil,
        tool_calls: [DeltaToolCall]? = nil,
        reasoning_content: String? = nil
    ) {
        self.role = role
        self.content = content
        self.refusal = refusal
        self.tool_calls = tool_calls
        self.reasoning_content = reasoning_content
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, refusal, tool_calls, reasoning_content
    }

    /// One entry of Mistral's structured `content` array. Mistral streams
    /// reasoning models as `content: [{type:"thinking", thinking:[{type:"text",
    /// text:…}]}, {type:"text", text:…}]` rather than the OpenAI-standard plain
    /// `content` string plus separate `reasoning_content`. Decoded here so
    /// thinking chunks route to `reasoning_content` and text chunks to `content`,
    /// letting the rest of the streaming pipeline handle Mistral like every other
    /// separate-channel reasoning provider.
    private struct MistralContentChunk: Decodable {
        let type: String?
        let text: String?
        let thinking: [InnerText]?

        struct InnerText: Decodable {
            let type: String?
            let text: String?
        }
    }

    init(from decoder: Decoder) throws {
        // Preserve the synthesized decoder's throwing `decodeIfPresent`
        // semantics for every field: a present-but-malformed value must throw so
        // the stream parser's split-JSON recovery path can retry, rather than
        // being silently dropped. Only `content` adds a string-or-array fallback.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decodeIfPresent(String.self, forKey: .role)
        self.refusal = try container.decodeIfPresent(String.self, forKey: .refusal)
        self.tool_calls = try container.decodeIfPresent([DeltaToolCall].self, forKey: .tool_calls)
        let explicitReasoning = try container.decodeIfPresent(String.self, forKey: .reasoning_content)

        do {
            // Standard OpenAI-compatible shape: `content` is a string (or absent).
            self.content = try container.decodeIfPresent(String.self, forKey: .content)
            self.reasoning_content = explicitReasoning
        } catch DecodingError.typeMismatch(_, _) {
            // Mistral reasoning models stream `content` as a structured array of
            // thinking/text chunks. Route thinking to `reasoning_content` and
            // text to `content`. A genuine structural error (not a type mismatch)
            // propagates from here so recovery can retry.
            let chunks = try container.decode([MistralContentChunk].self, forKey: .content)
            var visible = ""
            var thinking = ""
            for chunk in chunks {
                if chunk.type == "thinking" {
                    for part in chunk.thinking ?? [] { thinking += part.text ?? "" }
                } else {
                    visible += chunk.text ?? ""
                }
            }
            self.content = visible.isEmpty ? nil : visible
            let mergedReasoning = (explicitReasoning ?? "") + thinking
            self.reasoning_content = mergedReasoning.isEmpty ? nil : mergedReasoning
        }
    }
}

/// Streaming choice
struct StreamChoice: Codable, Sendable {
    let index: Int
    /// Optional on decode: OpenAI-compatible providers (DeepSeek among them)
    /// omit `delta` on the final finish/usage chunk. Osaurus's own stream
    /// writers always populate it.
    let delta: DeltaContent?
    let finish_reason: String?

    init(index: Int, delta: DeltaContent, finish_reason: String?) {
        self.index = index
        self.delta = delta
        self.finish_reason = finish_reason
    }
}

/// Chat completion chunk for streaming
struct ChatCompletionChunk: Codable, Sendable {
    let id: String
    var object: String = "chat.completion.chunk"
    let created: Int
    let model: String
    let choices: [StreamChoice]
    var system_fingerprint: String? = nil
    /// Included only in the first chunk; see `ChatCompletionResponse.prefix_hash`.
    var prefix_hash: String? = nil
    /// Final usage chunk (OpenAI `stream_options.include_usage`). Populated
    /// only on the dedicated penultimate SSE chunk; nil on every other.
    var usage: Usage? = nil
    // Upstream's `osaurus_prefill` (local prefill progress, MLX) and
    // `osaurus_artifacts` (hosted shared-agent runs, workspaces) extension
    // fields are left out on Intel.
}

// MARK: - Error Response

/// OpenAI-compatible error response
struct OpenAIError: Codable, Error, Sendable {
    let error: ErrorDetail

    struct ErrorDetail: Codable, Sendable {
        let message: String
        let type: String
        let param: String?
        let code: String?
    }
}

struct DeltaToolCall: Codable, Sendable {
    let index: Int?
    let id: String?
    let type: String?
    let function: DeltaToolCallFunction?
}

struct DeltaToolCallFunction: Codable, Sendable {
    let name: String?
    let arguments: String?
}

// MARK: - Tool choice

enum ToolChoiceOption: Codable, Sendable, Equatable {
    case auto
    case none
    case required
    case function(FunctionName)

    struct FunctionName: Codable, Sendable, Equatable {
        let type: String
        let function: Name
    }
    struct Name: Codable, Sendable, Equatable { let name: String }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            switch str {
            case "auto": self = .auto
            case "none": self = .none
            case "required": self = .required
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription:
                        "Unsupported tool_choice string '\(str)'. Expected 'auto', 'none', 'required', or a typed function selector."
                )
            }
            return
        }
        let obj = try container.decode(FunctionName.self)
        self = .function(obj)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto:
            try container.encode("auto")
        case .none:
            try container.encode("none")
        case .required:
            try container.encode("required")
        case .function(let obj):
            try container.encode(obj)
        }
    }
}

// MARK: - Legacy completions request (upstream)

struct CompletionRequest: Decodable, Sendable {
    let model: String
    /// Raw prompt sent to the generation path. For OpenAI insertion/FIM
    /// clients that send `prefix` instead of `prompt`, this falls back to the
    /// prefix because the local raw completion contract accepts one string.
    let prompt: String
    /// OpenAI-compatible FIM/insertion request fields. `suffix` and `middle`
    /// are decoded so callers get a precise compatibility error instead of the
    /// field being silently ignored by the raw left-to-right completion path.
    let prefix: String?
    let suffix: String?
    let middle: String?
    let maxTokens: Int?
    let temperature: Float?
    let topP: Float?
    let topK: Int?
    let stop: [String]
    let stream: Bool?
    let streamOptions: StreamOptions?

    private enum CodingKeys: String, CodingKey {
        case model, prompt, prefix, suffix, middle, temperature, stop, stream
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case topK = "top_k"
        case streamOptions = "stream_options"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
        let decodedPrefix = Self.decodeStringOrFirstArray(from: c, forKey: .prefix)
        prefix = decodedPrefix
        suffix = Self.decodeStringOrFirstArray(from: c, forKey: .suffix)
        middle = Self.decodeStringOrFirstArray(from: c, forKey: .middle)
        // `prompt` may be a string or an array of strings. FIM clients send a
        // single string; for an array we take the first entry. Some OpenAI-
        // compatible insertion clients use `prefix` instead of `prompt`; treat
        // that as the raw prompt only when `prompt` is absent.
        prompt = Self.decodeStringOrFirstArray(from: c, forKey: .prompt) ?? decodedPrefix ?? ""
        maxTokens = try? c.decodeIfPresent(Int.self, forKey: .maxTokens)
        temperature = try? c.decodeIfPresent(Float.self, forKey: .temperature)
        topP = try? c.decodeIfPresent(Float.self, forKey: .topP)
        topK = try? c.decodeIfPresent(Int.self, forKey: .topK)
        // `stop` may be a string or an array of strings.
        if let s = try? c.decode(String.self, forKey: .stop) {
            stop = [s]
        } else if let arr = try? c.decode([String].self, forKey: .stop) {
            stop = arr
        } else {
            stop = []
        }
        stream = try? c.decodeIfPresent(Bool.self, forKey: .stream)
        streamOptions = try c.decodeIfPresent(StreamOptions.self, forKey: .streamOptions)
    }

    private static func decodeStringOrFirstArray(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String? {
        if let s = try? container.decode(String.self, forKey: key) {
            return s
        }
        if let arr = try? container.decode([String].self, forKey: key) {
            return arr.first
        }
        return nil
    }

    /// FIM completions are short; default generously when the client omits
    /// `max_tokens` (OpenAI's legacy default of 16 is too small for most
    /// autocomplete use).
    var resolvedMaxTokens: Int { maxTokens ?? 256 }

    /// The current local raw-completion generation contract accepts one prompt
    /// string. A prompt that already contains model-native FIM tokens is routed
    /// verbatim; separate `suffix` / `middle` fields cannot be honored without
    /// a runtime-level suffix channel, so reject them explicitly instead of
    /// ignoring suffix context and generating a misleading left-to-right
    /// continuation.
    var unsupportedFIMReason: String? {
        var unsupportedFields: [String] = []
        if let suffix, !suffix.isEmpty {
            unsupportedFields.append("suffix")
        }
        if let middle, !middle.isEmpty {
            unsupportedFields.append("middle")
        }
        guard !unsupportedFields.isEmpty else { return nil }
        let fields = unsupportedFields.map { "'\($0)'" }.joined(separator: ", ")
        return "FIM fields \(fields) are not supported by the local /v1/completions runtime. "
            + "Send a single raw prompt containing the model's native FIM tokens, or omit "
            + "separate suffix/middle fields."
    }
}
