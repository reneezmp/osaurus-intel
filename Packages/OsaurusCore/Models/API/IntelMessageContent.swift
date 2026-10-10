//
//  IntelMessageContent.swift
//  OsaurusCore — Intel fork
//
//  Multimodal message content for Intel's `ChatMessage` (Networking/
//  HTTPHandler.swift). `MessageContentPart` is upstream's, verbatim (it lives
//  in Models/API/OpenAIAPI.swift, which Intel excludes). Until 2026-10-10
//  Intel's `ChatMessage` was text-only: the image initializers dropped their
//  images, so no picture ever reached a cloud vision model, and the local
//  server could not decode an OpenAI vision request.
//

import Foundation

enum MessageContentPart: Codable, Sendable {
    case text(String)
    case imageUrl(url: String, detail: String?)
    case audioInput(data: String, format: String)
    case videoUrl(url: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case input_text
        case image_url
        case input_audio
        case video_url
    }

    private struct ImageUrlContent: Codable {
        let url: String
        let detail: String?
    }

    private struct InputAudioContent: Codable {
        let data: String
        let format: String
    }

    private struct VideoUrlContent: Codable {
        let url: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            if let text = try? container.decode(String.self, forKey: .text) {
                self = .text(text)
            } else if let inputText = try? container.decode(String.self, forKey: .input_text) {
                self = .text(inputText)
            } else {
                self = .text("")
            }
        case "image_url":
            let imageUrl = try container.decode(ImageUrlContent.self, forKey: .image_url)
            self = .imageUrl(url: imageUrl.url, detail: imageUrl.detail)
        case "input_audio":
            let audio = try container.decode(InputAudioContent.self, forKey: .input_audio)
            self = .audioInput(data: audio.data, format: audio.format)
        case "video_url":
            let video = try container.decode(VideoUrlContent.self, forKey: .video_url)
            self = .videoUrl(url: video.url)
        default:
            // Fallback to text for unknown types
            if let text = try? container.decode(String.self, forKey: .text) {
                self = .text(text)
            } else {
                self = .text("")
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageUrl(let url, let detail):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageUrlContent(url: url, detail: detail), forKey: .image_url)
        case .audioInput(let data, let format):
            try container.encode("input_audio", forKey: .type)
            try container.encode(InputAudioContent(data: data, format: format), forKey: .input_audio)
        case .videoUrl(let url):
            try container.encode("video_url", forKey: .type)
            try container.encode(VideoUrlContent(url: url), forKey: .video_url)
        }
    }
}

extension MessageContentPart {
    /// `data:` URL for raw image bytes, labelled by sniffing the container
    /// (upstream's initializer always says `image/png`; strict providers
    /// reject a JPEG labelled as PNG, so Intel sniffs like upstream's
    /// `ToolResultMediaBridge`).
    static func imageDataURL(_ data: Data) -> String {
        "data:\(imageMimeType(data));base64,\(data.base64EncodedString())"
    }

    static func imageMimeType(_ data: Data) -> String {
        guard data.count >= 12 else { return "image/png" }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b[0] == 0xFF, b[1] == 0xD8 { return "image/jpeg" }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42,
            b[11] == 0x50
        {
            return "image/webp"
        }
        return "image/png"
    }

    var isMedia: Bool {
        if case .text = self { return false }
        return true
    }
}
