//
//  IntelHangFixTests.swift
//  osaurusTests
//
//  `W-cov-reaudit` stage 3e (docs/COV_REAUDIT.md): upstream's main-thread
//  hang fixes on Intel's own managers.
//  - #1672: `ToolRegistry.listTools()` is memoized and rebuilt on change.
//  - #1948: chat saves are written off the main thread; a reload waits for
//    them.
//  - #2128: schedule writes are queued; the in-memory list updates at once.
//  Isolated storage roots; nothing reaches ~/.osaurus.
//

import Foundation
import Testing

@testable import OsaurusCore

private struct HangFixFixtureTool: OsaurusTool {
    let name: String
    let description = "Fixture"
    let parameters: JSONValue? = .object(["type": .string("object"), "properties": .object([:])])
    func execute(argumentsJSON: String) async throws -> String { "{}" }
}

@Suite("Intel hang fixes", .serialized)
@MainActor
struct IntelHangFixTests {
    private func withRoot(_ label: String, _ body: @escaping @Sendable @MainActor () throws -> Void) async throws {
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
            try await MainActor.run { try body() }
        }
    }

    @Test("The tool list is cached and rebuilt when tools or switches change")
    func listToolsMemo() {
        let registry = ToolRegistry.shared
        let name = "hangfix_tool_\(UUID().uuidString.prefix(6).lowercased())"
        let before = registry.listTools()
        #expect(registry.listTools().map(\.name) == before.map(\.name))
        registry.registerPluginTool(HangFixFixtureTool(name: name), group: "Hang Fix Fixture")
        defer { registry.unregister(names: [name]) }
        #expect(registry.listTools().contains { $0.name == name && $0.enabled })
        registry.setEnabled(false, for: name)
        #expect(registry.listTools().first { $0.name == name }?.enabled == false)
        registry.setEnabled(true, for: name)
        registry.unregister(names: [name])
        #expect(!registry.listTools().contains { $0.name == name })
    }

    @Test("A queued chat save lands, and a reload sees it")
    func chatSaveAsync() async throws {
        try await withRoot("hangfix-chat") {
            let manager = ChatSessionsManager.shared
            manager.refresh()
            defer { manager.refresh() }
            let data = ChatSessionData(
                title: "Queued",
                turns: [ChatTurnData(id: UUID(), role: .user, content: "hello", createdAt: Date())],
                agentId: Agent.defaultId)
            manager.saveAsync(data)
            #expect(manager.session(for: data.id)?.title == "Queued")  // in memory at once
            manager.refresh()  // waits for the queued write
            #expect(manager.session(for: data.id)?.turns.first?.content == "hello")
            ChatSessionsManager.flushPendingWrites()
            #expect(FileManager.default.fileExists(atPath: OsaurusPaths.sessionFile(for: data.id).path))
            manager.delete(id: data.id)
        }
    }

    @Test("Schedule changes apply in memory and land on disk in order")
    func scheduleQueuedWrites() async throws {
        try await withRoot("hangfix-schedule") {
            let manager = ScheduleManager.shared
            manager.refresh()
            let schedule = manager.create(
                name: "Hang fix fixture", instructions: "noop",
                frequency: .once(date: Date().addingTimeInterval(86_400 * 365)), isEnabled: false)
            #expect(manager.schedule(for: schedule.id) != nil)
            var renamed = schedule
            renamed.name = "Renamed fixture"
            manager.update(renamed)
            ScheduleManager.flushPendingWrites()
            #expect(ScheduleStore.loadAll().first { $0.id == schedule.id }?.name == "Renamed fixture")
            #expect(manager.delete(id: schedule.id))
            #expect(manager.schedule(for: schedule.id) == nil)
            ScheduleManager.flushPendingWrites()
            #expect(!ScheduleStore.loadAll().contains { $0.id == schedule.id })
            #expect(!manager.delete(id: schedule.id))
            manager.refresh()
        }
    }
}
