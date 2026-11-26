import AppKit
import Foundation
import Vision
import Testing

@testable import OsaurusCore

/// Deterministic error-flow coverage: no Vision request, model, network, or UI.
// Intel: the cloud-send loop tests of this upstream file (they need `ComputerUseLoop`)
// land with stage 4 of docs/W_COMPUTER_USE_PLAN.md.
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
}
