//
//  AgentReasoningPolicy.swift
//  osaurus
//
//  Preserves the model's reasoning contract: only explicit user or agent
//  choices override omitted thinking controls (upstream #3233's
//  `AgentReasoningPolicy.applyingExplicitReasoning`).
//
//  Intel: upstream reads the choices off `ResponsesGenerationOptions`, which
//  Intel does not compile, so the explicit values are passed directly. The
//  result is the `modelOptions` Intel's engine already reads for every
//  provider (`disableThinking`, `reasoningEffort`).
//

import Foundation

enum AgentReasoningPolicy {
    /// Project explicit reasoning choices onto runtime options. Shared with the
    /// chat readout so saved agent defaults display what dispatch uses.
    /// Omitted controls do not manufacture model defaults.
    static func applyingExplicitReasoning(
        enableThinking: Bool?,
        reasoningEffort: String?,
        to options: [String: ModelOptionValue],
        modelID: String
    ) -> [String: ModelOptionValue] {
        var options = options
        let effort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines)
        if Hy3ReasoningProfile.matches(modelId: modelID) {
            if let effort, !effort.isEmpty {
                options["reasoningEffort"] = .string(Hy3ReasoningProfile.normalizedEffort(effort))
            } else if options["reasoningEffort"] == nil, let enableThinking {
                options["reasoningEffort"] = .string(enableThinking ? "high" : "no_think")
            }
            options.removeValue(forKey: "disableThinking")
        } else {
            if let enableThinking { options["disableThinking"] = .bool(!enableThinking) }
            if let effort, !effort.isEmpty { options["reasoningEffort"] = .string(effort) }
        }
        return options
    }
}
