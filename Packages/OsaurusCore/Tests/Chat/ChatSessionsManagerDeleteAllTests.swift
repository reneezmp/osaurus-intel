//
//  ChatSessionsManagerDeleteAllTests.swift
//  osaurusTests
//
//  Pins the ownership contract of `ChatSessionsManager.deleteAll(for:)`,
//  the bulk wipe behind the agent detail "Delete All Data" card and agent
//  deletion (upstream #2355). Unlike `sessions(for:)`, where the Default
//  agent means "show everything", the wipe matches strictly: a per-agent
//  wipe removes only that agent's sessions, and a Default-agent wipe removes
//  only its own and unowned (nil-agent) sessions, never another agent's
//  history. Runs entirely in `ChatHistoryTestStorage`'s temp root.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatSessionsManagerDeleteAllTests {

    private func make(agent: UUID?) -> ChatSessionData {
        ChatSessionData(id: UUID(), selectedModel: nil, agentId: agent)
    }

    @Test
    func deleteAll_removesOnlyTheAgentsOwnSessionsFromMemoryAndDisk() async throws {
        try await ChatHistoryTestStorage.run {
            let manager = ChatSessionsManager.shared
            let agentA = UUID()
            let agentB = UUID()
            let a1 = make(agent: agentA)
            let a2 = make(agent: agentA)
            let b1 = make(agent: agentB)
            let unowned = make(agent: nil)
            for s in [a1, a2, b1, unowned] { manager.save(s) }
            ChatSessionsManager.flushPendingWrites()

            await manager.deleteAll(for: agentA)

            #expect(manager.session(for: a1.id) == nil)
            #expect(manager.session(for: a2.id) == nil)
            #expect(manager.session(for: b1.id) != nil)
            #expect(manager.session(for: unowned.id) != nil)

            // Disk agrees: a full reload shows the same survivors.
            manager.refresh()
            #expect(manager.session(for: a1.id) == nil)
            #expect(manager.session(for: a2.id) == nil)
            #expect(manager.session(for: b1.id) != nil)
            #expect(manager.session(for: unowned.id) != nil)
            #expect(!FileManager.default.fileExists(atPath: OsaurusPaths.sessionFile(for: a1.id).path))
            #expect(FileManager.default.fileExists(atPath: OsaurusPaths.sessionFile(for: b1.id).path))

            manager.delete(id: b1.id)
            manager.delete(id: unowned.id)
        }
    }

    @Test
    func deleteAll_forDefaultAgent_leavesOtherAgentsSessions() async throws {
        try await ChatHistoryTestStorage.run {
            let manager = ChatSessionsManager.shared
            let agentB = UUID()
            let b1 = make(agent: agentB)
            let own = make(agent: Agent.defaultId)
            for s in [b1, own] { manager.save(s) }
            ChatSessionsManager.flushPendingWrites()

            // `sessions(for:)` returns EVERYTHING for the Default agent; the
            // wipe must not inherit that meaning.
            await manager.deleteAll(for: Agent.defaultId)

            #expect(manager.session(for: own.id) == nil)
            #expect(manager.session(for: b1.id) != nil)

            manager.refresh()
            #expect(manager.session(for: b1.id) != nil)
            manager.delete(id: b1.id)
        }
    }
}
