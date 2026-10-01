//
//  IntelFileCopyTests.swift
//  OsaurusCoreTests
//
//  `file_copy` on Intel: byte-exact copies inside the working folder, the
//  overwrite contract, limits, and undo through FileOperationLog.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel file_copy", .serialized)
struct IntelFileCopyTests {
    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func json(_ arguments: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
    }

    private static func isFailure(_ envelope: String) -> Bool {
        let object = (try? JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]) ?? [:]
        return object["ok"] as? Bool == false
    }

    @Test("file_copy is one of the folder tools")
    func registered() {
        #expect(FolderToolFactory.buildCoreTools().contains { $0.name == "file_copy" })
    }

    @Test("A new copy is byte-exact and undo removes it")
    func copyAndUndo() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([0x25, 0x50, 0x44, 0x46, 0x00, 0xFF, 0x10])  // binary
        try bytes.write(to: root.appendingPathComponent("report.pdf"))
        let sessionId = "copy-\(UUID().uuidString)"
        // Undo goes through the file history journal (upstream #2907 part A).
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }

        let result = try await env.run(
            FileCopyTool(rootPath: root),
            Self.json(["source": "report.pdf", "destination": "drafts/report-v2.pdf"]),
            sessionId: sessionId, folder: root)
        #expect(!Self.isFailure(result), "\(result)")
        #expect(result.contains("operation_id"), "\(result)")
        let copy = root.appendingPathComponent("drafts/report-v2.pdf")
        #expect(try Data(contentsOf: copy) == bytes)

        let undo = try await env.call(FileUndoTool(rootPath: root, journal: env.journal), "{}", sessionId: sessionId)
        #expect(!Self.isFailure(undo), "\(undo)")
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("drafts").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("report.pdf").path))
    }

    @Test("An existing destination needs overwrite; undo restores its old bytes")
    func overwriteAndUndo() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("a.bin"))
        let original = Data([9, 9, 0xFF])
        try original.write(to: root.appendingPathComponent("b.bin"))
        let tool = FileCopyTool(rootPath: root)

        let refused = try await tool.execute(argumentsJSON: Self.json(["source": "a.bin", "destination": "b.bin"]))
        #expect(Self.isFailure(refused))
        #expect(refused.contains("overwrite"))
        #expect(try Data(contentsOf: root.appendingPathComponent("b.bin")) == original)

        let sessionId = "copy-\(UUID().uuidString)"
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let replaced = try await env.run(
            tool, Self.json(["source": "a.bin", "destination": "b.bin", "overwrite": true]),
            sessionId: sessionId, folder: root)
        #expect(!Self.isFailure(replaced), "\(replaced)")
        #expect(try Data(contentsOf: root.appendingPathComponent("b.bin")) == Data([1, 2, 3]))

        _ = try await env.call(FileUndoTool(rootPath: root, journal: env.journal), "{}", sessionId: sessionId)
        #expect(try Data(contentsOf: root.appendingPathComponent("b.bin")) == original)
    }

    @Test("Folders, the same path, oversize files and paths outside the folder are refused")
    func refusals() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2048).write(to: root.appendingPathComponent("big.bin"))

        let folder = try await FileCopyTool(rootPath: root).execute(
            argumentsJSON: Self.json(["source": "dir", "destination": "dir2"]))
        #expect(Self.isFailure(folder))

        let same = try await FileCopyTool(rootPath: root).execute(
            argumentsJSON: Self.json(["source": "big.bin", "destination": "./big.bin"]))
        #expect(Self.isFailure(same))

        let capped = try await FileCopyTool(rootPath: root, maxCopyBytes: 1024).execute(
            argumentsJSON: Self.json(["source": "big.bin", "destination": "copy.bin"]))
        #expect(Self.isFailure(capped))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("copy.bin").path))

        await #expect(throws: (any Error).self) {
            _ = try await FileCopyTool(rootPath: root).execute(
                argumentsJSON: Self.json(["source": "big.bin", "destination": "../escape.bin"]))
        }
    }
}
