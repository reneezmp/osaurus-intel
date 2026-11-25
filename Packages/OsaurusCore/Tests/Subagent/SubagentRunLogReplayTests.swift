//
//  SubagentRunLogReplayTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  W-subagents stage 5: a finished subagent run's step log is saved with the
//  chat turn (`toolCallLogs`) and replayed by `SubagentFeedView` after the
//  live feed is gone or the chat is reopened. Upstream
//  `SubagentRunLogPersistenceTests` shape, on Intel's turn types.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Subagent run-log replay (stage 5)", .serialized)
struct SubagentRunLogReplayTests {
    private static func log(kind: String = SubagentCapabilityRegistry.appleScript.id) -> SubagentRunLog {
        SubagentRunLog(
            kindId: kind, title: "Tidy the desktop", startedAt: Date(timeIntervalSince1970: 500),
            success: true, summary: "Done",
            events: [
                SubagentActivityEvent(step: 1, kind: .act, title: "Ran script", detail: "tell Finder", success: true),
                SubagentActivityEvent(step: 2, kind: .outcome, title: "Finished", success: true),
            ],
            truncatedEventCount: 0)
    }

    @Test func turnDataRoundTripsItsLogs() throws {
        var turn = ChatTurnData(id: UUID(), role: .assistant, content: "ok", createdAt: Date())
        turn.toolCallLogs["call-1"] = Self.log()
        let data = try JSONEncoder().encode(turn)
        let decoded = try JSONDecoder().decode(ChatTurnData.self, from: data)
        #expect(decoded.toolCallLogs["call-1"] == Self.log() || decoded.toolCallLogs["call-1"]?.events.count == 2)
        #expect(decoded.toolCallLogs["call-1"]?.title == "Tidy the desktop")
    }

    @Test func turnWithoutLogsDecodesAndOmitsTheKey() throws {
        let turn = ChatTurnData(id: UUID(), role: .assistant, content: "ok", createdAt: Date())
        let json = String(decoding: try JSONEncoder().encode(turn), as: UTF8.self)
        #expect(!json.contains("toolCallLogs"))
        let decoded = try JSONDecoder().decode(ChatTurnData.self, from: Data(json.utf8))
        #expect(decoded.toolCallLogs.isEmpty)
    }

    @Test func loadingATurnFillsTheArchiveSoTheRowReplays() {
        let callId = "replay-\(UUID().uuidString)"
        var data = ChatTurnData(id: UUID(), role: .assistant, content: "ok", createdAt: Date())
        data.toolCallLogs[callId] = Self.log()
        #expect(SubagentRunLogArchive.shared.feed(for: callId) == nil)
        let turn = ChatTurn(from: data)
        #expect(turn.toolCallLogs[callId] != nil)
        let feed = SubagentRunLogArchive.shared.feed(for: callId)
        #expect(feed?.currentEvents().count == 2)
        #expect(feed?.currentStatus() == .finished(success: true, summary: "Done"))
    }

    @Test func aFinishedFeedIsCapturedWhenTheResultLands() {
        let callId = "live-\(UUID().uuidString)"
        let feed = SubagentFeed(
            toolCallId: callId, kindId: SubagentCapabilityRegistry.appleScript.id, title: "Run")
        feed.emit(SubagentActivityEvent(kind: .act, title: "Ran script", success: true))
        feed.finish(success: true, summary: "Done")
        SubagentFeedRegistry.shared.register(feed)
        defer { SubagentFeedRegistry.shared.removeNow(toolCallId: callId) }
        let turn = ChatTurn(role: .assistant, content: "")
        turn.setToolResult("{\"ok\":true}", for: callId)
        #expect(turn.toolCallLogs[callId]?.events.count == 1)
        #expect(ChatTurnData(from: turn).toolCallLogs[callId] != nil)
    }

    @Test func spawnRunsAreNotPersistedBecauseTheyHaveTheirOwnChat() {
        let callId = "spawn-\(UUID().uuidString)"
        let feed = SubagentFeed(
            toolCallId: callId, kindId: SubagentCapabilityRegistry.spawn.id, title: "Run")
        feed.finish(success: true, summary: "Done")
        #expect(feed.finishedRunLog() == nil)
    }
}
