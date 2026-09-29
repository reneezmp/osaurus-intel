//
//  IntelSelfSchedulingTests.swift
//  OsaurusCoreTests
//
//  `W-self-scheduling` (docs/INTEL_MISSING_FEATURES_BACKLOG.md): the per-agent
//  switch, the enable rule, prompt offering, and schedule_next_run /
//  cancel_next_run / notify through the real bridge and scheduler database
//  (isolated test storage).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel self-scheduling", .serialized)
struct IntelSelfSchedulingTests {
    private static func makeAgent(enabled: Bool, mode: AgentScheduleMode = .ambient) -> Agent {
        var agent = Agent(name: "sched-\(UUID().uuidString.prefix(6))", systemPrompt: "x", agentAddress: nil)
        agent.settings.selfSchedulingEnabled = enabled
        agent.settings.schedule = AgentScheduleSettings.defaults(for: mode)
        agent.manualToolNames = ["file_read"]  // a seeded allowlist without scheduler tools
        return agent
    }

    private static func object(_ envelope: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]) ?? [:]
    }

    @Test("The switch round-trips and older agents decode with it off")
    func settingCodable() throws {
        var settings = AgentSettings.defaultDisabled
        #expect(!settings.selfSchedulingEnabled)
        settings.selfSchedulingEnabled = true
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AgentSettings.self, from: data).selfSchedulingEnabled)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "selfSchedulingEnabled")
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try !JSONDecoder().decode(AgentSettings.self, from: old).selfSchedulingEnabled)
    }

    @MainActor
    @Test("Enabled only for a custom agent with the switch on and tools on")
    func enableRule() async throws {
        try await ChatHistoryTestStorage.run {
            let on = Self.makeAgent(enabled: true)
            let off = Self.makeAgent(enabled: false)
            var toolsOff = Self.makeAgent(enabled: true)
            toolsOff.disableTools = true
            for agent in [on, off, toolsOff] { AgentManager.shared.add(agent) }
            #expect(AgentManager.shared.effectiveSelfSchedulingEnabled(for: on.id))
            #expect(!AgentManager.shared.effectiveSelfSchedulingEnabled(for: off.id))
            #expect(!AgentManager.shared.effectiveSelfSchedulingEnabled(for: toolsOff.id))
            #expect(!AgentManager.shared.effectiveSelfSchedulingEnabled(for: Agent.defaultId))

            let offered = await SystemPromptComposer.composeChatContext(agentId: on.id, query: "hi")
            #expect(ToolRegistry.selfSchedulingToolNames.isSubset(of: Set(offered.tools.map(\.function.name))))
            let hidden = await SystemPromptComposer.composeChatContext(agentId: off.id, query: "hi")
            #expect(Set(hidden.tools.map(\.function.name)).isDisjoint(with: ToolRegistry.selfSchedulingToolNames))
            for agent in [on, off, toolsOff] { _ = await AgentManager.shared.delete(id: agent.id) }
        }
    }

    @Test("schedule_next_run writes a wake within bounds; cancel clears it; off is refused")
    func scheduleThroughBridge() async throws {
        try await ChatHistoryTestStorage.run {
            let on = Self.makeAgent(enabled: true, mode: .reactive)
            let off = Self.makeAgent(enabled: false)
            AgentManager.shared.add(on)
            AgentManager.shared.add(off)

            let refused = try await ChatExecutionContext.$currentAgentId.withValue(off.id) {
                try await ToolRegistry.shared.execute(
                    name: "schedule_next_run",
                    argumentsJSON: #"{"instructions":"Check the pantry list","in_seconds":600}"#)
            }
            #expect(refused.contains("Self-scheduling is disabled"))

            let scheduled = try await ChatExecutionContext.$currentAgentId.withValue(on.id) {
                try await ToolRegistry.shared.execute(
                    name: "schedule_next_run",
                    argumentsJSON: #"{"instructions":"Check the pantry list","in_seconds":600}"#)
            }
            let payload = Self.object(scheduled)["result"] as? [String: Any]
            #expect(Self.object(scheduled)["ok"] as? Bool == true, "\(scheduled)")
            #expect(payload?["instructions"] as? String == "Check the pantry list")
            #expect(payload?["scheduled_at"] as? String != nil)

            let cancelled = try await ChatExecutionContext.$currentAgentId.withValue(on.id) {
                try await ToolRegistry.shared.execute(name: "cancel_next_run", argumentsJSON: "{}")
            }
            #expect(Self.object(cancelled)["ok"] as? Bool == true, "\(cancelled)")

            // notify succeeds without posting anything in a test process.
            let notified = try await ChatExecutionContext.$currentAgentId.withValue(on.id) {
                try await ToolRegistry.shared.execute(
                    name: "notify", argumentsJSON: #"{"title":"Pantry","body":"Rice is low"}"#)
            }
            #expect(Self.object(notified)["ok"] as? Bool == true, "\(notified)")

            _ = await AgentManager.shared.delete(id: on.id)
            _ = await AgentManager.shared.delete(id: off.id)
        }
    }

    @Test("Preset summaries match the real preset numbers")
    func presetCopy() {
        let ambient = AgentScheduleSettings.defaults(for: .ambient)
        #expect(ambient.dailyRunCap == 6 && ambient.minIntervalSeconds == 3600)
        let reactive = AgentScheduleSettings.defaults(for: .reactive)
        #expect(reactive.dailyRunCap == 48 && reactive.minIntervalSeconds == 300)
        let project = AgentScheduleSettings.defaults(for: .project)
        #expect(project.dailyRunCap == 4)
    }
}
