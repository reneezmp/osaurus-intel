//
//  IntelMediaToolsTests.swift
//  osaurus
//
//  Intel's `image` / `video` agent tools (`W-media-generation`, part C):
//  per-agent settings, model resolution, the agent switch gate, the video
//  argument checks, the source-image rule, and the artifact card. Nothing
//  here generates media or reaches the network.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelMediaToolsTests {
    private static let providerId = UUID()

    private static func model(
        _ id: String, kind: MediaGenerationKind = .image, constraints: MediaModelConstraints = MediaModelConstraints()
    ) -> MediaModelInfo {
        MediaModelInfo(
            target: MediaModelTarget(backend: .remoteProvider(providerId), modelID: id),
            displayName: id, providerName: "Venice", kind: kind, constraints: constraints, offline: false)
    }

    @Test func agentSettingsKeepMediaFieldsAndDefaultOff() throws {
        let legacy = try JSONDecoder().decode(AgentSettings.self, from: Data(#"{"dbEnabled":false}"#.utf8))
        #expect(!legacy.imageEnabled)
        #expect(!legacy.videoEnabled)
        #expect(legacy.imagePermission == .ask)
        #expect(legacy.videoPermission == .ask)
        #expect(legacy.imageGenerationTarget == nil)

        var settings = AgentSettings.defaultDisabled
        settings.imageEnabled = true
        settings.videoEnabled = true
        settings.imageGenerationTarget = MediaModelTarget(backend: .osaurusCloud, modelID: "cloud-image")
        settings.textToVideoTarget = MediaModelTarget(backend: .remoteProvider(Self.providerId), modelID: "wan")
        settings.videoPermission = .alwaysAllow
        settings.imagePermission = .deny
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test func malformedTargetMeansChooseAutomatically() throws {
        let json = #"{"dbEnabled":false,"imageEnabled":true,"imageGenerationTarget":{"kind":"martian"}}"#
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))
        #expect(decoded.imageEnabled)
        #expect(decoded.imageGenerationTarget == nil)
    }

    @Test func resolutionPrefersRequestThenConfiguredThenFirst() {
        let a = Self.model("flux")
        let b = Self.model("seedream")
        let all = [a, b]
        #expect(IntelMediaToolSupport.resolve(requested: nil, configured: nil, candidates: all) == a)
        #expect(IntelMediaToolSupport.resolve(requested: nil, configured: b.target, candidates: all) == b)
        #expect(IntelMediaToolSupport.resolve(requested: "seedream", configured: a.target, candidates: all) == b)
        #expect(IntelMediaToolSupport.resolve(requested: b.id, configured: nil, candidates: all) == b)
        // An unknown request never falls back to a different, billable model.
        #expect(IntelMediaToolSupport.resolve(requested: "nope", configured: nil, candidates: all) == nil)
        // A configured model that is gone resolves to nothing, as upstream.
        #expect(
            IntelMediaToolSupport.resolve(
                requested: nil, configured: MediaModelTarget(backend: .osaurusCloud, modelID: "gone"),
                candidates: all) == nil)
    }

    @Test func imageToolRefusesWhenTheAgentSwitchIsOff() async throws {
        // No agent context resolves to the built-in agent, which never has it.
        let result = try await ImageTool().execute(argumentsJSON: #"{"prompt":"a lighthouse"}"#)
        #expect(!ToolEnvelope.isSuccess(result))
        #expect(result.contains("not enabled for this agent"))
        let video = try await VideoTool().execute(argumentsJSON: #"{"prompt":"waves","duration":"5s"}"#)
        #expect(!ToolEnvelope.isSuccess(video))
        #expect(video.contains("not enabled for this agent"))
    }

    @Test func toolsAreRegistered() {
        let names = Set(ToolRegistry.shared.listTools().map(\.name))
        #expect(names.contains("image"))
        #expect(names.contains("video"))
    }

    @Test func videoArgumentsAreCheckedAgainstTheCatalog() {
        let video = Self.model(
            "wan", kind: .textToVideo,
            constraints: MediaModelConstraints(
                aspectRatios: ["16:9"], resolutions: ["720p"], durations: ["5s"], promptCharacterLimit: 10))
        #expect(
            VideoTool.validate(
                model: video, prompt: "waves", duration: "5s", resolution: "720p", aspectRatio: "16:9", audio: nil)
                == nil)
        let badDuration = VideoTool.validate(
            model: video, prompt: "waves", duration: "8s", resolution: nil, aspectRatio: nil, audio: nil)
        #expect(badDuration?.contains("\"field\":\"duration\"") == true)
        #expect(
            VideoTool.validate(
                model: video, prompt: "waves", duration: "5s", resolution: "1080p", aspectRatio: nil, audio: nil)?
                .contains("resolution") == true)
        #expect(
            VideoTool.validate(
                model: video, prompt: "waves", duration: "5s", resolution: nil, aspectRatio: nil, audio: true)?
                .contains("audio") == true)
        #expect(
            VideoTool.validate(
                model: video, prompt: "far too long a prompt", duration: "5s", resolution: nil, aspectRatio: nil,
                audio: nil)?
                .contains("too long") == true)
    }

    @Test func videoSourceMustBeAnOsaurusImageWithMatchingBytes() async throws {
        try await StoragePathsTestLock.shared.run {
            let previous = OsaurusPaths.overrideRoot
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-video-source-\(UUID().uuidString)", isDirectory: true)
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: root)
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let png = Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
            let good = root.appendingPathComponent("frame.png")
            try png.write(to: good)
            let source = try VideoTool.loadSourceImage(good.path)
            #expect(source.0 == png)
            #expect(source.1 == "image/png")

            let mislabeled = root.appendingPathComponent("frame.jpg")
            try png.write(to: mislabeled)
            #expect(throws: VideoTool.SourceImageError.self) { try VideoTool.loadSourceImage(mislabeled.path) }

            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent("outside-\(UUID().uuidString).png")
            try png.write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            #expect(throws: VideoTool.SourceImageError.self) { try VideoTool.loadSourceImage(outside.path) }
        }
    }
}
