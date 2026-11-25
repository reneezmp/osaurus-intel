//
//  IntelSpawnResultWire.swift
//  osaurus
//
//  What the launching model reads of a `spawn_agent` result (upstream #2936,
//  `ChatView` tool-result handling): the card and telemetry keep the full
//  `spawn_result` envelope (structured usage/context), the model reads the
//  digest, continuation handles, deliverable paths and one accounting line,
//  with a shorter digest on a compact launcher.
//
//  Intel (W-subagents stage 4): the transcript is built in `CloudChatEngine`,
//  not `ChatView`, so the engine calls this where it writes the wire message.
//  Upstream's `ContextSizeResolver.prefersCompactPrompt` (tiny and small
//  windows, up to 8192 tokens) is not compiled on Intel; the same ceiling is
//  applied to `IntelContextBudget`'s window.
//

import Foundation

enum IntelSpawnResultWire {
    /// Upstream's `ContextSizeResolver.smallCeiling`.
    static let compactWindowCeiling = 8192

    static func prefersCompactPrompt(windowTokens: Int?) -> Bool {
        guard let windowTokens else { return false }
        return windowTokens <= compactWindowCeiling
    }

    /// The text the model sees for tool `name`'s `result`. Anything but a
    /// successful `spawn_agent` result passes through unchanged.
    static func modelVisible(name: String, result: String, modelID: String?) async -> String {
        guard name == SubagentCapabilityRegistry.spawnAgentToolName,
            SpawnResultCompaction.applies(to: result)
        else { return result }
        let tokens = await MainActor.run { IntelContextBudget.resolveWindow(modelId: modelID)?.tokens }
        return SpawnResultCompaction.modelVisible(
            result, prefersCompactPrompt: prefersCompactPrompt(windowTokens: tokens))
    }
}
