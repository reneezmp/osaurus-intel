//
//  SetupCheckerTests.swift
//  OsaurusCoreTests
//
//  Upstream #3172's first-run gate, adapted for Intel (no bookmarks, no skill
//  allow-list): the check must catch exactly the things a creator cannot
//  grant on someone else's Mac, and nothing else. A clean agent must never be
//  prompted, and an unreadable working folder must always block.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct SetupCheckerTests {

    private func env(
        tools: Set<String> = ["fetch", "time"],
        providers: [ConfigModelReference.ProviderModels] = [],
        granted: Set<SystemPermission> = [.accessibility, .automation],
        folderOK: Bool = true
    ) -> SetupChecker.Environment {
        SetupChecker.Environment(
            registeredToolNames: tools,
            modelCatalog: ConfigModelReference.Catalog(localModelIds: [], providers: providers),
            isPermissionGranted: { granted.contains($0) },
            folderReadable: { _ in folderOK })
    }

    private func agent() -> Agent {
        AgentManager.newCustomAgentRecord(name: "Probe")
    }

    @Test
    func cleanAgent_hasNoItems() {
        var a = agent()
        a.toolSelectionMode = .manual
        a.manualToolNames = ["fetch"]
        #expect(SetupChecker.check(a, environment: env()).isClean)
    }

    @Test
    func unreadableFolder_blocks_readableFolderDoesNot() {
        var a = agent()
        a.workingFolderPath = "/Users/someone/Downloads/Medical Stuff"
        let blocked = SetupChecker.check(a, environment: env(folderOK: false))
        #expect(blocked.hasBlockers)
        #expect(blocked.blocking.first?.kind == .workingFolder)
        #expect(SetupChecker.check(a, environment: env(folderOK: true)).isClean)
    }

    @Test
    func missingModel_blocks() {
        var a = agent()
        a.defaultModel = "qwen3-coder-next-mlx"
        let report = SetupChecker.check(a, environment: env())
        #expect(report.blocking.map(\.kind) == [.model])
    }

    @Test
    func computerUseWithoutAccessibility_blocks_automationIsAdvisory() {
        var a = agent()
        a.settings.computerUseEnabled = true
        a.settings.appleScriptEnabled = true
        let report = SetupChecker.check(a, environment: env(granted: []))
        #expect(report.blocking.map(\.value) == [SystemPermission.accessibility.rawValue])
        #expect(report.items.contains { $0.value == SystemPermission.automation.rawValue && !$0.isBlocking })
    }

    @Test
    func unknownManualTools_areAdvisory_autoModeIgnored() {
        var a = agent()
        a.toolSelectionMode = .manual
        a.manualToolNames = ["fetch", "linear_search", "notes_create"]
        let report = SetupChecker.check(a, environment: env())
        #expect(!report.hasBlockers)
        #expect(report.items.first?.value == "linear_search, notes_create")
        a.toolSelectionMode = .auto
        #expect(SetupChecker.check(a, environment: env()).isClean)
    }
}

@MainActor
struct SetupStateStoreTests {

    @Test
    func markClearPrune_persistAcrossReads() throws {
        let previous = OsaurusPaths.overrideRoot
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-setup-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        OsaurusPaths.overrideRoot = root
        defer {
            OsaurusPaths.overrideRoot = previous
            try? FileManager.default.removeItem(at: root)
        }
        let store = SetupStateStore.shared
        store.resetForTesting()
        let a = UUID(), b = UUID()
        store.markNeedsSetup(a)
        store.markNeedsSetup(b)
        store.markNeedsSetup(a)  // idempotent
        #expect(store.pending == [a, b])
        let onDisk =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: SetupStateStore.fileURL)) as? [String: Any]
        #expect((onDisk?["pending"] as? [String])?.count == 2)
        store.clear(a)
        #expect(store.pending == [b])
        store.prune(existing: [])
        #expect(store.pending.isEmpty)
    }
}

/// `spawn_agent`'s first-run refusal (upstream #3172's `setupRefusal`), through
/// its pure half so no live service is read.
@MainActor
struct SpawnAgentSetupRefusalTests {

    private func withTempRoot(_ body: () throws -> Void) throws {
        let previous = OsaurusPaths.overrideRoot
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-setup-refusal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        OsaurusPaths.overrideRoot = root
        defer {
            OsaurusPaths.overrideRoot = previous
            try? FileManager.default.removeItem(at: root)
        }
        SetupStateStore.shared.resetForTesting()
        try body()
    }

    private func item(_ severity: SetupItem.Severity) -> SetupItem {
        SetupItem(
            kind: .workingFolder, severity: severity, title: "Working Folder",
            detail: "No access to /nope.", value: "/nope")
    }

    @Test
    func blocker_refusesWithNeedsUserAction_andKeepsTheFlag() throws {
        try withTempRoot {
            let agent = AgentManager.newCustomAgentRecord(name: "Medic")
            SetupStateStore.shared.markNeedsSetup(agent.id)
            let report = SetupReport(subjectId: agent.id, items: [item(.blocking)])
            let result = SpawnAgentTool.setupRefusal(agent: agent, report: report, tool: "spawn_agent")
            let envelope = try #require(result)
            #expect(ToolEnvelope.isError(envelope))
            #expect(ToolEnvelope.failureMessage(envelope).contains("cannot run yet"))
            #expect(envelope.contains("needs_user_action"))
            #expect(SetupStateStore.shared.needsSetup(agent.id))
        }
    }

    @Test
    func cleanReport_clearsTheFlag_andAdvisoryOnlyLetsTheRunProceed() throws {
        try withTempRoot {
            let agent = AgentManager.newCustomAgentRecord(name: "Scribe")
            SetupStateStore.shared.markNeedsSetup(agent.id)
            let advisory = SetupReport(subjectId: agent.id, items: [item(.advisory)])
            #expect(SpawnAgentTool.setupRefusal(agent: agent, report: advisory, tool: "spawn_agent") == nil)
            #expect(SetupStateStore.shared.needsSetup(agent.id))
            let clean = SetupReport(subjectId: agent.id, items: [])
            #expect(SpawnAgentTool.setupRefusal(agent: agent, report: clean, tool: "spawn_agent") == nil)
            #expect(!SetupStateStore.shared.needsSetup(agent.id))
        }
    }

    @Test
    func unflaggedAgent_isNeverChecked() throws {
        try withTempRoot {
            let agent = AgentManager.newCustomAgentRecord(name: "Seasoned")
            #expect(!SetupStateStore.shared.needsSetup(agent.id))
            #expect(SpawnAgentTool.setupRefusal(agentID: agent.id, tool: "spawn_agent") == nil)
        }
    }
}

/// Source pins in the repo's wiring-guard style: a gate nobody calls is how
/// the first-run check silently regresses.
struct AgentSetupWiringGuardTests {
    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Agent/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // OsaurusCore/
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test
    func creationHook_marksNeedsSetup() throws {
        let manager = try source("Models/Chat/IntelConformers/IntelManagerConformers.swift")
        #expect(manager.contains("SetupStateStore.shared.markNeedsSetup(agentID)"))
        #expect(manager.contains("await SetupStateStore.shared.clear(id)"))
    }

    @Test
    func spawnAgent_runsTheSetupGate_onlyInsideTheLauncherPool() throws {
        let tool = try source("Tools/SpawnAgentTool.swift")
        #expect(tool.contains("Self.setupRefusal(agentID: agentID, tool: name)"))
        #expect(tool.contains("IntelSpawnAdmission.liveFacts(launcherID: launcher).pool.contains(agentID)"))
    }

    @Test
    func chatAdoption_promptsForSetup() throws {
        // Intel's `ChatWindowState` is the second class in the file, after
        // the `#else`; the call must sit in that one.
        let state = try source("Managers/Chat/ChatWindowState.swift")
        let intelHalf = try #require(state.range(of: "#else")).upperBound
        #expect(
            state[intelHalf...].contains("AgentSetupPromptCoordinator.shared.agentShown(newAgentId, windowId: windowId)"))
    }

    @Test
    func agentsView_presentsTheWizard_andTheGalleryHandsOffToIt() throws {
        let agents = try source("Views/Agent/AgentsView.swift")
        #expect(agents.contains("AgentSetupWizardView("))
        #expect(agents.contains("setupSubject = .draft(draft, template: template)"))
        #expect(agents.contains("onRunSetup: { setupSubject = .saved(agent.id) }"))
        let gallery = try source("Views/Agent/Templates/AgentTemplatesGalleryView.swift")
        // The gallery must not create agents itself any more: Use Template
        // goes through the wizard's plan and Create Agent click.
        #expect(gallery.contains("onUse: { onUse(template) }"))
        #expect(!gallery.contains("ConfigApplier.apply"))
    }

    @Test
    func wizardCreate_requiresReviewedRisks_beforeAddingTheAgent() throws {
        let wizard = try source("Views/Agent/Setup/AgentSetupWizardView.swift")
        let gate = try #require(wizard.range(of: "if planHasHighRisk, !reviewedRisks"))
        let add = try #require(wizard.range(of: "AgentManager.shared.add(final)"))
        #expect(gate.lowerBound < add.lowerBound)
    }
}

struct AgentSetupTemplateGroupTests {

    @Test
    func addingTemplateGroupTools_addsAvailableGroupOnly() {
        var agent = Agent(name: "Plato")
        agent.toolSelectionMode = .manual
        agent.manualToolNames = ["web_search"]
        let updated = SetupChecker.addingTemplateGroupTools(
            to: agent,
            groups: [.mcpServer("Underwriting"), .plugin("osaurus.vision")],
            available: [.mcpServer("Underwriting"): ["uw_case_get", "uw_apps_list"]])
        #expect(updated.manualToolNames == ["web_search", "uw_case_get", "uw_apps_list"])
    }

    @Test
    func addingTemplateGroupTools_keepsDeliberateTrim() {
        var agent = Agent(name: "Plato")
        agent.toolSelectionMode = .manual
        agent.manualToolNames = ["uw_case_get"]
        let updated = SetupChecker.addingTemplateGroupTools(
            to: agent, groups: [.mcpServer("Underwriting")],
            available: [.mcpServer("Underwriting"): ["uw_case_get", "uw_apps_list"]])
        #expect(updated.manualToolNames == ["uw_case_get"])
    }
}

/// Intel adaptation: steps upstream offers that Intel cannot (knowledge
/// grants) are shown dimmed with a reason, never dropped.
struct AgentSetupWizardIntelStepTests {

    private func report(_ items: [SetupItem] = []) -> SetupReport {
        SetupReport(subjectId: UUID(), items: items)
    }

    @Test
    func knowledgeStep_isAddedDimmed_whenTheTemplateAsksForKnowledge() {
        let steps = AgentSetupWizardView.Step.steps(for: report(), needsKnowledge: true)
        #expect(steps == [.knowledge, .review])
        #expect(AgentSetupWizardView.Step.knowledge.isUnavailableOnIntel)
        #expect(!AgentSetupWizardView.Step.knowledge.unavailableReason.isEmpty)
    }

    @Test
    func knowledgeStep_isAbsent_whenNothingAsksForKnowledge() {
        #expect(AgentSetupWizardView.Step.steps(for: report()) == [.review])
    }

    @Test
    func otherSteps_areNotDimmed() {
        for step in [AgentSetupWizardView.Step.model, .folder, .tools, .permissions, .review] {
            #expect(!step.isUnavailableOnIntel)
        }
    }

    @Test
    func stepsFollowTheReport_andKeepTheDimmedKnowledgeStepInOrder() {
        let model = SetupItem(
            kind: .model, severity: .blocking, title: "Model", detail: "x", value: "m")
        let tool = SetupItem(
            kind: .mcpServer, severity: .advisory, title: "Tools", detail: "x", value: "t")
        let steps = AgentSetupWizardView.Step.steps(for: report([model, tool]), needsKnowledge: true)
        #expect(steps == [.model, .knowledge, .tools, .review])
    }
}
