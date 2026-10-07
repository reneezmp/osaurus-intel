//
//  CaptureScreenshotCommandTests.swift
//  osaurusTests
//
//  Focused tests for the permission-gated screenshot capture service and slash command.
//
//  Intel: blocks come from `BlockMemoizer.unrolledBlocks` (upstream
//  `ContentBlock.generateBlocks`); the rest is upstream's.
//

import Foundation
import Testing

@testable import OsaurusCore

private final class MockScreenshotPermissionChecker: ScreenshotPermissionChecking, @unchecked Sendable {
    var granted: Bool

    init(granted: Bool) {
        self.granted = granted
    }

    func hasScreenRecordingPermission() -> Bool {
        granted
    }
}

private final class MockScreenshotCapturer: ScreenshotImageCapturing, @unchecked Sendable {
    private(set) var includeCursorCalls: [Bool] = []
    var image = ScreenshotImage(
        pngData: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]),
        width: 320,
        height: 200,
        displayID: 42
    )

    func capture(includeCursor: Bool) async throws -> ScreenshotImage {
        includeCursorCalls.append(includeCursor)
        return image
    }
}

@Suite("screenshot slash command", .serialized)
struct CaptureScreenshotCommandTests {

    private static func runLocked(_ body: @Sendable (URL) async throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let previous = OsaurusPaths.overrideRoot
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-screenshot-command-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = tmp
            defer {
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: tmp)
            }
            try await body(tmp)
        }
    }

    @Test func serviceMissingPermissionDoesNotCapture() async throws {
        try await Self.runLocked { _ in
            let permission = MockScreenshotPermissionChecker(granted: false)
            let capturer = MockScreenshotCapturer()
            let service = ScreenshotCaptureService(
                permissionChecker: permission,
                capturer: capturer
            )

            await #expect(throws: ScreenshotCaptureError.missingScreenRecordingPermission) {
                _ = try await service.capture(
                    options: ScreenshotCaptureOptions(contextId: "session-a")
                )
            }

            #expect(capturer.includeCursorCalls.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: OsaurusPaths.artifactsDir().path))
        }
    }

    @Test func serviceWritesArtifactAndSanitizesFilename() async throws {
        try await Self.runLocked { _ in
            let capturer = MockScreenshotCapturer()
            let service = ScreenshotCaptureService(
                permissionChecker: MockScreenshotPermissionChecker(granted: true),
                capturer: capturer
            )
            let now = Date(timeIntervalSince1970: 1_771_000_000)

            let captured = try await service.capture(
                options: ScreenshotCaptureOptions(
                    contextId: "session-b",
                    filename: "../Quarterly Report.jpg",
                    description: "current screen",
                    includeCursor: true,
                    now: now
                )
            )

            #expect(capturer.includeCursorCalls == [true])
            #expect(captured.artifact.filename == "Quarterly-Report.png")
            #expect(captured.artifact.mimeType == "image/png")
            #expect(captured.artifact.description == "current screen")
            #expect(captured.width == 320)
            #expect(captured.height == 200)
            #expect(captured.displayID == 42)
            #expect(FileManager.default.fileExists(atPath: captured.artifact.hostPath))
            let stored = try Data(contentsOf: URL(fileURLWithPath: captured.artifact.hostPath))
            #expect(stored == capturer.image.pngData)
        }
    }

    @MainActor
    @Test func capturedArtifactPersistsAndRendersWithoutToolHistory() async throws {
        try await Self.runLocked { _ in
            let capturer = MockScreenshotCapturer()
            let service = ScreenshotCaptureService(
                permissionChecker: MockScreenshotPermissionChecker(granted: true),
                capturer: capturer
            )
            let captured = try await service.capture(
                options: ScreenshotCaptureOptions(
                    contextId: "session-d",
                    filename: "screen.png",
                    description: "screen"
                )
            )
            await MainActor.run {
                let turn = ChatTurn(
                    role: .assistant,
                    content: "",
                    sharedArtifacts: [captured.artifact]
                )

                #expect(turn.toolCalls == nil)
                #expect(turn.toolResults.isEmpty)
                #expect(turn.sharedArtifacts == [captured.artifact])

                let data = ChatTurnData(from: turn)
                #expect(data.toolCalls == nil)
                #expect(data.toolResults.isEmpty)
                #expect(data.sharedArtifacts == [captured.artifact])

                let restored = ChatTurn(from: data)
                #expect(restored.toolCalls == nil)
                #expect(restored.toolResults.isEmpty)
                #expect(restored.sharedArtifacts == [captured.artifact])

                let blocks = BlockMemoizer().unrolledBlocks(from: [restored], agentName: "Osaurus")
                let artifacts = blocks.compactMap { block -> SharedArtifact? in
                    if case let .sharedArtifact(artifact) = block.kind {
                        return artifact
                    }
                    return nil
                }
                #expect(artifacts == [captured.artifact])
                #expect(
                    !blocks.contains { block in
                        if case .toolCallGroup = block.kind {
                            return true
                        }
                        return false
                    }
                )
            }
        }
    }

    @MainActor
    @Test func screenshotCommandIsBuiltInSlashActionNotRegisteredModelTool() {
        let command = SlashCommand.builtIns.first { $0.name == "screenshot" }
        #expect(command?.kind == .action)
        #expect(command?.isBuiltIn == true)
        #expect(command?.icon == "camera.viewfinder")
        #expect(ToolRegistry.shared.entry(named: "capture_screenshot") == nil)
    }

    @Test func compactCommandIsBuiltInSlashAction() {
        let command = SlashCommand.builtIns.first { $0.name == "compact" }
        #expect(command?.kind == .action)
        #expect(command?.isBuiltIn == true)
        let ids = SlashCommand.builtIns.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}

@Suite("Intel screenshot artifacts", .serialized)
struct IntelScreenshotArtifactTests {
    @Test("Artifact turns round-trip through the saved chat JSON with upstream's keys")
    func artifactJSONRoundTrip() throws {
        let artifact = SharedArtifact(
            contextId: "c", contextType: .chat, filename: "s.png", mimeType: "image/png",
            fileSize: 6, hostPath: "/tmp/s.png", description: "Screenshot captured from chat")
        let data = ChatTurnData(id: UUID(), role: .assistant, content: "", sharedArtifacts: [artifact], createdAt: Date())
        let json = try JSONEncoder().encode(data)
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let stored = (object?["sharedArtifacts"] as? [[String: Any]])?.first
        #expect(stored?["hostPath"] as? String == "/tmp/s.png")
        #expect(stored?["contextType"] as? String == "chat")
        let decoded = try JSONDecoder().decode(ChatTurnData.self, from: json)
        #expect(decoded.sharedArtifacts == [artifact])
        // Turns without artifacts don't write the key (older chats unchanged).
        let plain = try JSONEncoder().encode(ChatTurnData(id: UUID(), role: .user, content: "hi", createdAt: Date()))
        #expect(!(String(data: plain, encoding: .utf8) ?? "").contains("sharedArtifacts"))
    }

    @MainActor
    @Test("Deleting a chat removes its artifacts folder")
    func deleteRemovesArtifacts() async throws {
        try await ChatHistoryTestStorage.run {
            let id = UUID()
            let dir = OsaurusPaths.contextArtifactsDir(contextId: id.uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([1]).write(to: dir.appendingPathComponent("s.png"))
            ChatSessionsManager.shared.delete(id: id)
            for _ in 0 ..< 100 where FileManager.default.fileExists(atPath: dir.path) {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(!FileManager.default.fileExists(atPath: dir.path))
        }
    }
}
