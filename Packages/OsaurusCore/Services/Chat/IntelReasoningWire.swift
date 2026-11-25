//
//  IntelReasoningWire.swift
//  osaurus
//
//  Stage 5d slice 7 (docs/COV_REAUDIT_STAGE5D_PROVIDER.md rows 23, 24, 26, 35).
//  Intel's compiled counterpart of the parts of upstream Classic's
//  `RemoteReasoningPolicy` (`Services/Provider/RemoteReasoningPolicy.swift`,
//  excluded from the Intel build because it is written against upstream's
//  `ChatMessage`) that `CloudChatEngine` needs: how a compatible provider sends
//  reasoning (inbound), how prior-turn reasoning must be re-sent (outbound),
//  and the request-side effort rules. The rules are upstream's, kept
//  identical so a later merge stays a read-only diff; only the message type
//  differs (the engine's wire dictionaries instead of `ChatMessage`).
//

import Foundation

struct IntelReasoningWire: Sendable, Equatable {
    /// How reasoning arrives in the streamed response.
    enum Inbound: Sendable, Equatable {
        /// A dedicated `delta.reasoning_content` field (DeepSeek, Qwen, vLLM).
        case separateField
        /// `<think>...</think>` inlined in `content` (MiniMax M-series).
        case inlineThink
    }

    /// How prior-turn reasoning is re-sent in multi-turn history.
    enum Outbound: Sendable, Equatable {
        /// Drop it (default: strict schemas reject unknown fields).
        case strip
        /// Keep `reasoning_content` on the wire (DeepSeek: the prompt template's
        /// `<think>` block and its KV cache, upstream issue #959).
        case echoField
        /// Fold it back into `content` as a `<think>` block (MiniMax's native
        /// history format).
        case embedAsThink
    }

    let inbound: Inbound
    let outbound: Outbound
    /// `nil` is Intel's built-in DeepSeek path (no provider record): an
    /// OpenAI-compatible chat-completions wire.
    let providerType: RemoteProviderType
    let host: String
    let model: String

    // MARK: Resolution

    static func resolve(providerType: RemoteProviderType?, host: String, model: String) -> IntelReasoningWire {
        let type = providerType ?? .openaiLegacy
        let (inbound, outbound) = behavior(providerType: type, host: host, model: model)
        return IntelReasoningWire(
            inbound: inbound, outbound: outbound, providerType: type, host: host, model: model)
    }

    private static func behavior(
        providerType: RemoteProviderType, host: String, model: String
    ) -> (Inbound, Outbound) {
        switch providerType {
        case .openaiLegacy, .azureOpenAI:
            // MiniMax matches by host or model id (hosted API and aggregators).
            if matches(needle: "minimax", host: host, model: model) { return (.inlineThink, .embedAsThink) }
            if matches(needle: "deepseek", host: host, model: model) { return (.separateField, .echoField) }
            return (.separateField, .strip)
        case .anthropic, .openResponses, .openAICodex, .gemini, .osaurus, .osaurusRouter:
            return (.separateField, .strip)
        }
    }

    private static func matches(needle: String, host: String, model: String) -> Bool {
        host.range(of: needle, options: .caseInsensitive) != nil
            || model.range(of: needle, options: .caseInsensitive) != nil
    }

    // MARK: Inbound (rows 23, 24)

    /// Mistral reasoning models stream `content` as an array of chunks
    /// (`{"type":"thinking","thinking":[{"type":"text","text":…}]}` and
    /// `{"type":"text","text":…}`) instead of a string. Thinking goes to the
    /// reasoning channel, text to the answer (upstream `DeltaContent`).
    /// Returns nil when `value` is not such an array.
    static func structuredContent(_ value: Any?) -> (visible: String, thinking: String)? {
        guard let chunks = value as? [[String: Any]] else { return nil }
        var visible = ""
        var thinking = ""
        for chunk in chunks {
            if (chunk["type"] as? String) == "thinking" {
                for part in chunk["thinking"] as? [[String: Any]] ?? [] {
                    thinking += part["text"] as? String ?? ""
                }
            } else {
                visible += chunk["text"] as? String ?? ""
            }
        }
        return (visible, thinking)
    }

    // MARK: Outbound (rows 24, 26)

    /// `reasoning` for an assistant history message, per this provider's
    /// outbound policy. Applies `content` folding for `embedAsThink` and the
    /// `reasoning_content` echo for `echoField`; strip leaves `message` as is.
    func applyingOutbound(reasoning: String?, to message: [String: Any]) -> [String: Any] {
        guard let reasoning, (message["role"] as? String) == "assistant" else { return message }
        var out = message
        switch outbound {
        case .strip:
            break
        case .echoField:
            out["reasoning_content"] = reasoning
        case .embedAsThink:
            // Parts arrays (media) are left alone: only a text answer is folded.
            guard out["content"] is String || out["content"] == nil else { break }
            let base = (out["content"] as? String) ?? ""
            if reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if base.isEmpty { out.removeValue(forKey: "content") }
            } else {
                out["content"] = "<think>\n\(reasoning)\n</think>\n\(base)"
            }
        }
        return out
    }

    // MARK: Request-side effort (row 35)

    /// Whether a `reasoning: { effort }` object may ride alongside
    /// `reasoning_effort`. Mistral rejects the sibling object with HTTP 422
    /// (`extra_forbidden`) and OpenAI proper reads only `reasoning_effort`.
    var allowsReasoningObject: Bool {
        switch providerType {
        case .openaiLegacy:
            let lowered = host.lowercased()
            return !lowered.contains("openai.com") && !lowered.contains("mistral")
        case .azureOpenAI, .anthropic, .openResponses, .openAICodex, .gemini, .osaurus, .osaurusRouter:
            return false
        }
    }

    /// Upstream `dsv4Effort` effort half: the direct-rail aliases (`instruct`,
    /// `none`, `off`, ...) are local controls, not wire values, except `none`
    /// on Mistral and on the official OpenAI host for models whose table has
    /// it. Returns the normalized value to send, or nil.
    static func wireEffort(host: String, model: String, effort: String?) -> String? {
        guard let normalized = effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !normalized.isEmpty
        else { return nil }
        let lowered = host.lowercased()
        // Mistral's public API accepts `reasoning_effort: "none"` as a real value.
        if lowered.contains("mistral") { return normalized }
        // The official OpenAI API documents `none` as a real effort for GPT-5.6
        // and some GPT-6 models; stripping it would re-enable default reasoning.
        if normalized == "none", lowered.contains("openai.com"),
            ModelPickerItem.officialOpenAIAcceptsNoneEffort(modelId: model)
        {
            return normalized
        }
        switch normalized {
        case "instruct", "chat", "none", "no_think", "nothink", "off", "disabled", "false":
            return nil
        default:
            return normalized
        }
    }

    /// Upstream `acceptedEffort`: DeepSeek takes only its fixed alias set.
    static func acceptedEffort(providerType: RemoteProviderType, host: String, effort: String?) -> String? {
        guard let effort = effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !effort.isEmpty
        else { return nil }
        switch providerType {
        case .openaiLegacy, .azureOpenAI:
            if host.lowercased().contains("deepseek") {
                let accepted: Set<String> = ["low", "medium", "high", "max", "xhigh"]
                return accepted.contains(effort) ? effort : nil
            }
            return effort
        case .anthropic, .openResponses, .openAICodex, .gemini, .osaurus, .osaurusRouter:
            return effort
        }
    }

    /// The `reasoning_effort` value to put on a chat-completions request.
    func chatEffort(_ effort: String?) -> String? {
        Self.acceptedEffort(
            providerType: providerType, host: host,
            effort: Self.wireEffort(host: host, model: model, effort: effort))
    }
}
