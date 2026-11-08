//
//  IntelStage3fTests.swift
//  osaurusTests
//
//  `W-cov-reaudit` stage 3f (docs/COV_REAUDIT.md):
//  - #2701: a dispatch without its own folder runs in the agent's Default
//    Working Folder.
//  - #2805: an MCP image result is staged as an `image_ref` the media bridge
//    resolves (Intel's text placeholder stays for undecodable data).
//  - #1608: agent files stranded in a legacy `Personas/` folder move to
//    `agents/`.
//  - #3070: continued phone history replays a turn's frozen prefix.
//  Isolated storage roots; nothing reaches ~/.osaurus.
//

import AppKit
import Foundation
import MCP
import Testing

@testable import OsaurusCore

@Suite("Intel stage 3f", .serialized)
@MainActor
struct IntelStage3fTests {
    private func withRoot(_ label: String, _ body: @escaping @Sendable @MainActor (URL) throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-\(label)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }
            try await MainActor.run { try body(root) }
        }
    }

    @Test("A dispatch's own folder wins; otherwise the agent's default is used")
    func dispatchFolderFallback() {
        let own = DispatchRequest(prompt: "x", agentId: UUID(), folderPath: "/tmp/own")
        #expect(BackgroundTaskManager.resolveDispatchFolder(for: own)?.path == "/tmp/own")
        let unknownAgent = DispatchRequest(prompt: "x", agentId: UUID())
        #expect(BackgroundTaskManager.resolveDispatchFolder(for: unknownAgent) == nil)
        let builtIn = DispatchRequest(prompt: "x", agentId: Agent.defaultId)
        #expect(BackgroundTaskManager.resolveDispatchFolder(for: builtIn) == nil)
    }

    @Test("An MCP image is staged by hash and resolved by the media bridge")
    func mcpImageStaging() async throws {
        try await withRoot("3f-mcp") { _ in
            let rep = try #require(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            let result = MCPProviderTool.convertMCPContent(
                [
                    .text(text: "caption", annotations: nil, _meta: nil),
                    .image(data: png.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil),
                ],
                toolName: "fixture_screenshot")
            #expect(!result.contains(png.base64EncodedString()))
            #expect(ToolResultMediaBridge.isMCPImageEnvelope(result))
            let attachments = ToolResultMediaBridge.attachments(toolName: "fixture_screenshot", result: result)
            #expect(attachments.count == 1)
        }
    }

    @Test("Legacy Personas records move to agents/, conflicts are kept as .bak")
    func legacyPersonasMigration() async throws {
        try await withRoot("3f-personas") { root in
            let legacy = root.appendingPathComponent("Personas", isDirectory: true)
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            let a = UUID().uuidString + ".json", b = UUID().uuidString + ".json"
            try Data("{}".utf8).write(to: legacy.appendingPathComponent(a))
            try Data("{\"legacy\":true}".utf8).write(to: legacy.appendingPathComponent(b))
            let agents = OsaurusPaths.agents()
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            try Data("{\"current\":true}".utf8).write(to: agents.appendingPathComponent(b))

            let result = OsaurusPaths.migrateLegacyPersonasIfNeeded()
            #expect(result == .migrated(moved: 1, conflicts: 1))
            #expect(FileManager.default.fileExists(atPath: agents.appendingPathComponent(a).path))
            #expect(FileManager.default.fileExists(atPath: agents.appendingPathComponent(b + ".bak").path))
            let kept = try String(contentsOf: agents.appendingPathComponent(b), encoding: .utf8)
            #expect(kept.contains("current"))
            #expect(OsaurusPaths.migrateLegacyPersonasIfNeeded() == .legacyDirectoryAbsent)
        }
    }

    @Test("Continued phone history replays the turn's frozen prefix (#3070)")
    func continuationReplaysPrefix() {
        var turn = ChatTurnData(id: UUID(), role: .user, content: "hello", createdAt: Date())
        turn.injectedContextPrefix = "[Memory]\nm\n[/Memory]\n\n"
        let message = RemoteSessionContinuation.message(from: turn)
        #expect(message?.content == "[Memory]\nm\n[/Memory]\n\nhello")
    }
}
