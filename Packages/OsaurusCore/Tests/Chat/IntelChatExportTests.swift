//
//  IntelChatExportTests.swift
//  OsaurusCoreTests
//
//  `W-chat-export` (docs/INTEL_MISSING_FEATURES_BACKLOG.md): upstream's
//  exporter on Intel's chat data — Markdown, PDF and zip (via `ditto`), with
//  the timing options. Files go to a temporary folder only.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Intel chat export", .serialized)
struct IntelChatExportTests {
    private static func session() -> ChatSessionData {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let call = ToolCall(
            id: "call_1", type: "function",
            function: ToolCallFunction(name: "file_read", arguments: #"{"path":"notes/pantry.md"}"#))
        let turns = [
            ChatTurnData(id: UUID(), role: .user, content: "What's in the pantry?", createdAt: start),
            ChatTurnData(
                id: UUID(), role: .assistant, content: "", toolCalls: [call],
                createdAt: start.addingTimeInterval(1), completedAt: start.addingTimeInterval(2)),
            ChatTurnData(
                id: UUID(), role: .assistant, content: "Rice and **lentils**.",
                createdAt: start.addingTimeInterval(3), completedAt: start.addingTimeInterval(5),
                generationTokenCount: 12, generationTokensPerSecond: 24),
        ]
        return ChatSessionData(title: "Pantry check", turns: turns)
    }

    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Markdown carries the messages, tool calls and optional timing")
    func markdown() {
        let plain = ChatSessionExporter.markdown(for: Self.session())
        #expect(plain.contains("Pantry check"))
        #expect(plain.contains("What's in the pantry?"))
        #expect(plain.contains("Rice and **lentils**."))
        #expect(plain.contains("`file_read`"))
        #expect(plain.contains("notes/pantry.md"))  // unescaped slashes

        var options = ChatExportOptions()
        options.includeTokenUsage = true
        let timed = ChatSessionExporter.markdown(for: Self.session(), options: options)
        #expect(timed.contains("12 tok"))
        #expect(timed.contains("24.0 tok/s"))
        #expect(Self.session().hasAnyTimingData)
    }

    @Test("PDF and zip exports write real files")
    func pdfAndZip() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdf = dir.appendingPathComponent("chat.pdf")
        try ChatSessionExporter.writePDF(session: Self.session(), to: pdf)
        let pdfData = try Data(contentsOf: pdf)
        #expect(pdfData.starts(with: Data("%PDF".utf8)))

        let zip = dir.appendingPathComponent("chat.zip")
        try await ChatSessionExporter.writeZip(session: Self.session(), to: zip)
        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listing.arguments = ["-Z1", zip.path]
        let pipe = Pipe()
        listing.standardOutput = pipe
        try listing.run()
        listing.waitUntilExit()
        let names = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(listing.terminationStatus == 0)
        #expect(names.contains(".md"), "\(names)")
    }

    @Test("Repeated identical tool calls are recognised regardless of key order")
    func canonicalArgs() {
        #expect(ChatSessionExporter.canonicalArgs(#"{"b":1,"a":2}"#) == ChatSessionExporter.canonicalArgs(#"{"a":2, "b":1}"#))
        #expect(ChatSessionExporter.canonicalArgs("not json ") == "not json")
    }
}
