//
//  AttachmentProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on Attachment.
//

import Foundation

protocol AttachmentProtocol: Identifiable, Sendable {
    var id: UUID { get }
    var filename: String? { get }
    var isDocument: Bool { get }
    var documentContent: String? { get }
    var isAudio: Bool { get }
    var isVideo: Bool { get }
    var audioFormat: String? { get }
    var estimatedTokens: Int { get }
    var imageData: Data? { get }

    func loadAudioData() async throws -> Data?
    func loadVideoData() async throws -> Data?
}
