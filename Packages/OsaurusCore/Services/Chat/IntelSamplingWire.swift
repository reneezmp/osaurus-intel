//
//  IntelSamplingWire.swift
//  osaurus
//
//  Maps a turn's explicit sampling (`ChatExplicitSampling`) onto the request
//  body a cloud provider will actually accept (`W-agent-generation-overrides`,
//  upstream #3226 / #3233 / #3246).
//
//  Upstream's `RemoteProviderService` encodes `top_k`, `min_p` and
//  `repetition_penalty` on OpenAI-compatible chat requests and throws
//  `RemoteProviderServiceError.unsupportedParameter` ("This provider protocol
//  cannot represent ...") when the selected protocol cannot carry an explicit
//  value. Intel builds its request bodies in `CloudChatEngine`, so the same
//  rules live here as one pure function:
//
//  - Only explicit values are sent. Nothing is invented for providers.
//  - Temperature and Top P are "soft": a provider or model that rejects them
//    (OpenAI reasoning models, Anthropic thinking models, the Responses wire)
//    simply does not get them, as upstream strips them on the same predicates.
//  - Every other control is "hard": if the provider cannot represent it, the
//    request fails before any HTTP call with a message naming the setting,
//    instead of silently ignoring something the user asked for.
//
//  Local-only controls (MLX sampling defaults, speculation, chat-template
//  kwargs, local seed validation) are not part of this: they are Incompatible
//  on Intel.
//

import Foundation

enum IntelSamplingWire {
    /// How a provider's request body is shaped.
    enum Wire: Equatable {
        /// OpenAI-compatible Chat Completions. `acceptsExtensions` is false for
        /// hosts with a strict schema that rejects `top_k` / `min_p` /
        /// `repetition_penalty` as unknown fields.
        case chatCompletions(acceptsExtensions: Bool)
        /// Anthropic Messages (`IntelAnthropicMessagesAdapter`).
        case anthropic
        /// Gemini `generateContent` (`IntelGeminiAdapter`).
        case gemini
        /// OpenAI Responses (Codex and API-key OpenAI): the adapter carries no
        /// sampling fields.
        case responses
    }

    struct Unsupported: LocalizedError, Equatable {
        let provider: String
        let names: [String]
        var errorDescription: String? {
            String(
                format: L(
                    "%@ can't use these generation settings: %@. Clear them in the agent's Generation Overrides, or choose another model."
                ),
                provider, names.joined(separator: ", "))
        }
    }

    /// Hosts that reject sampler extensions as unknown fields. Deliberately
    /// short: only hosts known to be strict. Everything else gets the fields
    /// (upstream sends them to every OpenAI-compatible endpoint).
    nonisolated static let strictExtensionHosts = ["openai.com", "mistral.ai", "x.ai"]

    nonisolated static func wire(
        providerType: RemoteProviderType?, host: String, usesResponsesWire: Bool
    ) -> Wire {
        if usesResponsesWire { return .responses }
        guard let providerType else { return .chatCompletions(acceptsExtensions: true) }
        switch providerType {
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        case .openResponses, .openAICodex: return .responses
        case .azureOpenAI: return .chatCompletions(acceptsExtensions: false)
        case .openaiLegacy, .osaurusRouter, .osaurus:
            let lowered = host.lowercased()
            let strict = strictExtensionHosts.contains { lowered.contains($0) }
            return .chatCompletions(acceptsExtensions: !strict)
        }
    }

    /// Settings the wire cannot represent, in display order.
    nonisolated static func unsupportedNames(
        _ sampling: ChatExplicitSampling, wire: Wire
    ) -> [String] {
        var names: [String] = []
        func add(_ present: Bool, _ name: String) { if present { names.append(name) } }
        let hasStop = !(sampling.stop?.isEmpty ?? true)
        switch wire {
        case .chatCompletions(let acceptsExtensions):
            if !acceptsExtensions {
                add(sampling.topK != nil, "top_k")
                add(sampling.minP != nil, "min_p")
                add(sampling.repetitionPenalty != nil, "repetition_penalty")
            }
        case .anthropic:
            add(sampling.minP != nil, "min_p")
            add(sampling.repetitionPenalty != nil, "repetition_penalty")
            add(sampling.frequencyPenalty != nil, "frequency_penalty")
            add(sampling.presencePenalty != nil, "presence_penalty")
            add(sampling.seed != nil, "seed")
        case .gemini:
            add(sampling.minP != nil, "min_p")
            add(sampling.repetitionPenalty != nil, "repetition_penalty")
            add(sampling.frequencyPenalty != nil, "frequency_penalty")
            add(sampling.presencePenalty != nil, "presence_penalty")
        case .responses:
            add(sampling.topK != nil, "top_k")
            add(sampling.minP != nil, "min_p")
            add(sampling.repetitionPenalty != nil, "repetition_penalty")
            add(sampling.frequencyPenalty != nil, "frequency_penalty")
            add(sampling.presencePenalty != nil, "presence_penalty")
            add(sampling.seed != nil, "seed")
            add(hasStop, "stop")
        }
        return names
    }

    /// Add the explicit sampling this provider accepts to `body`, or throw
    /// `Unsupported` naming what it cannot represent.
    ///
    /// - Parameter rejectsSamplers: the model rejects `temperature` / `top_p`
    ///   and the penalties (OpenAI reasoning models; upstream strips them on
    ///   the same predicate). Those are dropped, not an error.
    nonisolated static func apply(
        _ sampling: ChatExplicitSampling?,
        wire: Wire,
        rejectsSamplers: Bool,
        providerLabel: String,
        into body: inout [String: Any]
    ) throws {
        guard let sampling, !sampling.isEmpty else { return }
        // A reasoning model that drops penalties silently is upstream's
        // behavior; do not turn it into an error here.
        var effective = sampling
        if rejectsSamplers {
            effective.temperature = nil
            effective.topP = nil
            effective.frequencyPenalty = nil
            effective.presencePenalty = nil
        }
        let unsupported = unsupportedNames(effective, wire: wire)
        guard unsupported.isEmpty else {
            throw Unsupported(provider: providerLabel, names: unsupported)
        }
        // The Responses adapter accepts no sampling keys; temperature and
        // Top P are dropped there (soft), everything else already threw.
        if wire == .responses { return }

        if let value = effective.temperature { body["temperature"] = value }
        if let value = effective.topP { body["top_p"] = value }
        if let value = effective.topK { body["top_k"] = value }
        if let value = effective.seed { body["seed"] = value }
        if let stop = effective.stop, !stop.isEmpty { body["stop"] = stop }
        if case .chatCompletions = wire {
            if let value = effective.minP { body["min_p"] = value }
            if let value = effective.repetitionPenalty { body["repetition_penalty"] = value }
            if let value = effective.frequencyPenalty { body["frequency_penalty"] = value }
            if let value = effective.presencePenalty { body["presence_penalty"] = value }
        }
    }
}
