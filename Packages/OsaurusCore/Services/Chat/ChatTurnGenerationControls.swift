//
//  ChatTurnGenerationControls.swift
//  osaurus
//
//  Freezes prompt-affecting UI model controls for one logical chat turn.
//  Agent loops rebuild ChatCompletionRequest for every model step, so the
//  explicit Thinking choice must be copied to every reconstruction in both
//  its local runtime representation (`modelOptions`) and its wire-safe API
//  representation (`enable_thinking`).
//
//  Intel (W-cov-reaudit 3c-3): Intel's `ChatCompletionRequest` has no
//  `enable_thinking`; its engine reads the Thinking choice from
//  `modelOptions` on every round, so `apply` sets only that.
//  `enableThinking` is kept for parity and tests.
//
//  Intel (`W-agent-generation-overrides`, upstream #3226 / #3233): the
//  custom agent's saved generation settings and the explicit sampling values
//  (temperature, Top P) are frozen with the turn too, so a settings change
//  mid-run cannot alter later tool rounds. `apply` projects them two ways:
//  Thinking and reasoning effort into `modelOptions` (the path every provider
//  adapter already reads) and the sampling values into
//  `request.explicitSampling`, which the cloud engine maps per provider
//  (`IntelSamplingWire`). Upstream's per-turn controls are persisted on the
//  turn and replayed on retry; Intel recaptures on retry (see the work log).
//

import Foundation

/// Sampling values the user set explicitly (agent editor or Settings). Anything
/// nil is not sent: providers keep their own defaults. Doubles on purpose: the
/// wire body is JSON, and `Float(0.7)` would serialize as 0.699999988.
struct ChatExplicitSampling: Sendable, Equatable {
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var minP: Double?
    var repetitionPenalty: Double?
    var frequencyPenalty: Double?
    var presencePenalty: Double?
    var seed: Int?
    var stop: [String]?

    var isEmpty: Bool {
        temperature == nil && topP == nil && topK == nil && minP == nil
            && repetitionPenalty == nil && frequencyPenalty == nil
            && presencePenalty == nil && seed == nil && (stop?.isEmpty ?? true)
    }

    /// `Float(0.7)` → `0.7`, not `0.699999988…`.
    static func double(_ value: Float?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return Double("\(value)") ?? Double(value)
    }
}

struct ChatTurnGenerationControls: Sendable, Equatable {
    let modelOptions: [String: ModelOptionValue]?
    let enableThinking: Bool?
    var overrides = ChatTurnOverrides()
    /// Explicit sampling defaults, captured once before asynchronous dispatch.
    var temperature: Float? = nil
    var topP: Float? = nil
    /// The custom agent's saved settings, frozen with the turn.
    var agentSettings: AgentGenerationSettings? = nil

    var reasoningEffort: String? {
        overrides.reasoningEffort ?? agentSettings?.reasoningEffort ?? modelOptions?["reasoningEffort"]?.stringValue
    }

    static func capture(
        activeModelOptions: [String: ModelOptionValue],
        agentSettings: AgentGenerationSettings? = nil,
        temperature: Float? = nil,
        topP: Float? = nil
    ) -> ChatTurnGenerationControls {
        let options = activeModelOptions.isEmpty ? nil : activeModelOptions

        // Only an explicit toggle becomes an API override. An absent value
        // remains nil so the bundle's chat-template default still owns fresh
        // models. `disableThinking` is the canonical stored option for every
        // current Thinking profile, including dynamically discovered local
        // profiles such as Ornith. Translate it directly instead of resolving
        // the model profile again on the send path; dynamic profile discovery
        // can touch the local model catalog and must not add synchronous TTFT.
        let enableThinking = options?["disableThinking"]?.boolValue.map { !$0 }

        return ChatTurnGenerationControls(
            modelOptions: options,
            enableThinking: enableThinking,
            temperature: temperature,
            topP: topP,
            agentSettings: agentSettings
        )
    }

    /// The explicit sampling this turn sends. Precedence follows upstream:
    /// per-turn overrides, then the agent's saved values, then the captured
    /// defaults.
    var explicitSampling: ChatExplicitSampling? {
        var sampling = ChatExplicitSampling()
        sampling.temperature = ChatExplicitSampling.double(overrides.temperature ?? temperature)
        sampling.topP = ChatExplicitSampling.double(overrides.topP ?? agentSettings?.topP ?? topP)
        sampling.topK = overrides.topK ?? agentSettings?.topK
        sampling.minP = ChatExplicitSampling.double(agentSettings?.minP)
        sampling.repetitionPenalty = ChatExplicitSampling.double(agentSettings?.repetitionPenalty)
        sampling.frequencyPenalty = ChatExplicitSampling.double(agentSettings?.frequencyPenalty)
        sampling.presencePenalty = ChatExplicitSampling.double(agentSettings?.presencePenalty)
        sampling.seed = agentSettings?.seed
        sampling.stop = agentSettings?.stop
        return sampling.isEmpty ? nil : sampling
    }

    /// The options the engine reads: the frozen picker values with explicit
    /// agent and per-turn reasoning on top (upstream: an agent's saved choice
    /// wins over the picker, and the composer shows what dispatch uses).
    func reasoningOptions(for modelID: String) -> [String: ModelOptionValue] {
        AgentReasoningPolicy.applyingExplicitReasoning(
            enableThinking: overrides.enableThinking ?? agentSettings?.enableThinking,
            reasoningEffort: overrides.reasoningEffort ?? agentSettings?.reasoningEffort,
            to: modelOptions ?? [:],
            modelID: modelID
        )
    }

    /// Upstream #3233 rejects a saved agent reasoning default the selected
    /// model does not advertise, rather than silently dropping it. The check
    /// reads the same catalog/profile contract the picker shows.
    func validateAgentReasoning(modelID: String) throws {
        guard let settings = agentSettings, settings.hasReasoningOverride else { return }
        try AgentGenerationReasoningChoices.resolve(modelID: modelID).validate(settings: settings)
    }

    func apply(to request: inout ChatCompletionRequest) {
        let options = reasoningOptions(for: request.model ?? "")
        request.modelOptions = options.isEmpty ? nil : options
        request.explicitSampling = explicitSampling
    }
}
