import Foundation

/// User-saved custom-agent overrides. Omission inherits the selected model's defaults.
/// Temperature and output-token limits remain on `Agent` rather than being duplicated here.
///
/// Port of upstream Classic's `AgentGenerationSettings` (#3233, #3246). Intel
/// keeps the cloud-meaningful keys only: upstream's `template_kwargs` and
/// `speculative_decoding` are local-MLX controls (Incompatible on Intel), so
/// they are not stored. The JSON keys match upstream's, so an agent file from
/// either app still decodes (the two local-only keys are ignored).
public struct AgentGenerationSettings: Codable, Equatable, Sendable {
    public var topP: Float?
    public var topK: Int?
    public var minP: Float?
    public var repetitionPenalty: Float?
    public var frequencyPenalty: Float?
    public var presencePenalty: Float?
    public var seed: Int?
    public var stop: [String]?
    public var enableThinking: Bool?
    public var reasoningEffort: String?

    public init(
        topP: Float? = nil, topK: Int? = nil, minP: Float? = nil,
        repetitionPenalty: Float? = nil, frequencyPenalty: Float? = nil,
        presencePenalty: Float? = nil, seed: Int? = nil, stop: [String]? = nil,
        enableThinking: Bool? = nil, reasoningEffort: String? = nil
    ) {
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.seed = seed
        self.stop = stop
        self.enableThinking = enableThinking
        self.reasoningEffort = reasoningEffort
    }

    enum CodingKeys: String, CodingKey {
        case topP = "top_p"
        case topK = "top_k"
        case minP = "min_p"
        case repetitionPenalty = "repetition_penalty"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case seed, stop
        case enableThinking = "enable_thinking"
        case reasoningEffort = "reasoning_effort"
    }

    var hasReasoningOverride: Bool { enableThinking != nil || reasoningEffort != nil }

    var isEmpty: Bool {
        topP == nil && topK == nil && minP == nil && repetitionPenalty == nil
            && frequencyPenalty == nil && presencePenalty == nil && seed == nil
            && stop == nil && enableThinking == nil && reasoningEffort == nil
    }

    func validate() throws {
        try ChatTurnOverrides(
            topP: topP, topK: topK, reasoningEffort: reasoningEffort,
            enableThinking: enableThinking
        ).validate()
        if let reason = Self.repetitionPenaltyReason(repetitionPenalty) {
            throw ChatTurnOverrides.ValidationError.invalid(reason)
        }
        // These request fields have no shared model-independent range contract.
        // Reject non-numbers without inventing provider-specific bounds or defaults.
        for (name, value) in [
            ("Min P", minP), ("Frequency penalty", frequencyPenalty),
            ("Presence penalty", presencePenalty),
        ] {
            if let value, !value.isFinite {
                throw ChatTurnOverrides.ValidationError.invalid("\(name) must be a finite number.")
            }
        }
    }

    /// Multiplicative penalties divide positive logits; zero, negatives and
    /// nonfinite values have no valid sampling meaning (upstream #3226's
    /// `RequestValidator.repetitionPenaltyReason`, which Intel does not compile).
    static func repetitionPenaltyReason(_ value: Float?) -> String? {
        guard let value else { return nil }
        guard value.isFinite, value > 0 else {
            return "Parameter 'repetition_penalty' must be a finite number greater than zero."
        }
        return nil
    }
}
