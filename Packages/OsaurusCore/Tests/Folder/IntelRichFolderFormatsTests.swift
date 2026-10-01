//
//  IntelRichFolderFormatsTests.swift
//  OsaurusCoreTests
//
//  Upstream #91 on Intel: folder tools read, write and search documents.
//  (In-place editing, #2907/#2914, is covered by IntelDocumentEditingTests.)
//  Every test works in its own temporary folder through the real tools.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel rich folder formats", .serialized)
struct IntelRichFolderFormatsTests {
    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-rich-formats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func json(_ arguments: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
    }

    private static func isFailure(_ envelope: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]
        else { return false }
        return object["ok"] as? Bool == false || object["error"] != nil
    }

    private static let markdown = """
        # Quarterly Plan

        The pantry inventory needs **three** restocks.

        - Rice
        - Lentils
        """

    @Test("file_write makes a .docx and .pdf from Markdown that file_read reads back")
    func wordAndPDFRoundTrip() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let write = FileWriteTool(rootPath: root)
        let read = FileReadTool(rootPath: root)

        for name in ["plan.docx", "plan.pdf"] {
            let result = try await write.execute(argumentsJSON: Self.json(["path": name, "content": Self.markdown]))
            #expect(!Self.isFailure(result), "\(name): \(result)")
            #expect(result.contains("document_write_result"))
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            #expect(!data.isEmpty)
            #expect(!data.starts(with: Data("# Quarterly".utf8)))  // a real document, not Markdown bytes
            let text = try await read.execute(argumentsJSON: Self.json(["path": name]))
            #expect(text.contains("Quarterly Plan"), "\(name): \(text.prefix(300))")
            #expect(text.contains("pantry"))
        }
    }

    @Test("file_write makes an .xlsx from CSV; file_read previews it")
    func workbookRoundTrip() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await FileWriteTool(rootPath: root).execute(
            argumentsJSON: Self.json(["path": "stock.xlsx", "content": "item,qty\nRice,3\nLentils,2\n"]))
        #expect(!Self.isFailure(result), "\(result)")
        let text = try await FileReadTool(rootPath: root).execute(argumentsJSON: Self.json(["path": "stock.xlsx"]))
        #expect(text.contains("Lentils"))
    }

    @Test("dry_run previews a document without writing it")
    func dryRun() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await FileWriteTool(rootPath: root).execute(
            argumentsJSON: Self.json(["path": "draft.pdf", "content": Self.markdown, "dry_run": true]))
        #expect(result.contains("dry_run"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("draft.pdf").path))
    }

    @Test("Unreadable legacy formats are refused with a pointer to what works")
    func refusals() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: root.appendingPathComponent("old.xls"))
        let xls = try await FileReadTool(rootPath: root).execute(argumentsJSON: Self.json(["path": "old.xls"]))
        #expect(Self.isFailure(xls))
        #expect(xls.contains(".xlsx"))
    }

    @Test("file_write makes a .pptx from Markdown that file_read reads back")
    func powerPointWrite() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let deck = "# Pantry Plan\n\n- Rice\n- Lentils\n\n# Shopping\n\n- Oats\n"
        let result = try await FileWriteTool(rootPath: root).execute(
            argumentsJSON: Self.json(["path": "deck.pptx", "content": deck]))
        #expect(!Self.isFailure(result), "\(result)")
        #expect(result.contains("\"slides\":2"))
        let text = try await FileReadTool(rootPath: root).execute(argumentsJSON: Self.json(["path": "deck.pptx"]))
        #expect(text.contains("Lentils"), "\(text.prefix(300))")
    }

    @Test("file_search finds text inside documents with a locator")
    func searchInsideDocuments() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await FileWriteTool(rootPath: root).execute(
            argumentsJSON: Self.json(["path": "notes/plan.docx", "content": Self.markdown]))
        try "nothing here\n".write(to: root.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let result = try await FileSearchTool(rootPath: root).execute(
            argumentsJSON: Self.json(["pattern": "lentils"]))
        #expect(result.contains("plan.docx ["), "\(result)")
    }

    @Test("Undo restores an overwritten binary document byte for byte")
    func binarySafeUndo() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "rich-formats-\(UUID().uuidString)"
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }

        let target = root.appendingPathComponent("report.xlsx")
        _ = try await FileWriteTool(rootPath: root).execute(
            argumentsJSON: Self.json(["path": "report.xlsx", "content": "a,b\n1,2\n"]))
        let original = try Data(contentsOf: target)
        #expect(String(data: original, encoding: .utf8) == nil)  // binary

        _ = try await env.run(
            FileWriteTool(rootPath: root), Self.json(["path": "report.xlsx", "content": "a,b\n9,9\n"]),
            sessionId: sessionId, folder: root)
        #expect(try Data(contentsOf: target) != original)
        _ = try await env.call(FileUndoTool(rootPath: root, journal: env.journal), "{}", sessionId: sessionId)
        #expect(try Data(contentsOf: target) == original)
    }

    @Test("file_read recognizes text in an image (OCR)")
    func imageOCR() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let size = NSSize(width: 900, height: 220)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        ("OSAURUS PANTRY" as NSString).draw(
            at: NSPoint(x: 40, y: 70),
            withAttributes: [.font: NSFont.systemFont(ofSize: 72, weight: .bold), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("label.png"))

        let text = try await FileReadTool(rootPath: root).execute(argumentsJSON: Self.json(["path": "label.png"]))
        #expect(text.uppercased().contains("PANTRY"), "\(text.prefix(300))")
    }
}
