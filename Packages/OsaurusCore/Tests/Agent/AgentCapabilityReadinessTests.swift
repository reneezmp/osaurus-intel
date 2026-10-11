import Testing

@testable import OsaurusCore

@Suite("Agent capability readiness")
struct AgentCapabilityReadinessTests {
    @Test("configured and callable is active")
    func active() {
        let readiness = AgentCapabilityReadiness.resolve(
            configured: true,
            toolsEnabled: true
        )

        #expect(readiness.state == .active)
        #expect(readiness.isCallable)
        #expect(readiness.blockers.isEmpty)
    }

    @Test("tools off pauses configuration without erasing it")
    func toolsOff() {
        let readiness = AgentCapabilityReadiness.resolve(
            configured: true,
            toolsEnabled: false,
            blockers: [.noModelSelected]
        )

        #expect(readiness.configured)
        #expect(readiness.state == .paused)
        #expect(readiness.primaryBlocker == .toolsDisabled)
        #expect(readiness.blockers.contains(.noModelSelected))
    }

    // Intel: upstream's subagent-factory cases (spawn targets, dedicated
    // models, computer use, deny policy, checking targets) come back with
    // `W-subagents`, which brings `AgentCapabilityReadiness.subagent`.

    @Test("knowledge and context blockers map to distinct readiness states")
    func genericBlockerStates() {
        let knowledge = AgentCapabilityReadiness.resolve(
            configured: true,
            toolsEnabled: true,
            blockers: [.noKnowledgeCollections]
        )
        let context = AgentCapabilityReadiness.resolve(
            configured: true,
            toolsEnabled: true,
            blockers: [.contextLimit]
        )

        #expect(knowledge.state == .needsSetup)
        #expect(context.state == .paused)
    }
}
