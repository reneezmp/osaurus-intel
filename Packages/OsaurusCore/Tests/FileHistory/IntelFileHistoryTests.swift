//
//  IntelFileHistoryTests.swift
//  osaurusTests
//
//  File history on Intel (`W-file-history`, upstream #2907 part A;
//  docs/FILE_HISTORY_INTEL.md). Upstream's `file_undo` cases live in
//  `FolderToolsResilienceTests` and `PerChatFolderIsolationTests`, which
//  Intel doesn't compile; they are ported here, plus the Intel wiring:
//  `shell_run` and `file_copy` captures, the chat window's File Changes
//  state, and chat deletion purging history.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelFileUndoToolTests {

    private func tmpRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-intel-file-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func failureKind(_ result: String) -> String? { EnvelopeAssertions.failureKind(result) }

    @Test func fileOperationHistory_requiresSessionContext() async throws {
        let tool = FileOperationHistoryTool(rootPath: try tmpRoot())
        let result = try await tool.execute(argumentsJSON: "{}")
        #expect(ToolEnvelope.isError(result))
        #expect(failureKind(result) == "unavailable")
    }

    @Test func fileOperationHistory_listsEachCallNewestFirst() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let root = try tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "history-\(UUID().uuidString)"

        _ = try await env.run(
            FileWriteTool(rootPath: root), ##"{"path": "nested/report.md", "content": "# Report\n"}"##,
            sessionId: sessionId, folder: root)
        _ = try await env.run(
            FileEditTool(rootPath: root),
            #"{"path": "nested/report.md", "old_string": "Report", "new_string": "Summary"}"#,
            sessionId: sessionId, folder: root)

        let history = FileOperationHistoryTool(rootPath: root, journal: env.journal)
        let result = try await env.call(history, #"{"limit": 5}"#, sessionId: sessionId)
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["kind"] as? String == "file_operation_history")
        let entries = try #require(payload["entries"] as? [[String: Any]])
        #expect(entries.map { $0["tool"] as? String } == ["file_edit", "file_write"])
        let files = try #require(entries.last?["files"] as? [[String: Any]])
        #expect(files.contains { $0["path"] as? String == "nested/report.md" && $0["change"] as? String == "created" })
        #expect(files.contains { $0["path"] as? String == "nested" && $0["type"] as? String == "directory" })

        let filtered = try await env.call(
            history, #"{"path": "nested/report.md", "limit": 1}"#, sessionId: sessionId)
        let filteredPayload = try #require(EnvelopeAssertions.successPayload(filtered))
        #expect((filteredPayload["entries"] as? [[String: Any]])?.count == 1)
        #expect(filteredPayload["operation_count"] as? Int == 2)
    }

    /// Models routinely echo `path` alongside the `operation_id` they got
    /// from the write result. Agreeing arguments are redundant, not
    /// ambiguous: the undo must run. Upstream.
    @Test func fileUndo_operationIdWithAgreeingPathUndoes() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let root = try tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("CHANGELOG.md")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)
        let sessionId = "resilience-\(UUID().uuidString)"

        let writeResult = try await env.run(
            FileWriteTool(rootPath: root), #"{"path": "CHANGELOG.md", "content": "clobbered\n"}"#,
            sessionId: sessionId, folder: root)
        let opId = try #require(EnvelopeAssertions.successPayload(writeResult)?["operation_id"] as? String)

        let undo = FileUndoTool(rootPath: root, journal: env.journal)
        let result = try await env.call(
            undo, #"{"operation_id": "\#(opId)", "path": "CHANGELOG.md"}"#, sessionId: sessionId)
        #expect(ToolEnvelope.isSuccess(result), "got: \(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["undone_count"] as? Int == 1)
        #expect(payload["undone_operation_id"] as? String == opId)
        #expect(payload["undone_tool"] as? String == "file_write")
        #expect((payload["undone"] as? [[String: Any]])?.first?["path"] as? String == "CHANGELOG.md")
        #expect(try String(contentsOf: file, encoding: .utf8) == "original\n")

        // A second undo of the same operation is refused, not re-applied.
        let again = try await env.call(undo, #"{"operation_id": "\#(opId)"}"#, sessionId: sessionId)
        #expect(ToolEnvelope.isError(again))
    }

    /// A genuine disagreement stays refused, with a message naming the real
    /// file. Upstream.
    @Test func fileUndo_operationIdWithConflictingPathIsRefusedWithDiagnosis() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let root = try tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "keep\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let sessionId = "resilience-\(UUID().uuidString)"

        let writeResult = try await env.run(
            FileWriteTool(rootPath: root), #"{"path": "a.txt", "content": "changed\n"}"#,
            sessionId: sessionId, folder: root)
        let opId = try #require(EnvelopeAssertions.successPayload(writeResult)?["operation_id"] as? String)

        let undo = FileUndoTool(rootPath: root, journal: env.journal)
        let result = try await env.call(
            undo, #"{"operation_id": "\#(opId)", "path": "other.txt"}"#, sessionId: sessionId)
        #expect(ToolEnvelope.isError(result))
        #expect(failureKind(result) == "invalid_args")
        let message = EnvelopeAssertions.failureMessage(result) ?? ""
        #expect(message.contains("a.txt"))
        #expect(message.contains("other.txt"))
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "changed\n")
    }

    /// Undo never overwrites a file the user edited after the agent's
    /// change. Upstream.
    @Test func fileUndo_leavesFilesChangedSinceUntouched() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let root = try tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.txt")
        try "v1\n".write(to: file, atomically: true, encoding: .utf8)
        let sessionId = "resilience-\(UUID().uuidString)"

        _ = try await env.run(
            FileWriteTool(rootPath: root), #"{"path": "notes.txt", "content": "v2\n"}"#,
            sessionId: sessionId, folder: root)
        try "user edit\n".write(to: file, atomically: true, encoding: .utf8)

        let result = try await env.call(FileUndoTool(rootPath: root, journal: env.journal), "{}", sessionId: sessionId)
        #expect(ToolEnvelope.isError(result))
        #expect((EnvelopeAssertions.failureMessage(result) ?? "").contains("notes.txt"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "user edit\n")
    }

    /// Undo resolves against the root recorded on the change set, so a
    /// session can undo a write made under folder A while another folder is
    /// bound. Upstream `PerChatFolderIsolationTests`.
    @Test func undoUsesRootRecordedOnOperation() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let rootA = try tmpRoot()
        let rootB = try tmpRoot()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let file = rootA.appendingPathComponent("undo.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        let sessionId = "undo-\(UUID().uuidString)"

        let written = try await ChatExecutionContext.$currentFolderRoot.withValue(rootA) {
            try await env.run(
                FileWriteTool(), #"{"path": "undo.txt", "content": "clobbered"}"#,
                sessionId: sessionId, folder: rootA)
        }
        let opId = try #require(EnvelopeAssertions.successPayload(written)?["operation_id"] as? String)

        let undo = FileUndoTool(journal: env.journal)
        let result = try await ChatExecutionContext.$currentFolderRoot.withValue(rootB) {
            try await env.call(undo, #"{"operation_id": "\#(opId)"}"#, sessionId: sessionId)
        }
        #expect(ToolEnvelope.isSuccess(result), "got: \(result)")
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
    }

    /// `shell_run` is opaque: the whole folder is scanned before and after,
    /// so a `mv` lands as a rename that reverts in one step.
    @Test func shellRunMoveIsCapturedAndReverts() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let root = try tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "draft".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let sessionId = "shell-\(UUID().uuidString)"

        let result = try await ChatExecutionContext.$currentFolderRoot.withValue(root) {
            try await env.run(
                ShellRunTool(rootPath: root), #"{"command": "mv a.txt b.txt"}"#,
                sessionId: sessionId, folder: root, toolCallId: "call-shell")
        }
        #expect(ToolEnvelope.isSuccess(result), "\(result)")
        #expect(EnvelopeAssertions.successPayload(result)?["operation_id"] as? String != nil)
        let sets = await env.journal.changeSets(for: sessionId)
        let set = try #require(sets.first)
        #expect(sets.count == 1)
        #expect(set.toolName == "shell_run")
        #expect(set.entries.contains { $0.path == "b.txt" && $0.fromPath == "a.txt" })

        let summary = await env.journal.revert(.set(set.id), sessionId: sessionId)
        #expect(summary.isClean, "\(summary)")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
    }

    /// The Intel folder tools opt in to capture with the declared targets
    /// upstream uses, and the history tools are in the folder tool set.
    @Test func folderToolsDeclareTheirTargets() {
        #expect(FileWriteTool().mutatesHostFolder)
        #expect(FileEditTool().mutatesHostFolder)
        #expect(FileCopyTool().mutatesHostFolder)
        #expect(ShellRunTool().mutatesHostFolder)
        #expect(!FileReadTool().mutatesHostFolder)
        #expect(FileWriteTool().declaredMutationTargets(argumentsJSON: #"{"path":"a.md","content":"x"}"#) == ["a.md"])
        #expect(FileCopyTool().declaredMutationTargets(argumentsJSON: #"{"source":"a","destination":"b"}"#) == ["b"])
        #expect(ShellRunTool().declaredMutationTargets(argumentsJSON: #"{"command":"ls"}"#) == nil)
        let names = FolderToolFactory.buildCoreTools().map(\.name)
        #expect(names.contains("file_undo") && names.contains("file_operation_history"))
    }
}

/// The chat window follows the journal for the chat on screen.
@Suite(.serialized)
@MainActor
struct IntelFileChangesWindowTests {

    private func record(sessionId: String, in folder: URL, file: String) async throws -> FileChangeSet {
        let token = await FileChangeJournal.shared.beginCapture(
            sessionId: sessionId, toolName: "file_write",
            targets: [.init(kind: .hostFolder, rootId: folder.path, declaredPaths: [file])])
        try "new".write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        return try #require(await FileChangeJournal.shared.endCapture(token))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 100 where !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test func windowCountsTheChatsChangedFilesAndOpensTheirPanel() async throws {
        try await ChatHistoryTestStorage.run {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("osu-intel-window-history-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            let id = UUID()
            window.session.sessionId = id
            defer { Task { await FileChangeJournal.shared.purgeSession(id.uuidString) } }

            let set = try await record(sessionId: id.uuidString, in: folder, file: "a.txt")
            await waitUntil { window.fileChangesCount == 1 }
            #expect(window.fileChangesCount == 1)
            #expect(window.fileChangeSetCount == 1)
            #expect(window.inspectorBadgeCount == 1)

            // With sets recorded, File Changes is shown rather than falling back.
            #expect(
                ChatWindowState.effectiveInspectorPane(
                    requested: .fileChanges, fileChangeSetCount: window.fileChangeSetCount, isPinned: false)
                    == .fileChanges)

            // A card's "View changes" deep-links to the set.
            FileChangeSummaryStore.requestPanel(sessionId: id.uuidString, focusing: set.id)
            await waitUntil { window.inspectorPane == .fileChanges }
            #expect(window.inspectorPane == .fileChanges)
            #expect(window.changesPanelFocusSetId == set.id)
            #expect(window.inspectorBadgeCount == nil, "the lens bar carries the count while open")
        }
    }

    @Test func aRequestForAnotherChatWaitsForTheSwitch() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            let other = ChatSessionData(
                title: "Other",
                turns: [ChatTurnData(id: UUID(), role: .user, content: "hi", createdAt: Date())],
                agentId: Agent.defaultId)
            ChatSessionsManager.shared.save(other)
            defer { ChatSessionsManager.shared.delete(id: other.id) }

            FileChangeSummaryStore.requestPanel(sessionId: other.id.uuidString)
            try? await Task.sleep(nanoseconds: 50_000_000)
            #expect(window.inspectorPane == nil)
            window.loadSession(other)
            await waitUntil { window.inspectorPane == .fileChanges }
            #expect(window.inspectorPane == .fileChanges)
        }
    }

    @Test func deletingAChatPurgesItsFileHistory() async throws {
        try await ChatHistoryTestStorage.run {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("osu-intel-purge-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let data = ChatSessionData(
                title: "Doomed",
                turns: [ChatTurnData(id: UUID(), role: .user, content: "go", createdAt: Date())],
                agentId: Agent.defaultId)
            ChatSessionsManager.shared.save(data)
            _ = try await record(sessionId: data.id.uuidString, in: folder, file: "b.txt")
            #expect(await FileChangeJournal.shared.changeSets(for: data.id.uuidString).count == 1)

            ChatSessionsManager.shared.delete(id: data.id)
            for _ in 0 ..< 100 {
                if await FileChangeJournal.shared.changeSets(for: data.id.uuidString).isEmpty { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(await FileChangeJournal.shared.changeSets(for: data.id.uuidString).isEmpty)
        }
    }
}
