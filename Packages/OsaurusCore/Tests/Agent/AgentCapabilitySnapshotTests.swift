//
//  AgentCapabilitySnapshotTests.swift
//  osaurusTests
//
//  Regression coverage for `AgentManager.diffKnownCapabilities`, the pure
//  transform that decides which newly-registered tools/skills get auto-grown
//  into a seeded agent's allowlist on `.toolsListChanged`.
//
//  The bug this guards: at startup plugins register incrementally, so the
//  notification fires repeatedly with a *partial* live set. An earlier
//  implementation replaced the known-names snapshot with each partial set,
//  which made the not-yet-loaded tools look "newly discovered" on the next
//  event and re-grew them into agents the user had explicitly disabled them
//  on — capability toggles silently reverted across restart.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
@MainActor
struct AgentCapabilitySnapshotTests {

    @Test("first observation seeds the snapshot without growing")
    func firstObservationSeedsWithoutGrowing() {
        let result = AgentManager.diffKnownCapabilities(
            known: nil,
            live: ["a", "b", "c"]
        )
        #expect(result.toGrow.isEmpty)
        #expect(result.merged == ["a", "b", "c"])
    }

    @Test("a genuinely new capability is grown and added to the snapshot")
    func genuinelyNewCapabilityGrows() {
        let result = AgentManager.diffKnownCapabilities(
            known: ["a", "b"],
            live: ["a", "b", "c"]
        )
        #expect(result.toGrow == ["c"])
        #expect(result.merged == ["a", "b", "c"])
    }

    @Test("a partial live set never shrinks the snapshot")
    func partialLiveSetKeepsSnapshot() {
        // Restart: full set was known, but only one plugin has loaded so far.
        let result = AgentManager.diffKnownCapabilities(
            known: ["a", "b", "c"],
            live: ["a"]
        )
        #expect(result.toGrow.isEmpty)
        // b and c must survive even though they are absent from `live`.
        #expect(result.merged == ["a", "b", "c"])
    }

    @Test("incremental startup never resurrects a disabled capability")
    func incrementalStartupDoesNotResurrectDisabled() {
        // Full catalog seen in a prior session.
        let fullCatalog: Set<String> = ["browser_a", "browser_b", "calendar_a", "time_a"]
        var snapshot: Set<String>? = AgentManager.diffKnownCapabilities(
            known: nil,
            live: fullCatalog
        ).merged

        // User disabled the browser group; that only changes the agent
        // allowlist, not the known-names snapshot, so the snapshot still
        // holds every name.

        // Restart: plugins register one at a time. Each event carries only the
        // tools that have loaded so far. None of these should ever be flagged
        // for growth, because every name is already known.
        let startupSequence: [Set<String>] = [
            ["time_a"],
            ["time_a", "calendar_a"],
            ["time_a", "calendar_a", "browser_a"],
            fullCatalog,
        ]
        for live in startupSequence {
            let result = AgentManager.diffKnownCapabilities(known: snapshot, live: live)
            #expect(result.toGrow.isEmpty, "partial live \(live.sorted()) wrongly grew \(result.toGrow.sorted())")
            snapshot = result.merged
        }

        // Snapshot still contains the whole catalog after the noisy startup.
        #expect(snapshot == fullCatalog)
    }

    @Test("a new plugin installed mid-session still grows")
    func newPluginMidSessionGrows() {
        let snapshot: Set<String> = ["browser_a", "calendar_a"]
        let result = AgentManager.diffKnownCapabilities(
            known: snapshot,
            live: ["browser_a", "calendar_a", "newplugin_a", "newplugin_b"]
        )
        #expect(result.toGrow == ["newplugin_a", "newplugin_b"])
        #expect(result.merged == ["browser_a", "calendar_a", "newplugin_a", "newplugin_b"])
    }

    // MARK: - Growth rule (upstream #2647; W-tool-list-growth)

    @Test("auto agent with a seeded list grows with new names, existing order kept")
    func autoAgentGrows() {
        let grown = AgentManager.grownManualToolNames(
            current: ["b", "a"], mode: .auto, live: ["c", "a", "d"])
        #expect(grown == ["b", "a", "c", "d"])
        #expect(
            AgentManager.grownManualToolNames(current: ["b"], mode: nil, live: ["x"]) == ["b", "x"])
    }

    @Test("manual agents and un-seeded agents never grow")
    func manualAndUnseededUntouched() {
        #expect(AgentManager.grownManualToolNames(current: ["a"], mode: .manual, live: ["z"]) == nil)
        #expect(AgentManager.grownManualToolNames(current: nil, mode: .auto, live: ["z"]) == nil)
        #expect(AgentManager.grownManualToolNames(current: ["a", "z"], mode: .auto, live: ["z"]) == nil)
    }

    @Test("growEnabledToolNames grows auto agents only and persists")
    func growEnabledToolNamesEndToEnd() async throws {
        try await ChatHistoryTestStorage.run {
            let auto = Agent(
                name: "GrowAuto-\(UUID().uuidString.prefix(6))", systemPrompt: "x",
                agentAddress: "test-grow-\(UUID().uuidString)",
                toolSelectionMode: .auto, manualToolNames: ["keep_a"])
            let manual = Agent(
                name: "GrowManual-\(UUID().uuidString.prefix(6))", systemPrompt: "x",
                agentAddress: "test-grow-\(UUID().uuidString)",
                toolSelectionMode: .manual, manualToolNames: ["keep_a"])
            AgentManager.shared.add(auto)
            AgentManager.shared.add(manual)

            AgentManager.shared.growEnabledToolNames(["keep_a", "new_tool"])

            #expect(AgentManager.shared.effectiveEnabledToolNames(for: auto.id) == ["keep_a", "new_tool"])
            #expect(AgentManager.shared.effectiveEnabledToolNames(for: manual.id) == ["keep_a"])

            // A reload from disk still has the grown list.
            AgentManager.shared.refresh()
            #expect(AgentManager.shared.effectiveEnabledToolNames(for: auto.id) == ["keep_a", "new_tool"])

            // A tool the user turned off is already known, so it never returns.
            AgentManager.shared.updateEnabledToolNames(["keep_a"], for: auto.id)
            let diff = AgentManager.diffKnownCapabilities(
                known: ["keep_a", "new_tool"], live: ["keep_a", "new_tool"])
            #expect(diff.toGrow.isEmpty)

            _ = await AgentManager.shared.delete(id: auto.id)
            _ = await AgentManager.shared.delete(id: manual.id)
        }
    }

    @Test("first session only collects names; growth starts the next launch")
    func firstSessionNeverGrows() async throws {
        try await ChatHistoryTestStorage.run {
            let suite = "osaurus-grow-test-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let key = AgentManager.knownToolNamesKey
            let agent = Agent(
                name: "GrowSession-\(UUID().uuidString.prefix(6))", systemPrompt: "x",
                agentAddress: "test-grow-\(UUID().uuidString)",
                toolSelectionMode: .auto, manualToolNames: ["keep_a"])
            AgentManager.shared.add(agent)
            let m = AgentManager.shared

            // Session 1: no stored snapshot, two waves of registration.
            #expect(defaults.array(forKey: key) == nil)
            for wave: Set<String> in [["wave1_a"], ["wave1_a", "wave2_b"]] {
                m.growNewlyDiscoveredCapabilities(
                    live: wave, key: key, defaults: defaults, snapshotCreatedThisSession: true,
                    grow: m.growEnabledToolNames)
            }
            #expect(m.effectiveEnabledToolNames(for: agent.id) == ["keep_a"])
            #expect(Set(defaults.array(forKey: key) as? [String] ?? []) == ["wave1_a", "wave2_b"])

            // Session 2: snapshot stored, a new name grows; known names do not.
            m.growNewlyDiscoveredCapabilities(
                live: ["wave1_a", "wave2_b", "new_c"], key: key, defaults: defaults,
                snapshotCreatedThisSession: false, grow: m.growEnabledToolNames)
            #expect(m.effectiveEnabledToolNames(for: agent.id) == ["keep_a", "new_c"])

            _ = await m.delete(id: agent.id)
        }
    }
}
