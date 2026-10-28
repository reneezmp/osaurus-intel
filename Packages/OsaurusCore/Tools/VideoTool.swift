//
//  VideoTool.swift
//  osaurus
//
//  Intel's `video` tool (`W-media-generation`): upstream's `VideoTool` with
//  its `VideoSubagentKind` folded in, cloud only. A current price quote rides
//  in the approval before the job is queued; once queued, a paid job is
//  recovered after Stop or relaunch (`MediaGenerationCoordinator`). Upstream's
//  local controls (width/height, frame_count, fps, steps, guidance, seed) are
//  left out of the schema: the coordinator rejects them for remote models.
//

import Foundation

final class VideoTool: OsaurusTool, @unchecked Sendable {
    let name = "video"

    static let toolDescription =
        "Generate a video with a configured cloud provider, from text or one source image. A current price quote is included "
        + "in the approval request before the job is queued. The completed video is shown automatically."

    var description: String { Self.toolDescription }
    var bypassRegistryTimeout: Bool { true }

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "prompt": .object([
                "type": .string("string"),
                "description": .string("What the video should show."),
            ]),
            "source_path": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional local PNG/JPEG/WebP source image. Providing it selects image-to-video."
                ),
            ]),
            "model": .object([
                "type": .string("string"),
                "description": .string("Optional configured media model id."),
            ]),
            "negative_prompt": .object([
                "type": .string("string"),
                "description": .string("Optional negative prompt."),
            ]),
            "duration": .object([
                "type": .string("string"),
                "description": .string("A catalog-supported duration, e.g. `5s`."),
            ]),
            "resolution": .object([
                "type": .string("string"),
                "description": .string("Optional catalog-supported resolution such as `720p`."),
            ]),
            "aspect_ratio": .object([
                "type": .string("string"),
                "description": .string("Optional catalog-supported aspect ratio such as `16:9`."),
            ]),
            "audio": .object([
                "type": .string("boolean"),
                "description": .string("Optional audio generation setting when the model supports it."),
            ]),
        ]),
        "required": .array([.string("prompt"), .string("duration")]),
    ])

    init() {}

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let promptReq = requireString(args, "prompt", expected: "non-empty video prompt", tool: name)
        guard case .value(let prompt) = promptReq else { return promptReq.failureEnvelope ?? "" }
        let durationReq = requireString(args, "duration", expected: "catalog-supported duration", tool: name)
        guard case .value(let duration) = durationReq else { return durationReq.failureEnvelope ?? "" }

        let sourcePath = IntelMediaToolSupport.optionalString(args["source_path"])
        let isImageToVideo = sourcePath != nil
        let resolution = IntelMediaToolSupport.optionalString(args["resolution"])
        let aspectRatio = IntelMediaToolSupport.optionalString(args["aspect_ratio"])
        let audio = args["audio"] as? Bool

        let agent = await IntelMediaToolSupport.agentSettings(forImage: false, imageToVideo: isImageToVideo)
        guard agent.enabled else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "Video generation is not enabled for this agent (Agents → Abilities → Images & Video).",
                tool: name)
        }
        let wantedKind: MediaGenerationKind = isImageToVideo ? .imageToVideo : .textToVideo
        let candidates = await IntelMediaToolSupport.pickerItems()
            .videoGenerationDelegateCandidates.compactMap(\.mediaModel)
            .filter { $0.kind == wantedKind }
        guard
            let model = IntelMediaToolSupport.resolve(
                requested: IntelMediaToolSupport.optionalString(args["model"]),
                configured: agent.target, candidates: candidates)
        else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: isImageToVideo
                    ? "No configured image-to-video model is available."
                    : "No configured text-to-video model is available.",
                tool: name)
        }
        if let invalid = Self.validate(
            model: model, prompt: prompt, duration: duration, resolution: resolution,
            aspectRatio: aspectRatio, audio: audio)
        {
            return invalid
        }

        let source: (Data, String)?
        do {
            source = try sourcePath.map(Self.loadSourceImage)
        } catch let error as SourceImageError {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: error.message, field: "source_path", expected: error.expected,
                tool: name)
        }
        let request = MediaVideoGenerationRequest(
            target: model.target,
            prompt: prompt,
            negativePrompt: IntelMediaToolSupport.optionalString(args["negative_prompt"]),
            sourceImage: source?.0,
            sourceImageMIMEType: source?.1,
            duration: duration,
            aspectRatio: aspectRatio,
            resolution: resolution,
            audio: audio
        )

        // Upstream `VideoSubagentKind.permission`: quote first, then the
        // agent's policy (Ask shows the quote; Always Allow skips the card).
        let quote: MediaVideoQuote
        do {
            quote = try await MediaGenerationCoordinator.shared.quoteVideo(request)
        } catch {
            return ToolEnvelope.failure(
                kind: .rejected, message: "Could not quote this video: \(error.localizedDescription)", tool: name)
        }
        switch agent.permission {
        case .deny:
            return ToolEnvelope.failure(
                kind: .rejected, message: "Video generation is denied by this agent's permission settings.",
                tool: name)
        case .alwaysAllow:
            break
        case .ask:
            let approved = await ToolPermissionPromptService.requestApproval(
                toolName: name,
                description: Self.toolDescription,
                argumentsJSON: SubagentApprovalArguments.enrichedJSON(
                    from: argumentsJSON,
                    values: [
                        "resolved_model": model.displayName,
                        "quote_usd": quote.usd,
                        "billing_notice": "This queues a billable remote video job.",
                    ])
            )
            guard approved else {
                return ToolEnvelope.failure(
                    kind: .userDenied, message: "User denied the quoted video generation.", tool: name)
            }
        }

        let media: GeneratedMedia
        do {
            media = try await MediaGenerationCoordinator.shared.generateVideo(
                request, approvedQuote: quote, progress: { _ in })
        } catch {
            return IntelMediaToolSupport.failure(error, tool: name)
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
        if let card = await IntelMediaToolSupport.promoteToChatArtifact(
            media, description: "Video generation result from \(model.displayName)")
        {
            payload["text"] = card
        }
        return ToolEnvelope.success(tool: name, result: payload)
    }

    /// Upstream `VideoSubagentKind.validate(model:)` for cloud models.
    static func validate(
        model: MediaModelInfo, prompt: String, duration: String, resolution: String?,
        aspectRatio: String?, audio: Bool?
    ) -> String? {
        let c = model.constraints
        func invalid(_ message: String, _ field: String, _ expected: String) -> String {
            ToolEnvelope.failure(kind: .invalidArgs, message: message, field: field, expected: expected, tool: "video")
        }
        if !c.durations.isEmpty, !c.durations.contains(duration) {
            return invalid(
                "Unsupported duration for \(model.displayName).", "duration", c.durations.joined(separator: ", "))
        }
        if let resolution, !c.resolutions.isEmpty, !c.resolutions.contains(resolution) {
            return invalid(
                "Unsupported resolution for \(model.displayName).", "resolution",
                c.resolutions.joined(separator: ", "))
        }
        if let aspectRatio, !c.aspectRatios.isEmpty, !c.aspectRatios.contains(aspectRatio) {
            return invalid(
                "Unsupported aspect ratio for \(model.displayName).", "aspect_ratio",
                c.aspectRatios.joined(separator: ", "))
        }
        if audio != nil, !c.audioConfigurable {
            return invalid("Audio cannot be configured for \(model.displayName).", "audio", "omit this field")
        }
        if let limit = c.promptCharacterLimit, prompt.count > limit {
            return invalid("The video prompt is too long.", "prompt", "at most \(limit) characters")
        }
        return nil
    }

    struct SourceImageError: Error {
        let message: String
        let expected: String
    }

    /// Upstream `VideoSubagentKind.loadSourceImage`: the source must be an
    /// Osaurus attachment or generated artifact (inside the Osaurus root),
    /// PNG/JPEG/WebP, at most 25 MB, with bytes matching its extension
    /// (Intel checks the magic bytes; upstream's HTTP decoder is not here).
    static func loadSourceImage(_ path: String) throws -> (Data, String) {
        let url = (URL(string: path).flatMap { $0.isFileURL ? $0 : nil } ?? URL(fileURLWithPath: path))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let approvedRoot = OsaurusPaths.root().standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path.hasPrefix(approvedRoot + "/") else {
            throw SourceImageError(
                message: "Remote video source images must come from an Osaurus attachment or generated artifact.",
                expected: "a file path inside the current Osaurus artifact store")
        }
        let format: ImageOutputFormat
        switch url.pathExtension.lowercased() {
        case "png": format = .png
        case "jpg", "jpeg": format = .jpeg
        case "webp": format = .webp
        default:
            throw SourceImageError(message: "Unsupported source image.", expected: "an existing PNG, JPEG, or WebP file")
        }
        guard
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true,
            (values.fileSize ?? 0) <= 25 * 1_024 * 1_024,
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else {
            throw SourceImageError(
                message: "Source image is missing or larger than 25 MB.",
                expected: "an existing image no larger than 25 MB")
        }
        guard (try? MediaFileValidation.detectImageFormat(data)) == format else {
            throw SourceImageError(
                message: "The source image bytes do not match its file type.",
                expected: "a valid PNG, JPEG, or WebP image")
        }
        return (data, "image/\(format.rawValue)")
    }
}
