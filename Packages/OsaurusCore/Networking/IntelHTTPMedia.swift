//
//  IntelHTTPMedia.swift
//  osaurus
//
//  The OpenAI-style media routes (`W-server-api` stage 6,
//  docs/SERVER_API_INTEL.md), on the cloud media coordinator Intel already
//  has (docs/MEDIA_GENERATION_INTEL.md):
//
//  - `GET /images/models` — the on-device image models. Always empty on
//    Intel: they are MLX bundles (upstream lists only those here too).
//  - `POST /images/generations` — an Osaurus Cloud or Venice image, or the
//    configured default image target. JSON, or SSE (`stream: true`) with one
//    `completed` / `error` event, as upstream answers a cloud model.
//  - `POST /images/edits`, `POST /images/upscale` — on-device only upstream
//    (cloud editing isn't supported there either): checked as upstream
//    checks them, then 501, since they need an Apple Silicon Mac.
//  - `POST /images/cancel` — stops a running streamed cloud image request.
//  - `GET /images/jobs/{id}/events` — the phone's rejoin of a detached image
//    job; there are none until the Secure Channel (`W-identity-mobile`).
//  - `POST /videos/quote`, `POST /videos/generations`,
//    `GET /videos/jobs/{id}`, `GET /videos/jobs/{id}/content` — upstream's
//    quote-then-queue flow with single-use quote receipts.
//
//  Remote spend needs `allow_remote_media_spend: true` (upstream). These
//  routes stay plaintext for third-party SDKs (upstream's owner-channel list
//  holds only `/images/jobs`); the gate refuses them to agent-scoped keys
//  while the owner doesn't share inference.
//
//  Phone-only parts wait for `W-identity-mobile`: `osaurus_session_id` /
//  `osaurus_create_session` (the exchange appended to a Mac chat) and
//  `osaurus_job_id` (a job that outlives the connection) are ignored, as
//  `/agents/{id}/run` ignores its phone fields.
//

import Foundation
import NIOCore
import NIOHTTP1

extension HTTPHandler {
    func routeMediaRequest(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) -> Bool {
        switch (head.method, path) {
        case (.GET, "/images/models"): serveImageModels(context: context, head: head)
        case (.POST, "/images/generations"): serveImageGenerations(context: context, head: head)
        case (.POST, "/images/edits"): serveImageEdits(context: context, head: head)
        case (.POST, "/images/upscale"): serveImageUpscale(context: context, head: head)
        case (.POST, "/images/cancel"): serveImageCancel(context: context, head: head)
        case (.POST, "/videos/quote"): serveVideoQuote(context: context, head: head)
        case (.POST, "/videos/generations"): serveVideoGeneration(context: context, head: head)
        case (.GET, _) where path.hasPrefix("/images/jobs/") && path.hasSuffix("/events"):
            serveImageJobEvents(context: context)
        case (.GET, _) where path.hasPrefix("/videos/jobs/") && path.hasSuffix("/content"):
            serveVideoContent(context: context, head: head, path: path)
        case (.GET, _) where path.hasPrefix("/videos/jobs/"):
            serveVideoJob(context: context, head: head, path: path)
        default:
            return false
        }
        return true
    }

    // MARK: - Shared pieces (upstream)

    /// The error envelope every media route answers with (upstream's
    /// `sendImageError`), logged with the route's own row.
    private func sendMediaError(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        status: HTTPResponseStatus,
        message: String,
        path: String,
        requestBody: String?
    ) {
        stateRef.value.routeLogsItself = true
        sendResponse(context: context, status: status, headers: jsonHeaders(), body: Self.mediaErrorBody(message))
        logRequest(
            method: head.method.rawValue, path: path, userAgent: head.headers.first(name: "User-Agent"),
            requestBody: requestBody, responseStatus: Int(status.code),
            startTime: stateRef.value.requestStartedAt ?? Date(), errorMessage: message)
    }

    static func mediaErrorBody(_ message: String) -> String {
        #"{"error":{"message":"\#(escapeJSONString(message))","type":"invalid_request_error"}}"#
    }

    /// The request body as text, with a source image left out of the log
    /// (upstream's `redactedMediaRequestBody`).
    static func redactedMediaRequestBody(_ body: String?) -> String? {
        guard let body else { return nil }
        guard
            let data = body.data(using: .utf8),
            var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return body }
        if object["source_image"] != nil {
            object["source_image"] = "[REDACTED IMAGE]"
        }
        guard let redacted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return body }
        return String(decoding: redacted, as: UTF8.self)
    }

    /// Decode an image input field — a `data:` URI, a `file://` URL, or raw
    /// base64 (upstream; used by the on-device paths' checks).
    static func decodeImageInput(_ value: String) -> Data? {
        if value.hasPrefix("data:") {
            guard let comma = value.firstIndex(of: ",") else { return nil }
            return Data(base64Encoded: String(value[value.index(after: comma)...]))
        }
        if value.hasPrefix("file://"), let url = URL(string: value) {
            return try? Data(contentsOf: url)
        }
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return nil
        }
        return Data(base64Encoded: value)
    }

    /// Decode an image that will leave the machine for a remote media
    /// provider. Unlike `decodeImageInput`, this rejects `file://`
    /// references so an API caller cannot turn Osaurus into a local file
    /// exfiltration proxy (upstream).
    static func decodeImageInputWithMIME(_ value: String) -> (data: Data, mimeType: String)? {
        if value.hasPrefix("data:") {
            guard
                let comma = value.firstIndex(of: ","),
                let semicolon = value[..<comma].firstIndex(of: ";"),
                value[value.index(after: semicolon) ..< comma].lowercased() == "base64"
            else { return nil }
            let mime = String(value[value.index(value.startIndex, offsetBy: 5) ..< semicolon]).lowercased()
            guard ["image/png", "image/jpeg", "image/webp"].contains(mime),
                let data = Data(base64Encoded: String(value[value.index(after: comma)...])),
                sniffedImageMIME(data) == mime
            else { return nil }
            return (data, mime)
        }
        guard !value.hasPrefix("file://"),
            !value.hasPrefix("http://"),
            !value.hasPrefix("https://"),
            let data = Data(base64Encoded: value),
            let mime = sniffedImageMIME(data)
        else { return nil }
        return (data, mime)
    }

    private static func sniffedImageMIME(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if bytes.count >= 12,
            Array(bytes[0 ..< 4]) == Array("RIFF".utf8),
            Array(bytes[8 ..< 12]) == Array("WEBP".utf8)
        {
            return "image/webp"
        }
        return nil
    }

    /// Resolve width/height from explicit fields or an OpenAI-style `WxH`
    /// size (upstream).
    static func resolveImageSize(size: String?, width: Int?, height: Int?) -> (Int?, Int?) {
        if let width, let height { return (width, height) }
        if let size {
            let parts = size.lowercased().split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                return (w, h)
            }
        }
        return (width, height)
    }

    static func imageOutputFormat(_ raw: String?) -> ImageOutputFormat {
        switch raw?.lowercased() {
        case "jpeg", "jpg": return .jpeg
        case "webp": return .webp
        default: return .png
        }
    }

    /// Provider adapters accept one base seed, not native seed arrays or GPU
    /// batch sizing: refused before any billable remote request (upstream's
    /// `ImageHTTPParameterBuilder.validateRemoteBatch`; the rest of that file
    /// is the on-device engine's).
    static func validateRemoteImageBatch(_ request: ImageGenerationRequestDTO) throws {
        guard request.seeds == nil, request.batch_size == nil,
            request.sampler == nil, request.scheduler == nil, request.shift == nil,
            request.preview_interval == nil, request.preview_max_pixel == nil, request.adapters == nil
        else {
            throw ImageGenerationError.invalidRequest(
                "seeds, batch_size, sampler, scheduler, shift, adapters and previews require a local image model")
        }
    }

    static func mediaErrorStatus(_ error: Error) -> HTTPResponseStatus {
        guard let media = error as? MediaGenerationError else {
            return .internalServerError
        }
        switch media {
        case .authenticationRequired: return .unauthorized
        case .insufficientFunds: return HTTPResponseStatus(statusCode: 402)
        case .contentPolicy, .invalidRequest, .invalidTarget: return .badRequest
        case .regionRestricted: return .forbidden
        case .providerUnavailable, .modelUnavailable: return .notFound
        case .queuedJobContinues: return .accepted
        case .unsupported: return .notImplemented
        case .server(let status, _): return HTTPResponseStatus(statusCode: status)
        case .invalidResponse, .transport: return .badGateway
        }
    }

    /// Row facts for the media routes; mirrors the keys `MediaActivityLogger`
    /// writes for in-app media jobs, so Insights shows both the same way
    /// (upstream).
    static func mediaActivityDetails(
        kind: String,
        operation: String,
        backend: MediaGenerationBackend,
        count: Int?,
        width: Int?,
        height: Int?,
        aspect: String?,
        resolution: String?,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var details: [String: String] = [
            "media_kind": kind,
            "operation": operation,
            "backend": String(describing: backend),
        ]
        if let count { details["count"] = String(count) }
        if let width, let height {
            details["size"] = "\(width)x\(height)"
        } else if let resolution, !resolution.isEmpty {
            details["size"] = aspect.map { "\(resolution) \($0)" } ?? resolution
        } else if let aspect, !aspect.isEmpty {
            details["size"] = aspect
        }
        details.merge(extra) { current, _ in current }
        return details
    }

    /// Running streamed cloud image requests, by job id, so
    /// `/images/cancel` can stop one (upstream stops these through the
    /// phone's detached job; Intel's callers name it by the `job_id` of the
    /// stream's events).
    static let runningImageJobs = RunningImageJobs()

    final class RunningImageJobs: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [String: Task<Void, Never>] = [:]

        func insert(_ id: String, _ task: Task<Void, Never>) {
            lock.lock()
            defer { lock.unlock() }
            tasks[id] = task
        }

        func remove(_ id: String) {
            lock.lock()
            defer { lock.unlock() }
            tasks[id] = nil
        }

        @discardableResult
        func cancel(_ id: String) -> Bool {
            lock.lock()
            let task = tasks.removeValue(forKey: id)
            lock.unlock()
            task?.cancel()
            return task != nil
        }
    }

    // MARK: - GET /images/models

    /// Upstream lists the on-device (MLX) image models; Intel has none.
    private func serveImageModels(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let body = (try? JSONEncoder.osaurusCanonical().encode(ImageModelsResponseDTO(object: "list", data: [])))
            .map { String(decoding: $0, as: UTF8.self) } ?? #"{"data":[],"object":"list"}"#
        sendResponse(context: context, status: .ok, headers: jsonHeaders(), body: body)
    }

    // MARK: - POST /images/generations

    private func serveImageGenerations(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let path = "/images/generations"
        let data = requestBodyData()
        let bodyString = String(decoding: data, as: UTF8.self)
        let loggedBody = Self.redactedMediaRequestBody(bodyString)
        guard let req = try? JSONDecoder().decode(ImageGenerationRequestDTO.self, from: data) else {
            sendMediaError(
                context: context, head: head, status: .badRequest, message: "Invalid request body", path: path,
                requestBody: loggedBody)
            return
        }
        let trimmedModel = req.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredTarget = SubagentConfigurationStore.snapshot().defaultImageGenerationTarget
        let selectedTarget =
            req.target?.target()
            ?? (trimmedModel?.isEmpty == false
                ? MediaModelTarget(backend: .local, modelID: trimmedModel!)
                : configuredTarget)
        guard let selectedTarget, selectedTarget.isValid else {
            sendMediaError(
                context: context, head: head, status: .badRequest,
                message:
                    "No image model specified and no default image generation model is configured (Settings → Agent Delegation).",
                path: path, requestBody: loggedBody)
            return
        }
        // Upstream runs a bare `model` (or a local target) on the on-device
        // engine, which is MLX.
        guard selectedTarget.backend != .local else {
            sendMediaError(
                context: context, head: head, status: .notImplemented,
                message: MediaGenerationCoordinator.intelLocalUnsupported, path: path, requestBody: loggedBody)
            return
        }
        do {
            try Self.validateRemoteImageBatch(req)
        } catch {
            sendMediaError(
                context: context, head: head, status: .badRequest, message: String(describing: error), path: path,
                requestBody: loggedBody)
            return
        }
        guard req.allow_remote_media_spend == true else {
            sendMediaError(
                context: context, head: head, status: .forbidden,
                message: "Remote image generation requires allow_remote_media_spend=true.", path: path,
                requestBody: loggedBody)
            return
        }
        serveRemoteImageGeneration(context: context, head: head, request: req, target: selectedTarget, logged: loggedBody)
    }

    private func serveRemoteImageGeneration(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        request req: ImageGenerationRequestDTO,
        target: MediaModelTarget,
        logged: String?
    ) {
        let path = "/images/generations"
        let (width, height) = Self.resolveImageSize(size: req.size, width: req.width, height: req.height)
        let request = MediaImageGenerationRequest(
            target: target,
            prompt: req.prompt,
            negativePrompt: req.negative_prompt,
            width: width,
            height: height,
            aspectRatio: req.aspect_ratio,
            resolution: req.resolution,
            quality: req.quality,
            steps: req.steps,
            guidance: req.guidance,
            seed: req.seed.flatMap(Int.init(exactly:)),
            count: min(4, max(1, req.n ?? 1)),
            format: Self.imageOutputFormat(req.output_format)
        )
        stateRef.value.routeLogsItself = true
        let startTime = stateRef.value.requestStartedAt ?? Date()
        let userAgent = head.headers.first(name: "User-Agent")
        let eventLoop = context.eventLoop
        let stateRef = self.stateRef
        let details = Self.mediaActivityDetails(
            kind: "image", operation: "generate", backend: target.backend,
            count: request.count, width: width, height: height,
            aspect: req.aspect_ratio, resolution: req.resolution)

        // A provider call doesn't stream, but a client that asked for SSE
        // still gets its answer as SSE: a `completed` or `error` event once
        // the provider is done (upstream).
        if req.stream == true {
            stateRef.value.isStreaming = true
            let writer = SSEResponseWriter()
            writer.writeHeaders(context, extraHeaders: stateRef.value.corsHeaders)
            let onLoop: @Sendable (@escaping @Sendable (ChannelHandlerContext) -> Void) -> Void = { body in
                eventLoop.execute {
                    guard let ctx = stateRef.value.contextBox else { return }
                    body(ctx)
                }
            }
            @Sendable func emit(_ event: ImageStreamEventDTO) {
                let json =
                    (try? JSONEncoder.osaurusCanonical().encode(event))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                onLoop { writer.writeRawJSONData(json, context: $0) }
            }
            let jobID = Self.shortId(prefix: "img")
            // The job id first, so a client can stop it (Intel addition:
            // upstream's on-device path opens with `queued`, its cloud path
            // doesn't, and its phone names the job itself).
            emit(ImageStreamEventDTO(type: "queued", job_id: jobID, model: target.modelID))
            let task = runRequestTask {
                defer {
                    Self.runningImageJobs.remove(jobID)
                    onLoop { writer.writeEnd($0) }
                }
                var status = 200
                var errorMessage: String?
                do {
                    let generated = try await MediaGenerationCoordinator.shared.generateImage(request)
                    guard !generated.isEmpty else { throw MediaGenerationError.invalidResponse }
                    let results = try generated.map { media in
                        ImageResultDTO(
                            url: nil,
                            b64_json: try Data(contentsOf: media.url).base64EncodedString(),
                            seed: req.seed ?? 0
                        )
                    }
                    try Task.checkCancellation()
                    emit(ImageStreamEventDTO(type: "completed", job_id: jobID, images: results))
                } catch where Task.isCancelled {
                    // Stopped (`/images/cancel`), said as upstream says it.
                    status = 499
                    emit(ImageStreamEventDTO(type: "cancelled", job_id: jobID))
                } catch {
                    status = Int(Self.mediaErrorStatus(error).code)
                    errorMessage = error.localizedDescription
                    emit(ImageStreamEventDTO(type: "error", job_id: jobID, message: error.localizedDescription))
                }
                self.logRequest(
                    method: "POST", path: path, userAgent: userAgent, requestBody: logged,
                    responseBody: "[stream]", responseStatus: status, startTime: startTime,
                    model: target.modelID, errorMessage: errorMessage, details: details)
            }
            Self.runningImageJobs.insert(jobID, task)
            return
        }

        runRequestTask {
            do {
                let generated = try await MediaGenerationCoordinator.shared.generateImage(request)
                guard !generated.isEmpty else { throw MediaGenerationError.invalidResponse }
                let results = try generated.map { media -> ImageResultDTO in
                    if req.response_format == "b64_json" {
                        let bytes = try Data(contentsOf: media.url)
                        return ImageResultDTO(url: nil, b64_json: bytes.base64EncodedString(), seed: req.seed ?? 0)
                    }
                    return ImageResultDTO(url: media.url.absoluteString, b64_json: nil, seed: req.seed ?? 0)
                }
                let response = ImagesResponseDTO(created: Int(Date().timeIntervalSince1970), data: results)
                let json = String(decoding: try JSONEncoder.osaurusCanonical().encode(response), as: UTF8.self)
                self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: json)
                var rowDetails = details
                rowDetails["count"] = String(generated.count)
                self.logRequest(
                    method: "POST", path: path, userAgent: userAgent, requestBody: logged, responseBody: json,
                    responseStatus: 200, startTime: startTime, model: target.modelID, details: rowDetails)
            } catch {
                let status = Self.mediaErrorStatus(error)
                let body = Self.mediaErrorBody(error.localizedDescription)
                self.respondOnLoop(eventLoop, status: status, headers: self.jsonHeaders(), body: body)
                self.logRequest(
                    method: "POST", path: path, userAgent: userAgent, requestBody: logged,
                    responseStatus: Int(status.code), startTime: startTime, model: target.modelID,
                    errorMessage: error.localizedDescription, details: details)
            }
        }
    }

    // MARK: - POST /images/edits, /images/upscale (on-device upstream)

    /// Upstream's checks, in its order; what passes them needs the
    /// on-device engine, so it answers 501.
    private func serveImageEdits(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let path = "/images/edits"
        let data = requestBodyData()
        let bodyString = String(decoding: data, as: UTF8.self)
        func fail(_ status: HTTPResponseStatus, _ message: String) {
            sendMediaError(context: context, head: head, status: status, message: message, path: path, requestBody: bodyString)
        }
        guard let req = try? JSONDecoder().decode(ImageEditRequestDTO.self, from: data) else {
            return fail(.badRequest, "Invalid request body")
        }
        let rawSources = req.images ?? [req.image].compactMap { $0 }
        guard rawSources.contains(where: { Self.decodeImageInput($0) != nil }) else {
            return fail(.badRequest, "edit requires a source image")
        }
        if req.mask != nil {
            return fail(.notImplemented, "mask editing is not supported by this model")
        }
        fail(.notImplemented, MediaGenerationCoordinator.intelLocalUnsupported)
    }

    private func serveImageUpscale(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let path = "/images/upscale"
        let data = requestBodyData()
        let bodyString = String(decoding: data, as: UTF8.self)
        func fail(_ status: HTTPResponseStatus, _ message: String) {
            sendMediaError(context: context, head: head, status: status, message: message, path: path, requestBody: bodyString)
        }
        guard let req = try? JSONDecoder().decode(ImageUpscaleRequestDTO.self, from: data),
            Self.decodeImageInput(req.image) != nil
        else {
            return fail(.badRequest, "Invalid request body")
        }
        if let format = req.output_format, !["png", "jpeg", "jpg", "webp"].contains(format.lowercased()) {
            return fail(.badRequest, "Invalid output_format: use png, jpeg, jpg or webp as supported by the model")
        }
        fail(.notImplemented, MediaGenerationCoordinator.intelLocalUnsupported)
    }

    // MARK: - POST /images/cancel, GET /images/jobs/{id}/events

    /// Stops a streamed cloud image request by the `job_id` of its events
    /// and answers `cancelled` whatever the id, as upstream does. A billed
    /// provider call already sent may still complete on the provider's side.
    private func serveImageCancel(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let data = requestBodyData()
        guard let req = try? JSONDecoder().decode(ImageCancelRequestDTO.self, from: data) else {
            sendMediaError(
                context: context, head: head, status: .badRequest, message: "Invalid request body",
                path: "/images/cancel", requestBody: String(decoding: data, as: UTF8.self))
            return
        }
        Self.runningImageJobs.cancel(req.job_id)
        let body = #"{"type":"cancelled","job_id":"\#(Self.escapeJSONString(req.job_id))"}"#
        sendResponse(context: context, status: .ok, headers: jsonHeaders(), body: body)
    }

    /// The phone's rejoin of an image job that outlived its connection
    /// (upstream §12.5). Owner-only; such jobs start only over the Secure
    /// Channel (`W-identity-mobile`), so every id is unknown.
    private func serveImageJobEvents(context: ChannelHandlerContext) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        sendResponse(context: context, status: .notFound, headers: jsonHeaders(), body: #"{"error":"job_not_found"}"#)
    }

    // MARK: - POST /videos/quote

    private func serveVideoQuote(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let path = "/videos/quote"
        let data = requestBodyData()
        let loggedBody = Self.redactedMediaRequestBody(String(decoding: data, as: UTF8.self))
        guard
            let dto = try? JSONDecoder().decode(VideoGenerationRequestDTO.self, from: data),
            let request = dto.request()
        else {
            sendMediaError(
                context: context, head: head, status: .badRequest, message: "Invalid video request or target",
                path: path, requestBody: loggedBody)
            return
        }
        stateRef.value.routeLogsItself = true
        let startTime = stateRef.value.requestStartedAt ?? Date()
        let userAgent = head.headers.first(name: "User-Agent")
        let eventLoop = context.eventLoop
        runRequestTask {
            do {
                let quote = try await MediaGenerationCoordinator.shared.quoteVideo(request)
                let receipt = await MediaQuoteStore.shared.issue(for: request, quote: quote)
                let response = VideoQuoteResponseDTO(
                    quote_usd: quote.usd,
                    quote_token: receipt.token,
                    expires_at: ISO8601DateFormatter().string(from: receipt.expiresAt)
                )
                let json = String(decoding: try JSONEncoder.osaurusCanonical().encode(response), as: UTF8.self)
                self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: json)
                self.logRequest(
                    method: "POST", path: path, userAgent: userAgent, requestBody: loggedBody, responseBody: json,
                    responseStatus: 200, startTime: startTime, model: request.target.modelID,
                    details: Self.mediaActivityDetails(
                        kind: "video", operation: "quote", backend: request.target.backend,
                        count: nil, width: nil, height: nil,
                        aspect: request.aspectRatio, resolution: request.resolution,
                        extra: ["duration": request.duration, "quote_usd": String(format: "%.4f", quote.usd)]))
            } catch {
                let status = Self.mediaErrorStatus(error)
                self.respondOnLoop(
                    eventLoop, status: status, headers: self.jsonHeaders(),
                    body: Self.mediaErrorBody(error.localizedDescription))
                self.logRequest(
                    method: "POST", path: path, userAgent: userAgent, requestBody: loggedBody,
                    responseStatus: Int(status.code), startTime: startTime, model: request.target.modelID,
                    errorMessage: error.localizedDescription)
            }
        }
    }

    // MARK: - POST /videos/generations

    private func serveVideoGeneration(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let path = "/videos/generations"
        let data = requestBodyData()
        let loggedBody = Self.redactedMediaRequestBody(String(decoding: data, as: UTF8.self))
        guard
            let dto = try? JSONDecoder().decode(VideoGenerationRequestDTO.self, from: data),
            let request = dto.request(),
            let quoteToken = dto.quote_token?.trimmingCharacters(in: .whitespacesAndNewlines),
            !quoteToken.isEmpty
        else {
            sendMediaError(
                context: context, head: head, status: .badRequest,
                message: "A valid target and prior quote_token are required", path: path, requestBody: loggedBody)
            return
        }
        guard request.target.backend == .local || dto.allow_remote_media_spend == true else {
            sendMediaError(
                context: context, head: head, status: .forbidden,
                message: "Remote video generation requires allow_remote_media_spend=true.", path: path,
                requestBody: loggedBody)
            return
        }
        stateRef.value.routeLogsItself = true
        let startTime = stateRef.value.requestStartedAt ?? Date()
        let userAgent = head.headers.first(name: "User-Agent")
        let eventLoop = context.eventLoop
        runRequestTask {
            do {
                let approvedQuote = try await MediaQuoteStore.shared.consume(token: quoteToken, for: request)
                let job = try await MediaGenerationCoordinator.shared.queueVideo(request, approvedQuote: approvedQuote)
                let json = String(
                    decoding: try JSONEncoder.osaurusCanonical().encode(VideoJobResponseDTO(job)), as: UTF8.self)
                self.respondOnLoop(eventLoop, status: .accepted, headers: self.jsonHeaders(), body: json)
                self.logRequest(
                    method: "POST", path: path, userAgent: userAgent, requestBody: loggedBody, responseBody: json,
                    responseStatus: 202, startTime: startTime, model: request.target.modelID,
                    details: Self.mediaActivityDetails(
                        kind: "video", operation: "generate", backend: request.target.backend,
                        count: 1, width: nil, height: nil,
                        aspect: request.aspectRatio, resolution: request.resolution,
                        extra: ["duration": request.duration, "job_id": job.id.uuidString]))
            } catch {
                let status = Self.mediaErrorStatus(error)
                self.respondOnLoop(
                    eventLoop, status: status, headers: self.jsonHeaders(),
                    body: Self.mediaErrorBody(error.localizedDescription))
                self.logRequest(
                    method: "POST", path: path, userAgent: userAgent, requestBody: loggedBody,
                    responseStatus: Int(status.code), startTime: startTime, model: request.target.modelID,
                    errorMessage: error.localizedDescription)
            }
        }
    }

    // MARK: - GET /videos/jobs/{id}, /videos/jobs/{id}/content

    static func videoJobID(fromPath path: String, suffix: String = "") -> UUID? {
        let prefix = "/videos/jobs/"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let raw = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard !raw.contains("/") else { return nil }
        return UUID(uuidString: raw)
    }

    private func serveVideoJob(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) {
        guard let id = Self.videoJobID(fromPath: path) else {
            sendMediaError(
                context: context, head: head, status: .badRequest, message: "Invalid video job id", path: path,
                requestBody: nil)
            return
        }
        let eventLoop = context.eventLoop
        runRequestTask {
            guard let job = await MediaGenerationCoordinator.shared.videoJob(id: id) else {
                self.respondOnLoop(
                    eventLoop, status: .notFound, headers: self.jsonHeaders(),
                    body: Self.mediaErrorBody("Video job not found"))
                return
            }
            let json =
                (try? JSONEncoder.osaurusCanonical().encode(VideoJobResponseDTO(job)))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: json)
        }
    }

    private func serveVideoContent(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) {
        guard let id = Self.videoJobID(fromPath: path, suffix: "/content") else {
            sendMediaError(
                context: context, head: head, status: .badRequest, message: "Invalid video job id", path: path,
                requestBody: nil)
            return
        }
        stateRef.value.routeLogsItself = true
        let startTime = stateRef.value.requestStartedAt ?? Date()
        let userAgent = head.headers.first(name: "User-Agent")
        let eventLoop = context.eventLoop
        runRequestTask {
            func fail(_ status: HTTPResponseStatus, _ message: String) {
                self.respondOnLoop(eventLoop, status: status, headers: self.jsonHeaders(), body: Self.mediaErrorBody(message))
                self.logRequest(
                    method: "GET", path: path, userAgent: userAgent, requestBody: nil,
                    responseStatus: Int(status.code), startTime: startTime, errorMessage: message)
            }
            guard let job = await MediaGenerationCoordinator.shared.videoJob(id: id) else {
                return fail(.notFound, "Video job not found")
            }
            guard job.state == .completed, let output = job.outputURL else {
                return fail(.conflict, "Video content is not available yet")
            }
            guard let data = try? Data(contentsOf: output, options: .mappedIfSafe) else {
                return fail(.internalServerError, "Stored video content is unavailable")
            }
            self.sendBytesOnLoop(eventLoop, data: data, contentType: "video/mp4")
            self.logRequest(
                method: "GET", path: path, userAgent: userAgent, requestBody: nil,
                responseStatus: 200, startTime: startTime, model: job.modelID)
        }
    }
}
