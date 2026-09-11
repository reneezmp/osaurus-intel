//
//  IntelOrchestratorDelegationRuntime.swift
//  OsaurusCore
//
//  Gate 4's smallest executable contract: one bounded, text-only child.
//

#if OSAURUS_INTEL

import Foundation

/// Process-wide admission control for Gate 4's single child. Runtimes are
/// short-lived UI collaborators, so this state cannot live on a runtime
/// instance without allowing separate sheets or windows to overlap.
actor IntelOrchestratorDelegationChildSlot {
    static let shared = IntelOrchestratorDelegationChildSlot()

    private var activeReservationID: UUID?

    func reserve() -> UUID? {
        guard activeReservationID == nil else { return nil }
        let reservationID = UUID()
        activeReservationID = reservationID
        return reservationID
    }

    func release(_ reservationID: UUID) {
        guard activeReservationID == reservationID else { return }
        activeReservationID = nil
    }
}

/// A fail-closed dispatcher for a single text-only cloud child. It owns no
/// chat, agent-store, or tool-registry state; callers inject fresh target and
/// model validators so every run rechecks current application state.
actor IntelOrchestratorDelegationRuntime {
    struct TargetSnapshot: Sendable, Equatable {
        let agentID: UUID
        let isBuiltIn: Bool
        let systemPrompt: String
        let effectiveModel: String?
        let effectiveTemperature: Double?
        let effectiveMaxTokens: Int?

        init(
            agentID: UUID,
            isBuiltIn: Bool,
            systemPrompt: String,
            effectiveModel: String?,
            effectiveTemperature: Double?,
            effectiveMaxTokens: Int?
        ) {
            self.agentID = agentID
            self.isBuiltIn = isBuiltIn
            self.systemPrompt = systemPrompt
            self.effectiveModel = effectiveModel
            self.effectiveTemperature = effectiveTemperature
            self.effectiveMaxTokens = effectiveMaxTokens
        }
    }

    struct RunRequest: Sendable, Equatable {
        let launcherAgentID: UUID
        let targetAgentID: UUID
        let text: String

        init(launcherAgentID: UUID, targetAgentID: UUID, text: String) {
            self.launcherAgentID = launcherAgentID
            self.targetAgentID = targetAgentID
            self.text = text
        }
    }

    /// An approval token is valid only for the exact pair it names and only
    /// for the current call; the runtime deliberately persists nothing here.
    enum PerRunApproval: Sendable, Equatable {
        case none
        case approved(OrchestratorDelegationPermissionScope)

        fileprivate func covers(_ scope: OrchestratorDelegationPermissionScope) -> Bool {
            guard case let .approved(approvedScope) = self else { return false }
            return approvedScope == scope
        }
    }

    struct ApprovalRequired: Sendable, Equatable {
        let scope: OrchestratorDelegationPermissionScope
        let targetAgentID: UUID
        let modelID: String
    }

    struct InlineArtifact: Sendable, Equatable {
        let text: String
    }

    struct Success: Sendable, Equatable {
        let childSessionID: UUID
        let targetAgentID: UUID
        let modelID: String
        let text: String
        let artifact: InlineArtifact
    }

    enum Denial: String, Sendable, Equatable {
        case concurrentChild
        case emptyInput
        case inputTooLarge
        case missingTarget
        case builtInTarget
        case selfTarget
        case targetNotAllowlisted
        case missingModel
        case modelNotAdmitted
        case modelUnavailable
        case permissionDenied
    }

    enum Outcome: Sendable, Equatable {
        case succeeded(Success)
        case approvalRequired(ApprovalRequired)
        case denied(Denial)
        case timedOut
        case cancelled
        case failed(String)
    }

    typealias TargetResolver = @Sendable (UUID) -> TargetSnapshot?
    typealias CloudModelValidator = @Sendable (String) -> Bool
    typealias ChatEngineFactory = @Sendable () -> any ChatEngineProtocol

    private enum RaceResult: Sendable {
        case response(ChatCompletionResponse)
        case timedOut
        case cancelled
        case failed(String)
    }

    private let configuration: OrchestratorDelegationConfiguration
    private let resolveTarget: TargetResolver
    private let modelIsAvailable: CloudModelValidator
    private let makeEngine: ChatEngineFactory
    private let childSlot: IntelOrchestratorDelegationChildSlot

    init(
        configuration: OrchestratorDelegationConfiguration,
        targetResolver: @escaping TargetResolver,
        cloudModelValidator: @escaping CloudModelValidator,
        engineFactory: @escaping ChatEngineFactory,
        childSlot: IntelOrchestratorDelegationChildSlot = .shared
    ) {
        self.configuration = configuration
        self.resolveTarget = targetResolver
        self.modelIsAvailable = cloudModelValidator
        self.makeEngine = engineFactory
        self.childSlot = childSlot
    }

    /// Runs exactly one non-streaming request. The request has two messages and
    /// hard-codes both `tools` and `tool_choice` to nil, regardless of target
    /// configuration or the caller's tool state.
    func run(_ request: RunRequest, approval: PerRunApproval = .none) async -> Outcome {
        guard !Task.isCancelled else { return .cancelled }

        let input = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .denied(.emptyInput) }
        guard input.count <= configuration.maximumInputCharacters else { return .denied(.inputTooLarge) }

        let scope = OrchestratorDelegationPermissionScope(
            launcherAgentID: request.launcherAgentID,
            targetAgentID: request.targetAgentID
        )
        guard let target = resolveTarget(request.targetAgentID) else { return .denied(.missingTarget) }
        guard target.agentID == request.targetAgentID else { return .denied(.missingTarget) }
        guard !target.isBuiltIn else { return .denied(.builtInTarget) }
        guard target.agentID != request.launcherAgentID else { return .denied(.selfTarget) }
        guard configuration.customAgentAllowlist.contains(target.agentID) else {
            return .denied(.targetNotAllowlisted)
        }
        guard let model = OrchestratorDelegationConfiguration.normalizedModelID(target.effectiveModel ?? "") else {
            return .denied(.missingModel)
        }
        guard configuration.admits(modelID: model) else { return .denied(.modelNotAdmitted) }
        guard modelIsAvailable(model) else { return .denied(.modelUnavailable) }

        switch configuration.permission(for: scope) {
        case .deny:
            return .denied(.permissionDenied)
        case .ask where !approval.covers(scope):
            return .approvalRequired(.init(scope: scope, targetAgentID: target.agentID, modelID: model))
        case .ask, .alwaysAllow:
            break
        }

        guard !Task.isCancelled else { return .cancelled }
        guard let sessionID = await childSlot.reserve() else { return .denied(.concurrentChild) }

        let outcome = await runReservedChild(
            sessionID: sessionID,
            target: target,
            model: model,
            input: input
        )
        await childSlot.release(sessionID)
        return outcome
    }

    private func runReservedChild(
        sessionID: UUID,
        target: TargetSnapshot,
        model: String,
        input: String
    ) async -> Outcome {
        guard !Task.isCancelled else { return .cancelled }

        let requestedCap = target.effectiveMaxTokens ?? configuration.maximumChildTokens
        let maxTokens = min(configuration.maximumChildTokens, max(1, requestedCap))
        let childRequest = ChatCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: target.systemPrompt),
                ChatMessage(role: "user", content: input),
            ],
            temperature: target.effectiveTemperature,
            max_tokens: maxTokens,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: sessionID.uuidString
        )

        let race = await completionRace(for: childRequest)
        switch race {
        case let .response(response):
            guard !Task.isCancelled else { return .cancelled }
            let text = (response.choices.first?.message?.content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .failed("Child returned no text.") }
            let bounded = String(text.prefix(configuration.maximumOutputCharacters))
            return .succeeded(.init(
                childSessionID: sessionID,
                targetAgentID: target.agentID,
                modelID: model,
                text: bounded,
                artifact: .init(text: bounded)
            ))
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        case let .failed(message):
            return .failed(message)
        }
    }

    private func completionRace(for request: ChatCompletionRequest) async -> RaceResult {
        let engine = makeEngine()
        return await withTaskGroup(of: RaceResult.self, returning: RaceResult.self) { group in
            group.addTask {
                do {
                    let response = try await engine.completeChat(request: request)
                    return Task.isCancelled ? .cancelled : .response(response)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failed(String(describing: error))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: self.timeoutNanoseconds)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }

            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }
    }

    private var timeoutNanoseconds: UInt64 {
        let seconds = min(configuration.timeoutSeconds, UInt64.max / 1_000_000_000)
        return max(1, seconds * 1_000_000_000)
    }
}

#endif
