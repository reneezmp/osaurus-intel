//
//  IntelMediaKindServices.swift
//  OsaurusCore — Subagent framework
//
//  Everything `ImageSubagentKind` / `VideoSubagentKind` reach outside
//  themselves for (W-subagents stage 6, image / video kinds): the agent's
//  switch and policy, the connected media catalog, the coordinator (the only
//  thing that spends money), the approval prompt and the chat artifact.
//  Upstream's kinds call those singletons directly; Intel passes them
//  through one value so tests run the whole kind on fakes (no network, no
//  keychain, no `~/.osaurus`, no spend). `live` is what production uses.
//

import Foundation

struct IntelMediaKindServices: Sendable {
    /// The calling agent's switch, configured model and policy.
    var agentSettings:
        @Sendable (_ agentId: UUID, _ forImage: Bool, _ imageToVideo: Bool) async
            -> IntelMediaToolSupport.AgentMediaSettings
    /// Connected image-generation models (Osaurus Cloud, Venice).
    var imageCandidates: @Sendable () async -> [MediaModelInfo]
    /// Connected video models, text-to-video and image-to-video.
    var videoCandidates: @Sendable () async -> [MediaModelInfo]
    var generateImage: @Sendable (MediaImageGenerationRequest) async throws -> [GeneratedMedia]
    var quoteVideo: @Sendable (MediaVideoGenerationRequest) async throws -> MediaVideoQuote
    var generateVideo:
        @Sendable (
            MediaVideoGenerationRequest, MediaVideoQuote, InterruptToken,
            @escaping @Sendable (MediaGenerationEvent) -> Void
        ) async throws -> GeneratedMedia
    /// The billable-spend approval card: tool name, description, enriched
    /// arguments. The same prompt service Intel's tools used before the
    /// kinds; it never auto-approves.
    var requestApproval: @Sendable (_ toolName: String, _ description: String, _ argumentsJSON: String) async -> Bool
    /// Copies the file into the chat's artifact store; returns the file-card
    /// text, or nil outside a chat.
    var promote: @Sendable (_ media: GeneratedMedia, _ description: String, _ chatSessionId: String?) async -> String?

    static let live = IntelMediaKindServices(
        agentSettings: { agentId, forImage, imageToVideo in
            await IntelMediaToolSupport.agentSettings(
                agentId: agentId, forImage: forImage, imageToVideo: imageToVideo)
        },
        imageCandidates: {
            await IntelMediaToolSupport.pickerItems().imageGenerationDelegateCandidates.compactMap(\.mediaModel)
        },
        videoCandidates: {
            await IntelMediaToolSupport.pickerItems().videoGenerationDelegateCandidates.compactMap(\.mediaModel)
        },
        generateImage: { try await MediaGenerationCoordinator.shared.generateImage($0) },
        quoteVideo: { try await MediaGenerationCoordinator.shared.quoteVideo($0) },
        generateVideo: { request, quote, interrupt, progress in
            try await MediaGenerationCoordinator.shared.generateVideo(
                request, approvedQuote: quote, interrupt: interrupt, progress: progress)
        },
        requestApproval: { toolName, description, argumentsJSON in
            await ToolPermissionPromptService.requestApproval(
                toolName: toolName, description: description, argumentsJSON: argumentsJSON)
        },
        promote: { media, description, chatSessionId in
            await IntelMediaToolSupport.promoteToChatArtifact(
                media, description: description, sessionId: chatSessionId)
        }
    )
}

extension IntelMediaToolSupport {
    /// Runs `body` on its own task that is cancelled when the run's
    /// `InterruptToken` trips (the feed's Stop button), so a Stop reaches a
    /// request that is waiting on a provider. A video that is already queued
    /// is recovered by the coordinator (it throws `queuedJobContinues`).
    static func cancellingOnInterrupt<T: Sendable>(
        _ interrupt: InterruptToken,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task { try await body() }
        let observer = interrupt.observeInterrupt { task.cancel() }
        defer { interrupt.removeInterruptObserver(observer) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
