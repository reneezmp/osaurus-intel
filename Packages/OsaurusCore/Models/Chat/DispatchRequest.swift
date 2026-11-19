//
//  DispatchRequest.swift
//  osaurus
//
//  Async dispatch trigger for running a chat task.
//  Any trigger (schedules, webhooks, shortcuts, plugins, etc.) creates a
//  DispatchRequest and hands it to TaskDispatcher.
//

import Foundation

// MARK: - Request

/// Describes a task to dispatch as a (possibly headless) chat session.
public struct DispatchRequest: Sendable {
    public let id: UUID
    public let prompt: String
    public let agentId: UUID?
    public let title: String?
    public let parameters: [String: String]
    public let folderPath: String?
    public let folderBookmark: Data?
    /// Set to `false` for headless execution (e.g. webhooks).
    public let showToast: Bool
    /// Plugin that originated this dispatch (for on_task_event callback routing).
    public let sourcePluginId: String?
    /// Where this dispatch came from. Drives the persisted `SessionSource`
    /// so the sidebar / DB can distinguish plugin / HTTP / scheduler runs
    /// from user-initiated chats.
    public let source: SessionSource
    /// Stable external grouping key (e.g. Telegram chat id, HTTP `X-Session-Id`).
    /// Lets repeated dispatches from the same conversation accrete into one
    /// persisted session row instead of a fresh one per call.
    public let externalSessionKey: String?
    /// When false, `externalSessionKey` only tags the new session (so the
    /// sidebar can group runs by trigger) and never reattaches to an earlier
    /// row. Schedules use this so every run starts a fresh chat (upstream
    /// #3007).
    public let reattachSession: Bool
    /// Tool names the dispatcher wants exposed to the model on top of the
    /// agent's normal selection (auto-mode preflight or manual list).
    /// Plugin-sourced dispatches populate this from the validated `tools`
    /// array on the dispatch JSON; the host has already filtered names to
    /// the calling plugin's own manifest tools plus host built-in
    /// always-loaded names. Empty for non-plugin sources today; safe to
    /// feed straight into `SessionToolStateStore.appendLoadedTools` since
    /// the names are pre-validated.
    public let requestedToolNames: [String]
    /// Intel: lets this dispatch target a built-in agent (the Default agent),
    /// which background dispatch otherwise refuses. Set only by the in-process
    /// App Intents client (`OsaurusLocalClient`), whose callers have the same
    /// trust as upstream's loopback callers of `/agents/{id}/run`, where
    /// upstream relaxes the same guard. Never set from HTTP, plugins,
    /// schedules or watchers.
    public let allowsBuiltInAgent: Bool
    /// Upstream: the run comes from an external caller (a non-loopback HTTP
    /// dispatch). The background runner binds
    /// `ChatExecutionContext.isExternalSurface` for it, so the external
    /// tool deny list and the `.ask` refusal hold for the whole run.
    public let externalSurface: Bool

    /// True when this dispatch is a TRUE agent delegation (an orchestrating
    /// agent's `spawn_agent` call). Derived from `source` so there is exactly
    /// one source of truth (upstream Classic `DispatchRequest`). The
    /// dispatcher binds the source as `ChatExecutionContext.currentSessionSource`
    /// for the run, which the composer uses to strip `spawn_*` tools from the
    /// delegated child so a helper can never fan out recursively.
    public var isDelegatedRun: Bool { source == .delegation }

    /// Enforced delegation budget for `.delegation` dispatches: the child
    /// run's per-generation response-token cap, assistant tool-loop turn cap
    /// and context-position cap, from the launcher's `SubagentBudgets`. nil
    /// (every other source) leaves the chat surface's normal limits
    /// untouched. A budget the child is not held to would be fail-open, so
    /// these are enforced by `ChatSession`.
    public let delegationResponseTokenCap: Int?
    public let delegationAssistantTurnCap: Int?
    public let delegationContextPositionCap: Int?
    /// Exact model resolved and admitted for this delegated run (Intel: the
    /// Gate 4 admitted cloud model). Only carried for `.delegation`.
    public let delegationModel: String?

    /// The enforced delegation contract carried by this request, or nil.
    /// All three caps must be present to form a contract; a partial contract
    /// is no contract (upstream).
    public var delegationContract: DelegatedRunContract? {
        guard
            let tokens = delegationResponseTokenCap,
            let turns = delegationAssistantTurnCap,
            let positions = delegationContextPositionCap
        else { return nil }
        return DelegatedRunContract(
            responseTokens: tokens,
            assistantTurns: turns,
            contextPositions: positions
        )
    }

    public init(
        id: UUID = UUID(),
        prompt: String,
        agentId: UUID? = nil,
        title: String? = nil,
        parameters: [String: String] = [:],
        folderPath: String? = nil,
        folderBookmark: Data? = nil,
        showToast: Bool = true,
        sourcePluginId: String? = nil,
        source: SessionSource = .chat,
        externalSessionKey: String? = nil,
        reattachSession: Bool = true,
        requestedToolNames: [String] = [],
        allowsBuiltInAgent: Bool = false,
        externalSurface: Bool = false,
        delegationResponseTokenCap: Int? = nil,
        delegationContextPositionCap: Int? = nil,
        delegationAssistantTurnCap: Int? = nil,
        delegationModel: String? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.agentId = agentId
        self.title = title
        self.parameters = parameters
        self.folderPath = folderPath
        self.folderBookmark = folderBookmark
        self.showToast = showToast
        self.sourcePluginId = sourcePluginId
        self.source = source
        self.externalSessionKey = externalSessionKey
        self.reattachSession = reattachSession
        self.requestedToolNames = requestedToolNames
        self.allowsBuiltInAgent = allowsBuiltInAgent
        self.externalSurface = externalSurface
        self.delegationResponseTokenCap = delegationResponseTokenCap
        self.delegationContextPositionCap = delegationContextPositionCap
        self.delegationAssistantTurnCap = delegationAssistantTurnCap
        self.delegationModel = source == .delegation ? delegationModel : nil
    }
}

// MARK: - Handle

/// Returned after dispatch; used for observation and cancellation
public struct DispatchHandle: Sendable {
    public let id: UUID
    public let request: DispatchRequest
}

// MARK: - Result

/// Outcome of a dispatched task
public enum DispatchResult: Sendable {
    case completed(sessionId: UUID?)
    case cancelled
    case failed(String)
}
