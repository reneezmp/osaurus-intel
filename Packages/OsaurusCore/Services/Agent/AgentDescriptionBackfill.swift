//
//  AgentDescriptionBackfill.swift
//  osaurus
//
//  Upstream #2892/#2897/#2901 background description backfill, adapted for
//  Intel (docs/INTEL_MISSING_FEATURES_BACKLOG.md, `W-description-backfill`).
//
//  Fills `Agent.generatedDescription` for custom agents whose own
//  `description` is blank, so the Orchestrator roster and agent lists can show
//  a purpose. The user's text always wins; a generated purpose is redone only
//  when the instructions change (prompt hash).
//
//  Intel differences: upstream runs this on a free local core model. Intel has
//  no local model, so every call is a paid request with the agent's own cloud
//  model — it runs **only while Settings › Chat › "Fill in missing agent
//  descriptions" is on (off by default)**, decided by Renée 2026-09-29.
//

import Foundation

@MainActor
final class AgentDescriptionBackfill {
    static let shared = AgentDescriptionBackfill()

    typealias Generator = @MainActor (_ systemPrompt: String, _ model: String?) async throws -> String

    /// The opt-in switch. Tests inject their own.
    var isEnabled: () -> Bool
    var generator: Generator
    /// Wait before retrying an agent after a failure (same prompt).
    var retryInterval: TimeInterval = 10 * 60

    private var inFlight: [UUID: String] = [:]
    private var retryAfter: [UUID: (promptHash: String, until: Date)] = [:]
    private var queue: [UUID] = []
    private var drainTask: Task<Void, Never>?

    init(
        isEnabled: @escaping () -> Bool = {
            !RuntimeEnvironment.isUnderTests && ChatConfiguration.load().backfillAgentDescriptions
        },
        generator: @escaping Generator = { prompt, model in
            try await IntelAgentDescriptionGenerator.suggest(systemPrompt: prompt, agentModel: model)
        }
    ) {
        self.isEnabled = isEnabled
        self.generator = generator
    }

    /// Eligibility shared by every trigger.
    static func needsGeneration(_ agent: Agent) -> Bool {
        guard !agent.isBuiltIn else { return false }
        guard AgentDescriptionPolicy.normalized(agent.description).isEmpty else { return false }
        let prompt = AgentDescriptionPolicy.normalized(agent.systemPrompt)
        guard !prompt.isEmpty else { return false }
        if agent.generatedDescriptionPromptHash == AgentDescriptionPolicy.promptHash(prompt),
            !AgentDescriptionPolicy.normalized(agent.generatedDescription ?? "").isEmpty
        {
            return false
        }
        return true
    }

    /// Queue one agent when eligible. Safe to call from any save path.
    func scheduleIfNeeded(_ id: UUID) {
        guard isEnabled(), let agent = AgentManager.shared.agent(for: id), Self.needsGeneration(agent) else {
            return
        }
        let hash = AgentDescriptionPolicy.promptHash(agent.systemPrompt)
        guard inFlight[id] != hash, !queue.contains(id) else { return }
        if let retry = retryAfter[id], retry.promptHash == hash, retry.until > Date() { return }
        queue.append(id)
        drainIfNeeded()
    }

    /// Queue every eligible agent (after a chat run, or when the switch is turned on).
    func scheduleAll() {
        guard isEnabled() else { return }
        for agent in AgentManager.shared.agents where Self.needsGeneration(agent) {
            scheduleIfNeeded(agent.id)
        }
    }

    /// Await the current queue. Test hook.
    func drain() async {
        while let task = drainTask { await task.value }
    }

    private func drainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // One request at a time: a long roster never fans out paid calls.
            while !self.queue.isEmpty {
                let id = self.queue.removeFirst()
                await self.run(id)
            }
            self.drainTask = nil
        }
    }

    private func run(_ id: UUID) async {
        guard isEnabled(), let agent = AgentManager.shared.agent(for: id), Self.needsGeneration(agent) else {
            return
        }
        let prompt = AgentDescriptionPolicy.normalized(agent.systemPrompt)
        let hash = AgentDescriptionPolicy.promptHash(prompt)
        if let retry = retryAfter[id], retry.promptHash == hash, retry.until > Date() { return }
        inFlight[id] = hash
        defer { inFlight[id] = nil }
        do {
            let summary = try await generator(prompt, AgentManager.shared.effectiveModel(for: id))
            // Re-read: the user may have typed a description or changed the
            // instructions while the model was working. Their edit wins.
            guard var current = AgentManager.shared.agent(for: id), !current.isBuiltIn,
                AgentDescriptionPolicy.normalized(current.description).isEmpty,
                AgentDescriptionPolicy.promptHash(current.systemPrompt) == hash
            else { return }
            let normalized = AgentDescriptionPolicy.normalized(summary)
            guard !normalized.isEmpty else {
                retryAfter[id] = (hash, Date().addingTimeInterval(retryInterval))
                return
            }
            current.generatedDescription = normalized
            current.generatedDescriptionPromptHash = hash
            AgentManager.shared.update(current)
            retryAfter[id] = nil
        } catch is CancellationError {
            // Nothing persisted; the next trigger reschedules.
        } catch {
            retryAfter[id] = (hash, Date().addingTimeInterval(retryInterval))
            NSLog("[Osaurus] description backfill failed for \(id.uuidString): \(error.localizedDescription)")
        }
    }
}
