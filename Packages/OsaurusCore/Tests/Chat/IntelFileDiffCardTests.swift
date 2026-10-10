//
//  IntelFileDiffCardTests.swift
//  osaurusTests
//
//  Inline diff cards on Intel (`W-file-history` stage 2, upstream #1683 +
//  #2907 part A; docs/FILE_HISTORY_INTEL.md). Intel builds transcript blocks
//  in its own `BlockMemoizer`, so the card emission upstream tests through
//  `ContentBlock.generateBlocks` is checked here, plus the folder tools'
//  diff payload and `dry_run` on text files.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct IntelFileDiffCardTests {

    private func tmpRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-intel-diff-card-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func call(_ id: String, _ name: String, _ args: String) -> ToolCall {
        ToolCall(id: id, type: "function", function: ToolCallFunction(name: name, arguments: args))
    }

    private func kinds(_ blocks: [ContentBlock]) -> [String] {
        blocks.map { block in
            switch block.kind {
            case .toolCallGroup(let calls): return "group:\(calls.map(\.call.id).joined(separator: ","))"
            case .fileDiff(let diff): return "diff:\(diff.path)\(diff.isPreview ? ":preview" : "")\(diff.isStreamingPreview ? ":streaming" : "")"
            case .pendingToolCall(let name, _, _): return "pending:\(name)"
            default: return "other"
            }
        }.filter { $0 != "other" }
    }

    @Test func fileWriteResultCarriesTheDiffTheCardReads() async throws {
        let root = try tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let result = try await FileWriteTool(rootPath: root).execute(
            argumentsJSON: #"{"path": "a.txt", "content": "one\ntwo\n"}"#)
        let diff = try #require(FileDiff.from(toolResult: result))
        #expect(diff.path == "a.txt")
        #expect(diff.addedCount >= 1)
        // Upstream's summary (WorkspaceWriteSafety) counts the empty line after
        // a trailing newline: "one\ntwo\n" reads as 3 lines (2026-10-10, when
        // file_write became upstream's).
        #expect(EnvelopeAssertions.successPayload(result)?["text"] as? String == "Updated a.txt (3 lines, 8 characters)")

        // A brand-new one-line file diffs as +1 −0 (no phantom removal).
        let created = try await FileWriteTool(rootPath: root).execute(
            argumentsJSON: #"{"path": "new.txt", "content": "hello"}"#)
        let newDiff = try #require(FileDiff.from(toolResult: created))
        #expect(newDiff.addedCount == 1)
        #expect(newDiff.removedCount == 0)
    }

    @Test func dryRunOnTextFilesPreviewsWithoutWriting() async throws {
        let root = try tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.txt")
        try "alpha\nbeta\n".write(to: file, atomically: true, encoding: .utf8)

        let write = try await FileWriteTool(rootPath: root).execute(
            argumentsJSON: #"{"path": "notes.txt", "content": "alpha\ngamma\n", "dry_run": true}"#)
        let writePayload = try #require(EnvelopeAssertions.successPayload(write))
        #expect(writePayload["kind"] as? String == "workspace_write_preview")
        #expect((writePayload["diff"] as? String)?.contains("+gamma") == true)
        #expect(try String(contentsOf: file, encoding: .utf8) == "alpha\nbeta\n")

        let edit = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: #"{"path": "notes.txt", "old_string": "beta", "new_string": "delta", "dry_run": true}"#)
        let editPayload = try #require(EnvelopeAssertions.successPayload(edit))
        #expect(editPayload["kind"] as? String == "workspace_write_preview")
        #expect(edit.contains("PREVIEW ONLY"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "alpha\nbeta\n")

        // Applied edit: diff payload, upstream's summary text, no overwrite warning.
        let applied = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: #"{"path": "notes.txt", "old_string": "beta", "new_string": "delta"}"#)
        let appliedPayload = try #require(EnvelopeAssertions.successPayload(applied))
        #expect(appliedPayload["kind"] as? String == "workspace_write_result")
        #expect((appliedPayload["text"] as? String)?.hasPrefix("Updated notes.txt") == true)
        #expect(appliedPayload["match_strategy"] as? String != nil)
        #expect(!applied.contains("This will overwrite an existing file"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "alpha\ndelta\n")
    }

    @Test func completedWriteKeepsItsRowWithTheCardBelow() {
        let user = ChatTurn(role: .user, content: "make files")
        let turn = ChatTurn(role: .assistant, content: "")
        let read = call("c1", "file_read", #"{"path":"a.txt"}"#)
        let write = call("c2", "file_write", #"{"path":"a.txt","content":"x"}"#)
        let shell = call("c3", "shell_run", #"{"command":"ls"}"#)
        turn.toolCalls = [read, write, shell]
        turn.toolResults = [
            "c1": ToolEnvelope.success(tool: "file_read", text: "a"),
            "c2": ToolEnvelope.success(
                tool: "file_write",
                result: ["path": "a.txt", "diff": "--- a/a.txt\n+++ b/a.txt\n-a\n+x"] as [String: Any]),
            "c3": ToolEnvelope.success(tool: "shell_run", text: "ok"),
        ]
        let blocks = BlockMemoizer().unrolledBlocks(from: [user, turn])
        #expect(kinds(blocks) == ["group:c1,c2", "diff:a.txt", "group:c3"])
        let ids = blocks.filter { if case .toolCallGroup = $0.kind { return true } else { return false } }.map(\.id)
        #expect(ids == ["toolgroup-\(turn.id.uuidString)", "toolgroup-\(turn.id.uuidString)-1"])
        #expect(blocks.contains { $0.id == "filediff-c2" })
    }

    @Test func failedWriteShowsItsContentAsAPreviewCard() {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.toolCalls = [call("c1", "file_write", ##"{"path":"b.md","content":"# Title\nbody"}"##)]
        turn.toolResults = ["c1": ToolEnvelope.failure(kind: .executionError, message: "disk full", tool: "file_write")]
        #expect(kinds(BlockMemoizer().blocks(from: [turn])) == ["group:c1", "diff:b.md:preview"])
    }

    @Test func runningAndStreamingWritesShowLivePreviews() {
        let running = ChatTurn(role: .assistant, content: "")
        running.toolCalls = [call("c1", "file_write", #"{"path":"c.swift","content":"let x = 1"}"#)]
        #expect(
            kinds(BlockMemoizer().blocks(from: [running], streamingTurnId: running.id))
                == ["group:c1", "diff:c.swift:streaming"])
        #expect(kinds(BlockMemoizer().blocks(from: [running])) == ["group:c1"], "not streaming: no card yet")

        let streaming = ChatTurn(role: .assistant, content: "")
        streaming.pendingToolName = "file_write"
        streaming.appendToolArgFragment(#"{"path":"d.txt","content":"partial li"#)
        #expect(streaming.pendingToolArgFull != nil)
        #expect(
            kinds(BlockMemoizer().blocks(from: [streaming], streamingTurnId: streaming.id))
                == ["pending:file_write", "diff:d.txt:streaming"])
        streaming.clearPendingToolArgs()
        #expect(streaming.pendingToolArgFull == nil)

        // Other tools never buffer their full arguments.
        let search = ChatTurn(role: .assistant, content: "")
        search.pendingToolName = "web_search"
        search.appendToolArgFragment(#"{"query":"x"}"#)
        #expect(search.pendingToolArgFull == nil)
    }
}
