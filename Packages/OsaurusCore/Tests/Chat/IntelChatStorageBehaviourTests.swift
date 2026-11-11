//
//  IntelChatStorageBehaviourTests.swift
//  osaurusTests
//
//  W-cov-reaudit 5a (2026-11-11): upstream's conversation-store queries over
//  Intel's JSON chats (reattach by external key, turn counts, a session
//  load) and upstream's unsaved-chat retry. Runs under a temporary root.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct IntelChatStorageBehaviourTests {
    private func session(
        agent: UUID,
        source: SessionSource = .plugin,
        pluginId: String? = "com.example.plugin",
        key: String? = "thread-1",
        turns: Int = 1,
        updatedAt: Date = Date()
    ) -> ChatSessionData {
        ChatSessionData(
            updatedAt: updatedAt,
            turns: (0..<turns).map { ChatTurnData(from: ChatTurn(role: .user, content: "turn \($0)")) },
            agentId: agent,
            source: source,
            sourcePluginId: pluginId,
            externalSessionKey: key
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func reattachFindsTheNewestMatchingChat() async throws {
        try await ChatHistoryTestStorage.run {
            let manager = ChatSessionsManager.shared
            let agent = UUID()
            let older = session(agent: agent, updatedAt: Date(timeIntervalSinceNow: -60))
            let newer = session(agent: agent)
            let otherAgent = session(agent: UUID())
            let otherPlugin = session(agent: agent, pluginId: "com.example.other")
            let schedule = session(agent: agent, source: .schedule, pluginId: nil)
            let all = [older, newer, otherAgent, otherPlugin, schedule]
            for s in all { manager.save(s) }
            defer { for s in all { manager.delete(id: s.id) } }

            let db = ChatHistoryDatabase.shared
            #expect(db.findSession(pluginId: "com.example.plugin", externalKey: "thread-1", agentId: agent)?.id == newer.id)
            #expect(db.findSession(source: .schedule, externalKey: "thread-1", agentId: agent)?.id == schedule.id)
            #expect(db.findSession(pluginId: "com.example.plugin", externalKey: "thread-2", agentId: agent) == nil)
            #expect(db.loadSession(id: older.id)?.turns.count == 1)
        }
    }

    @Test func turnCountsFollowTheAgentFilter() async throws {
        try await ChatHistoryTestStorage.run {
            let manager = ChatSessionsManager.shared
            let agent = UUID()
            let mine = session(agent: agent, key: nil, turns: 3)
            let theirs = session(agent: UUID(), key: nil, turns: 2)
            manager.save(mine)
            manager.save(theirs)
            defer { [mine, theirs].forEach { manager.delete(id: $0.id) } }

            let scoped = ChatHistoryDatabase.shared.turnCounts(forAgent: agent)
            #expect(scoped == [mine.id: 3])
            let all = ChatHistoryDatabase.shared.turnCounts(forAgent: nil)
            #expect(all[mine.id] == 3 && all[theirs.id] == 2)
        }
    }

    @Test func aFailedSaveIsFlaggedAndRetried() async throws {
        try await ChatHistoryTestStorage.run {
            let manager = ChatSessionsManager.shared
            let fm = FileManager.default
            let dir = OsaurusPaths.sessions()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            let chat = session(agent: UUID(), key: nil)
            defer {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
                manager.delete(id: chat.id)
            }

            manager.save(chat)
            try await waitUntil { ChatPersistenceStatus.shared.unsaved.contains(chat.id) }
            #expect(ChatPersistenceStatus.shared.unsaved.contains(chat.id), "the failed write is flagged")
            #expect(!fm.fileExists(atPath: OsaurusPaths.sessionFile(for: chat.id).path))

            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            manager.retryUnsaved()
            ChatSessionsManager.flushPendingWrites()
            try await waitUntil { !ChatPersistenceStatus.shared.unsaved.contains(chat.id) }
            #expect(!ChatPersistenceStatus.shared.unsaved.contains(chat.id), "the retry landed")
            #expect(fm.fileExists(atPath: OsaurusPaths.sessionFile(for: chat.id).path))
        }
    }
}
