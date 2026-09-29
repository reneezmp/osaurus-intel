//
//  RemoteImagePayloadPolicy.swift
//  Intel: image-size helpers only (used by file_read OCR/loading). Upstream
//  also rewrites vision message parts, which Intel's text-only chat lacks.
//  osaurus
//
//  Client-side sizing for images bound to REMOTE providers.
//
//  Chat attachments enter the message set as full-resolution `data:` URIs
//  labeled `image/png` regardless of their actual bytes. Local VL models
//  are fine with that — their processors downscale internally and vmlx
//  sniffs the container. Remote APIs are not: a Retina screenshot base64s
//  into tens of megabytes (relay/provider 413), and a JPEG mislabeled
//  `image/png` is a provider 400 waiting to happen.
//
//  This policy runs once, in `RemoteProviderService.applyPrivacyOutbound`
//  — the single funnel every remote request passes through — and never on
//  the local path:
//    - images longer than `maxLongSidePixels` on their long side, or larger
//      than `maxEncodedBytes`, are downscaled and re-encoded as JPEG; the
//      re-encode is adopted ONLY when it is actually smaller,
//    - images left byte-identical get their data-URI mime corrected to the
//      container's real type.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RemoteImagePayloadPolicy {
    /// Longest-side budget for a remote-bound image. 2048 px keeps text in
    /// screenshots legible for every current vision API while cutting a 5K
    /// Retina capture's payload by an order of magnitude.
    static let maxLongSidePixels = 2048
    /// Encoded-bytes budget per image. Anthropic caps a single image at 5 MB
    /// and Gemini rejects oversized inline data with a 400/413; 4 MB clears
    /// both with headroom for the base64 expansion.
    static let maxEncodedBytes = 4 * 1024 * 1024
    /// JPEG quality for the re-encode. High enough that screenshots and
    /// photos stay visually faithful for a vision model.
    static let jpegQuality = 0.85

    /// Rewrite every oversized or mislabeled `data:` image part in the
    /// outbound messages. Messages without image parts are returned as-is.
    /// Downscale arbitrary encoded image bytes to the wire budget as JPEG.
    /// Used by the composer's attach path for files over its inline cap —
    /// attach a usable rendition instead of silently dropping the file.
    static func downsizedJPEGData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsizedJPEG(from: source)
    }

    // MARK: - ImageIO helpers

    private static func mime(of source: CGImageSource) -> String? {
        guard let uti = CGImageSourceGetType(source) as String?,
            let type = UTType(uti)
        else { return nil }
        return type.preferredMIMEType
    }

    private static func longestSide(of source: CGImageSource) -> Int? {
        guard
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int,
            let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return max(w, h)
    }

    private static func downsizedJPEG(from source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongSidePixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let out = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}

