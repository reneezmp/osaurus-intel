//
//  HarnessUITests.swift
//  osaurusTests
//
//  `W-harness-runtimes` stage 5: the picker columns (#3180), the Claude Code
//  effort row (#3293), Settings > Agent Runtimes' form and Test button, and the
//  owner rule that a harness runs only when the user chose it. Nothing here
//  starts `claude` or `pi`: the Test button runs a fake probe, and the
//  never-by-default checks read source files and in-memory values.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Picker columns (#3180)

@MainActor
@Suite("Harness picker columns")
struct ChatHarnessPickerOptionTests {
    private let claude = HarnessRuntime.builtInClaudeCode
    private let pi = HarnessRuntime(name: "Spotlight", kind: .piRPC)

    @Test func claudeCodeListsEachAliasAndPiListsOneRow() {
        let aliases = ClaudeCodeModel.allCases.map(\.rawValue)
        let claudeRows = ChatHarnessPickerOption.options(for: claude)
        #expect(claudeRows.map(\.claudeModel) == aliases)
        #expect(claudeRows.map(\.title) == aliases.map { $0.capitalized })
        #expect(Set(claudeRows.map(\.id)).count == aliases.count)

        let piRows = ChatHarnessPickerOption.options(for: pi)
        #expect(piRows.count == 1)
        #expect(piRows.first?.claudeModel == nil)
        #expect(piRows.first?.id == "harness:\(pi.id.uuidString)")
    }

    @Test func aFullClaudeModelIdGetsItsOwnRowSoItShowsSelected() {
        let aliases = ClaudeCodeModel.allCases.map(\.rawValue)
        let rows = ChatHarnessPickerOption.options(for: claude, currentClaudeModel: "claude-opus-4-1")
        #expect(rows.map(\.claudeModel) == aliases + ["claude-opus-4-1"])
        let alias = ChatHarnessPickerOption.options(for: claude, currentClaudeModel: "opus")
        #expect(alias.count == aliases.count)
    }

    @Test func selectedIdFollowsRuntimeAndClaudeModel() {
        var config = ClaudeCodeAgentConfig.default
        #expect(ChatHarnessPickerOption.selectedID(runtime: nil, claudeConfig: config) == nil)
        #expect(
            ChatHarnessPickerOption.selectedID(runtime: claude, claudeConfig: config)
                == ChatHarnessPickerOption.id(runtimeId: claude.id, claudeModel: config.resolvedModel))
        config.model = "haiku"
        #expect(
            ChatHarnessPickerOption.selectedID(runtime: claude, claudeConfig: config)
                == ChatHarnessPickerOption.id(runtimeId: claude.id, claudeModel: "haiku"))
        #expect(
            ChatHarnessPickerOption.selectedID(runtime: pi, claudeConfig: config)
                == ChatHarnessPickerOption.id(runtimeId: pi.id, claudeModel: nil))
    }

    @Test func harnessColumnsFollowModelProvidersAheadOfInactiveEntries() {
        let harnesses = ChatModelPickerProvider.harnessProviders(runtimes: [claude, pi])
        let groups = ChatModelPickerProvider.groups(from: [.foundation()], harnesses: harnesses)
        let harnessKinds = groups.map(\.kind).filter { if case .harness = $0 { return true } else { return false } }
        #expect(harnessKinds.count == 2)
        let claudeColumn = groups.first { $0.kind == .harness(.claudeCode) }
        let piColumn = groups.first { $0.kind == .harness(.piRPC) }
        #expect(claudeColumn?.title == "Claude Code")
        #expect(piColumn?.title == "Spotlight")
        let column = try! #require(claudeColumn)
        #expect(column.isActive && column.isHarness)
        #expect(column.models.isEmpty, "harness rows never become routable model ids")
        #expect(column.rowCount == ClaudeCodeModel.allCases.count)
        // Harness columns sit after every model column.
        let firstHarness = groups.firstIndex { $0.isHarness }!
        #expect(groups[..<firstHarness].allSatisfy { !$0.isHarness })
    }

    @Test func onlyTheCurrentRuntimeGetsTheExtraModelRow() {
        let harnesses = ChatModelPickerProvider.harnessProviders(
            runtimes: [claude, HarnessRuntime(name: "Work Claude", kind: .claudeCode)],
            current: (runtimeId: claude.id, claudeModel: "claude-sonnet-4-5"))
        #expect(harnesses[0].harnessOptions.count == ClaudeCodeModel.allCases.count + 1)
        #expect(harnesses[1].harnessOptions.count == ClaudeCodeModel.allCases.count)
    }

    @Test func initialSizeOpensOnTheSelectedHarnessColumn() {
        let harnesses = ChatModelPickerProvider.harnessProviders(runtimes: [claude])
        let groups = ChatModelPickerProvider.groups(from: [.foundation()], harnesses: harnesses)
        let selected = ChatHarnessPickerOption.id(runtimeId: claude.id, claudeModel: "opus")
        let onHarness = ChatModelPickerCard.initialSize(
            providers: groups, selectedModel: "foundation", optionsControl: nil, selectedHarnessID: selected)
        let onModel = ChatModelPickerCard.initialSize(
            providers: groups, selectedModel: "foundation", optionsControl: nil)
        #expect(onHarness.width > 0 && onHarness.height > 0)
        #expect(onModel.width > 0 && onModel.height > 0)
    }
}

// MARK: - Effort row (#3293)

@Suite("Claude Code effort picker row")
struct ClaudeCodeEffortPickerTests {
    private func snapshot(effort: String?) throws -> ChatPickerOptionsSnapshot {
        let id = ClaudeCodeEffort.pickerOptionID
        let control = ModelPickerOptionsControl(
            capabilities: nil,
            options: [ClaudeCodeEffort.pickerOption],
            values: effort.map { [id: .string($0)] } ?? [:],
            defaults: [id: .string(ModelOptionSegment.defaultID)],
            onChange: { _, _ in }
        )
        return try #require(ChatPickerOptionsSnapshot.make(modelID: "harness:claude", control: control))
    }

    @Test func offersDefaultAndEveryCLILevelWithDefaultSelectedWhenUnset() throws {
        let section = try #require(try snapshot(effort: nil).sections.first)
        #expect(section.rows.map(\.label) == [L("Default")] + ClaudeCodeEffort.allCases.map(\.displayName))
        #expect(section.rows.first?.selected == true, "no --effort shows as Default, never as Low")
        #expect(section.reset == nil)
    }

    @Test func marksTheExplicitLevelWithoutAResetLink() throws {
        let section = try #require(try snapshot(effort: "xhigh").sections.first)
        #expect(section.rows.filter(\.selected).map(\.label) == [ClaudeCodeEffort.xhigh.displayName])
        #expect(section.reset == nil)
    }

    @Test func segmentsMapToTheStoredFlagValue() {
        #expect(ClaudeCodeEffort.storedValue(forSegment: "max") == "max")
        #expect(ClaudeCodeEffort.storedValue(forSegment: ModelOptionSegment.defaultID) == nil)
        #expect(ClaudeCodeEffort.storedValue(forSegment: nil) == nil)
        #expect(ClaudeCodeEffort.storedValue(forSegment: "turbo") == nil)
    }
}

// MARK: - Settings > Agent Runtimes

@Suite("Agent Runtimes form")
struct HarnessRuntimeFormTests {
    @Test func argumentsAreOnePerLineWithBlanksDropped() {
        #expect(HarnessRuntimeForm.parseArguments("--mode\n  rpc \n\n") == ["--mode", "rpc"])
        #expect(HarnessRuntimeForm.parseArguments("").isEmpty)
    }

    @Test func aPiRuntimeWithoutRpcModeGetsAWarning() {
        #expect(HarnessRuntimeForm.argumentWarning(kind: .piRPC, arguments: ["--mode", "rpc"]) == nil)
        #expect(HarnessRuntimeForm.argumentWarning(kind: .piRPC, arguments: ["--mode=rpc"]) == nil)
        #expect(HarnessRuntimeForm.argumentWarning(kind: .piRPC, arguments: ["--tools", "read"]) != nil)
        #expect(HarnessRuntimeForm.argumentWarning(kind: .claudeCode, arguments: []) == nil)
    }

    @Test func environmentLinesParseAndBadOnesAreReported() {
        let ok = HarnessRuntimeForm.parseEnvironment("# note\nCLAUDE_CONFIG_DIR=/tmp/c\n  FOO = bar baz\n\nEMPTY=")
        #expect(ok.errors.isEmpty)
        #expect(ok.values == ["CLAUDE_CONFIG_DIR": "/tmp/c", "FOO": " bar baz", "EMPTY": ""])

        let bad = HarnessRuntimeForm.parseEnvironment("NOEQUALS\n1BAD=x\nOSAURUS_AGENT_TOKEN=nope\nosaurus_chat_id=y")
        #expect(bad.values.isEmpty)
        #expect(bad.errors.count == 4)
    }

    @Test func theOverlayCannotReplaceTheOsaurusContract() {
        let result = HarnessRuntimeForm.parseEnvironment("OSAURUS_API_BASE=http://evil")
        #expect(result.values["OSAURUS_API_BASE"] == nil)
        #expect(result.errors.count == 1)
    }

    @Test func theTerminalSignInScriptQuotesPathAndExecutable() {
        let script = ClaudeCodeConfiguration.terminalLoginScript(
            executable: "/Users/me/it's here/claude", path: "/usr/local/bin:/usr/bin")
        #expect(script.hasPrefix("#!/bin/zsh -l\n"))
        #expect(script.contains("export PATH='/usr/local/bin:/usr/bin'\n"))
        #expect(script.contains("'/Users/me/it'\\''s here/claude' auth login\n"))
        #expect(!ClaudeCodeConfiguration.terminalLoginScript(executable: "claude", path: nil).contains("export PATH"))
    }
}

/// Counts the probe's calls and lets a test hold it open.
private actor FakeProbe {
    private(set) var calls: [UUID] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var held = false

    func hold() { held = true }
    func release() { held = false; gate?.resume(); gate = nil }

    func run(_ runtime: HarnessRuntime) async -> HarnessProbeResult {
        calls.append(runtime.id)
        if held { await withCheckedContinuation { gate = $0 } }
        return HarnessProbeResult(status: .ready, message: "fake ok", resolvedExecutable: "/fake/\(runtime.executable)")
    }
}

@MainActor
@Suite("Agent Runtimes Test button")
struct HarnessRuntimeTesterTests {
    @Test func aTestRunsOnlyTheInjectedProbeAndKeepsItsResult() async throws {
        let fake = FakeProbe()
        let tester = HarnessRuntimeTester(probe: { await fake.run($0) })
        let runtime = HarnessRuntime(name: "Fake", kind: .piRPC, executable: "fake-pi")

        #expect(tester.results.isEmpty, "nothing is tested until the button is pressed")
        let task = try #require(tester.run(runtime))
        await task.value
        #expect(await fake.calls == [runtime.id])
        #expect(tester.results[runtime.id]?.status == .ready)
        #expect(tester.results[runtime.id]?.resolvedExecutable == "/fake/fake-pi")
        #expect(!tester.isTesting(runtime.id))

        tester.clear(runtime.id)
        #expect(tester.results[runtime.id] == nil)
    }

    @Test func aSecondPressWhileATestRunsDoesNothing() async throws {
        let fake = FakeProbe()
        await fake.hold()
        let tester = HarnessRuntimeTester(probe: { await fake.run($0) })
        let runtime = HarnessRuntime(name: "Fake", kind: .piRPC, executable: "fake-pi")

        let first = try #require(tester.run(runtime))
        #expect(tester.isTesting(runtime.id))
        #expect(tester.run(runtime) == nil)
        await fake.release()
        await first.value
        #expect(await fake.calls.count == 1)
    }
}

// MARK: - Owner rule: a harness runs only when the user chose it

@MainActor
@Suite("Harness never by default", .serialized)
struct HarnessNeverByDefaultTests {
    @Test func discoveryNeverPicksARuntimeAndAHarnessOnlyMachineGetsNoSelection() {
        // Only harness columns exist: no model items at all.
        let harnesses = ChatModelPickerProvider.harnessProviders(runtimes: [.builtInClaudeCode])
        let groups = ChatModelPickerProvider.groups(from: [], harnesses: harnesses)
        #expect(groups.contains { $0.isHarness && $0.isActive })
        #expect(groups.filter { !$0.isHarness }.allSatisfy { !$0.isActive })

        // Discovery after the model list arrives: a saved `claude-code/…` id or
        // no preference at all never resolves to anything when no model exists.
        for agentDefault in [nil, "claude-code/sonnet", "harness:\(HarnessRuntime.builtInClaudeCodeId.uuidString)"] {
            #expect(
                ChatSession.modelAfterDiscovery(
                    manual: nil, restored: nil, agentDefault: agentDefault, previous: nil, among: []) == nil)
        }

        // With no runtime chosen, the picker marks no harness row and opens
        // without a selection; the user sees the choose-a-model state.
        #expect(ChatHarnessPickerOption.selectedID(runtime: nil, claudeConfig: .default) == nil)
        let size = ChatModelPickerCard.initialSize(
            providers: groups, selectedModel: nil, optionsControl: nil, selectedHarnessID: nil)
        #expect(size.width > 0 && size.height > 0)
    }

    @Test func aChatWithAHarnessAvailableButNotChosenStaysOnTheBuiltInLoop() async throws {
        try await ChatHistoryTestStorage.run {
            let previousStoreDir = HarnessRuntimeStore.overrideDirectory
            HarnessRuntimeStore.overrideDirectory = OsaurusPaths.root()
            HarnessRuntimeStore.shared.resetForTests()
            defer {
                HarnessRuntimeStore.overrideDirectory = previousStoreDir
                HarnessRuntimeStore.shared.resetForTests()
            }
            // The Claude Code runtime is registered (seeded) and offered.
            _ = HarnessRuntimeStore.shared.ensureClaudeCodeRuntime()
            #expect(!HarnessRuntimeStore.shared.all().isEmpty)

            let fresh = Agent(name: "Fresh")
            AgentManager.shared.add(fresh)
            let session = ChatSession()
            session.agentId = fresh.id
            #expect(session.harnessSelection == nil)
            #expect(!session.isHarnessAgentActive)
            #expect(AgentManager.shared.effectiveRuntime(for: fresh.id) == .builtIn)
            #expect(AgentManager.shared.effectiveRuntime(for: Agent.defaultId) == .builtIn)
            #expect(await HarnessSessionManager.shared.liveSessionCount() == 0)
        }
    }

    @Test func onlyTheUsersOwnActionsCanStartOrProbeARuntime() throws {
        // Source guard: the calls that spawn `claude` / `pi` (a chat turn, the
        // Test button, the sign-in sheet) live in these files only. Nothing in
        // the picker, new chat, new agent, templates, discovery or schedules
        // calls them.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let allowed: Set<String> = [
            "Models/Configuration/ClaudeCodeConfiguration.swift",
            "Views/Settings/ClaudeCodeSetupStep.swift",
            "Views/Chat/ChatSession+Harness.swift",
            "Services/Harness/HarnessRuntimeProbe.swift",
            "Services/Harness/HarnessSession.swift",
            "Services/Harness/HarnessRuntimeForm.swift",
        ]
        let patterns = [
            "HarnessSessionManager.shared.session(", "HarnessProcess.launch(", "HarnessRuntimeProbe.run(",
            "ClaudeCodeConfiguration.login(", "openTerminalLogin(", "ClaudeCodeConfiguration.setupState(",
            "ClaudeCodeConfiguration.authStatus(", "ClaudeCodeConfiguration.cliVersion(",
            "ClaudeCodeProcessRunner.capture(", "HarnessControlCommand.resolve(",
        ]
        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if relative.hasPrefix(".build") || relative.hasPrefix("Tests") {
                enumerator?.skipDescendants()
                continue
            }
            guard url.pathExtension == "swift", !allowed.contains(relative),
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            for pattern in patterns where text.contains(pattern) { offenders.append("\(relative): \(pattern)") }
        }
        #expect(offenders.isEmpty, "unexpected launch or probe callers: \(offenders)")

        // The sign-in sheet is shown only from Agent Runtimes (Sign In) and the
        // onboarding Claude Code step the user clicked.
        var sheetUsers: Set<String> = []
        let again = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = again?.nextObject() as? URL {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if relative.hasPrefix(".build") || relative.hasPrefix("Tests") {
                again?.skipDescendants()
                continue
            }
            guard url.pathExtension == "swift", relative != "Views/Settings/ClaudeCodeSetupStep.swift",
                let text = try? String(contentsOf: url, encoding: .utf8), text.contains("ClaudeCodeSetupStep(")
            else { continue }
            sheetUsers.insert(relative)
        }
        #expect(
            sheetUsers == ["Views/Settings/AgentRuntimesView.swift", "Views/Onboarding/OnboardingConfigureAIView.swift"])
    }

    @Test func newAgentsAndTemplatesCarryNoRuntime() {
        #expect(Agent(name: "Fresh").runtime == nil)
        #expect(DefaultAgentConfiguration().runtime == nil)
    }
}
