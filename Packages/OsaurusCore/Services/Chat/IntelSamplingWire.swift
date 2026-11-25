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

    /// The sampling to send: the turn's explicit sampling (agent settings, hard
    /// controls) over what an API or plugin caller put in its request (upstream
    /// `buildChatRequest` forwards the caller's temperature, top_p, penalties,
    /// stop and seed). Caller values are soft, as upstream: a wire that cannot
    /// carry one (Anthropic and Gemini have no penalties, Anthropic and the
    /// Responses wires no seed, Responses no `stop`) drops it instead of
    /// failing a client that sends OpenAI SDK defaults.
    nonisolated static func effectiveSampling(
        explicit: ChatExplicitSampling?, caller: ChatExplicitSampling?, wire: Wire
    ) -> ChatExplicitSampling? {
        guard var merged = caller, !merged.isEmpty else { return explicit }
        switch wire {
        case .chatCompletions:
            break
        case .anthropic:
            merged.frequencyPenalty = nil
            merged.presencePenalty = nil
            merged.seed = nil
        case .gemini:
            merged.frequencyPenalty = nil
            merged.presencePenalty = nil
        case .responses:
            merged.frequencyPenalty = nil
            merged.presencePenalty = nil
            merged.seed = nil
            merged.stop = nil
        }
        guard let explicit else { return merged.isEmpty ? nil : merged }
        merged.temperature = explicit.temperature ?? merged.temperature
        merged.topP = explicit.topP ?? merged.topP
        merged.topK = explicit.topK ?? merged.topK
        merged.minP = explicit.minP ?? merged.minP
        merged.repetitionPenalty = explicit.repetitionPenalty ?? merged.repetitionPenalty
        merged.frequencyPenalty = explicit.frequencyPenalty ?? merged.frequencyPenalty
        merged.presencePenalty = explicit.presencePenalty ?? merged.presencePenalty
        merged.seed = explicit.seed ?? merged.seed
        if let stop = explicit.stop, !stop.isEmpty { merged.stop = stop }
        return merged.isEmpty ? nil : merged
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
        sendsResponsesSamplers: Bool = false,
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
        // The Codex Responses adapter accepts no sampling keys; temperature and
        // Top P are dropped there (soft), everything else already threw. The
        // public Responses API (`.openResponses`) takes both for non-reasoning
        // models (upstream `toOpenResponsesRequest`).
        if wire == .responses {
            if sendsResponsesSamplers {
                if let value = effective.temperature { body["temperature"] = value }
                if let value = effective.topP { body["top_p"] = value }
            }
            return
        }

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

extension ChatCompletionRequest {
    /// What an API or plugin caller asked for in the request body (nil when
    /// it sent none of these).
    var samplingFromFields: ChatExplicitSampling? {
        var sampling = ChatExplicitSampling()
        sampling.temperature = temperature
        sampling.topP = top_p
        sampling.frequencyPenalty = frequency_penalty
        sampling.presencePenalty = presence_penalty
        sampling.seed = seed
        sampling.stop = stop?.filter { !$0.isEmpty }
        return sampling.isEmpty ? nil : sampling
    }

    /// Mark the request's own sampling fields as a caller's. Called only at
    /// the API and plugin entry points; the app's chat never calls it, so its
    /// behaviour (explicit sampling only) is unchanged.
    mutating func adoptCallerSampling() {
        callerSampling = samplingFromFields
    }
}

/// Client-side stop-sequence truncation (upstream `applyStopSequences`):
/// providers and compatible servers that ignore `stop` still end the reply at
/// the first sequence found in a streamed delta. Like upstream it matches per
/// delta, and checks the sequences in the order given.
struct IntelStopSequences {
    private let sequences: [String]
    private(set) var hit = false

    init(_ sequences: [String]) {
        var seen = Set<String>()
        self.sequences = sequences.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    init(request: ChatCompletionRequest) {
        self.init((request.stop ?? []) + (request.explicitSampling?.stop ?? []))
    }

    var isEmpty: Bool { sequences.isEmpty }

    /// The delta with everything from the first stop sequence removed; once a
    /// sequence was hit, later text is dropped.
    mutating func apply(_ text: String) -> String {
        guard !sequences.isEmpty else { return text }
        if hit { return "" }
        for sequence in sequences {
            if let range = text.range(of: sequence) {
                hit = true
                return String(text[..<range.lowerBound])
            }
        }
        return text
    }
}
