//
//  IntelImageInputFallback.swift
//  OsaurusCore — Intel fork
//
//  Upstream treats every cloud model as image-capable and, for the Osaurus
//  Router only, remembers a model that rejected image input so later turns
//  flatten historical images instead of replaying the same 400 forever
//  (upstream #2559, `recordRouterImageInputRejection`).
//
//  Intel generalises that memory to every provider. Until 2026-10-10 Intel
//  silently dropped all images, so existing chats with text-only models
//  (DeepSeek) can hold image attachments; without this, the first message
//  in such a chat after the fix would fail and keep failing. When a provider
//  rejects image content, the engine records the model here, strips the
//  images and retries the same request once. Later requests to that model
//  are flattened before sending. Process lifetime only, like upstream's.
//

import Foundation

enum IntelImageInputFallback {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var rejectedModels: Set<String> = []

    /// Note left in place of stripped images so the model knows they existed.
    static let omittedImageNote = "[image not sent: this model does not accept images]"

    static func key(provider: String, model: String) -> String {
        "\(provider.lowercased())|\(model.lowercased())"
    }

    static func isRejected(provider: String, model: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejectedModels.contains(key(provider: provider, model: model))
    }

    static func recordRejection(provider: String, model: String) {
        lock.lock()
        rejectedModels.insert(key(provider: provider, model: model))
        lock.unlock()
    }

    /// Test seam.
    static func reset() {
        lock.lock()
        rejectedModels.removeAll()
        lock.unlock()
    }

    /// An HTTP error body saying the provider refused image / multipart user
    /// content. Upstream matches the Router's "user message content must be
    /// a string"; Intel also matches the shapes OpenAI-compatible text-only
    /// hosts return (DeepSeek: "unknown variant `image_url`").
    static func isImageInputRejection(_ body: String) -> Bool {
        let text = body.lowercased()
        if text.contains("user message content must be a string") { return true }
        if text.contains("unknown variant"), text.contains("image_url") { return true }
        let mentionsImages = text.contains("image") || text.contains("multimodal") || text.contains("vision")
        let refuses =
            text.contains("not support") || text.contains("unsupported") || text.contains("does not accept")
            || text.contains("not allowed")
        return mentionsImages && refuses
    }

    /// Whether any wire message carries an image part.
    static func containsImages(_ messages: [[String: Any]]) -> Bool {
        messages.contains { message in
            guard let parts = message["content"] as? [[String: Any]] else { return false }
            return parts.contains { ($0["type"] as? String) == "image_url" }
        }
    }

    /// Replace each parts array that holds images with its text plus one
    /// note per stripped image. Messages without images are untouched.
    static func strippingImages(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.map { message in
            guard let parts = message["content"] as? [[String: Any]],
                parts.contains(where: { ($0["type"] as? String) == "image_url" })
            else { return message }
            var kept: [[String: Any]] = []
            var omitted = 0
            for part in parts {
                if (part["type"] as? String) == "image_url" {
                    omitted += 1
                } else {
                    kept.append(part)
                }
            }
            let notes = Array(repeating: omittedImageNote, count: omitted)
            var out = message
            if kept.allSatisfy({ ($0["type"] as? String) == "text" }) {
                let texts = kept.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
                out["content"] = (texts + notes).joined(separator: "\n")
            } else {
                out["content"] = kept + notes.map { ["type": "text", "text": $0] }
            }
            return out
        }
    }
}
