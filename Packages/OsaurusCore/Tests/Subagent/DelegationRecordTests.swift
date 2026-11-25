//
//  DelegationRecordTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  W-subagents stage 5: the Orchestrator's Delegations list rows
//  (`DelegationRecord`) and the Ventura/Gate 4 source pins of the shared Spawn
//  editor. Model-free, no UI, no storage.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Delegation record (stage 5)")
struct DelegationRecordTests {
    private static func turn(_ role: MessageRole, _ content: String) -> ChatTurnData {
        ChatTurnData(id: UUID(), role: role, content: content, createdAt: Date())
    }

    private static func session(
        title: String = "Delegated: summarize the notes",
        turns: [ChatTurnData],
        created: Date = Date(timeIntervalSince1970: 1_000),
        updated: Date = Date(timeIntervalSince1970: 1_075)
    ) -> ChatSessionData {
        ChatSessionData(
            id: UUID(), title: title, createdAt: created, updatedAt: updated, turns: turns,
            source: .delegation)
    }

    @Test func taskTitleStripsTheDispatcherPrefixOnly() {
        #expect(DelegationRecord.taskTitle(from: "Delegated: summarize") == "summarize")
        #expect(DelegationRecord.taskTitle(from: "Some other chat") == "Some other chat")
    }

    @Test func finishedRunWithAnswerIsCompletedWithDuration() {
        let s = Self.session(turns: [Self.turn(.user, "task"), Self.turn(.assistant, "Done.")])
        let record = DelegationRecord.make(from: s, direction: .sent, agentName: "Writer", liveStatus: nil)
        #expect(record.status == .completed)
        #expect(record.isLive == false)
        #expect(record.task == "summarize the notes")
        #expect(record.duration == 75)
        #expect(record.agentName == "Writer")
        #expect(record.needsInput == false)
    }

    @Test func finishedRunWithoutAnswerIsFailed() {
        let s = Self.session(turns: [Self.turn(.user, "task")])
        let record = DelegationRecord.make(from: s, direction: .sent, agentName: "Writer", liveStatus: nil)
        #expect(record.status == .failed)
    }

    @Test func needsInputMarkerIsSurfaced() {
        let s = Self.session(turns: [
            Self.turn(.user, "task"), Self.turn(.assistant, "NEEDS INPUT: which folder?"),
        ])
        let record = DelegationRecord.make(from: s, direction: .sent, agentName: "Writer", liveStatus: nil)
        #expect(record.needsInput)
    }

    @Test func liveStatusWinsAndMarksTheRecordLive() {
        let s = Self.session(turns: [Self.turn(.user, "task")])
        let running = DelegationRecord.make(from: s, direction: .sent, agentName: "W", liveStatus: .running)
        #expect(running.status == .running && running.isLive)
        let waiting = DelegationRecord.make(
            from: s, direction: .sent, agentName: "W", liveStatus: .waitingForInput)
        #expect(waiting.status == .waitingForInput && waiting.isLive)
        let done = DelegationRecord.make(
            from: s, direction: .sent, agentName: "W", liveStatus: .completed(summary: "ok"))
        #expect(done.status == .completed && !done.isLive)
        let cancelled = DelegationRecord.make(from: s, direction: .sent, agentName: "W", liveStatus: .cancelled)
        #expect(cancelled.status == .cancelled)
    }

    @Test func metricsLineFormatsStatusDurationAndFiles() {
        let row = DelegationRecord(
            id: UUID(), direction: .sent, agentName: "W", task: "t", status: .completed,
            startedAt: Date(), duration: 72, completionTokens: 120, tokensPerSecond: 42.5,
            artifactCount: 2, needsInput: false, isLive: false)
        #expect(
            OrchestratorDelegationsSection.metricsLine(row)
                == "\(L("Completed")) · 1m 12s · 42.5 tok/s · 120 tokens · 2 files")
        #expect(OrchestratorDelegationsSection.formatDuration(5) == "5s")
        #expect(OrchestratorDelegationsSection.formatDuration(3_720) == "1h 2m")
    }

    // MARK: Source pins (Ventura and Gate 4 rules)

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func oneSharedEditorServesBothSurfaces() throws {
        let editor = try Self.source("Views/Agent/SpawnConfigurationEditor.swift")
        let settings = try Self.source("Views/Settings/SubagentSettingsSection.swift")
        let ability = try Self.source("Views/Agent/IntelSpawnAbilitySection.swift")
        #expect(settings.components(separatedBy: "SpawnConfigurationEditor(").count - 1 == 1)
        #expect(ability.components(separatedBy: "SpawnConfigurationEditor(").count - 1 == 1)
        // The Orchestrator's pool is Gate 4's allowlist: its editor shows no
        // pool picker and the stored pool binding is a throwaway constant.
        #expect(settings.contains("spawnableAgentIDs: .constant([])"))
        #expect(editor.contains("if !isOrchestrator {"))
        #expect(!editor.contains("WorkspaceRosterStore"))
    }

    @Test func editorNeverLoosensGate4() throws {
        let editor = try Self.source("Views/Agent/SpawnConfigurationEditor.swift")
        // An unset launcher permission reads as Ask, never upstream's stored
        // default (Always Allow); Always Allow is only an explicit choice.
        #expect(editor.contains("hasExplicitPolicy(for: kindId)"))
        #expect(editor.contains(": .ask"))
        // Upstream's bounds, never raised.
        #expect(editor.contains("range: SubagentBudgets.tokenBounds"))
        #expect(editor.contains("range: SubagentBudgets.remoteParallelSpawnBounds"))
        // Ventura: themed picker, single-value onChange only.
        #expect(!editor.contains(".pickerStyle(.segmented)"))
        #expect(editor.contains("ThemedSegmentedPicker("))
        #expect(!editor.contains("onChange(of:") || !editor.contains("{ _, _ in"))
    }

    @Test func delegationRowsUseVenturaSymbols() {
        for status in [DelegationRecord.Status.queued, .running, .waitingForInput, .completed, .failed, .cancelled] {
            #expect(!OrchestratorDelegationsSection.statusIcon(status).isEmpty)
        }
    }
}
