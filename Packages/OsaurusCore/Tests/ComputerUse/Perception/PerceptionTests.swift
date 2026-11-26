//
//  PerceptionTests.swift
//  OsaurusCoreTests — Computer Use
//
//  PR3 coverage for the local-first perception layer: the `CaptureRouter`
//  escalation ladder + cloud-route gating, the `CloudVisionConsent` gate, the
//  `FrameScrubber` type guarantee + masking superset invariant, the
//  `ComputerUseRunMetrics` buckets, and the ax-resolvable sweep.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

private func availability(screenRecording: Bool) -> MacDriverAvailability {
    MacDriverAvailability(accessibility: true, screenRecording: screenRecording, skyLight: true)
}

// MARK: - Capture router

@Suite struct CaptureRouterTests {
    @Test func testLadderEscalatesOneRungWithScreenRecording() {
        let av = availability(screenRecording: true)
        #expect(CaptureRouter.nextTier(current: .ax, reason: .axEmpty, availability: av) == .som)
        #expect(CaptureRouter.nextTier(current: .som, reason: .targetUnresolved, availability: av) == .vision)
        #expect(CaptureRouter.nextTier(current: .vision, reason: .pixelsRequested, availability: av) == .vision)
    }

    @Test func testNoScreenRecordingPinsToAx() {
        let av = availability(screenRecording: false)
        #expect(CaptureRouter.nextTier(current: .ax, reason: .axEmpty, availability: av) == .ax)
        #expect(!(CaptureRouter.canEscalate(from: .ax, availability: av)))
        #expect(CaptureRouter.canEscalate(from: .ax, availability: availability(screenRecording: true)))
        #expect(!(CaptureRouter.canEscalate(from: .vision, availability: availability(screenRecording: true))))
    }

    @Test func testEscalateForEmptyAXClimbsWhenPixelsAvailable() {
        let av = availability(screenRecording: true)
        // Empty view (0 items) escalates one rung up the ladder.
        #expect(CaptureRouter.escalateForEmptyAX(currentTier: .ax, itemCount: 0, availability: av) == .som)
        #expect(CaptureRouter.escalateForEmptyAX(currentTier: .som, itemCount: 0, availability: av) == .vision)
        // Already at the top → nothing to climb to.
        #expect(CaptureRouter.escalateForEmptyAX(currentTier: .vision, itemCount: 0, availability: av) == nil)
    }

    @Test func testEscalateForEmptyAXStaysOnPopulatedView() {
        let av = availability(screenRecording: true)
        #expect(CaptureRouter.escalateForEmptyAX(currentTier: .ax, itemCount: 3, availability: av) == nil)
        // A custom threshold treats a near-empty view as escalatable.
        #expect(CaptureRouter.escalateForEmptyAX(currentTier: .ax, itemCount: 1, availability: av, threshold: 2) == .som)
    }

    @Test func testEscalateForEmptyAXPinsWithoutScreenRecording() {
        // No pixels available → no escalation even on an empty view.
        #expect(CaptureRouter.escalateForEmptyAX(
                currentTier: .ax,
                itemCount: 0,
                availability: availability(screenRecording: false)
            ) == nil)
    }

    @Test func testCloudRouteRequiresConsent() async throws {
        let frame = try await makeScrubbedFrame()
        let av = availability(screenRecording: true)
        // No consent → no route, no matter that the frame is scrubbed.
        #expect(CaptureRouter.cloudRoute(scrubbed: frame, consentGranted: false, availability: av) == nil)
        // No screen recording → not permitted even with consent.
        #expect(!(CaptureRouter.cloudVisionPermitted(
                consentGranted: true,
                availability: availability(screenRecording: false)
            )))
        // Consent + screen recording → the cloud route exists, carrying the frame.
        guard
            case .cloudVision(let carried)? = CaptureRouter.cloudRoute(
                scrubbed: frame,
                consentGranted: true,
                availability: av
            )
        else {
            Issue.record("expected a cloudVision route"); return
        }
        #expect(carried == frame)
    }

    /// A scrubbed frame can only come from `FrameScrubber` — build one from a
    /// trivial solid image (no text ⇒ nothing masked, but still a `ScrubbedFrame`).
    private func makeScrubbedFrame() async throws -> ScrubbedFrame {
        let cu = renderCUImage(text: "")
        return try await FrameScrubber.scrub(cu, mode: .pii)
    }
}

// MARK: - Cloud vision consent

@Suite struct CloudVisionConsentTests {
    @MainActor
    @Test func testDefaultOffAndScopes() {
        let suite = "cu-consent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let consent = CloudVisionConsent(defaults: defaults)
        #expect(!(consent.isGranted))

        consent.grantForSession()
        #expect(consent.isGranted)
        #expect(!(consent.isPersistentlyGranted))

        consent.revoke()
        #expect(!(consent.isGranted))

        consent.grantPersistently()
        #expect(consent.isGranted)
        // A fresh instance over the same defaults sees the persisted grant.
        #expect(CloudVisionConsent(defaults: defaults).isPersistentlyGranted)

        consent.setPersistent(false)
        #expect(!(consent.isGranted))
    }
}

// MARK: - Frame scrubber

@Suite struct FrameScrubberTests {
    @Test func testReturnsScrubbedFrameForValidImage() async throws {
        let cu = renderCUImage(text: "hello world")
        let frame = try await FrameScrubber.scrub(cu, mode: .pii)
        #expect(frame.image.mimeType == "image/jpeg")
    }

    @Test func testAllTextMasksAtLeastAsMuchAsPII() async throws {
        // Independent of exact OCR output: masking every text region is a
        // superset of masking only the PII regions.
        let image = renderCGImage(text: "Reach me: jane.doe@example.com or 415-555-0142")
        let pii = try await FrameScrubber.scrub(cgImage: image, mode: .pii)
        let all = try await FrameScrubber.scrub(cgImage: image, mode: .allText)
        #expect(all.1.maskedRegions >= pii.1.maskedRegions)
        // If OCR ran at all, allText masks exactly the recognized regions.
        if all.1.textRegions > 0 {
            #expect(all.1.maskedRegions == all.1.textRegions)
        }
    }

    /// Regression for APPLE-MACOS-37K: a degenerate image Vision can't
    /// recognize must report failure instead of trapping on a double-resumed
    /// continuation or claiming an empty successful scan.
    @Test func testDegenerateImageDoesNotTrap() async {
        let image = renderCGImage(text: "", size: CGSize(width: 1, height: 1))
        for mode in [ScrubMode.pii, .allText] {
            do {
                let result = try await FrameScrubber.scrub(cgImage: image, mode: mode)
                #expect(result.1.textRegions == 0)
                #expect(result.1.maskedRegions == 0)
            } catch let error as FrameScrubError {
                switch error {
                case .recognitionFailed, .recognitionResultsUnavailable: break
                default: Issue.record("Unexpected degenerate-image failure: \(error)")
                }
            } catch {
                Issue.record("Unexpected failure: \(error)")
            }
        }
    }
}

// MARK: - Metrics

@Suite struct ComputerUseRunMetricsTests {
    @Test func testCountAndRateBuckets() {
        #expect(ComputerUseRunMetrics.countBucket(0) == "0")
        #expect(ComputerUseRunMetrics.countBucket(2) == "1-3")
        #expect(ComputerUseRunMetrics.countBucket(5) == "4-9")
        #expect(ComputerUseRunMetrics.countBucket(99) == "10+")

        #expect(ComputerUseRunMetrics.rateBucket(nil) == "na")
        #expect(ComputerUseRunMetrics.rateBucket(0.1) == "low")
        #expect(ComputerUseRunMetrics.rateBucket(0.5) == "med")
        #expect(ComputerUseRunMetrics.rateBucket(0.95) == "high")
    }

    @Test func testTierAndRateAccumulation() {
        var m = ComputerUseRunMetrics()
        #expect(m.axResolvableRate == nil)
        m.recordResolveAttempt(success: true)
        m.recordResolveAttempt(success: false)
        #expect(m.axResolvableRate == 0.5)

        #expect(m.maxTier == .ax)
        m.raiseTier(to: .som)
        #expect(m.maxTier == .som)
        m.raiseTier(to: .ax)  // never lowers
        #expect(m.maxTier == .som)
        m.raiseTier(to: .vision)
        #expect(m.maxTier == .vision)
    }
}

// MARK: - Ax-resolvable sweep

@Suite struct AxResolvableSweepTests {
    @Test func testSweepTalliesResolutionOutcomes() async {
        let driver = MockMacDriver.demo()  // pid 4242: Search textfield + Go button
        let probe = AxProbe(
            pid: 4242,
            targets: [
                AgentTarget(describe: "Go"),  // exact label → resolved
                AgentTarget(describe: "Search"),  // exact label → resolved
                AgentTarget(describe: "zzzzz"),  // no match → reobserve
            ]
        )
        let result = await AxResolvableSweep.run(driver: driver, probes: [probe])
        #expect(result.total == 3)
        #expect(result.resolved == 2)
        #expect(result.reobserve == 1)
        #expect(result.deadEnd == 0)
        #expect(abs(result.resolvableRate - 2.0 / 3.0) < 0.0001)
    }

    @Test func testEmptySweepHasZeroRate() async {
        let result = await AxResolvableSweep.run(driver: MockMacDriver(), probes: [])
        #expect(result.total == 0)
        #expect(result.resolvableRate == 0)
    }
}

// MARK: - Vision attachment decision

@Suite struct VisionAttachmentTests {
    private let frame = renderCUImage(text: "")
    private let av = availability(screenRecording: true)

    @Test func testNoImageOrNonVisionModelAttachesNothing() {
        let visionLocal = VisionContext(
            modelAcceptsImages: true,
            modelIsLocal: true,
            cloudConsent: false
        )
        #expect(VisionAttachment.decide(image: nil, context: visionLocal, availability: av) == .none)

        let nonVision = VisionContext(
            modelAcceptsImages: false,
            modelIsLocal: true,
            cloudConsent: true
        )
        #expect(VisionAttachment.decide(image: frame, context: nonVision, availability: av) == .none)
    }

    @Test func testLocalVisionModelAttachesDirectly() {
        let ctx = VisionContext(modelAcceptsImages: true, modelIsLocal: true, cloudConsent: false)
        #expect(VisionAttachment.decide(image: frame, context: ctx, availability: av) == .localFrame(frame))
    }

    @Test func testRemoteVisionModelNeedsConsent() {
        let consented = VisionContext(
            modelAcceptsImages: true,
            modelIsLocal: false,
            cloudConsent: true
        )
        #expect(VisionAttachment.decide(image: frame, context: consented, availability: av) == .needsScrubForCloud(frame))

        let noConsent = VisionContext(
            modelAcceptsImages: true,
            modelIsLocal: false,
            cloudConsent: false
        )
        #expect(VisionAttachment.decide(image: frame, context: noConsent, availability: av) == .none)
    }

    @Test func testRemoteVisionModelNeedsScreenRecordingForCloud() {
        // Consent without Screen Recording can't reach the cloud route.
        let ctx = VisionContext(modelAcceptsImages: true, modelIsLocal: false, cloudConsent: true)
        #expect(VisionAttachment.decide(
                image: frame,
                context: ctx,
                availability: availability(screenRecording: false)
            ) == .none)
    }
}

// MARK: - Image helpers

/// Render text onto a white background and return the CGImage.
private func renderCGImage(text: String, size: CGSize = CGSize(width: 640, height: 140)) -> CGImage {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    if !text.isEmpty {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34),
            .foregroundColor: NSColor.black,
        ]
        (text as NSString).draw(at: CGPoint(x: 20, y: 50), withAttributes: attrs)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

private func renderCUImage(text: String) -> CUImage {
    let cg = renderCGImage(text: text)
    let rep = NSBitmapImageRep(cgImage: cg)
    let data = rep.representation(using: .png, properties: [:])!
    return CUImage(
        base64: data.base64EncodedString(),
        mimeType: "image/png",
        width: cg.width,
        height: cg.height
    )
}
