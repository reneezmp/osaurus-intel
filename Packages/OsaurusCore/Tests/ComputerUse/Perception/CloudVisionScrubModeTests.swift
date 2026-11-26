//
//  CloudVisionScrubModeTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Audit-remediation coverage for the cloud-vision redaction posture (P0/P1):
//    • `CloudVisionConsent` exposes a persisted scrub-mode preference that
//      defaults to `.allText` (mask everything) — so non-PII on-screen text
//      never ships readable out of the box — and only flips to `.pii` when the
//      user knowingly opts in.
//    • `VisionContext.withConsent` flips just-in-time consent without losing the
//      run's resolved scrub mode.
//    • `VisionAttachment.wouldAttachWithConsent` recognizes exactly the case
//      where consent is the only thing between the run and a (scrubbed) cloud
//      attach, so the loop can offer the just-in-time prompt.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Persisted scrub-mode preference

@Suite struct CloudVisionScrubModeTests {
    @MainActor
    @Test func testDefaultsToAllTextAndPersistsOptIn() {
        let suite = "cu-scrub-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let consent = CloudVisionConsent(defaults: defaults)
        // Out of the box: mask everything (safest).
        #expect(!(consent.masksOnlyDetectedPII))
        #expect(consent.scrubMode == .allText)

        consent.setMasksOnlyDetectedPII(true)
        #expect(consent.scrubMode == .pii)
        // A fresh instance over the same defaults sees the persisted choice.
        #expect(CloudVisionConsent(defaults: defaults).masksOnlyDetectedPII)

        consent.setMasksOnlyDetectedPII(false)
        #expect(consent.scrubMode == .allText)
        #expect(!(CloudVisionConsent(defaults: defaults).masksOnlyDetectedPII))
    }
}

// MARK: - VisionContext consent override

@Suite struct VisionContextConsentTests {
    @Test func testWithConsentFlipsConsentButKeepsScrubMode() {
        let base = VisionContext(
            modelAcceptsImages: true,
            modelIsLocal: false,
            cloudConsent: false,
            cloudScrubMode: .pii
        )
        let granted = base.withConsent(true)
        #expect(granted.cloudConsent)
        #expect(granted.cloudScrubMode == .pii)
        #expect(granted.modelAcceptsImages == base.modelAcceptsImages)
        #expect(granted.modelIsLocal == base.modelIsLocal)
        // Original is unchanged (value semantics).
        #expect(!(base.cloudConsent))
    }

    @Test func testDefaultScrubModeIsAllText() {
        let ctx = VisionContext(modelAcceptsImages: true, modelIsLocal: false, cloudConsent: true)
        #expect(ctx.cloudScrubMode == .allText)
    }
}

// MARK: - Just-in-time consent eligibility

@Suite struct WouldAttachWithConsentTests {
    private let image = CUImage(base64: "AAAA", mimeType: "image/png", width: 1, height: 1)

    private func availability(screenRecording: Bool) -> MacDriverAvailability {
        MacDriverAvailability(accessibility: true, screenRecording: screenRecording, skyLight: true)
    }

    /// The canonical case: pixels in hand, a remote image model, Screen
    /// Recording on, but consent OFF → consent is the only blocker, so prompt.
    @Test func testTrueWhenOnlyConsentIsMissing() {
        let ctx = VisionContext(modelAcceptsImages: true, modelIsLocal: false, cloudConsent: false)
        #expect(VisionAttachment.wouldAttachWithConsent(
                image: image,
                context: ctx,
                availability: availability(screenRecording: true)
            ))
    }

    @Test func testFalseWhenConsentAlreadyGranted() {
        let ctx = VisionContext(modelAcceptsImages: true, modelIsLocal: false, cloudConsent: true)
        #expect(!(VisionAttachment.wouldAttachWithConsent(
                image: image,
                context: ctx,
                availability: availability(screenRecording: true)
            )))
    }

    @Test func testFalseForLocalModel() {
        // A local model never needs cloud consent (and never prompts for it).
        let ctx = VisionContext(modelAcceptsImages: true, modelIsLocal: true, cloudConsent: false)
        #expect(!(VisionAttachment.wouldAttachWithConsent(
                image: image,
                context: ctx,
                availability: availability(screenRecording: true)
            )))
    }

    @Test func testFalseWithoutScreenRecording() {
        // Without Screen Recording there are no pixels to send, so consent
        // wouldn't help — don't prompt.
        let ctx = VisionContext(modelAcceptsImages: true, modelIsLocal: false, cloudConsent: false)
        #expect(!(VisionAttachment.wouldAttachWithConsent(
                image: image,
                context: ctx,
                availability: availability(screenRecording: false)
            )))
    }

    @Test func testFalseWhenNoImageOrNonVisionModel() {
        let ctx = VisionContext(modelAcceptsImages: true, modelIsLocal: false, cloudConsent: false)
        #expect(!(VisionAttachment.wouldAttachWithConsent(
                image: nil,
                context: ctx,
                availability: availability(screenRecording: true)
            )))

        let nonVision = VisionContext(
            modelAcceptsImages: false,
            modelIsLocal: false,
            cloudConsent: false
        )
        #expect(!(VisionAttachment.wouldAttachWithConsent(
                image: image,
                context: nonVision,
                availability: availability(screenRecording: true)
            )))
    }
}
