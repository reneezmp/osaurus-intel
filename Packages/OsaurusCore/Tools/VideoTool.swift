//
//  VideoTool.swift
//  osaurus
//
//  Intel's `video` tool (`W-media-generation`): upstream's `VideoTool`; its
//  `VideoSubagentKind` (cloud branch) is `Subagent/Kinds/VideoSubagentKind.swift`. A current price quote rides
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

        // The switch, model, catalog checks, source image rule, quote,
        // approval and the coordinator call run in `VideoSubagentKind` on the
        // shared subagent host (W-subagents stage 6).
        let params = VideoJobParams(
            prompt: prompt,
            duration: duration,
            sourcePath: IntelMediaToolSupport.optionalString(args["source_path"]),
            model: IntelMediaToolSupport.optionalString(args["model"]),
            negativePrompt: IntelMediaToolSupport.optionalString(args["negative_prompt"]),
            resolution: IntelMediaToolSupport.optionalString(args["resolution"]),
            aspectRatio: IntelMediaToolSupport.optionalString(args["aspect_ratio"]),
            audio: args["audio"] as? Bool
        )
        return await SubagentSession.run(
            VideoSubagentKind(params: params, argumentsJSON: argumentsJSON), tool: name)
    }

    /// Upstream `VideoSubagentKind.validate(model:)` for cloud models, as an
    /// `invalid_args` envelope (nil when the arguments fit the catalog).
    static func validate(
        model: MediaModelInfo, prompt: String, duration: String, resolution: String?,
        aspectRatio: String?, audio: Bool?
    ) -> String? {
        guard
            let failure = validationFailure(
                model: model, prompt: prompt, duration: duration, resolution: resolution,
                aspectRatio: aspectRatio, audio: audio)
        else { return nil }
        return ToolEnvelope.failure(
            kind: .invalidArgs, message: failure.message, field: failure.field, expected: failure.expected,
            tool: "video")
    }

    /// The same check as a value, for `VideoSubagentKind`.
    static func validationFailure(
        model: MediaModelInfo, prompt: String, duration: String, resolution: String?,
        aspectRatio: String?, audio: Bool?
    ) -> (message: String, field: String, expected: String)? {
        let c = model.constraints
        if !c.durations.isEmpty, !c.durations.contains(duration) {
            return (
                "Unsupported duration for \(model.displayName).", "duration", c.durations.joined(separator: ", ")
            )
        }
        if let resolution, !c.resolutions.isEmpty, !c.resolutions.contains(resolution) {
            return (
                "Unsupported resolution for \(model.displayName).", "resolution",
                c.resolutions.joined(separator: ", ")
            )
        }
        if let aspectRatio, !c.aspectRatios.isEmpty, !c.aspectRatios.contains(aspectRatio) {
            return (
                "Unsupported aspect ratio for \(model.displayName).", "aspect_ratio",
                c.aspectRatios.joined(separator: ", ")
            )
        }
        if audio != nil, !c.audioConfigurable {
            return ("Audio cannot be configured for \(model.displayName).", "audio", "omit this field")
        }
        if let limit = c.promptCharacterLimit, prompt.count > limit {
            return ("The video prompt is too long.", "prompt", "at most \(limit) characters")
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
