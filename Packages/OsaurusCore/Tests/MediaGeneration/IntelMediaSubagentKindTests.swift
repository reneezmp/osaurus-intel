//
//  IntelMediaSubagentKindTests.swift
//  osaurus
//
//  The `image` / `video` subagent kinds (W-subagents stage 6): the cloud
//  branch of upstream's kinds on the shared host. Every external call is a
//  fake (`IntelMediaKindServices`): no media API, network, keychain or
//  `~/.osaurus`, and a recorder proves what was (not) spent. The spend gates
//  are the point: nothing generates without the agent's switch, a live
//  model, an allowed policy and (for Ask) an approved card.
//

import Foundation
import Testing

@testable import OsaurusCore

/// Thread-safe call log for the fakes.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _imageCalls: [MediaImageGenerationRequest] = []
    private var _quotes: [MediaVideoGenerationRequest] = []
    private var _videoCalls: [(MediaVideoGenerationRequest, MediaVideoQuote)] = []
    private var _approvals: [(tool: String, args: String)] = []
    private var _promoted: [String?] = []

    var imageCalls: [MediaImageGenerationRequest] { lock.withLock { _imageCalls } }
    var quotes: [MediaVideoGenerationRequest] { lock.withLock { _quotes } }
    var videoCalls: [(MediaVideoGenerationRequest, MediaVideoQuote)] { lock.withLock { _videoCalls } }
    var approvals: [(tool: String, args: String)] { lock.withLock { _approvals } }
    var promoted: [String?] { lock.withLock { _promoted } }

    func image(_ r: MediaImageGenerationRequest) { lock.withLock { _imageCalls.append(r) } }
    func quote(_ r: MediaVideoGenerationRequest) { lock.withLock { _quotes.append(r) } }
    func video(_ r: MediaVideoGenerationRequest, _ q: MediaVideoQuote) { lock.withLock { _videoCalls.append((r, q)) } }
    func approval(_ tool: String, _ args: String) { lock.withLock { _approvals.append((tool, args)) } }
    func promote(_ session: String?) { lock.withLock { _promoted.append(session) } }
}

private enum Fake {
    static let providerId = UUID()

    static func imageModel(_ id: String = "flux") -> MediaModelInfo {
        MediaModelInfo(
            target: MediaModelTarget(backend: .remoteProvider(providerId), modelID: id),
            displayName: id, providerName: "Venice", kind: .image, constraints: MediaModelConstraints(),
            offline: false)
    }

    static func videoModel(
        _ id: String = "wan", kind: MediaGenerationKind = .textToVideo,
        constraints: MediaModelConstraints = MediaModelConstraints(durations: ["5s"])
    ) -> MediaModelInfo {
        MediaModelInfo(
            target: MediaModelTarget(backend: .remoteProvider(providerId), modelID: id),
            displayName: id, providerName: "Venice", kind: kind, constraints: constraints, offline: false)
    }

    static func media(_ kind: MediaGenerationKind, ext: String, mime: String) -> GeneratedMedia {
        GeneratedMedia(
            url: URL(fileURLWithPath: "/tmp/osaurus-fake-\(UUID().uuidString).\(ext)"),
            mimeType: mime, modelID: "fake-model", kind: kind)
    }

    static func services(
        recorder: Recorder,
        enabled: Bool = true,
        permission: MediaToolPermission = .ask,
        target: MediaModelTarget? = nil,
        images: [MediaModelInfo] = [Fake.imageModel()],
        videos: [MediaModelInfo] = [Fake.videoModel()],
        approve: Bool = true,
        quote: Result<MediaVideoQuote, Error> = .success(MediaVideoQuote(usd: 0.5)),
        generateImage: (@Sendable () async throws -> [GeneratedMedia])? = nil,
        generateVideo: (@Sendable (@Sendable (MediaGenerationEvent) -> Void) async throws -> GeneratedMedia)? = nil
    ) -> IntelMediaKindServices {
        IntelMediaKindServices(
            agentSettings: { agentId, _, _ in
                IntelMediaToolSupport.AgentMediaSettings(
                    agentId: agentId, enabled: enabled, target: target, permission: permission)
            },
            imageCandidates: { images },
            videoCandidates: { videos },
            generateImage: { request in
                recorder.image(request)
                if let generateImage { return try await generateImage() }
                return [media(.image, ext: "png", mime: "image/png")]
            },
            quoteVideo: { request in
                recorder.quote(request)
                return try quote.get()
            },
            generateVideo: { request, quote, _, progress in
                recorder.video(request, quote)
                if let generateVideo { return try await generateVideo(progress) }
                return media(.textToVideo, ext: "mp4", mime: "video/mp4")
            },
            requestApproval: { tool, _, args in
                recorder.approval(tool, args)
                return approve
            },
            promote: { _, _, session in
                recorder.promote(session)
                return "FILE-CARD"
            }
        )
    }
}

private struct FakeQuoteError: LocalizedError {
    var errorDescription: String? { "quote service down" }
}

private func imageKind(
    _ services: IntelMediaKindServices, params: ImageJobParams? = nil, session: String? = "chat-1"
) -> ImageSubagentKind {
    ImageSubagentKind(
        params: params ?? ImageJobParams(prompt: "a lighthouse"), argumentsJSON: #"{"prompt":"a lighthouse"}"#,
        chatSessionId: session, services: services)
}

private func videoKind(
    _ services: IntelMediaKindServices, params: VideoJobParams? = nil, session: String? = "chat-1"
) -> VideoSubagentKind {
    VideoSubagentKind(
        params: params ?? VideoJobParams(prompt: "waves", duration: "5s"),
        argumentsJSON: #"{"prompt":"waves","duration":"5s"}"#, chatSessionId: session, services: services)
}

@Suite("Image and video subagent kinds", .serialized)
struct IntelMediaSubagentKindTests {

    // MARK: Image: spend gates

    @Test func imageIsRefusedWhenTheAgentSwitchIsOffAndNothingIsSpent() async {
        let recorder = Recorder()
        let result = await SubagentSession.run(
            imageKind(Fake.services(recorder: recorder, enabled: false)), tool: "image")
        #expect(!ToolEnvelope.isSuccess(result))
        #expect(result.contains("not enabled for this agent"))
        #expect(recorder.imageCalls.isEmpty)
        #expect(recorder.approvals.isEmpty)
    }

    @Test func imageDenyPolicyRefusesWithoutCardOrSpend() async {
        let recorder = Recorder()
        let result = await SubagentSession.run(
            imageKind(Fake.services(recorder: recorder, permission: .deny)), tool: "image")
        #expect(result.contains("\"kind\":\"rejected\""))
        #expect(recorder.approvals.isEmpty)
        #expect(recorder.imageCalls.isEmpty)
    }

    @Test func imageDeclinedCardSpendsNothing() async {
        let recorder = Recorder()
        let result = await SubagentSession.run(
            imageKind(Fake.services(recorder: recorder, approve: false)), tool: "image")
        #expect(result.contains("\"kind\":\"user_denied\""))
        #expect(recorder.approvals.count == 1)
        #expect(recorder.imageCalls.isEmpty)
    }

    @Test func imageAlwaysAsksEvenIfAnAlwaysAllowPolicyWasStored() async {
        // The UI offers only Ask and Deny for images; a hand-edited setting
        // must not turn a billable image into a silent one.
        let recorder = Recorder()
        let result = await SubagentSession.run(
            imageKind(Fake.services(recorder: recorder, permission: .alwaysAllow)), tool: "image")
        #expect(ToolEnvelope.isSuccess(result))
        #expect(recorder.approvals.count == 1)
        #expect(recorder.approvals.first?.tool == "image")
        #expect(recorder.approvals.first?.args.contains("billable remote provider") == true)
        #expect(recorder.imageCalls.count == 1)
    }

    @Test func imageUnknownRequestedModelNeverFallsBackToAnotherBillableModel() async {
        let recorder = Recorder()
        let params = ImageJobParams(prompt: "x", model: "nope")
        let result = await SubagentSession.run(
            imageKind(Fake.services(recorder: recorder), params: params), tool: "image")
        #expect(result.contains("\"kind\":\"unavailable\""))
        #expect(recorder.approvals.isEmpty)
        #expect(recorder.imageCalls.isEmpty)
    }

    @Test func imageConfiguredModelThatIsGoneDoesNotFallBack() async {
        let recorder = Recorder()
        let gone = MediaModelTarget(backend: .osaurusCloud, modelID: "gone")
        let result = await SubagentSession.run(
            imageKind(Fake.services(recorder: recorder, target: gone)), tool: "image")
        #expect(!ToolEnvelope.isSuccess(result))
        #expect(recorder.imageCalls.isEmpty)
    }

    @Test func imageLocalModelIsNotRunnableOnIntel() async {
        let recorder = Recorder()
        let local = MediaModelInfo(
            target: MediaModelTarget(backend: .local, modelID: "flux-local"), displayName: "flux-local",
            providerName: "On device", kind: .image, constraints: MediaModelConstraints(), offline: true)
        let result = await SubagentSession.run(
            imageKind(Fake.services(recorder: recorder, images: [local])), tool: "image")
        #expect(result.contains("Apple Silicon"))
        #expect(recorder.approvals.isEmpty)
        #expect(recorder.imageCalls.isEmpty)
    }

    // MARK: Image: happy path

    @Test func imageGeneratesOneImageWithTheSameBillingCardAndPayloadAsTheTool() async {
        let recorder = Recorder()
        let params = ImageJobParams(prompt: "a lighthouse", width: 9999, height: 100, steps: 500, seed: 7)
        let result = await SubagentSession.run(
            imageKind(Fake.services(recorder: recorder), params: params, session: "chat-42"), tool: "image")
        #expect(ToolEnvelope.isSuccess(result))
        let request = recorder.imageCalls.first
        #expect(recorder.imageCalls.count == 1)
        #expect(request?.count == 1)
        #expect(request?.width == 4096)
        #expect(request?.height == 256)
        #expect(request?.steps == 50)
        #expect(request?.seed == 7)
        let payload = ToolEnvelope.successPayload(result) as? [String: Any]
        #expect(payload?["kind"] as? String == "generated_media_job")
        #expect(payload?["media_type"] as? String == "image")
        #expect(payload?["already_displayed"] as? Bool == true)
        #expect(payload?["text"] as? String == "FILE-CARD")
        // The artifact goes to the chat the call came from, not the host's scope id.
        #expect(recorder.promoted == ["chat-42"])
    }

    @Test func imageOutsideAChatPromotesNothing() async {
        let recorder = Recorder()
        let result = await SubagentSession.run(
            imageKind(Fake.services(recorder: recorder), session: nil), tool: "image")
        #expect(ToolEnvelope.isSuccess(result))
        #expect(recorder.promoted.count == 1)
        #expect(recorder.promoted.first! == nil)
    }

    @Test func imageProviderFailureIsAnEnvelopeNotACrash() async {
        let recorder = Recorder()
        let result = await SubagentSession.run(
            imageKind(
                Fake.services(
                    recorder: recorder, generateImage: { throw MediaGenerationError.insufficientFunds })),
            tool: "image")
        #expect(!ToolEnvelope.isSuccess(result))
        #expect(result.contains("\"kind\":\"execution_error\""))
    }

    @Test func imageStopFromTheFeedCancelsTheWaitAndReportsUserStop() async {
        let recorder = Recorder()
        let services = Fake.services(
            recorder: recorder,
            generateImage: {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return []
            })
        let kind = imageKind(services)
        let interrupt = InterruptToken()
        let feed = SubagentFeed(toolCallId: "t", kindId: "image", title: "image")
        let scope = SubagentScope(sessionId: "s", toolCallId: "t", agentId: UUID())
        let resolved = ResolvedModel(name: "flux", id: nil, isLocal: false)
        _ = try? await kind.resolveModel(scope)
        let run = Task { try await kind.run(scope, resolved, feed: feed, interrupt: interrupt) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        interrupt.interrupt()
        do {
            _ = try await run.value
            Issue.record("expected the run to stop")
        } catch let error as SubagentError {
            guard case .userDenied = error else {
                Issue.record("expected userDenied, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: Video: spend gates

    @Test func videoSwitchOffSpendsAndQuotesNothing() async {
        let recorder = Recorder()
        let result = await SubagentSession.run(
            videoKind(Fake.services(recorder: recorder, enabled: false)), tool: "video")
        #expect(result.contains("not enabled for this agent"))
        #expect(recorder.quotes.isEmpty)
        #expect(recorder.videoCalls.isEmpty)
    }

    @Test func videoCatalogMismatchFailsBeforeAnyQuote() async {
        let recorder = Recorder()
        let params = VideoJobParams(prompt: "waves", duration: "8s")
        let result = await SubagentSession.run(
            videoKind(Fake.services(recorder: recorder), params: params), tool: "video")
        #expect(result.contains("\"field\":\"duration\""))
        #expect(recorder.quotes.isEmpty)
        #expect(recorder.videoCalls.isEmpty)
    }

    @Test func videoDenyNeverReachesTheProviderNotEvenForAQuote() async {
        let recorder = Recorder()
        let result = await SubagentSession.run(
            videoKind(Fake.services(recorder: recorder, permission: .deny)), tool: "video")
        #expect(result.contains("\"kind\":\"rejected\""))
        #expect(recorder.quotes.isEmpty)
        #expect(recorder.approvals.isEmpty)
        #expect(recorder.videoCalls.isEmpty)
    }

    @Test func videoQuoteFailureRefusesWithoutQueueing() async {
        let recorder = Recorder()
        let result = await SubagentSession.run(
            videoKind(Fake.services(recorder: recorder, quote: .failure(FakeQuoteError()))), tool: "video")
        #expect(result.contains("Could not quote this video"))
        #expect(recorder.approvals.isEmpty)
        #expect(recorder.videoCalls.isEmpty)
    }

    @Test func videoAskShowsTheQuoteAndADeclineQueuesNothing() async {
        let recorder = Recorder()
        let result = await SubagentSession.run(
            videoKind(Fake.services(recorder: recorder, approve: false)), tool: "video")
        #expect(result.contains("\"kind\":\"user_denied\""))
        #expect(recorder.approvals.count == 1)
        #expect(recorder.approvals.first?.args.contains("quote_usd") == true)
        #expect(recorder.videoCalls.isEmpty)
    }

    @Test func videoApprovedQueuesOnceWithTheApprovedQuote() async {
        let recorder = Recorder()
        let result = await SubagentSession.run(
            videoKind(Fake.services(recorder: recorder), session: "chat-9"), tool: "video")
        #expect(ToolEnvelope.isSuccess(result))
        #expect(recorder.quotes.count == 1)
        #expect(recorder.videoCalls.count == 1)
        #expect(recorder.videoCalls.first?.1 == MediaVideoQuote(usd: 0.5))
        let payload = ToolEnvelope.successPayload(result) as? [String: Any]
        #expect(payload?["media_type"] as? String == "video")
        #expect(payload?["quote_usd"] as? Double == 0.5)
        #expect(payload?["text"] as? String == "FILE-CARD")
        #expect(recorder.promoted == ["chat-9"])
    }

    @Test func videoAlwaysAllowSkipsTheCardButStillUsesTheQuote() async {
        let recorder = Recorder()
        let result = await SubagentSession.run(
            videoKind(Fake.services(recorder: recorder, permission: .alwaysAllow)), tool: "video")
        #expect(ToolEnvelope.isSuccess(result))
        #expect(recorder.approvals.isEmpty)
        #expect(recorder.videoCalls.first?.1 == MediaVideoQuote(usd: 0.5))
    }

    @Test func videoWrongModelKindForImageToVideoIsUnavailable() async throws {
        try await StoragePathsTestLock.shared.run {
            let previous = OsaurusPaths.overrideRoot
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-video-kind-\(UUID().uuidString)", isDirectory: true)
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: root)
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let png = Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )!
            let frame = root.appendingPathComponent("frame.png")
            try png.write(to: frame)

            // Only a text-to-video model is connected: image-to-video has none.
            let recorder = Recorder()
            let params = VideoJobParams(prompt: "waves", duration: "5s", sourcePath: frame.path)
            let result = await SubagentSession.run(
                videoKind(Fake.services(recorder: recorder), params: params), tool: "video")
            #expect(result.contains("No configured image-to-video model"))
            #expect(recorder.quotes.isEmpty)

            // With an image-to-video model the source is read and sent.
            let i2v = Fake.videoModel("i2v", kind: .imageToVideo)
            let ok = await SubagentSession.run(
                videoKind(Fake.services(recorder: recorder, videos: [i2v]), params: params), tool: "video")
            #expect(ToolEnvelope.isSuccess(ok))
            #expect(recorder.videoCalls.first?.0.sourceImage == png)
            #expect(recorder.videoCalls.first?.0.sourceImageMIMEType == "image/png")

            // A source outside the Osaurus root fails before any quote.
            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent("outside-\(UUID().uuidString).png")
            try png.write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            let quotesBefore = recorder.quotes.count
            let bad = await SubagentSession.run(
                videoKind(
                    Fake.services(recorder: recorder, videos: [i2v]),
                    params: VideoJobParams(prompt: "waves", duration: "5s", sourcePath: outside.path)),
                tool: "video")
            #expect(bad.contains("\"field\":\"source_path\""))
            #expect(recorder.quotes.count == quotesBefore)
        }
    }

    // MARK: Video: progress and cancellation

    @Test func videoProgressCoalescesIntoOneEtaRow() {
        let feed = SubagentFeed(toolCallId: "t", kindId: "video", title: "video")
        VideoSubagentKind.emit(.queued(jobID: "job-1"), to: feed)
        VideoSubagentKind.emit(.running(progress: nil, etaSeconds: 40), to: feed)
        VideoSubagentKind.emit(.running(progress: 0.5, etaSeconds: 20), to: feed)
        let events = feed.currentEvents()
        let rows = events.filter { $0.title == "generating video" }
        #expect(rows.count == 1)
        #expect(rows.first?.detail == "~20s left")
        #expect(rows.first?.fraction == 0.5)
        #expect(events.contains { $0.title == "queued" && $0.detail == "job-1" })
    }

    @Test func videoProgressFromTheCoordinatorReachesTheFeed() async throws {
        let recorder = Recorder()
        let services = Fake.services(
            recorder: recorder,
            generateVideo: { progress in
                progress(.queued(jobID: "j"))
                progress(.running(progress: nil, etaSeconds: 12))
                return Fake.media(.textToVideo, ext: "mp4", mime: "video/mp4")
            })
        let kind = videoKind(services)
        let scope = SubagentScope(sessionId: "s", toolCallId: "t", agentId: UUID())
        let resolved = try await kind.resolveModel(scope)
        #expect(await kind.permission(scope, resolved) == .allow)
        let feed = SubagentFeed(toolCallId: "t", kindId: "video", title: "video")
        _ = try await kind.run(scope, resolved, feed: feed, interrupt: InterruptToken())
        let titles = feed.currentEvents().map(\.title)
        #expect(titles.contains("quoted"))
        #expect(titles.contains("queued"))
        #expect(titles.contains("generating video"))
    }

    @Test func videoQueuedJobContinuesIsReportedRetryableNotAsAFailure() async {
        let recorder = Recorder()
        let result = await SubagentSession.run(
            videoKind(
                Fake.services(
                    recorder: recorder,
                    generateVideo: { _ in throw MediaGenerationError.queuedJobContinues("job-7") })),
            tool: "video")
        #expect(!ToolEnvelope.isSuccess(result))
        #expect(result.contains("\"retryable\":true"))
    }

    // MARK: Host and wiring

    @Test func kindsUseTheRegisteredImageAndVideoCapabilities() {
        let services = Fake.services(recorder: Recorder())
        #expect(imageKind(services).capability.id == "image")
        #expect(videoKind(services).capability.id == "video")
        #expect(imageKind(services).feedTitle == "image: a lighthouse")
    }

    @Test func aRunningSubagentCannotStartAnImage() async {
        // The host's one recursion guard covers the media kinds too.
        let recorder = Recorder()
        let outer = imageKind(
            Fake.services(
                recorder: recorder,
                generateImage: {
                    let nested = await SubagentSession.run(
                        imageKind(Fake.services(recorder: recorder)), tool: "image")
                    #expect(nested.contains("cannot be called from inside a running subagent"))
                    return [Fake.media(.image, ext: "png", mime: "image/png")]
                }))
        _ = await SubagentSession.run(outer, tool: "image")
        // Only the outer run reached the generator that matters: the nested
        // call was refused before resolving a model.
        #expect(recorder.imageCalls.count == 1)
    }

    @Test func theToolsRunThroughTheHostWithTheCloudSwitchStillGating() async throws {
        // Live services with no agent context: the built-in agent never has
        // the switch, so the tool refuses before any model or network use.
        let image = try await ImageTool().execute(argumentsJSON: #"{"prompt":"a lighthouse"}"#)
        #expect(!ToolEnvelope.isSuccess(image))
        #expect(image.contains("not enabled for this agent"))
        let video = try await VideoTool().execute(argumentsJSON: #"{"prompt":"waves","duration":"5s"}"#)
        #expect(!ToolEnvelope.isSuccess(video))
        #expect(video.contains("not enabled for this agent"))
    }
}
