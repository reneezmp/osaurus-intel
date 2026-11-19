//
//  SpawnDescriptors.swift
//  OsaurusCore — Subagent framework
//
//  Rich, render-ready descriptions of an agent's spawnable targets, used to
//  build the dynamic `spawn` system-prompt block. The composer resolves the
//  launching agent's spawnable AGENT UUIDs + workspace refs (from
//  `SubagentToolVisibility`) into these descriptors so the prompt can
//  enumerate what `spawn_agent` can actually reach — with locality
//  (local/remote), provider, the agent's description, and its working folder
//  — instead of bare names. Pure value types.
//
//  Intel (docs/SUBAGENTS_INTEL.md, W-subagents stage 1): only the value types
//  and `SpawnInputContract` are taken. Upstream's `SpawnDescriptors` resolver
//  reads the local-model catalog, picker cache and
//  `RemoteProviderManager.connectedSpawnModelTargetIndex`; Intel resolves a
//  target's availability from Gate 4 admission instead (stage 2).
//

import Foundation

/// Shared schema contract for the delegation tool.
///
/// Workers are context-isolated: an agent receives only its own prompt plus
/// this input, never the parent transcript.
enum SpawnInputContract {
    static let schemaDescription =
        "The complete standalone task. The agent cannot see this chat, so include every "
        + "instruction, input value, constraint, and the required output format here."

    static let backgroundParameterDescription =
        "Default false. True returns immediately with the worker's session_id; the result "
        + "arrives later as a follow-up message. Do not poll or re-send."

    /// Enforce only the structural part of the standalone-input contract.
    ///
    /// Whether prose depends on parent-chat state cannot be decided safely by
    /// substring matching: quoted text, translation work, and source code may
    /// legitimately contain phrases such as “previous message”. The schema
    /// description remains the model-facing guidance; execution rejects only a
    /// task that is structurally empty.
    static func validationFailure(
        input: String,
        field: String = "input",
        tool: String
    ) -> String? {
        guard input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ToolEnvelope.failure(
            kind: .invalidArgs,
            message:
                "The worker task in `\(field)` cannot be blank. Provide the complete standalone "
                + "instructions, input values, constraints, and required output format.",
            field: field,
            expected: "a non-empty standalone worker task",
            tool: tool,
            retryable: true
        )
    }
}

/// One spawnable agent (`spawn_agent` target), resolved for the prompt.
public struct SpawnAgentDescriptor: Sendable, Equatable {
    /// Stable execution/authorization identity.
    public let id: UUID
    public let name: String
    /// The agent's own description (trimmed; nil when blank).
    public let description: String?
    /// The agent's effective model id (nil when none resolved).
    public let modelId: String?
    /// Locality of `modelId`: `true` local, `false` remote, nil when unknown
    /// (cold picker cache / model not currently present).
    public let isLocal: Bool?
    /// Remote provider name when the model is remote (nil otherwise).
    public let providerName: String?
    /// The agent's own configured Working Folder (`Agent.workingFolderPath`),
    /// nil when none is set. A delegated child runs as a real chat session
    /// of the target agent; when the agent has its own folder the child
    /// works there, otherwise it inherits the launcher's folder
    /// (`AgentDelegationDispatcher`). Surfaced in the spawn guidance so the
    /// orchestrator knows where a worker's files land.
    public let workingFolderPath: String?

    public init(
        id: UUID,
        name: String,
        description: String?,
        modelId: String?,
        isLocal: Bool?,
        providerName: String?,
        workingFolderPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.modelId = modelId
        self.isLocal = isLocal
        self.providerName = providerName
        self.workingFolderPath = workingFolderPath?.isEmpty == false ? workingFolderPath : nil
    }
}

/// One spawnable shared WORKSPACE agent (`spawn_agent` target that runs on a
/// teammate's Mac), resolved for the prompt. Deliberately carries NO model
/// and NO presence: the host decides the model (and may change it), and
/// presence flips constantly — either in the prompt would reset the prefix
/// cache on almost every turn. Liveness is probed at spawn time instead
/// (`WorkspaceAgentLiveness`).
public struct SpawnWorkspaceAgentDescriptor: Sendable, Equatable {
    /// Durable identity (`(workspaceId, agentAddress)`); the tool enum value
    /// is `ref.agentAddress`.
    public let ref: WorkspaceAgentRef
    /// The sharer's chosen display name (roster → pairing → last known →
    /// shortened address).
    public let name: String
    /// The roster description (trimmed; nil when blank).
    public let description: String?
    /// Workspace display name, when the roster knows it.
    public let workspaceName: String?
    /// The sharer's friendly name, when the roster knows it.
    public let ownerName: String?

    public init(
        ref: WorkspaceAgentRef,
        name: String,
        description: String?,
        workspaceName: String?,
        ownerName: String?
    ) {
        self.ref = ref
        self.name = name
        self.description = description
        self.workspaceName = workspaceName
        self.ownerName = ownerName
    }

    /// `Name@Workspace` when the workspace name is known, else the name.
    public var qualifiedName: String {
        guard let workspaceName, !workspaceName.isEmpty else { return name }
        return "\(name)@\(workspaceName)"
    }
}

/// Request-local execution truth for one configured spawn target. Durable
/// configuration remains untouched so unavailable rows can still be repaired
/// or removed in Settings.
enum SpawnTargetState: Sendable, Equatable {
    case runnable
    case checking
    case disconnected
    case missing
    /// Runs on an external harness, which `spawn_agent` can't drive.
    case harness
}

struct SpawnAgentTarget: Sendable, Equatable {
    let descriptor: SpawnAgentDescriptor
    let state: SpawnTargetState
}

/// A workspace target is `runnable` or `missing` ONLY (never `checking` /
/// `disconnected`): membership is durable state that changes by user action
/// (unshare, leave workspace, router off), like deleting a local agent.
struct SpawnWorkspaceAgentTarget: Sendable, Equatable {
    let descriptor: SpawnWorkspaceAgentDescriptor
    let state: SpawnTargetState
}

/// One immutable target view shared by prompt prose and the spawn schema for
/// a request. This prevents provider/model changes between composition phases
/// from producing zombie options or prompt/schema drift.
struct SpawnTargetAvailabilitySnapshot: Sendable, Equatable {
    static let empty = SpawnTargetAvailabilitySnapshot(agentTargets: [])

    let agentTargets: [SpawnAgentTarget]
    let workspaceAgentTargets: [SpawnWorkspaceAgentTarget]

    init(
        agentTargets: [SpawnAgentTarget],
        workspaceAgentTargets: [SpawnWorkspaceAgentTarget] = []
    ) {
        self.agentTargets = agentTargets
        self.workspaceAgentTargets = workspaceAgentTargets
    }

    var agents: [SpawnAgentDescriptor] {
        agentTargets.compactMap { $0.state == .runnable ? $0.descriptor : nil }
    }

    var workspaceAgents: [SpawnWorkspaceAgentDescriptor] {
        workspaceAgentTargets.compactMap { $0.state == .runnable ? $0.descriptor : nil }
    }

    var runnableAgentIDs: [UUID] { agents.map(\.id) }
    var runnableWorkspaceAgents: [WorkspaceAgentRef] { workspaceAgents.map(\.ref) }
    /// Whether `spawn_agent` has anything to reach (local or workspace).
    var hasRunnableAgentTargets: Bool {
        !runnableAgentIDs.isEmpty || !runnableWorkspaceAgents.isEmpty
    }
}
