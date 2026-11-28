//
//  VideoSubagentKind.swift
//  OsaurusCore — Subagent framework
//
//  The `video` kind (upstream `VideoSubagentKind`), cloud branch only
//  (W-subagents stage 6, W-media-generation). Serves the `video` tool
//  through the shared host: live feed row with the queue / ETA progress and
//  Stop, recursion guard, telemetry, compact result.
//
//  What runs on Intel: text-to-video and image-to-video with an Osaurus
//  Cloud or Venice model. Upstream's local branch (Wan on MLX, frame
//  grids, fps, steps, seeds) is Incompatible and not in `VideoTool`'s
//  schema.
//
//  Spend gates (unchanged from Intel's tool before the kind): the agent's
//  video switch, a model that must still exist (never another billable
//  model), catalog checks and the source-image rule before any network
//  call, then a current quote, then the agent's policy (Deny refuses, Ask
//  shows the quote, Always Allow is the user's explicit choice). The
//  coordinator re-quotes when queueing and refuses if the price rose. Unlike
//  upstream there is no `autoApproveToolPrompts` bypass: Ask always asks.
//

import Foundation

/// Parsed, validated `video` tool arguments (cloud).
struct VideoJobParams: Sendable {
    var prompt: String
    var duration: String
    var sourcePath: String?
    var model: String?
    var negativePrompt: String?
    var resolution: String?
    var aspectRatio: String?
    var audio: Bool?

    var isImageToVideo: Bool { sourcePath != nil }
}

final class VideoSubagentKind: SubagentKind, @unchecked Sendable {
    let capability = SubagentCapabilityRegistry.video

    private let params: VideoJobParams
    private let argumentsJSON: String
    private let chatSessionId: String?
    private let services: IntelMediaKindServices
    private var selectedModel: MediaModelInfo?
    private var approvedQuote: MediaVideoQuote?
    private var source: (Data, String)?

    init(
        params: VideoJobParams,
        argumentsJSON: String,
        chatSessionId: String? = ChatExecutionContext.currentSessionId,
        services: IntelMediaKindServices = .live
    ) {
        self.params = params
        self.argumentsJSON = argumentsJSON
        self.chatSessionId = chatSessionId
        self.services = services
    }

    var feedTitle: String {
        let value = params.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return "video: \(value.count > 72 ? String(value.prefix(72)) + "…" : value)"
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        let agent = await services.agentSettings(scope.agentId, false, params.isImageToVideo)
        guard agent.enabled else {
            throw SubagentError.unavailable(
                "Video generation is not enabled for this agent (Agents → Abilities → Images & Video).")
        }
        let wanted: MediaGenerationKind = params.isImageToVideo ? .imageToVideo : .textToVideo
        let candidates = await services.videoCandidates().filter { $0.kind == wanted }
        guard
            let model = IntelMediaToolSupport.resolve(
                requested: params.model, configured: agent.target, candidates: candidates)
        else {
            throw SubagentError.unavailable(
                params.isImageToVideo
                    ? "No configured image-to-video model is available."
                    : "No configured text-to-video model is available.")
        }
        guard model.target.backend != .local else {
            throw SubagentError.unavailable(MediaGenerationCoordinator.intelLocalUnsupported)
        }
        try Self.validate(model: model, params: params)
        // The source image is read and checked here, before any quote call.
        do {
            source = try params.sourcePath.map(VideoTool.loadSourceImage)
        } catch let error as VideoTool.SourceImageError {
            throw SubagentError.invalidArgs(
                message: error.message, field: "source_path", expected: error.expected)
        }
        selectedModel = model
        return ResolvedModel(name: model.displayName, id: model.id, isLocal: false)
    }

    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        guard let model = selectedModel else {
            return .denied("The selected video model is no longer available.")
        }
        let agent = await services.agentSettings(scope.agentId, false, params.isImageToVideo)
        // Deny never reaches the provider, not even for a quote.
        if agent.permission == .deny {
            return .denied("Video generation is denied by this agent's permission settings.")
        }
        let quote: MediaVideoQuote
        do {
            quote = try await services.quoteVideo(makeRequest(model: model))
        } catch {
            return .denied("Could not quote this video: \(error.localizedDescription)")
        }
        approvedQuote = quote
        switch agent.permission {
        case .deny:
            return .denied("Video generation is denied by this agent's permission settings.")
        case .alwaysAllow:
            return .allow
        case .ask:
            let approved = await services.requestApproval(
                "video",
                VideoTool.toolDescription,
                SubagentApprovalArguments.enrichedJSON(
                    from: argumentsJSON,
                    values: [
                        "resolved_model": model.displayName,
                        "quote_usd": quote.usd,
                        "billing_notice": "This queues a billable remote video job.",
                    ])
            )
            return approved ? .allow : .userDenied("User denied the quoted video generation.")
        }
    }

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        guard let model = selectedModel, let quote = approvedQuote else {
            throw SubagentError.executionFailed(
                message: "The video quote or model expired before execution.", retryable: true)
        }
        let request = makeRequest(model: model)
        feed.emitPhase("quoted", detail: OsaurusRouter.formatUSDAsCredits(quote.usd))
        let generate = services.generateVideo
        let media: GeneratedMedia
        do {
            media = try await IntelMediaToolSupport.cancellingOnInterrupt(interrupt) {
                try await generate(request, quote, interrupt) { event in
                    Self.emit(event, to: feed)
                }
            }
        } catch let error as MediaGenerationError {
            throw SubagentError.executionFailed(
                message: error.localizedDescription, retryable: Self.isRetryable(error))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SubagentError.executionFailed(message: error.localizedDescription, retryable: false)
        }
        var payload: [String: Any] = [
            "kind": "generated_media_job",
            "media_type": "video",
            "job_id": media.url.deletingPathExtension().lastPathComponent,
            "model": media.modelID,
            "status": "completed",
            "quote_usd": quote.usd,
            "already_displayed": true,
            "display_note": "The video is already shown to the user; do NOT call share_artifact for it.",
            "media": [
                "path": media.url.path,
                "url": media.url.absoluteString,
                "mime_type": media.mimeType,
            ],
        ]
        if let effective = media.effectiveVideo,
            let object = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(effective))
        {
            payload["effective_parameters"] = object
        }
        if let card = await services.promote(
            media, "Video generation result from \(model.displayName)", chatSessionId)
        {
            payload["text"] = card
        }
        return SubagentResult(payload: payload, summary: "Generated a video with \(resolved.name).")
    }

    // MARK: - Helpers

    private func makeRequest(model: MediaModelInfo) -> MediaVideoGenerationRequest {
        MediaVideoGenerationRequest(
            target: model.target,
            prompt: params.prompt,
            negativePrompt: params.negativePrompt,
            sourceImage: source?.0,
            sourceImageMIMEType: source?.1,
            duration: params.duration,
            aspectRatio: params.aspectRatio,
            resolution: params.resolution,
            audio: params.audio
        )
    }

    /// Queue / ETA progress on the shared feed (upstream's mapping). The ETA
    /// row coalesces in place, so the chat shows one "generating video" line
    /// with "~Ns left" next to the feed's elapsed timer.
    static func emit(_ event: MediaGenerationEvent, to feed: SubagentFeed) {
        switch event {
        case .queued(let id):
            feed.emitPhase("queued", detail: id)
        case .running(let progress, let eta):
            feed.emitProgress(
                "generating video",
                fraction: progress.map { min(1, max(0, $0)) },
                step: 0,
                detail: eta.flatMap { $0 > 0 ? String(format: "~%.0fs left", $0) : nil }
            )
        case .completed:
            break
        case .failed(let message):
            feed.emitPhase("failed", detail: message)
        case .cancelled:
            feed.emitPhase("cancelled")
        }
    }

    private static func isRetryable(_ error: MediaGenerationError) -> Bool {
        switch error {
        case .transport, .queuedJobContinues: return true
        default: return false
        }
    }

    /// Catalog checks for a cloud model (upstream `validate(model:)`),
    /// as a thrown `invalid_args` the host turns into the envelope.
    static func validate(model: MediaModelInfo, params: VideoJobParams) throws {
        if let failure = VideoTool.validationFailure(
            model: model, prompt: params.prompt, duration: params.duration,
            resolution: params.resolution, aspectRatio: params.aspectRatio, audio: params.audio)
        {
            throw SubagentError.invalidArgs(
                message: failure.message, field: failure.field, expected: failure.expected)
        }
    }
}
