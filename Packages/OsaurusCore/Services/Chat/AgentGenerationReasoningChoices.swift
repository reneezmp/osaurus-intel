import Foundation

/// The selected model's existing catalog/profile contract, never a generic
/// effort ladder (upstream #3233 / #3261).
///
/// Intel: upstream resolves local-model capabilities through MLX
/// (`LocalReasoningCapability.resolveForDispatch`, Incompatible). On Intel the
/// choices come from the same two sources the model picker already uses: the
/// provider catalog (`ModelReasoningCapabilities`) and the static model
/// profiles (`ModelProfileRegistry`), so the editor, the composer and the
/// dispatch check can never disagree.
struct AgentGenerationReasoningChoices: Equatable, Sendable {
    struct Effort: Equatable, Sendable, Identifiable {
        let id: String
        let label: String
    }

    var modelID: String? = nil
    var efforts: [Effort]
    var supportsThinking: Bool

    var hasEfforts: Bool { !efforts.isEmpty }
    var showsThinkingControl: Bool { supportsThinking }

    static func resolve(modelID: String) -> Self {
        let options = ModelProfileRegistry.options(for: modelID)
        var efforts: [Effort] = []
        if let option = options.first(where: { $0.id == "reasoningEffort" }),
            case .segmented(let segments) = option.kind
        {
            efforts = segments.map { Effort(id: $0.id, label: $0.label) }
        }
        return Self(
            modelID: modelID,
            efforts: efforts,
            supportsThinking: ModelProfileRegistry.profile(for: modelID)?.thinkingOption != nil
        )
    }

    enum ReasoningIssue: Equatable, Sendable {
        case effort(String)
        case thinking
    }

    /// Check raw saved controls before a model profile can normalize them away.
    func reasoningIssue(settings: AgentGenerationSettings) -> ReasoningIssue? {
        if let effort = settings.reasoningEffort,
            !efforts.contains(where: { $0.id == effort })
        {
            return .effort(effort)
        }
        if settings.enableThinking != nil, !supportsThinking {
            return .thinking
        }
        return nil
    }

    func validate(settings: AgentGenerationSettings) throws {
        switch reasoningIssue(settings: settings) {
        case .effort(let effort):
            throw ChatTurnOverrides.ValidationError.invalid(
                String(
                    format: L(
                        "The selected model does not advertise reasoning effort '%@'. Choose a supported value or Inherit in the agent's Generation Overrides."
                    ), effort))
        case .thinking:
            throw ChatTurnOverrides.ValidationError.invalid(
                L(
                    "The selected model does not advertise a Thinking switch. Choose Inherit in the agent's Generation Overrides."
                ))
        case nil:
            break
        }
    }
}
