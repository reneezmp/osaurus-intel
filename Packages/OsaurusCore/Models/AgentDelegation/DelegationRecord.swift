//
//  DelegationRecord.swift
//  osaurus
//
//  One row of the Orchestrator's Delegations list: a delegated worker run
//  (sent — `source: .delegation`). Built from the persisted chat session plus,
//  while it runs, the live background task, so the list needs no second store.
//
//  Intel: upstream also lists runs a teammate's Osaurus dispatched to this Mac
//  over a workspace relay ("received", `source: .workspace`). Workspaces are
//  deferred on Intel, so `DelegationRecordLoader` returns sent runs only; the
//  `received` direction is kept so a later workspace port needs no model change.
//

import Foundation

public struct DelegationRecord: Identifiable, Sendable, Equatable {
    public enum Direction: String, Sendable {
        /// This Osaurus delegated the task (Orchestrator or custom agent).
        case sent
        /// A teammate's Osaurus ran one of this Mac's shared agents
        /// (workspaces are deferred on Intel; never produced yet).
        case received
    }

    public enum Status: String, Sendable {
        case queued, running, waitingForInput, completed, failed, cancelled
    }

    /// The child session id (== the background task id).
    public let id: UUID
    public let direction: Direction
    /// Worker agent name.
    public let agentName: String
    /// The task, from the session title (`Delegated: …` prefix stripped).
    public let task: String
    public let status: Status
    public let startedAt: Date
    public let duration: TimeInterval
    public let completionTokens: Int?
    public let tokensPerSecond: Double?
    public let artifactCount: Int
    /// Whether the worker ended asking for input (`NEEDS INPUT:`).
    public let needsInput: Bool
    /// True while a live background task still drives the session.
    public let isLive: Bool

    public init(
        id: UUID,
        direction: Direction,
        agentName: String,
        task: String,
        status: Status,
        startedAt: Date,
        duration: TimeInterval,
        completionTokens: Int?,
        tokensPerSecond: Double?,
        artifactCount: Int,
        needsInput: Bool,
        isLive: Bool
    ) {
        self.id = id
        self.direction = direction
        self.agentName = agentName
        self.task = task
        self.status = status
        self.startedAt = startedAt
        self.duration = duration
        self.completionTokens = completionTokens
        self.tokensPerSecond = tokensPerSecond
        self.artifactCount = artifactCount
        self.needsInput = needsInput
        self.isLive = isLive
    }

    /// Strip the dispatcher's session-title prefix. Pure, for tests.
    static func taskTitle(from sessionTitle: String) -> String {
        let prefix = AgentDelegationDispatcher.titlePrefix
        if sessionTitle.hasPrefix(prefix) {
            return String(sessionTitle.dropFirst(prefix.count))
        }
        return sessionTitle
    }

    /// Build a record from a persisted session (turns loaded) and, when the
    /// run is still live, its background task status. Pure apart from the
    /// caller-supplied `agentName`, so the mapping is unit-testable.
    static func make(
        from session: ChatSessionData,
        direction: Direction,
        agentName: String,
        liveStatus: BackgroundTaskStatus?
    ) -> DelegationRecord {
        let usage = AgentDelegationDispatcher.usageAccounting(for: session.turns)
        let outcome = AgentDelegationDispatcher.outcome(from: session, elapsed: 0)
        let status: Status
        var isLive = false
        if let liveStatus {
            isLive = liveStatus.isActive
            switch liveStatus {
            case .queued: status = .queued
            case .running: status = .running
            case .waitingForInput: status = .waitingForInput
            case .completed: status = .completed
            case .failed: status = .failed
            case .cancelled: status = .cancelled
            }
        } else {
            status = outcome == nil ? .failed : .completed
        }
        let end = isLive ? Date() : session.updatedAt
        return DelegationRecord(
            id: session.id,
            direction: direction,
            agentName: agentName,
            task: taskTitle(from: session.title),
            status: status,
            startedAt: session.createdAt,
            duration: max(0, end.timeIntervalSince(session.createdAt)),
            completionTokens: usage.completionTokens,
            tokensPerSecond: usage.tokensPerSecond,
            artifactCount: AgentDelegationDispatcher.harvestArtifacts(from: session.turns).count,
            needsInput: outcome?.needsInput ?? false,
            isLive: isLive
        )
    }
}

/// Loads the Delegations list from the chat history DB + live tasks.
@MainActor
enum DelegationRecordLoader {
    /// Most recent `limit` sent records, newest first.
    static func load(limit: Int = 40) -> [DelegationRecord] {
        // Intel keeps sessions in `ChatSessionsManager` (a dictionary, turns
        // loaded), not upstream's SQLite chat-history database.
        let sentSessions = ChatSessionsManager.shared.sessions.values
            .filter { $0.source == .delegation }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
        let manager = BackgroundTaskManager.shared
        let agents = AgentManager.shared

        var sent: [DelegationRecord] = []
        for session in sentSessions {
            let name: String
            if let agent = agents.agent(for: session.agentId) {
                name = agent.name
            } else {
                name = L("Removed agent")
            }
            sent.append(
                DelegationRecord.make(
                    from: session,
                    direction: .sent,
                    agentName: name,
                    liveStatus: manager.taskState(for: session.id)?.status
                )
            )
        }
        return sent
    }
}
