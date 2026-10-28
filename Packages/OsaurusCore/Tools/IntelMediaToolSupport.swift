//
//  IntelMediaToolSupport.swift
//  osaurus
//
//  Shared pieces of Intel's `image` / `video` tools (`W-media-generation`,
//  docs/MEDIA_GENERATION_INTEL.md). Upstream runs both tools through its
//  subagent framework (`ImageSubagentKind`, `VideoSubagentKind`), which
//  Intel does not have (`W-subagents`); these helpers carry the parts of
//  those kinds that apply to cloud media: model resolution, the agent's
//  switch and policy, the result payload, and the chat artifact.
//

import Foundation

enum IntelMediaToolSupport {
    struct AgentMediaSettings: Sendable {
        let agentId: UUID
        let enabled: Bool
        let target: MediaModelTarget?
        let permission: MediaToolPermission
    }

    /// The calling agent's switch, configured model and policy for one tool.
    static func agentSettings(
        forImage: Bool,
        imageToVideo: Bool = false
    ) async -> AgentMediaSettings {
        let agentId = ChatExecutionContext.currentAgentId ?? Agent.defaultId
        return await MainActor.run {
            let manager = AgentManager.shared
            let settings = manager.agent(for: agentId)?.settings
            if forImage {
                return AgentMediaSettings(
                    agentId: agentId,
                    enabled: manager.effectiveImageEnabled(for: agentId),
                    target: settings?.imageGenerationTarget,
                    permission: settings?.imagePermission ?? .ask)
            }
            return AgentMediaSettings(
                agentId: agentId,
                enabled: manager.effectiveVideoEnabled(for: agentId),
                target: imageToVideo ? settings?.imageToVideoTarget : settings?.textToVideoTarget,
                permission: settings?.videoPermission ?? .ask)
        }
    }

    /// Picker rows for connected media models; rebuilt once when the cache
    /// has not loaded yet (a tool call before the chat window opened).
    static func pickerItems() async -> [ModelPickerItem] {
        let cached = await MainActor.run { ModelPickerItemCache.shared.items }
        if !cached.isEmpty { return cached }
        return await ModelPickerItemCache.shared.buildModelPickerItems()
    }

    /// Upstream's resolution order: an explicit `model` argument (picker id
    /// or provider model id, matched uniquely), then the agent's configured
    /// target, then the first available candidate.
    static func resolve(
        requested: String?,
        configured: MediaModelTarget?,
        candidates: [MediaModelInfo]
    ) -> MediaModelInfo? {
        if let requested {
            let matches = candidates.filter { $0.id == requested || $0.target.modelID == requested }
            return matches.count == 1 ? matches[0] : nil
        }
        if let configured {
            return candidates.first { $0.target == configured }
        }
        return candidates.first
    }

    static func backendDescription(_ model: MediaModelInfo) -> String {
        switch model.target.backend {
        case .local: return "Local"
        case .remoteProvider: return model.providerName
        case .osaurusCloud: return "Osaurus Cloud"
        }
    }

    static func optionalString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func optionalDouble(_ raw: Any?) -> Double? {
        if let double = raw as? Double { return double }
        if let number = raw as? NSNumber { return number.doubleValue }
        if let string = raw as? String { return Double(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Upstream's `image` tool clamp (256…4096, multiple of 16).
    static func clampedDimension(_ value: Int) -> Int {
        let bounded = min(4096, max(256, value))
        return max(256, (bounded / 16) * 16)
    }

    /// Copies the file into the chat's artifact store so the transcript shows
    /// it as a file card (Intel's form of upstream's
    /// `GeneratedMediaToolArtifactBridge`, run inside the tool because Intel's
    /// engine executes tools itself). Returns the enriched marker text, or
    /// nil outside a chat (no session) or when promotion fails.
    static func promoteToChatArtifact(_ media: GeneratedMedia, description: String) async -> String? {
        guard let sessionId = ChatExecutionContext.currentSessionId, !sessionId.isEmpty else { return nil }
        let outcome = SharedArtifact.processTrustedLocalFileResult(
            fileURL: media.url,
            filename: media.url.lastPathComponent,
            mimeType: media.mimeType,
            description: description,
            contextId: sessionId,
            contextType: .chat
        )
        switch outcome {
        case .success(let processed):
            await PluginManager.shared.notifyArtifactHandlers(artifact: processed.artifact)
            return processed.enrichedToolResult
        case .failure(let reason):
            NSLog("[MediaTools] artifact promotion failed: %@", String(describing: reason))
            return nil
        }
    }

    static func failure(_ error: Error, tool: String) -> String {
        if let media = error as? MediaGenerationError {
            let retryable: Bool
            switch media {
            case .transport, .queuedJobContinues: retryable = true
            default: retryable = false
            }
            return ToolEnvelope.failure(
                kind: .executionError, message: media.localizedDescription, tool: tool, retryable: retryable)
        }
        if error is CancellationError {
            return ToolEnvelope.failure(kind: .executionError, message: "Cancelled.", tool: tool, retryable: true)
        }
        return ToolEnvelope.failure(
            kind: .executionError, message: error.localizedDescription, tool: tool, retryable: false)
    }
}
