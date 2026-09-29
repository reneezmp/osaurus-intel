//
//  IntelAppleAppsTests.swift
//  OsaurusCoreTests
//
//  Release 1 of docs/APPLE_APPS_INTEL_PLAN.md: which apps ship, the per-agent
//  switch (storage, dispatch, prompt), approval defaults including per-call
//  deletes, the staged plugin migration, and the prompt guidance. Nothing
//  here reaches real Calendar/Contacts data: tools that would are only ever
//  called while their app is off, so dispatch refuses them first.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel Apple apps (Release 1)", .serialized)
struct IntelAppleAppsTests {
    private static func makeAgent(apps: Set<AppleApp> = [], manualTools: [String]? = nil) -> Agent {
        var agent = Agent(
            name: "apple-\(UUID().uuidString.prefix(6))",
            systemPrompt: "Test identity",
            agentAddress: "test-apple-\(UUID().uuidString)"
        )
        agent.settings.enabledAppleApps = apps
        agent.manualToolNames = manualTools
        return agent
    }

    private static func kind(_ envelope: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]
        else { return nil }
        return object["kind"] as? String
    }

    // MARK: - What ships

    @Test("Calendar, Reminders, Contacts, Notes and Shortcuts are registered; the rest wait")
    func registration() {
        #expect(AppleApp.availableOnIntel == [.calendar, .reminders, .contacts, .notes, .shortcuts])
        let names = Set(ToolRegistry.shared.listTools().map(\.name))
        #expect(ToolRegistry.appleAppToolNames.isSubset(of: names))
        for app in [AppleApp.mail, .messages, .maps, .music] {
            #expect(names.isDisjoint(with: app.toolNames), "\(app)")
        }
        let (undeclared, missing) = AppleAppToolCatalog.undeclaredOrMissingNames(in: AppleAppToolCatalog.makeTools())
        #expect(undeclared.isEmpty)
        #expect(missing.isEmpty)
    }

    @Test("Reads run automatically, changes ask, and deletes ask every single time")
    func approvals() async throws {
        try await ChatHistoryTestStorage.run {
            for tool in AppleAppToolCatalog.makeTools() {
                let base = try #require(tool as? AppleToolBase)
                let info = ToolRegistry.shared.policyInfo(for: tool.name)
                #expect(info?.defaultPolicy == (base.isWrite ? .ask : .auto), "\(tool.name)")
            }
            for name in ["calendar_delete_event", "reminders_delete"] {
                #expect(ToolRegistry.shared.requiresApprovalEveryCall(name))
                // Always Allow (or a hand-edited Auto) cannot pre-grant a delete.
                ToolRegistry.shared.setPolicy(.auto, for: name)
                #expect(ToolRegistry.shared.policyInfo(for: name)?.effectivePolicy == .ask)
                ToolRegistry.shared.setPolicy(.deny, for: name)
                #expect(ToolRegistry.shared.policyInfo(for: name)?.effectivePolicy == .deny)
                ToolRegistry.shared.clearPolicy(for: name)
            }
            #expect(!ToolRegistry.shared.requiresApprovalEveryCall("calendar_create_event"))
        }
    }

    @Test("Only Intel-shipped Apple plugins are superseded")
    func supersededPlugins() {
        let ids = PluginManager.supersededPluginIds
        #expect(ids.contains("search-intel"))
        for id in ["osaurus.calendar", "osaurus.reminders", "osaurus.contacts", "osaurus.notes"] {
            #expect(ids.contains(id), "\(id)")
        }
        for id in ["osaurus.mail", "osaurus.messages", "osaurus.maps", "osaurus.music"] {
            #expect(!ids.contains(id), "\(id)")
        }
    }

    @Test("An installed plugin needs a version folder or a current link")
    func installedPluginDetection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-apple-tools-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("osaurus.calendar/1.2.0"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("osaurus.notes"), withIntermediateDirectories: true)  // empty leftover
        try fm.createDirectory(at: root.appendingPathComponent("osaurus.mail/1.0.0"), withIntermediateDirectories: true)  // not Intel yet
        #expect(PluginManager.installedSupersededAppleAppPluginIds(toolsRoot: root) == ["osaurus.calendar"])
    }

    // MARK: - The per-agent switch

    @Test("Enabled apps round-trip; unknown names drop; older agents decode with none")
    func settingsCodable() throws {
        var settings = AgentSettings.defaultDisabled
        settings.enabledAppleApps = [.notes, .calendar]
        let data = try JSONEncoder().encode(settings)
        #expect(String(decoding: data, as: UTF8.self).contains(#""enabledAppleApps":["calendar","notes"]"#))
        #expect(try JSONDecoder().decode(AgentSettings.self, from: data).enabledAppleApps == [.calendar, .notes])

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["enabledAppleApps"] = ["calendar", "hologram"]
        let future = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(AgentSettings.self, from: future).enabledAppleApps == [.calendar])

        object.removeValue(forKey: "enabledAppleApps")
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(AgentSettings.self, from: old).enabledAppleApps.isEmpty)
    }

    @MainActor
    @Test("Effective apps skip unshipped apps; the built-in agent never gets any")
    func effectiveApps() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.makeAgent(apps: [.calendar, .mail], manualTools: ["file_read", "notes_create"])
            AgentManager.shared.add(agent)
            #expect(AgentManager.shared.effectiveAppleApps(for: agent.id) == [.calendar])

            AgentManager.shared.updateEnabledAppleApps([.notes], for: agent.id)
            let saved = try #require(AgentManager.shared.agent(for: agent.id))
            #expect(saved.settings.enabledAppleApps == [.notes])
            #expect(saved.manualToolNames == ["file_read"])  // stray Apple names are dropped
            #expect(try AgentManager.loadPersisted(id: agent.id).settings.enabledAppleApps == [.notes])

            AgentManager.shared.updateEnabledAppleApps([.calendar], for: Agent.defaultId)
            #expect(AgentManager.shared.effectiveAppleApps(for: Agent.defaultId).isEmpty)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test("Dispatch refuses an app that is off, for any agent and with no agent")
    func dispatchGate() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.makeAgent(apps: [.notes])
            await MainActor.run { AgentManager.shared.add(agent) }

            let off = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
                try await ToolRegistry.shared.execute(name: "calendar_list", argumentsJSON: "{}")
            }
            #expect(Self.kind(off) == "unavailable")
            #expect(off.contains("Calendar is not turned on"))

            let builtIn = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
                try await ToolRegistry.shared.execute(name: "reminders_lists", argumentsJSON: "{}")
            }
            #expect(Self.kind(builtIn) == "unavailable")

            let noAgent = try await ToolRegistry.shared.execute(name: "shortcuts_list", argumentsJSON: "{}")
            #expect(Self.kind(noAgent) == "unavailable")
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @MainActor
    @Test("The prompt offers only the enabled apps' tools, with guidance and a clock")
    func promptComposition() async throws {
        try await ChatHistoryTestStorage.run {
            // A seeded allowlist without Apple names: the switch alone grants them.
            let on = Self.makeAgent(apps: [.calendar, .shortcuts], manualTools: ["file_read"])
            let off = Self.makeAgent(apps: [], manualTools: ["file_read"])
            AgentManager.shared.add(on)
            AgentManager.shared.add(off)

            let onContext = await SystemPromptComposer.composeChatContext(agentId: on.id, query: "hi")
            let onTools = Set(onContext.tools.map(\.function.name))
            #expect(AppleApp.calendar.toolNames.isSubset(of: onTools))
            #expect(AppleApp.shortcuts.toolNames.isSubset(of: onTools))
            #expect(onTools.isDisjoint(with: AppleApp.reminders.toolNames))
            #expect(onContext.prompt.contains("## Apple apps"))
            #expect(onContext.prompt.contains("Calendar, Shortcuts"))
            #expect(!onContext.prompt.contains("Reminders,"))
            #expect(onContext.memorySection?.contains("## Current local time") == true)
            #expect(onContext.promptSections.contains { $0.id == "appleApps" })

            let offContext = await SystemPromptComposer.composeChatContext(agentId: off.id, query: "hi")
            #expect(Set(offContext.tools.map(\.function.name)).isDisjoint(with: AppleApp.allToolNames))
            #expect(!offContext.prompt.contains("## Apple apps"))

            let builtIn = await SystemPromptComposer.composeChatContext(agentId: Agent.defaultId, query: "hi")
            #expect(Set(builtIn.tools.map(\.function.name)).isDisjoint(with: AppleApp.allToolNames))

            _ = await AgentManager.shared.delete(id: on.id)
            _ = await AgentManager.shared.delete(id: off.id)
        }
    }

    @Test("Guidance names only active apps; the clock carries offset, weekday and zone")
    func guidance() throws {
        #expect(IntelAppleAppsGuidance.guidance(apps: []).isEmpty)
        let text = IntelAppleAppsGuidance.guidance(apps: [.notes])
        #expect(text.contains("`notes_*`"))
        #expect(!text.contains("Calendar/Reminders"))
        #expect(!text.contains("get_current_time"))
        #expect(IntelAppleAppsGuidance.activeApps(in: ["notes_read", "file_read"]) == [.notes])

        let zone = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        let clock = IntelAppleAppsGuidance.clock(now: Date(timeIntervalSince1970: 1_790_000_000), timeZone: zone)
        #expect(clock.contains("-03:00"))
        #expect(clock.contains("America/Sao_Paulo"))
        #expect(clock.contains("day,"))  // a weekday name
    }

    // MARK: - Plugin migration (staged, per app)

    @MainActor
    @Test("Only installed, Intel-shipped plugins migrate; the built-in agent is never touched")
    func pureMigration() {
        let agent = Self.makeAgent(manualTools: ["create_note", "play", "file_read", "calendar_list", "create_note"])
        let outcome = AppleAppsPluginMigration.migrate(
            agent: agent, installedPluginIds: ["osaurus.notes", "osaurus.music"])
        #expect(outcome.changed)
        #expect(outcome.enabledApps == [.notes])  // Music is not on Intel yet
        #expect(outcome.agent.manualToolNames == ["play", "file_read"])  // `play` keeps working via its plugin
        #expect(outcome.agent.settings.enabledAppleApps == [.notes])

        let notInstalled = AppleAppsPluginMigration.migrate(agent: agent, installedPluginIds: ["osaurus.calendar"])
        #expect(!notInstalled.changed)

        var builtIn = Agent.default
        builtIn.manualToolNames = ["create_note"]
        #expect(!AppleAppsPluginMigration.migrate(agent: builtIn, installedPluginIds: ["osaurus.notes"]).changed)
    }

    @MainActor
    @Test("The sweep marks each shipped app once, retries after a failed save, and notices once per app")
    func sweepMarkers() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-apple-config-\(UUID().uuidString)", isDirectory: true)
        AppleAppsConfigurationStore.overrideDirectory = dir
        AppleAppsConfigurationStore.resetCacheForTests()
        defer {
            AppleAppsConfigurationStore.overrideDirectory = nil
            AppleAppsConfigurationStore.resetCacheForTests()
            try? FileManager.default.removeItem(at: dir)
        }
        struct Failed: Error {}
        let agent = Self.makeAgent(manualTools: ["list_calendars"])

        // A failed save leaves the markers unset so the next launch retries.
        let first = AppleAppsPluginMigration.migrateIfNeeded(
            agents: [agent], installedPluginIds: ["osaurus.calendar"], persist: { _ in throw Failed() })
        #expect(first.isEmpty)
        #expect(AppleAppsConfigurationStore.load().migratedApps.isEmpty)

        var saved: [Agent] = []
        let second = AppleAppsPluginMigration.migrateIfNeeded(
            agents: [agent], installedPluginIds: ["osaurus.calendar"], persist: { saved.append($0) })
        #expect(second == [agent.name])
        #expect(saved.first?.settings.enabledAppleApps == [.calendar])
        #expect(AppleAppsConfigurationStore.load().migratedApps == Set(AppleApp.availableOnIntel))

        // Already migrated: nothing runs again.
        #expect(AppleAppsPluginMigration.migrateIfNeeded(
            agents: [agent], installedPluginIds: ["osaurus.calendar"], persist: { _ in throw Failed() }).isEmpty)

        // Markers persist across a cache drop, in the documented shape.
        AppleAppsConfigurationStore.resetCacheForTests()
        #expect(AppleAppsConfigurationStore.load().migratedApps.contains(.calendar))

        var shown: [String] = []
        let message = AppleAppsPluginMigration.showSupersededNoticeIfNeeded(
            installedPluginIds: ["osaurus.calendar", "osaurus.mail"], migratedAgents: [agent.name],
            present: { _, text in shown.append(text) })
        #expect(message?.contains("Calendar") == true)
        #expect(message?.contains("Mail") == false)  // Mail's plugin still loads on Intel
        #expect(AppleAppsPluginMigration.showSupersededNoticeIfNeeded(
            installedPluginIds: ["osaurus.calendar"], present: { _, text in shown.append(text) }) == nil)
        #expect(shown.count == 1)
    }
}
