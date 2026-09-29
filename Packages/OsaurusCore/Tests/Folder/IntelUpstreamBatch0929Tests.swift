//
//  IntelUpstreamBatch0929Tests.swift
//  OsaurusCoreTests
//
//  Upstream commits after `a4daf94c4` ported to Intel (docs/UPSTREAM_AUDIT_2026-09-29.md):
//  #2894 logical lines, #2914 tolerant file_edit, #2893 integer fields,
//  #2918 prompt_working_folder, #2916 "Worked for", #2912 minimap packing.
//  Every file test works in its own temporary folder through the real tools.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel upstream batch 2026-09-29", .serialized)
struct IntelUpstreamBatch0929Tests {
    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-batch0929-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func json(_ arguments: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
    }

    private static func object(_ envelope: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]) ?? [:]
    }

    // MARK: - #2894 logical lines

    @Test("CRLF counts as one line break and a final newline adds no empty line")
    func logicalLines() {
        #expect(FolderToolHelpers.contentLines("a\r\nb\r\n") == ["a", "b"])
        #expect(FolderToolHelpers.contentLines("a\nb") == ["a", "b"])
        #expect(FolderToolHelpers.contentLines("") == [""])
        #expect(FolderToolHelpers.contentLines("\n") == [""])
    }

    @Test("file_read and file_search number CRLF files like an editor does")
    func crlfLineNumbers() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("first\r\nsecond\r\nthird\r\n".utf8).write(to: root.appendingPathComponent("notes.txt"))

        let read = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: Self.json(["path": "notes.txt", "start_line": 3, "end_line": 3]))
        #expect(read.contains("3| third"), "\(read)")
        #expect(!read.contains("of 7"))  // CRLF used to double the line count

        let search = try await FileSearchTool(rootPath: root).execute(argumentsJSON: Self.json(["pattern": "third"]))
        #expect(search.contains("notes.txt:3"), "\(search)")
    }

    // MARK: - #2914 tolerant file_edit

    @Test("A whitespace-drifted old_string still applies, keeps the file's indentation, and says so")
    func tolerantEdit() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("list.md")
        try "# Pantry\n\n\t- rice\n\t- lentils\n".write(to: url, atomically: true, encoding: .utf8)

        let result = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: Self.json(["path": "list.md", "old_string": "  - rice\n  - lentils", "new_string": "  - rice\n  - beans"]))
        let object = Self.object(result)
        #expect(object["ok"] as? Bool == true, "\(result)")
        let payload = object["result"] as? [String: Any]
        #expect(payload?["match_strategy"] as? String == "whitespace_normalized")
        #expect((object["warnings"] as? [String])?.first?.contains("did not match the file byte-for-byte") == true)
        let text = try String(contentsOf: url, encoding: .utf8)
        // The model's two-space indent maps onto the file's tab.
        #expect(text == "# Pantry\n\n\t- rice\n\t- beans\n", "\(text.debugDescription)")
    }

    @Test("Several matches are refused with a replace_all hint; replace_all replaces them all")
    func ambiguousAndReplaceAll() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.txt")
        try "rice\nrice\n".write(to: url, atomically: true, encoding: .utf8)
        let tool = FileEditTool(rootPath: root)

        let refused = try await tool.execute(
            argumentsJSON: Self.json(["path": "a.txt", "old_string": "rice", "new_string": "oats"]))
        #expect(Self.object(refused)["ok"] as? Bool == false)
        #expect(refused.contains("replace_all"))
        #expect(try String(contentsOf: url, encoding: .utf8) == "rice\nrice\n")

        let all = try await tool.execute(
            argumentsJSON: Self.json(["path": "a.txt", "old_string": "rice", "new_string": "oats", "replace_all": true]))
        #expect((Self.object(all)["result"] as? [String: Any])?["replacements"] as? Int == 2)
        #expect(try String(contentsOf: url, encoding: .utf8) == "oats\noats\n")
    }

    @Test("A missing match explains line-number prefixes and quotes the closest line")
    func notFoundDiagnosis() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "alpha beta gamma\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let tool = FileEditTool(rootPath: root)

        let prefixed = try await tool.execute(
            argumentsJSON: Self.json(["path": "b.txt", "old_string": "     1| alpha beta", "new_string": "x"]))
        #expect(prefixed.contains("line-number prefixes"))

        let drifted = try await tool.execute(
            argumentsJSON: Self.json(["path": "b.txt", "old_string": "alpha beta delta", "new_string": "x"]))
        #expect(drifted.contains("closest matching line in the file is line 1"))

        let same = try await tool.execute(
            argumentsJSON: Self.json(["path": "b.txt", "old_string": "alpha", "new_string": "alpha"]))
        #expect(same.contains("nothing to change"))
    }

    // MARK: - #2893 integer fields

    @Test("A partly typed number survives its clamped echo; other values replace the draft")
    func integerFieldReconcile() {
        let clamp = 5 ... 100
        // Typing "1" on the way to "15": the binding holds 5, the draft stays "1".
        #expect(OptionalIntFieldEditing.reconcile("1", value: 5, clamp: clamp) == "1")
        #expect(OptionalIntFieldEditing.reconcile("15", value: 15, clamp: clamp) == "15")
        // An external change (another value) replaces what was typed.
        #expect(OptionalIntFieldEditing.reconcile("1", value: 40, clamp: clamp) == "40")
        #expect(OptionalIntFieldEditing.reconcile("", value: nil, clamp: clamp) == "")
        #expect(OptionalIntFieldEditing.reconcile("7", value: nil, clamp: clamp) == "")
    }

    // MARK: - #2918 prompt_working_folder

    private static func toolNames(_ context: ComposedContext) -> Set<String> {
        Set(context.tools.map(\.function.name))
    }

    @MainActor
    @Test("Offered only to a custom agent's attended chat without a folder")
    func folderPromptExposure() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Agent(name: "writer-\(UUID().uuidString.prefix(6))", systemPrompt: "x", agentAddress: nil)
            AgentManager.shared.add(agent)
            let name = PromptWorkingFolderTool.toolName

            let offered = await SystemPromptComposer.composeChatContext(
                agentId: agent.id, query: "hi", offerFolderPrompt: true)
            #expect(Self.toolNames(offered).contains(name))

            let notOffered = await SystemPromptComposer.composeChatContext(agentId: agent.id, query: "hi")
            #expect(!Self.toolNames(notOffered).contains(name))

            let orchestrator = await SystemPromptComposer.composeChatContext(
                agentId: Agent.defaultId, query: "hi", offerFolderPrompt: true)
            #expect(!Self.toolNames(orchestrator).contains(name))

            let root = try Self.makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let folder = await FolderContextService.shared.buildContext(from: root)
            let withFolder = await SystemPromptComposer.composeChatContext(
                agentId: agent.id, query: "hi", folderContext: folder, offerFolderPrompt: true)
            #expect(!Self.toolNames(withFolder).contains(name))

            // A session without a chat window (a background dispatch) never offers it.
            let session = ChatSession()
            session.agentId = agent.id
            #expect(!session.canPromptForWorkingFolder)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test("Without an attended chat the tool refuses; an empty reason is rejected")
    func folderPromptRefusals() async throws {
        let tool = PromptWorkingFolderTool()
        let noChat = try await tool.execute(argumentsJSON: Self.json(["reason": "Save the report"]))
        #expect(Self.object(noChat)["kind"] as? String == "unavailable")
        let empty = try await tool.execute(argumentsJSON: Self.json(["reason": "  "]))
        #expect(Self.object(empty)["kind"] as? String == "invalid_args")
        #expect(DatabaseFilePathResolver.noFolderMessageSuffix.contains(PromptWorkingFolderTool.toolName))
    }

    @MainActor
    @Test("A pick attaches the folder to the chat; a cancel says nothing was written")
    func folderPromptPick() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ChatSession()
        let box = WeakChatSessionBox(session)
        let tool = PromptWorkingFolderTool()

        let cancelled = try await PromptWorkingFolderTool.$pickerOverrideForTests.withValue({ _ in nil }) {
            try await ChatExecutionContext.$currentChatSessionBox.withValue(box) {
                try await tool.execute(argumentsJSON: Self.json(["reason": "Save the report"]))
            }
        }
        #expect(Self.object(cancelled)["kind"] as? String == "user_denied")
        #expect(!session.folderState.hasActiveFolder)

        var seenReason: String?
        let attached = try await PromptWorkingFolderTool.$pickerOverrideForTests.withValue({ reason in
            await MainActor.run { seenReason = reason }
            return root
        }) {
            try await ChatExecutionContext.$currentChatSessionBox.withValue(box) {
                try await tool.execute(argumentsJSON: Self.json(["reason": "Save the report"]))
            }
        }
        #expect(Self.object(attached)["ok"] as? Bool == true, "\(attached)")
        #expect(attached.contains("file_write"))
        #expect(seenReason == "Save the report")
        #expect(session.folderState.persistedPath == root.standardizedFileURL.path)

        // Already attached: refuses instead of asking again.
        let again = try await PromptWorkingFolderTool.$pickerOverrideForTests.withValue({ _ in root }) {
            try await ChatExecutionContext.$currentChatSessionBox.withValue(box) {
                try await tool.execute(argumentsJSON: Self.json(["reason": "Again"]))
            }
        }
        #expect(again.contains("already has a working folder"))
        session.folderState.clearFolder()
    }

    // MARK: - #2916 Worked for

    @Test("A finished reply shows how long it worked, measured from the user's message")
    func workedFor() {
        let start = Date(timeIntervalSince1970: 1_000)
        let user = ChatTurn(role: .user, content: "Plan my week", createdAt: start)
        let step = ChatTurn(role: .assistant, content: "Looking…", createdAt: start.addingTimeInterval(1))
        step.completedAt = start.addingTimeInterval(4)
        let final = ChatTurn(role: .assistant, content: "Here's the plan.", createdAt: start.addingTimeInterval(5))
        final.completedAt = start.addingTimeInterval(12.5)

        let blocks = BlockMemoizer().blocks(from: [user, step, final], agentName: "Assistant")
        let totals: [TimeInterval?] = blocks.compactMap {
            if case let .generationStats(_, _, _, _, total) = $0.kind { return total }
            return nil
        }
        #expect(totals == [12.5])  // only the reply's last turn carries it

        let streaming = BlockMemoizer().blocks(
            from: [user, step, final], streamingTurnId: final.id, agentName: "Assistant")
        #expect(!streaming.contains { if case .generationStats(_, _, _, _, .some) = $0.kind { true } else { false } })

        #expect(NativeStatsView.formatDuration(12.34) == "12.3s")
        #expect(NativeStatsView.formatDuration(125) == "2m5s")
        #expect(BlockMemoizer.workedFor(
            isUser: false, isLastInGroup: true, isStreaming: false,
            startedAt: start, completedAt: start.addingTimeInterval(-1)) == nil)
    }

    // MARK: - #2912 minimap packing

    @Test("The collapsed minimap packs ticks to fit, then groups them, never dropping a message")
    func minimapPacking() {
        func markers(_ n: Int) -> [ChatMinimap.Marker] {
            (0 ..< n).map { _ in ChatMinimap.Marker(id: UUID(), preview: "q") }
        }
        func height(_ layout: ChatMinimap.CollapsedLayout) -> CGFloat {
            let n = CGFloat(layout.groups.count)
            return n * layout.tickHeight + max(n - 1, 0) * layout.spacing + 20
        }
        let short = ChatMinimap.collapsedLayout(for: markers(10))
        #expect(short.tickHeight == 2 && short.spacing == 6 && short.groups.count == 10)

        let long = ChatMinimap.collapsedLayout(for: markers(100))
        #expect(long.tickHeight == 1 && long.groups.count == 100)
        #expect(height(long) <= ChatMinimap.collapsedMaxHeight + 0.001)

        let huge = markers(300)
        let grouped = ChatMinimap.collapsedLayout(for: huge)
        #expect(grouped.groups.count < 300)
        #expect(grouped.groups.flatMap { $0 }.map(\.id) == huge.map(\.id))
        #expect(height(grouped) <= ChatMinimap.collapsedMaxHeight)
    }
}
