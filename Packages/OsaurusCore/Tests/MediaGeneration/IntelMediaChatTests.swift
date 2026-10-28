//
//  IntelMediaChatTests.swift
//  osaurus
//
//  Intel's chat path for image/video models (`W-media-generation`, part B):
//  media rows in Intel's picker item, the session's option defaults, and the
//  guard that keeps a media id away from chat-model calls.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct IntelMediaChatTests {
    private static let providerId = UUID()

    private static func media(
        _ kind: MediaGenerationKind,
        constraints: MediaModelConstraints = MediaModelConstraints(),
        offline: Bool = false
    ) -> ModelPickerItem {
        .fromMediaModel(
            MediaModelInfo(
                target: MediaModelTarget(backend: .remoteProvider(providerId), modelID: "\(kind.rawValue)-model"),
                displayName: "Media \(kind.rawValue)",
                providerName: "Venice",
                kind: kind,
                constraints: constraints,
                pricing: MediaModelPricing(generation: MediaPrice(usd: 0.04)),
                privacy: "private",
                offline: offline
            ),
            providerId: providerId
        )
    }

    private static func chat(_ id: String) -> ModelPickerItem {
        ModelPickerItem(id: id, displayName: id, source: .remote(providerName: "Venice", providerId: providerId))
    }

    @Test func mediaRowsAreNeverChatModels() {
        let image = Self.media(.image)
        let video = Self.media(.textToVideo)
        #expect(!image.isLikelyChatCapable)
        #expect(!video.isLikelyChatCapable)
        #expect(image.isMediaGeneration)
        let items = [image, Self.chat("venice/llama"), video]
        #expect(items.firstChatCapable?.id == "venice/llama")
        #expect(items.imageGenerationDelegateCandidates.map(\.id) == [image.id])
        #expect(items.videoGenerationDelegateCandidates.map(\.id) == [video.id])
    }

    @Test func offlineMediaIsNotACandidate() {
        let items = [Self.media(.image, offline: true), Self.media(.imageToVideo, offline: true)]
        #expect(items.imageGenerationDelegateCandidates.isEmpty)
        #expect(items.videoGenerationDelegateCandidates.isEmpty)
    }

    @Test func mediaRowDescribesPrivacyAndPrice() {
        let row = Self.media(.image)
        #expect(row.description?.hasPrefix("private · From ") == true)
        #expect(row.id.hasPrefix("provider:\(Self.providerId.uuidString):"))
    }

    @Test func selectingAVideoModelAppliesItsDefaultsAndHidesItFromChatCalls() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let video = Self.media(
                .textToVideo,
                constraints: MediaModelConstraints(
                    aspectRatios: ["16:9", "9:16"], resolutions: ["720p"],
                    durations: ["5s", "10s"], supportsAudio: true, audioConfigurable: true))
            let chat = Self.chat("venice/llama")
            session.pickerItems = [chat, video]

            session.selectedModel = chat.id
            #expect(session.auxiliaryChatModel == chat.id)

            session.selectedModel = video.id
            #expect(session.selectedVideoPickerItem?.id == video.id)
            #expect(session.selectedImagePickerItem == nil)
            #expect(session.auxiliaryChatModel == nil)
            #expect(session.imageComposerSettings.aspectRatio == "16:9")
            #expect(session.imageComposerSettings.resolution == "720p")
            #expect(session.imageComposerSettings.duration == "5s")
            #expect(session.imageComposerSettings.audio == true)
        }
    }

    @Test func mediaPromptIsTheTrimmedText() throws {
        #expect(try ChatSession.mediaPrompt(text: "  a lighthouse at dusk \n", attachments: []) == "a lighthouse at dusk")
        #expect(try ChatSession.mediaPrompt(text: "   ", attachments: []).isEmpty)
    }
}
