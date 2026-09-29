//
//  IntelDocumentEditingTests.swift
//  OsaurusCoreTests
//
//  In-place document editing on Intel (upstream #2907 part B + #2914's
//  document slice): the Intel-specific wiring — undo through
//  FileOperationLog (upstream uses its file-change journal), refusals, the
//  file_write guard, dry run and structure reads. Upstream's editor behaviour
//  is covered by Tests/Documents/DocumentEditTests.swift.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel in-place document editing", .serialized)
struct IntelDocumentEditingTests {
    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-docedit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func json(_ arguments: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
    }

    private static func object(_ envelope: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]) ?? [:]
    }

    private static func makeDocx(_ root: URL) async throws {
        _ = try await FileWriteTool(rootPath: root).execute(
            argumentsJSON: json(["path": "plan.docx", "content": "# Plan\n\nBuy rice for Q3.\n\nCook lentils."]))
    }

    @Test("A Word edit applies in place, previews with dry_run, and undoes byte for byte")
    func docxEditDryRunAndUndo() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.makeDocx(root)
        let url = root.appendingPathComponent("plan.docx")
        let original = try Data(contentsOf: url)
        let tool = FileEditTool(rootPath: root)

        let preview = try await tool.execute(
            argumentsJSON: Self.json(["path": "plan.docx", "old_string": "Q3", "new_string": "Q4", "dry_run": true]))
        #expect(Self.object(preview)["ok"] as? Bool == true, "\(preview)")
        #expect(preview.contains("PREVIEW ONLY"))
        #expect(try Data(contentsOf: url) == original)

        let sessionId = "docedit-\(UUID().uuidString)"
        await FileOperationLog.shared.setRootPath(root)
        defer { Task { await FileOperationLog.shared.setRootPath(nil) } }
        let applied = try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
            try await tool.execute(argumentsJSON: Self.json(["path": "plan.docx", "old_string": "Q3", "new_string": "Q4"]))
        }
        #expect(Self.object(applied)["ok"] as? Bool == true, "\(applied)")
        let text = try await FileReadTool(rootPath: root).execute(argumentsJSON: Self.json(["path": "plan.docx"]))
        #expect(text.contains("Q4") && !text.contains("Q3"), "\(text.prefix(300))")

        _ = try await FileOperationLog.shared.undoLast(sessionId: sessionId)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("A spreadsheet edit sets cells through operations; structure lists sheets")
    func xlsxOperationsAndStructure() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await FileWriteTool(rootPath: root).execute(
            argumentsJSON: Self.json(["path": "stock.xlsx", "content": "item,qty\nRice,3\nLentils,2\n"]))

        let structure = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: Self.json(["path": "stock.xlsx", "mode": "structure"]))
        #expect(Self.object(structure)["ok"] as? Bool == true, "\(structure)")
        #expect(structure.contains("Rice"))

        let edited = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: Self.json([
                "path": "stock.xlsx",
                "operations": [["op": "set_cells", "cells": ["B2": 7, "A4": "Oats", "B4": 5]]],
            ]))
        #expect(Self.object(edited)["ok"] as? Bool == true, "\(edited)")
        let text = try await FileReadTool(rootPath: root).execute(argumentsJSON: Self.json(["path": "stock.xlsx"]))
        #expect(text.contains("Oats"), "\(text.prefix(300))")
    }

    @Test("Operations on a text file, text edits on a PDF, and structure on text are refused")
    func refusals() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        _ = try await FileWriteTool(rootPath: root).execute(
            argumentsJSON: Self.json(["path": "brief.pdf", "content": "# Brief\n\nHello"]))

        let textOps = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: Self.json(["path": "notes.txt", "operations": [["op": "set_cells", "cells": ["A1": 1]]]]))
        #expect(textOps.contains("`operations` edits .docx"))

        let pdfText = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: Self.json(["path": "brief.pdf", "old_string": "Hello", "new_string": "Hi"]))
        #expect(pdfText.contains("PDF body text can't be rewritten"))

        let structure = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: Self.json(["path": "notes.txt", "mode": "structure"]))
        #expect(Self.object(structure)["ok"] as? Bool == false)
    }

    @Test("file_write refuses content that is really a list of file_edit operations")
    func writeRefusesOperationsPayload() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.makeDocx(root)
        let before = try Data(contentsOf: root.appendingPathComponent("plan.docx"))
        let payload = #"[{"op":"replace_text","old_string":"Q3","new_string":"Q4"}]"#
        let result = try await FileWriteTool(rootPath: root).execute(
            argumentsJSON: Self.json(["path": "plan.docx", "content": payload]))
        #expect(Self.object(result)["ok"] as? Bool == false)
        #expect(result.contains("file_edit"))
        #expect(try Data(contentsOf: root.appendingPathComponent("plan.docx")) == before)
        // A real CSV for .xlsx is not mistaken for operations.
        #expect(FileWriteTool.fileEditOperationsPayload("a,b\n1,2") == nil)
        #expect(FileWriteTool.fileEditOperationsPayload(#"[{"item":"Rice"}]"#) == nil)
    }
}
