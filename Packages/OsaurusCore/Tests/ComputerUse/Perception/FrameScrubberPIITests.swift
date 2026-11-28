//
//  FrameScrubberPIITests.swift
//  OsaurusCoreTests — Computer Use
//
//  W-privacy-filter stage 6: the `.pii` branch of `FrameScrubber` on the
//  rule-only Privacy Filter. Synthetic text and images only; the screen is
//  never captured. The line-level rule pass is pure, so it is tested without
//  Vision; the image test accepts a Vision failure as the fail-closed outcome.
//

import AppKit
import Foundation
import Testing
import Vision

@testable import OsaurusCore

@Suite struct FrameScrubberPIITests {
    private let ruleset = RegexEntityDetector.EffectiveRuleSet.defaultSafetyNet()
    private let lineBox = CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.1)

    @Test func emailMatchMasksOnlyItsSubrangeWhenGeometryExists() {
        let text = "Reach me at jane.doe@example.com today"
        let sub = CGRect(x: 0.4, y: 0.4, width: 0.3, height: 0.1)
        let hit = FrameScrubber.lineMasks(in: text, lineBox: lineBox, ruleset: ruleset, subrangeBox: { _ in sub })
        #expect(hit.regions == [sub])
        #expect(hit.categories["email"] == 1)
    }

    @Test func missingSubrangeGeometryMasksTheWholeLine() {
        let text = "Reach me at jane.doe@example.com today"
        let hit = FrameScrubber.lineMasks(in: text, lineBox: lineBox, ruleset: ruleset, subrangeBox: { _ in nil })
        #expect(hit.regions == [lineBox])
    }

    @Test func textWithoutDetectableDataMasksNothing() {
        let hit = FrameScrubber.lineMasks(
            in: "Settings General About", lineBox: lineBox, ruleset: ruleset, subrangeBox: { _ in nil })
        #expect(hit.regions.isEmpty)
        #expect(hit.categories.isEmpty)
    }

    @Test func luhnValidCardNumberIsDetectedButAnInvalidOneIsNot() {
        let valid = FrameScrubber.lineMasks(
            in: "Card 4111 1111 1111 1111", lineBox: lineBox, ruleset: ruleset, subrangeBox: { _ in nil })
        #expect(!valid.regions.isEmpty)
        let invalid = FrameScrubber.lineMasks(
            in: "Order 4111 1111 1111 1112", lineBox: lineBox, ruleset: ruleset, subrangeBox: { _ in nil })
        #expect(invalid.regions.isEmpty)
    }

    @Test func eachMatchOnALineGetsItsOwnRegion() {
        let text = "a@example.com and b@example.org"
        let hit = FrameScrubber.lineMasks(in: text, lineBox: lineBox, ruleset: ruleset, subrangeBox: { _ in nil })
        #expect(hit.regions.count == 2)
        #expect(hit.categories["email"] == 2)
    }

    /// The model hook finds nothing on this Mac, so asking for it changes nothing.
    @Test func modelHookIsInertOnIntel() async {
        let text = "Margaret Synthetic lives at 12 Example Road"
        #expect(await PrivacyFilterEngine.shared.modelSpans(in: text).isEmpty)
    }

    // MARK: - Whole-image behavior

    private struct NoTextProcessing: FrameImageProcessing {
        func recognizeText(in image: CGImage) throws -> [VNRecognizedTextObservation] { [] }
        func paintMasks(over image: CGImage, normalizedRegions: [CGRect]) throws -> CGImage {
            try NativeFrameImageProcessing().paintMasks(over: image, normalizedRegions: normalizedRegions)
        }
    }

    private func solidImage() -> CUImage {
        let context = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let data = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        return CUImage(base64: data.base64EncodedString(), mimeType: "image/png", width: 32, height: 32)
    }

    @Test func piiModeWithNoRecognizedTextStillReturnsAFrame() async throws {
        for useModel in [false, true] {
            let frame = try await FrameScrubber.scrub(
                solidImage(), mode: .pii, honorUserRules: false, useModelDetection: useModel,
                processing: NoTextProcessing())
            #expect(frame.report.textRegions == 0)
            #expect(frame.report.maskedRegions == 0)
            #expect(frame.report.categories.isEmpty)
        }
    }

    /// Rendered synthetic text through real Vision. If recognition fails on
    /// this Mac the scrub must fail closed (throw), never return the frame.
    @Test func piiModeMasksDetectedTextRegionsOrFailsClosed() async throws {
        let size = CGSize(width: 900, height: 140)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        ("Contact jane.doe@example.com" as NSString).draw(
            at: CGPoint(x: 20, y: 50),
            withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let image = rep.cgImage!
        do {
            let (_, report) = try await FrameScrubber.scrub(cgImage: image, mode: .pii)
            // Every masked region came from a detection (no model on this Mac).
            #expect(report.maskedRegions == report.categories.values.reduce(0, +))
            let all = try await FrameScrubber.scrub(cgImage: image, mode: .allText)
            #expect(all.1.maskedRegions >= report.maskedRegions || all.1.textRegions == 0)
        } catch let error as FrameScrubError {
            switch error {
            case .recognitionFailed, .recognitionResultsUnavailable: break
            default: Issue.record("Unexpected failure: \(error)")
            }
        }
    }
}
