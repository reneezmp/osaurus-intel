import AppKit
import Foundation
import Vision
import Testing

@testable import OsaurusCore

/// Deterministic error-flow coverage: no Vision request, model, network, or UI.
@Suite struct FrameScrubFailureTests {
    private struct Processing: FrameImageProcessing {
        let recognitionError: FrameScrubError?
        let nativeRecognitionError: Bool
        let failPainting: Bool

        init(
            recognitionError: FrameScrubError? = nil,
            nativeRecognitionError: Bool = false,
            failPainting: Bool = false
        ) {
            self.recognitionError = recognitionError
            self.nativeRecognitionError = nativeRecognitionError
            self.failPainting = failPainting
        }

        func recognizeText(in image: CGImage) throws -> [VNRecognizedTextObservation] {
            if let recognitionError { throw recognitionError }
            if nativeRecognitionError { throw NSError(domain: "VisionProbe", code: 37) }
            return []
        }

        func paintMasks(over image: CGImage, normalizedRegions: [CGRect]) throws -> CGImage {
            if failPainting { throw NSError(domain: "PainterProbe", code: 1) }
            return try NativeFrameImageProcessing().paintMasks(over: image, normalizedRegions: normalizedRegions)
        }
    }

    private actor Calls {
        private(set) var model = 0
        private(set) var consent = 0
        private(set) var scrub = 0
        func recordModel() { model += 1 }
        func recordConsent() { consent += 1 }
        func recordScrub() { scrub += 1 }
    }

    private func image() -> CUImage {
        let context = CGContext(
            data: nil,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        let data = bitmap.representation(using: .png, properties: [:])!
        return CUImage(base64: data.base64EncodedString(), mimeType: "image/png", width: 32, height: 32)
    }

    private func scrub(
        _ image: CUImage,
        processing: Processing,
        mode: ScrubMode = .allText
    ) async throws -> ScrubbedFrame {
        try await FrameScrubber.scrub(
            image,
            mode: mode,
            honorUserRules: false,
            useModelDetection: false,
            processing: processing
        )
    }

    @Test func testRecognitionFailureIsNotAnEmptySuccessfulScan() async {
        for mode in [ScrubMode.pii, .allText] {
            do {
                _ = try await scrub(image(), processing: Processing(nativeRecognitionError: true), mode: mode)
                Issue.record("Failed recognition must not produce a ScrubbedFrame")
            } catch let error as FrameScrubError {
                #expect(error == .recognitionFailed(domain: "VisionProbe", code: 37))
            } catch { Issue.record("Unexpected error: \(error)") }
        }
    }

    @Test func testUnavailableRecognitionResultsRemainAFailure() async {
        do {
            _ = try await scrub(image(), processing: Processing(recognitionError: .recognitionResultsUnavailable))
            Issue.record("Unavailable results must not become an empty scan")
        } catch let error as FrameScrubError {
            #expect(error == .recognitionResultsUnavailable)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func testPainterFailureCannotReturnOriginalPixels() async {
        do {
            _ = try await scrub(image(), processing: Processing(failPainting: true))
            Issue.record("Painting failure must not return original pixels")
        } catch let error as FrameScrubError {
            #expect(error == .paintingFailed)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func testInvalidEncodedImageThrowsBeforeRecognition() async {
        let invalid = CUImage(base64: "invalid", mimeType: "image/png", width: 32, height: 32)
        do {
            _ = try await scrub(invalid, processing: Processing())
            Issue.record("Invalid image must not return nil or a successful frame")
        } catch let error as FrameScrubError {
            #expect(error == .imageDecodeFailed)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func testSuccessfulNoTextScanStillAttachesForCloud() async throws {
        var messages = [ChatMessage(role: "user", content: "goal")]
        var tokens = 0
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "empty-scan", kindId: "computer_use", title: "test")
        try await ComputerUseLoop.attachScrubbedForCloud(
            image(),
            vision: remote(consent: true),
            availability: available,
            messages: &messages,
            imageTokensInContext: &tokens,
            metrics: &metrics,
            feed: feed,
            step: 0,
            scrubFrame: { image, mode in
                try await FrameScrubber.scrub(
                    image,
                    mode: mode,
                    honorUserRules: false,
                    useModelDetection: false,
                    processing: Processing()
                )
            }
        )
        #expect(messages.flatMap(\.imageUrls).count == 1)
        #expect(tokens > 0)
        #expect(metrics.cloudVisionUsed)
        #expect(feed.currentEvents().contains { $0.title == "Attached a screenshot" })
    }

    @Test func testCloudFailureLeavesAttachmentBookkeepingUntouched() async {
        for failure in [FrameScrubError.recognitionFailed(domain: "VisionProbe", code: 37), .paintingFailed] {
            var messages = [ChatMessage(role: "user", content: "goal")]
            var tokens = 17
            var metrics = ComputerUseRunMetrics()
            let feed = SubagentFeed(toolCallId: "scrub-failure", kindId: "computer_use", title: "test")
            do {
                try await ComputerUseLoop.attachScrubbedForCloud(
                    image(),
                    vision: remote(consent: true),
                    availability: available,
                    messages: &messages,
                    imageTokensInContext: &tokens,
                    metrics: &metrics,
                    feed: feed,
                    step: 0,
                    scrubFrame: { _, _ in throw failure }
                )
                Issue.record("The cloud attachment caller must propagate scrub failure")
            } catch let error as FrameScrubError { #expect(error == failure) } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(messages.count == 1)
            #expect(messages[0].content == "goal")
            #expect(messages.flatMap(\.imageUrls).isEmpty)
            #expect(tokens == 17)
            #expect(!(metrics.cloudVisionUsed))
            #expect(!(feed.currentEvents().contains { $0.title == "Attached a screenshot" }))
        }
    }

    @Test func testConsentedCloudRecognitionFailureStopsBeforeModelSend() async {
        await assertRunFailure(consent: true, processing: Processing(nativeRecognitionError: true))
    }

    @Test func testJustInTimeConsentRecognitionFailureStopsBeforeModelSend() async {
        await assertRunFailure(consent: false, processing: Processing(nativeRecognitionError: true))
    }

    @Test func testConsentedCloudPaintingFailureStopsBeforeModelSend() async {
        await assertRunFailure(consent: true, processing: Processing(failPainting: true))
    }

    @Test func testJustInTimeConsentPaintingFailureStopsBeforeModelSend() async {
        await assertRunFailure(consent: false, processing: Processing(failPainting: true))
    }

    @Test func testLocalFramesBypassCloudScrubbing() async {
        let calls = Calls()
        let feed = SubagentFeed(toolCallId: "local-frame", kindId: "computer_use", title: "test")
        _ = await ComputerUseLoop.run(
            goal: "test",
            modelId: "test-model",
            driver: driver(image()),
            gate: HardwiredGate(),
            feed: feed,
            interrupt: InterruptToken(),
            confirm: { _ in true },
            vision: VisionContext(modelAcceptsImages: true, modelIsLocal: true, cloudConsent: false),
            sessionId: "local-frame",
            scrubFrame: { _, _ in
                await calls.recordScrub()
                throw FrameScrubError.paintingFailed
            },
            nextAction: { _ in
                await calls.recordModel()
                return ModelActionCall(id: "give-up", arguments: #"{"verb":"give_up","reason":"test complete"}"#)
            }
        )
        let scrubCalls = await calls.scrub
        let modelCalls = await calls.model
        #expect(scrubCalls == 0)
        #expect(modelCalls == 1)
        #expect(feed.currentEvents().contains { $0.title == "Attached a screenshot" && $0.detail == "on-device" })
        #expect(!(feed.currentEvents().contains { $0.kind == .error }))
    }

    @Test func testSubsequentFrameFailureStopsBeforeSecondModelSend() async {
        let calls = Calls()
        let feed = SubagentFeed(toolCallId: "later-failure", kindId: "computer_use", title: "test")
        let pid: Int32 = 4242
        let initial = CUSnapshot(
            snapshotId: 1,
            pid: pid,
            app: "Demo",
            focusedWindow: "Main",
            tier: .ax,
            truncated: false,
            windows: [],
            elements: [CUElement(id: "label", role: "statictext", label: "Ready")],
            image: nil
        )
        let later = CUSnapshot(
            snapshotId: 2,
            pid: pid,
            app: "Demo",
            focusedWindow: "Main",
            tier: .ax,
            truncated: false,
            windows: [],
            elements: [],
            image: image()
        )
        let driver = MockMacDriver(
            availability: available,
            activeWindow: CUActiveWindow(pid: pid, app: "Demo", title: "Main", x: 0, y: 0, w: 32, h: 32),
            snapshots: [pid: [initial, later]]
        )
        let result = await ComputerUseLoop.run(
            goal: "test",
            modelId: "test-model",
            driver: driver,
            gate: HardwiredGate(),
            feed: feed,
            interrupt: InterruptToken(),
            confirm: { _ in true },
            vision: remote(consent: true),
            sessionId: "later-failure",
            scrubFrame: { _, _ in
                await calls.recordScrub()
                throw FrameScrubError.paintingFailed
            },
            nextAction: { _ in
                await calls.recordModel()
                return ModelActionCall(id: "observe", arguments: #"{"verb":"observe"}"#)
            }
        )
        guard case .failed = result.outcome else { Issue.record("Expected failure, got \(result.outcome)"); return }
        let modelCalls = await calls.model
        let scrubCalls = await calls.scrub
        #expect(modelCalls == 1, "Later failed frame must not reach the second model request")
        #expect(scrubCalls == 1)
        #expect(result.metrics.steps == 1)
        #expect(!(result.metrics.cloudVisionUsed))
        #expect(!(feed.currentEvents().contains { $0.title == "Attached a screenshot" }))
        #expect(feed.currentEvents().contains { $0.kind == .error })
        guard case .finished(let success, _) = feed.currentStatus() else { Issue.record("Run feed not finished"); return }
        #expect(!(success))
    }

    @Test func testCancelledScrubInterruptsWithoutModelSendOrProcessingError() async {
        let calls = Calls()
        let feed = SubagentFeed(toolCallId: "cancelled", kindId: "computer_use", title: "test")
        let result = await ComputerUseLoop.run(
            goal: "test",
            modelId: "test-model",
            driver: driver(image()),
            gate: HardwiredGate(),
            feed: feed,
            interrupt: InterruptToken(),
            confirm: { _ in true },
            vision: remote(consent: true),
            sessionId: "cancelled",
            scrubFrame: { _, _ in throw CancellationError() },
            nextAction: { _ in
                await calls.recordModel()
                return nil
            }
        )
        #expect(result.outcome == .interrupted)
        let modelCalls = await calls.model
        #expect(modelCalls == 0)
        #expect(!(result.metrics.cloudVisionUsed))
        #expect(!(feed.currentEvents().contains { $0.kind == .error }))
        guard case .finished(let success, _) = feed.currentStatus() else { Issue.record("Run feed not finished"); return }
        #expect(!(success))
    }

    private let available = MacDriverAvailability(accessibility: true, screenRecording: true, skyLight: true)

    private func remote(consent: Bool) -> VisionContext {
        VisionContext(modelAcceptsImages: true, modelIsLocal: false, cloudConsent: consent)
    }

    private func driver(_ image: CUImage) -> MockMacDriver {
        let pid: Int32 = 4242
        let snapshot = CUSnapshot(
            snapshotId: 1,
            pid: pid,
            app: "Demo",
            focusedWindow: "Main",
            tier: .ax,
            truncated: false,
            windows: [],
            elements: [],
            image: image
        )
        return MockMacDriver(
            availability: available,
            activeWindow: CUActiveWindow(pid: pid, app: "Demo", title: "Main", x: 0, y: 0, w: 32, h: 32),
            snapshots: [pid: [snapshot]]
        )
    }

    private func assertRunFailure(consent: Bool, processing: Processing) async {
        let calls = Calls()
        let feed = SubagentFeed(toolCallId: "run-failure", kindId: "computer_use", title: "test")
        let result = await ComputerUseLoop.run(
            goal: "test",
            modelId: "test-model",
            driver: driver(image()),
            gate: HardwiredGate(),
            feed: feed,
            interrupt: InterruptToken(),
            confirm: { _ in true },
            requestCloudVisionConsent: {
                await calls.recordConsent()
                return .allowOnce
            },
            vision: remote(consent: consent),
            sessionId: "run-failure",
            scrubFrame: { image, mode in
                await calls.recordScrub()
                return try await FrameScrubber.scrub(
                    image,
                    mode: mode,
                    honorUserRules: false,
                    useModelDetection: false,
                    processing: processing
                )
            },
            nextAction: { _ in
                await calls.recordModel()
                return nil
            }
        )
        guard case .failed = result.outcome else { Issue.record("Expected visible failure, got \(result.outcome)"); return }
        let modelCalls = await calls.model
        let scrubCalls = await calls.scrub
        let consentCalls = await calls.consent
        #expect(modelCalls == 0, "No model request may consume a failed scrub")
        #expect(scrubCalls == 1)
        #expect(consentCalls == (consent ? 0 : 1))
        #expect(!(result.metrics.cloudVisionUsed))
        #expect(feed.currentEvents().contains { $0.kind == .error })
        #expect(!(feed.currentEvents().contains { $0.title == "Attached a screenshot" }))
        guard case .finished(let success, _) = feed.currentStatus() else { Issue.record("Run feed not finished"); return }
        #expect(!(success))
    }
}
