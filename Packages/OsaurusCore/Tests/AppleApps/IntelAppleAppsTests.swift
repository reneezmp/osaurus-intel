//
//  IntelAppleAppsTests.swift
//  OsaurusCoreTests
//
//  Releases 1–3 of docs/APPLE_APPS_INTEL_PLAN.md: which apps ship, the per-agent
//  switch (storage, dispatch, prompt), approval defaults including per-call
//  deletes, the staged plugin migration, and the prompt guidance. Nothing
//  here reaches real Calendar/Contacts data: tools that would are only ever
//  called while their app is off, so dispatch refuses them first.
//

import CoreLocation
import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel Apple apps", .serialized)
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

    @Test("All nine apps are registered")
    func registration() {
        #expect(AppleApp.availableOnIntel == AppleApp.allCases)
        let names = Set(ToolRegistry.shared.listTools().map(\.name))
        #expect(ToolRegistry.appleAppToolNames == AppleApp.allToolNames)
        #expect(AppleApp.allToolNames.isSubset(of: names))
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
            for name in ["calendar_delete_event", "reminders_delete", "messages_send"] {
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

    @Test("A Mail draft can be pre-approved; sending asks every time")
    func mailSendApproval() async throws {
        try await ChatHistoryTestStorage.run {
            let draft = #"{"to":["ada@example.com"],"subject":"Hi","body":"x"}"#
            let send = #"{"to":["ada@example.com"],"subject":"Hi","body":"x","send":true}"#
            for name in ["mail_compose", "mail_reply"] {
                #expect(!ToolRegistry.shared.requiresApprovalEveryCall(name))
                #expect(ToolRegistry.shared.effectivePolicy(for: name, argumentsJSON: draft) == .ask)
                ToolRegistry.shared.setPolicy(.auto, for: name)  // Always Allow on a draft
                #expect(ToolRegistry.shared.effectivePolicy(for: name, argumentsJSON: draft) == .auto)
                #expect(ToolRegistry.shared.requiresApprovalEveryCall(name, argumentsJSON: send))
                #expect(ToolRegistry.shared.effectivePolicy(for: name, argumentsJSON: send) == .ask)
                ToolRegistry.shared.setPolicy(.deny, for: name)
                #expect(ToolRegistry.shared.effectivePolicy(for: name, argumentsJSON: send) == .deny)
                ToolRegistry.shared.clearPolicy(for: name)
            }
        }
    }

    @Test("Music and Messages need Automation; Maps needs Location, and tests never show its dialog")
    @MainActor
    func appPermissions() async {
        #expect(AppleApp.messages.systemPermissions == [.disk, .automationMessages])
        #expect(SystemPermission.automationMessages.isAutomationBased)
        #expect(!SystemPermission.disk.isAutomationBased)
        #expect(AppleApp.music.systemPermissions == [.automationMusic])
        #expect(SystemPermission.automationMusic.isAutomationBased)
        #expect(SystemPermission.automationMusic.systemSettingsURL != nil)
        #expect(AppleApp.maps.systemPermissions == [.location])
        #expect(await SystemPermissionService.shared.requestPermissionAndWait(.location) == false)
    }

    @Test("Before macOS 15, far-away Maps results are dropped instead of trusted")
    func mapsRegionFallback() {
        func place(_ lat: Double, _ lng: Double) -> PlaceInfo {
            PlaceInfo(
                name: "p", coordinate: GeoCoordinate(latitude: lat, longitude: lng), address: nil,
                street: nil, city: nil, state: nil, postalCode: nil, country: nil, countryCode: nil,
                phone: nil, url: nil, category: nil, timeZone: nil, mapsURL: "maps://")
        }
        let center = CLLocation(latitude: -23.55, longitude: -46.63)  // São Paulo
        let kept = MapKitMapsService.regionFallbackFilter(
            [place(-23.56, -46.64), place(-22.90, -43.20)], center: center, radiusMeters: 2_000)
        #expect(kept.count == 1)  // Rio (about 360 km away) is dropped
    }

    @Test("Only Intel-shipped Apple plugins are superseded")
    func supersededPlugins() {
        let ids = PluginManager.supersededPluginIds
        #expect(ids.contains("search-intel"))
        for id in [
            "osaurus.calendar", "osaurus.reminders", "osaurus.contacts", "osaurus.notes",
            "osaurus.mail", "osaurus.messages", "osaurus.maps", "osaurus.music",
        ] {
            #expect(ids.contains(id), "\(id)")
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
        try fm.createDirectory(at: root.appendingPathComponent("osaurus.messages/current"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("unrelated.plugin/1.0.0"), withIntermediateDirectories: true)
        #expect(PluginManager.installedSupersededAppleAppPluginIds(toolsRoot: root) == ["osaurus.calendar", "osaurus.messages"])
        #expect(PluginManager.installedAppleAppPluginIds(toolsRoot: root) == ["osaurus.calendar", "osaurus.messages"])
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
    @Test("Effective apps follow the switches; the built-in agent never gets any")
    func effectiveApps() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.makeAgent(apps: [.calendar, .messages], manualTools: ["file_read", "notes_create"])
            AgentManager.shared.add(agent)
            #expect(AgentManager.shared.effectiveAppleApps(for: agent.id) == [.calendar, .messages])

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
    @Test("Only installed plugins migrate; the built-in agent is never touched")
    func pureMigration() {
        let agent = Self.makeAgent(
            manualTools: ["create_note", "send_message", "file_read", "calendar_list", "create_note"])
        let outcome = AppleAppsPluginMigration.migrate(
            agent: agent, installedPluginIds: ["osaurus.notes", "osaurus.messages"])
        #expect(outcome.changed)
        #expect(outcome.enabledApps == [.notes, .messages])
        #expect(outcome.agent.manualToolNames == ["file_read"])
        #expect(outcome.agent.settings.enabledAppleApps == [.notes, .messages])

        // `search_messages` ships in both the Mail and Messages plugins:
        // Messages wins when both are installed, Mail only when alone.
        let both = Self.makeAgent(manualTools: ["search_messages", "list_mailboxes"])
        let withMessages = AppleAppsPluginMigration.migrate(
            agent: both, installedPluginIds: ["osaurus.mail", "osaurus.messages"])
        #expect(withMessages.renamedTools["search_messages"] == "messages_search")
        #expect(withMessages.enabledApps == [.mail, .messages])
        let mailAlone = AppleAppsPluginMigration.migrate(agent: both, installedPluginIds: ["osaurus.mail"])
        #expect(mailAlone.agent.manualToolNames == [])
        #expect(mailAlone.renamedTools["search_messages"] == "mail_search")

        // Upgrading from Release 2 (only Messages pending): Release 2 left
        // `search_messages` in place because the Messages plugin served it.
        let r2 = Self.makeAgent(manualTools: ["search_messages", "list_mailboxes"])
        let upgrade = AppleAppsPluginMigration.migrate(
            agent: r2, installedPluginIds: ["osaurus.mail", "osaurus.messages"], apps: [.messages])
        #expect(upgrade.enabledApps == [.messages])
        #expect(upgrade.agent.manualToolNames == ["list_mailboxes"])  // Mail's own sweep is done

        // Only the requested apps are mapped (an earlier release's are done).
        let music = Self.makeAgent(manualTools: ["play", "create_note"])
        let onlyMusic = AppleAppsPluginMigration.migrate(
            agent: music, installedPluginIds: ["osaurus.music", "osaurus.notes"], apps: [.music])
        #expect(onlyMusic.enabledApps == [.music])
        #expect(onlyMusic.agent.manualToolNames == ["create_note"])

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
            installedPluginIds: ["osaurus.calendar", "osaurus.messages"], migratedAgents: [agent.name],
            present: { _, text in shown.append(text) })
        #expect(message?.contains("Calendar") == true)
        #expect(message?.contains("Messages") == true)
        #expect(AppleAppsPluginMigration.showSupersededNoticeIfNeeded(
            installedPluginIds: ["osaurus.calendar"], present: { _, text in shown.append(text) }) == nil)
        #expect(shown.count == 1)
    }

    @MainActor
    @Test("Upgrading from Release 1 sweeps only the new apps' plugins")
    func releaseOneUpgrade() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-apple-config-\(UUID().uuidString)", isDirectory: true)
        AppleAppsConfigurationStore.overrideDirectory = dir
        AppleAppsConfigurationStore.resetCacheForTests()
        defer {
            AppleAppsConfigurationStore.overrideDirectory = nil
            AppleAppsConfigurationStore.resetCacheForTests()
            try? FileManager.default.removeItem(at: dir)
        }
        // What a Release 1 build left behind.
        AppleAppsConfigurationStore.save(
            AppleAppsConfiguration(
                migratedApps: [.calendar, .reminders, .contacts, .notes, .shortcuts],
                noticeShownApps: [.notes]))
        // The user removed the Notes switch after Release 1; `create_note`
        // is now some other tool's name and must not be touched again.
        let agent = Self.makeAgent(manualTools: ["create_note", "list_playlists", "get_thread"])
        var saved: [Agent] = []
        let migrated = AppleAppsPluginMigration.migrateIfNeeded(
            agents: [agent], installedPluginIds: ["osaurus.notes", "osaurus.music", "osaurus.mail"],
            persist: { saved.append($0) })
        #expect(migrated == [agent.name])
        #expect(saved.first?.settings.enabledAppleApps == [.mail, .music])
        #expect(saved.first?.manualToolNames == ["create_note"])
        #expect(AppleAppsConfigurationStore.load().migratedApps == Set(AppleApp.availableOnIntel))

        let notice = AppleAppsPluginMigration.showSupersededNoticeIfNeeded(
            installedPluginIds: ["osaurus.notes", "osaurus.music", "osaurus.mail"], present: { _, _ in })
        #expect(notice?.contains("Notes") == false)  // shown in Release 1 already
        #expect(notice?.contains("Mail") == true)
        #expect(notice?.contains("Music") == true)
    }
}
