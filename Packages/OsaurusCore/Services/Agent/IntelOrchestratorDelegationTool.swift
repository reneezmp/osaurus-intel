//
//  IntelOrchestratorDelegationTool.swift
//  OsaurusCore
//
//  Model-callable bridge to Gate 4's bounded, fail-closed child runtime.
//

#if OSAURUS_INTEL

import AppKit
import Foundation

struct IntelOrchestratorDelegationTool: OsaurusTool, PermissionedTool {
    static let toolName = "orchestrator_delegate"

    enum ApprovalDecision: Sendable, Equatable {
        case allowOnce
        case deny
        case alwaysAllow
        case cancelled
    }

    struct ApprovalRequest: Sendable, Equatable {
        let scope: OrchestratorDelegationPermissionScope
        let targetAgentID: UUID
        let modelID: String
    }

    typealias RuntimeBuilder = @Sendable () async -> IntelOrchestratorDelegationRuntime
    typealias ApprovalRequester = @Sendable (ApprovalRequest) async -> ApprovalDecision
    typealias AlwaysAllowPersister = @Sendable (OrchestratorDelegationPermissionScope) async -> Void

    let name = Self.toolName
    let description =
        "Run one bounded, fresh, tool-free turn with an explicitly admitted custom agent and cloud model. "
        + "The result is returned as bounded inline text; no child chat, file, background task, or nested delegation is created."
    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy = .auto
    let handlesOwnApproval = true
    let bypassRegistryTimeout = true
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "target_agent_id": .object([
                "type": .string("string"),
                "description": .string("UUID of an explicitly admitted custom agent."),
            ]),
            "request": .object([
                "type": .string("string"),
                "description": .string("The single bounded task for the child agent."),
            ]),
        ]),
        "required": .array([.string("target_agent_id"), .string("request")]),
    ])

    private let runtimeBuilder: RuntimeBuilder
    private let approvalRequester: ApprovalRequester
    private let alwaysAllowPersister: AlwaysAllowPersister

    init(
        runtimeBuilder: @escaping RuntimeBuilder = Self.makeLiveRuntime,
        approvalRequester: @escaping ApprovalRequester = Self.requestLiveApproval,
        alwaysAllowPersister: @escaping AlwaysAllowPersister = Self.persistAlwaysAllow
    ) {
        self.runtimeBuilder = runtimeBuilder
        self.approvalRequester = approvalRequester
        self.alwaysAllowPersister = alwaysAllowPersister
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard ChatExecutionContext.currentAgentId == Agent.defaultId else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "Delegation is available only to the built-in Orchestrator.",
                tool: name
            )
        }
        guard !Task.isCancelled else {
            return ToolEnvelope.failure(kind: .rejected, message: "Delegation was cancelled.", tool: name)
        }

        let requirement = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let arguments) = requirement else {
            return requirement.failureEnvelope ?? ""
        }
        guard let rawTarget = arguments["target_agent_id"] as? String,
              let targetID = UUID(uuidString: rawTarget) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "target_agent_id must be a valid UUID.",
                field: "target_agent_id",
                tool: name
            )
        }
        guard let request = arguments["request"] as? String else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "request is required.",
                field: "request",
                tool: name
            )
        }

        let runtime = await runtimeBuilder()
        let runRequest = IntelOrchestratorDelegationRuntime.RunRequest(
            launcherAgentID: Agent.defaultId,
            targetAgentID: targetID,
            text: request
        )
        var outcome = await runtime.run(runRequest)
        if case let .approvalRequired(required) = outcome {
            let approval = ApprovalRequest(
                scope: required.scope,
                targetAgentID: required.targetAgentID,
                modelID: required.modelID
            )
            switch await approvalRequester(approval) {
            case .allowOnce:
                outcome = await runtime.run(runRequest, approval: .approved(required.scope))
            case .alwaysAllow:
                await alwaysAllowPersister(required.scope)
                outcome = await runtime.run(runRequest, approval: .approved(required.scope))
            case .deny:
                return ToolEnvelope.failure(
                    kind: .userDenied,
                    message: "The user denied this delegated run.",
                    tool: name,
                    retryable: false
                )
            case .cancelled:
                return ToolEnvelope.failure(
                    kind: .rejected,
                    message: "The delegation approval was cancelled.",
                    tool: name,
                    retryable: true
                )
            }
        }
        return envelope(for: outcome)
    }

    private func envelope(for outcome: IntelOrchestratorDelegationRuntime.Outcome) -> String {
        switch outcome {
        case let .succeeded(success):
            return ToolEnvelope.success(tool: name, result: [
                "status": "completed",
                "target_agent_id": success.targetAgentID.uuidString,
                "model": success.modelID,
                "text": success.text,
            ])
        case let .approvalRequired(required):
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Approval remains required for (required.scope.targetAgentID.uuidString).",
                tool: name,
                retryable: true
            )
        case let .denied(reason):
            return ToolEnvelope.failure(
                kind: .rejected,
                message: Self.message(for: reason),
                tool: name,
                retryable: false
            )
        case .timedOut:
            return ToolEnvelope.failure(kind: .timeout, message: "The delegated turn timed out.", tool: name, retryable: true)
        case .cancelled:
            return ToolEnvelope.failure(kind: .rejected, message: "The delegated turn was cancelled.", tool: name, retryable: true)
        case let .failed(message):
            return ToolEnvelope.failure(
                kind: .executionError,
                message: String(message.prefix(512)),
                tool: name,
                retryable: true
            )
        }
    }

    private static func message(for denial: IntelOrchestratorDelegationRuntime.Denial) -> String {
        switch denial {
        case .concurrentChild: return "Another delegated turn is already running."
        case .emptyInput: return "The delegated request is empty."
        case .inputTooLarge: return "The delegated request exceeds the configured input limit."
        case .missingTarget: return "The target agent no longer exists."
        case .builtInTarget: return "Built-in agents cannot be delegation targets."
        case .selfTarget: return "The Orchestrator cannot delegate to itself."
        case .targetNotAllowlisted: return "The target agent is not admitted in Orchestrator settings."
        case .missingModel: return "The target agent has no effective model."
        case .modelNotAdmitted: return "The target model is not admitted in Orchestrator settings."
        case .modelUnavailable: return "The admitted cloud model is not currently available."
        case .permissionDenied: return "Delegation is denied for this exact Orchestrator and target pair."
        }
    }

    private static func makeLiveRuntime() async -> IntelOrchestratorDelegationRuntime {
        await ModelPickerItemCache.shared.prewarmModelCache()
        let configuration = DefaultAgentConfigurationStore.load().delegation
        let live = await MainActor.run { () -> ([UUID: IntelOrchestratorDelegationRuntime.TargetSnapshot], Set<String>) in
            let manager = AgentManager.shared
            let targets = Dictionary(uniqueKeysWithValues: manager.agents.map { agent in
                let snapshot = IntelOrchestratorDelegationRuntime.TargetSnapshot(
                    agentID: agent.id,
                    isBuiltIn: agent.isBuiltIn,
                    systemPrompt: manager.effectiveSystemPrompt(for: agent.id),
                    effectiveModel: manager.effectiveModel(for: agent.id),
                    effectiveTemperature: manager.effectiveTemperature(for: agent.id),
                    effectiveMaxTokens: manager.effectiveMaxTokens(for: agent.id)
                )
                return (agent.id, snapshot)
            })
            let cloudModels = Set(ModelPickerItemCache.shared.items.compactMap { item -> String? in
                guard case .remote = item.source,
                      item.isLikelyChatCapable,
                      !item.id.hasPrefix("claude-code/") else { return nil }
                return item.id
            })
            return (targets, cloudModels)
        }
        return IntelOrchestratorDelegationRuntime(
            configuration: configuration,
            targetResolver: { live.0[$0] },
            cloudModelValidator: { live.1.contains($0) },
            engineFactory: { ChatEngine() }
        )
    }

    private static func requestLiveApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Allow one delegated turn?"
            alert.informativeText = "Target: \(request.targetAgentID.uuidString)\nModel: \(request.modelID)"
            alert.addButton(withTitle: "Allow Once")
            alert.addButton(withTitle: "Deny")
            alert.addButton(withTitle: "Always Allow")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .allowOnce
            case .alertThirdButtonReturn: return .alwaysAllow
            case .alertSecondButtonReturn: return .deny
            default: return .cancelled
            }
        }
    }

    private static func persistAlwaysAllow(_ scope: OrchestratorDelegationPermissionScope) async {
        await MainActor.run {
            var configuration = DefaultAgentConfigurationStore.load()
            configuration.delegation.setPermission(.alwaysAllow, for: scope)
            AgentManager.shared.updateDefaultAgentConfiguration(configuration)
        }
    }
}

/// Live, read-only discovery avoids treating a cached prompt or a pair of
/// switches as proof that a target can actually run. Dispatch still performs
/// its own fresh admission and availability checks.
struct IntelOrchestratorTargetsTool: OsaurusTool, PermissionedTool {
    static let toolName = "orchestrator_targets"
    typealias SnapshotBuilder = @Sendable () async -> IntelOrchestratorAdmission.Evaluation

    let name = Self.toolName
    let description = "List currently runnable, admitted Orchestrator delegation targets and explain why allowed agents are blocked. Read-only; never launches a child."
    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy = .auto
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([:]),
    ])

    private let snapshotBuilder: SnapshotBuilder

    init(snapshotBuilder: @escaping SnapshotBuilder = Self.liveSnapshot) {
        self.snapshotBuilder = snapshotBuilder
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard ChatExecutionContext.currentAgentId == Agent.defaultId else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "Target discovery is available only to the built-in Orchestrator.",
                tool: name
            )
        }
        let requirement = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value = requirement else { return requirement.failureEnvelope ?? "" }
        let snapshot = await snapshotBuilder()
        return ToolEnvelope.success(tool: name, result: [
            "targets": snapshot.targets.map { target in
                ["name": target.name, "target_agent_id": target.id.uuidString, "model": target.modelID]
            },
            "blocked": snapshot.blocked,
        ])
    }

    private static func liveSnapshot() async -> IntelOrchestratorAdmission.Evaluation {
        await ModelPickerItemCache.shared.prewarmModelCache()
        return await MainActor.run {
            let manager = AgentManager.shared
            let available = Set(ModelPickerItemCache.shared.items.compactMap { item -> String? in
                guard case .remote = item.source,
                      item.isLikelyChatCapable,
                      !item.id.hasPrefix("claude-code/") else { return nil }
                return item.id
            })
            return IntelOrchestratorAdmission.evaluate(
                configuration: DefaultAgentConfigurationStore.load().delegation,
                agents: manager.agents,
                effectiveModel: { manager.effectiveModel(for: $0) },
                availableModelIDs: available
            )
        }
    }
}

#endif
