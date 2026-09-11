//
//  IntelDelegationProbe.swift
//  OsaurusCore
//
//  A deliberately narrow, internal-only probe for the first Intel
//  Orchestrator delegation gate. It does not persist runs, alter the parent
//  chat, or expose a user-facing delegation surface.
//

#if OSAURUS_INTEL

import Foundation

/// A fail-closed, one-child delegation probe.
///
/// The caller resolves agent inheritance before constructing the input. This
/// keeps the probe independent of `AgentManager`, selected chats, and global
/// tool state: it reads no mutable application policy and writes none. The
/// resulting child request always has an empty tool surface and exactly two
/// messages (one system message and one user message).
actor IntelDelegationProbe {
    struct ParentSnapshot: Sendable, Equatable {
        let agentID: UUID
        let model: String?
        let systemPrompt: String
        let temperature: Double?
        let maxTokens: Int?

        init(
            agentID: UUID,
            model: String?,
            systemPrompt: String,
            temperature: Double?,
            maxTokens: Int?
        ) {
            self.agentID = agentID
            self.model = model
            self.systemPrompt = systemPrompt
            self.temperature = temperature
            self.maxTokens = maxTokens
        }
    }

    /// The already-resolved child configuration. `agent` remains present so
    /// admission can reject built-ins and accidental self-targeting even when
    /// the resolution came from a caller-owned snapshot.
    struct ChildConfiguration: Sendable, Equatable {
        let agent: Agent?
        let effectiveModel: String?
        let effectiveTemperature: Double?
        let effectiveMaxTokens: Int?

        init(
            agent: Agent?,
            effectiveModel: String?,
            effectiveTemperature: Double?,
            effectiveMaxTokens: Int?
        ) {
            self.agent = agent
            self.effectiveModel = effectiveModel
            self.effectiveTemperature = effectiveTemperature
            self.effectiveMaxTokens = effectiveMaxTokens
        }
    }

    /// Immutable details bound into the one child request.
    struct ChildSnapshot: Sendable, Equatable {
        let sessionID: UUID
        let targetAgentID: UUID
        let systemPrompt: String
        let model: String
        let temperature: Double?
        let maxTokens: Int
        let toolsSuppressed: Bool
    }

    struct InlineArtifact: Sendable, Equatable {
        let text: String
    }

    struct Success: Sendable, Equatable {
        let child: ChildSnapshot
        let text: String
        let artifact: InlineArtifact
    }

    enum Denial: String, Sendable, Equatable {
        case concurrentChild
        case missingTarget
        case builtInTarget
        case selfTarget
        case targetNotAllowlisted
        case missingModel
        case modelNotAllowlisted
        case missingOrInvalidTokenCap
    }

    enum Outcome: Sendable, Equatable {
        case succeeded(Success)
        case denied(Denial)
        case timedOut
        case cancelled
        case failed(String)
    }

    struct Configuration: Sendable, Equatable {
        let allowedTargetIDs: Set<UUID>
        let allowedModelIDs: Set<String>
        let spikeMaxTokens: Int
        let maxOutputCharacters: Int
        let timeoutNanoseconds: UInt64

        init(
            allowedTargetIDs: Set<UUID>,
            allowedModelIDs: Set<String>,
            spikeMaxTokens: Int = 256,
            maxOutputCharacters: Int = 8_192,
            timeoutNanoseconds: UInt64 = 30_000_000_000
        ) {
            self.allowedTargetIDs = allowedTargetIDs
            self.allowedModelIDs = allowedModelIDs
            self.spikeMaxTokens = max(1, spikeMaxTokens)
            self.maxOutputCharacters = max(1, maxOutputCharacters)
            self.timeoutNanoseconds = max(1, timeoutNanoseconds)
        }
    }

    typealias ChatEngineFactory = @Sendable () -> any ChatEngineProtocol

    private enum RaceResult: Sendable {
        case response(ChatCompletionResponse)
        case timedOut
        case cancelled
        case failed(String)
    }

    private let configuration: Configuration
    private let makeEngine: ChatEngineFactory
    private var activeChildSessionID: UUID?

    init(configuration: Configuration, engineFactory: @escaping ChatEngineFactory) {
        self.configuration = configuration
        self.makeEngine = engineFactory
    }

    /// Starts exactly one non-streaming completion. The parent snapshot is an
    /// input-only value; no parent, session, manager, or registry mutation is
    /// performed by this method.
    func run(
        parent: ParentSnapshot,
        child: ChildConfiguration,
        userMessage: String
    ) async -> Outcome {
        guard activeChildSessionID == nil else { return .denied(.concurrentChild) }
        guard let admitted = admit(parent: parent, child: child) else {
            return .denied(denial(parent: parent, child: child))
        }

        activeChildSessionID = admitted.sessionID
        defer { activeChildSessionID = nil }

        let request = ChatCompletionRequest(
            model: admitted.model,
            messages: [
                ChatMessage(role: "system", content: admitted.systemPrompt),
                ChatMessage(role: "user", content: userMessage),
            ],
            temperature: admitted.temperature,
            max_tokens: admitted.maxTokens,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: admitted.sessionID.uuidString
        )

        let engine = makeEngine()
        let race = await withTaskGroup(of: RaceResult.self, returning: RaceResult.self) { group in
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
                    try await Task.sleep(nanoseconds: self.configuration.timeoutNanoseconds)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }

            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }

        switch race {
        case let .response(response):
            let text = (response.choices.first?.message?.content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .failed("Child returned no text.") }
            let bounded = String(text.prefix(configuration.maxOutputCharacters))
            return .succeeded(
                Success(child: admitted, text: bounded, artifact: InlineArtifact(text: bounded))
            )
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        case let .failed(message):
            return .failed(message)
        }
    }

    private func admit(parent: ParentSnapshot, child: ChildConfiguration) -> ChildSnapshot? {
        guard let target = child.agent,
            !target.isBuiltIn,
            target.id != parent.agentID,
            configuration.allowedTargetIDs.contains(target.id),
            let model = normalized(child.effectiveModel),
            configuration.allowedModelIDs.contains(model),
            let childCap = child.effectiveMaxTokens,
            childCap > 0
        else { return nil }

        return ChildSnapshot(
            sessionID: UUID(),
            targetAgentID: target.id,
            systemPrompt: target.systemPrompt,
            model: model,
            temperature: child.effectiveTemperature,
            maxTokens: min(configuration.spikeMaxTokens, childCap),
            toolsSuppressed: true
        )
    }

    private func denial(parent: ParentSnapshot, child: ChildConfiguration) -> Denial {
        guard let target = child.agent else { return .missingTarget }
        guard !target.isBuiltIn else { return .builtInTarget }
        guard target.id != parent.agentID else { return .selfTarget }
        guard configuration.allowedTargetIDs.contains(target.id) else { return .targetNotAllowlisted }
        guard let model = normalized(child.effectiveModel) else { return .missingModel }
        guard configuration.allowedModelIDs.contains(model) else { return .modelNotAllowlisted }
        guard let childCap = child.effectiveMaxTokens, childCap > 0 else {
            return .missingOrInvalidTokenCap
        }
        return .missingTarget // Unreachable; keeps this fail-closed if admission changes.
    }

    private func normalized(_ model: String?) -> String? {
        guard let model else { return nil }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#endif
