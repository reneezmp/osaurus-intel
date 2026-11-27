//
//  ScreenContextStage6Tests.swift
//  OsaurusCoreTests — Computer Use
//
//  W-computer-use stage 6: opt-in per-agent screen context. Fakes only: no real
//  screen capture, Accessibility check, TCC prompt, network, keychain or
//  `~/.osaurus` (agents live in a temporary storage root).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Screen context stage 6", .serialized)
struct ScreenContextStage6Tests {

    private static let block = "[Screen Context]\nDoing: In Safari\n[/Screen Context]"

    private final class Counter: @unchecked Sendable { var calls = 0 }

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: Gate

    @Test func gateNeedsTheAgentOptInAndAnAttendedSource() {
        func mayCapture(
            _ enabled: Bool, _ source: SessionSource?, unattended: Bool = false, external: Bool = false
        ) -> Bool {
            ScreenContextGate.mayCapture(
                agentEnabled: enabled, source: source, isUnattendedDispatch: unattended, isExternalSurface: external)
        }
        #expect(mayCapture(true, .chat))
        #expect(mayCapture(true, .imported))
        // Off wins over everything.
        #expect(!mayCapture(false, .chat))
        // Unattended or external callers never capture, whatever the switch says.
        #expect(!mayCapture(true, .chat, unattended: true))
        #expect(!mayCapture(true, .chat, external: true))
        #expect(!mayCapture(true, .schedule))
        #expect(!mayCapture(true, .watcher))
        #expect(!mayCapture(true, .plugin))
        #expect(!mayCapture(true, .http))
        #expect(!mayCapture(true, nil))
    }

    // MARK: Freeze

    @MainActor
    @Test func capturesOnceThenReplaysTheSameBytes() async {
        let freeze = ScreenContextFreeze()
        let counter = Counter()
        let capture: () async -> String = {
            counter.calls += 1
            return "  \(Self.block)\n"
        }
        let first = await freeze.blockForSend(allowed: true, capture: capture)
        let second = await freeze.blockForSend(allowed: true, capture: capture)
        #expect(first == Self.block)
        #expect(second == first)
        #expect(counter.calls == 1)
        #expect(freeze.isFrozen)
        #expect(freeze.tokens == ContextBudgetManager.estimateTokens(for: Self.block))
    }

    @MainActor
    @Test func aSendThatIsNotAllowedNeverCapturesNorFreezes() async {
        let freeze = ScreenContextFreeze()
        let counter = Counter()
        let capture: () async -> String = {
            counter.calls += 1
            return Self.block
        }
        #expect(await freeze.blockForSend(allowed: false, capture: capture) == nil)
        #expect(counter.calls == 0)
        #expect(!freeze.isFrozen)
        #expect(freeze.tokens == 0)
        // Turning it on later captures at that send.
        #expect(await freeze.blockForSend(allowed: true, capture: capture) == Self.block)
        #expect(counter.calls == 1)
        // Turning it off again shares nothing, even though a block is frozen.
        #expect(await freeze.blockForSend(allowed: false, capture: capture) == nil)
    }

    @MainActor
    @Test func anEmptySnapshotFreezesAsNothingAndResetStartsOver() async {
        let freeze = ScreenContextFreeze()
        let counter = Counter()
        let blank: () async -> String = {
            counter.calls += 1
            return "   \n"
        }
        #expect(await freeze.blockForSend(allowed: true, capture: blank) == nil)
        #expect(await freeze.blockForSend(allowed: true, capture: blank) == nil)
        #expect(counter.calls == 1)
        #expect(freeze.tokens == 0)
        freeze.reset()
        #expect(!freeze.isFrozen)
        _ = await freeze.blockForSend(allowed: true, capture: blank)
        #expect(counter.calls == 2)
    }

    // MARK: Prefix

    @Test func prefixOrderIsAutomationScreenMemoryTime() throws {
        let automation = try #require(SystemPromptComposer.appleScriptWorkingAppContext(appName: "Pages"))
        let prefix = try #require(
            SystemPromptComposer.composeInjectedUserPrefix(
                memorySection: "a fact", screenContext: Self.block, automationContext: automation,
                timeContext: "[Current Time]\nnow"))
        let a = try #require(prefix.range(of: "[Mac Automation Context]"))
        let s = try #require(prefix.range(of: "[Screen Context]"))
        let m = try #require(prefix.range(of: "[Memory]"))
        let t = try #require(prefix.range(of: "[Current Time]"))
        #expect(a.lowerBound < s.lowerBound && s.lowerBound < m.lowerBound && m.lowerBound < t.lowerBound)
        #expect(prefix.hasSuffix("[Current Time]\nnow\n\n"))
        // Screen context alone, and blank screen context, behave like the other blocks.
        #expect(
            SystemPromptComposer.composeInjectedUserPrefix(memorySection: nil, screenContext: Self.block)
                == Self.block + "\n\n")
        #expect(SystemPromptComposer.composeInjectedUserPrefix(memorySection: nil, screenContext: "  \n") == nil)
        // Existing callers are unchanged.
        #expect(
            SystemPromptComposer.composeInjectedUserPrefix(memorySection: "x") == "[Memory]\nx\n[/Memory]\n\n")
    }

    @MainActor
    @Test func theFrozenTurnPrefixCarriesTheScreenBlockAndKeepsItOnRegenerate() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let turn = ChatTurn(role: .user, content: "Summarise this page")
            session.turns = [turn]
            session.freezeInjectedContextOntoLatestUserTurn(memorySection: nil, screenContext: Self.block)
            let frozen = try #require(turn.injectedContextPrefix)
            #expect(frozen.hasPrefix(Self.block + "\n\n"))
            session.freezeInjectedContextOntoLatestUserTurn(memorySection: nil, screenContext: "[Screen Context]\nother")
            #expect(turn.injectedContextPrefix == frozen)
        }
    }

    // MARK: Per-agent option

    @Test func theOptionIsOffByDefaultAndRoundTrips() throws {
        #expect(AgentSettings.defaultDisabled.screenContextEnabled == false)
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data("{}".utf8))
        #expect(decoded.screenContextEnabled == false)
        // An upstream file that says true is honoured; Intel writes the key back.
        let on = try JSONDecoder().decode(AgentSettings.self, from: Data(#"{"screenContextEnabled":true}"#.utf8))
        #expect(on.screenContextEnabled == true)
        let reencoded = try JSONEncoder().encode(on)
        let object = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        #expect(object["screenContextEnabled"] as? Bool == true)
    }

    @MainActor
    @Test func effectiveOnlyWhenComputerUseAndTheOptionAreBothOnForACustomAgent() async throws {
        try await ChatHistoryTestStorage.run {
            func addAgent(computerUse: Bool, screenContext: Bool) -> UUID {
                var settings = AgentSettings.defaultDisabled
                settings.computerUseEnabled = computerUse
                settings.screenContextEnabled = screenContext
                let agent = Agent(name: "sc-\(UUID().uuidString.prefix(6))", settings: settings)
                AgentManager.shared.add(agent)
                return agent.id
            }
            let both = addAgent(computerUse: true, screenContext: true)
            let cuOnly = addAgent(computerUse: true, screenContext: false)
            let optionOnly = addAgent(computerUse: false, screenContext: true)
            #expect(AgentManager.shared.effectiveScreenContextEnabled(for: both))
            #expect(!AgentManager.shared.effectiveScreenContextEnabled(for: cuOnly))
            #expect(!AgentManager.shared.effectiveScreenContextEnabled(for: optionOnly))
            // The built-in agent never shares the screen.
            #expect(!AgentManager.shared.effectiveScreenContextEnabled(for: Agent.defaultId))
            for id in [both, cuOnly, optionOnly] { _ = await AgentManager.shared.delete(id: id) }
        }
    }

    // MARK: Budget row

    @Test func contextBreakdownShowsAScreenContextRowOnlyWhenThereIsOne() {
        let none = ContextBreakdown.from(manifest: PromptManifest(), toolTokens: 10)
        #expect(!none.context.contains { $0.id == "screenContext" })
        let with = ContextBreakdown.from(manifest: PromptManifest(), toolTokens: 10, screenContextTokens: 42)
        let row = with.context.first { $0.id == "screenContext" }
        #expect(row?.tokens == 42)
        #expect(row?.tint == .pink)
        let composed = ContextBreakdown.from(context: ComposedContext(), screenContextTokens: 7)
        #expect(composed.context.first { $0.id == "screenContext" }?.tokens == 7)
    }

    // MARK: Composer guidance loop (audit row 12)

    @Test func theRegistryLoopCarriesComputerUseGuidanceGatedOnItsTool() {
        let capability = SubagentCapabilityRegistry.computerUse
        #expect(capability.guidanceSectionId == "computerUse")
        #expect(capability.guidance == SystemPromptTemplates.computerUseGuidance)
        #expect(capability.primaryToolName == ToolRegistry.computerUseToolName)
        #expect(SubagentCapabilityRegistry.all.contains { $0.id == capability.id })
        // Registry order: Computer Use renders before Browser Use and Image.
        let ids = SubagentCapabilityRegistry.all.map(\.id)
        #expect(ids.firstIndex(of: capability.id) == 0)
    }

    @MainActor
    @Test func aCustomAgentWithComputerUseGetsTheToolButTheLeanPromptSkipsTheGuidance() async throws {
        // Upstream #2250: the lean custom-agent prompt carries no registry
        // guidance; the tool's own description is what the model sees.
        try await ChatHistoryTestStorage.run {
            var settings = AgentSettings.defaultDisabled
            settings.computerUseEnabled = true
            var agent = Agent(name: "cu-\(UUID().uuidString.prefix(6))", systemPrompt: "You are Pip.", settings: settings)
            agent.toolSelectionMode = .auto
            AgentManager.shared.add(agent)
            let context = await SystemPromptComposer.composeChatContext(agentId: agent.id, model: "gpt-5", query: "hi")
            #expect(context.tools.contains { $0.function.name == ToolRegistry.computerUseToolName })
            #expect(!context.promptSections.contains { $0.id == "computerUse" })
            #expect(!context.prompt.contains("## Computer use"))
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    // MARK: Safety source guards

    @Test func captureNeverRequestsAPermissionAndThePreviewNeverRunsUnasked() throws {
        for file in [
            "ComputerUse/Perception/ScreenContextDistiller.swift",
            "ComputerUse/Perception/ScreenContextFreeze.swift",
            "Views/Settings/ScreenContextPreview.swift",
        ] {
            let text = try Self.source(file)
            #expect(!text.contains("requestPermission("), Comment(rawValue: file))
            #expect(!text.contains("AXIsProcessTrustedWithOptions"), Comment(rawValue: file))
            #expect(!text.contains("CGRequestScreenCaptureAccess"), Comment(rawValue: file))
        }
        // The global settings card reads the screen only when Refresh is pressed.
        let settings = try Self.source("Views/Settings/ComputerUseSettingsView.swift")
        #expect(settings.contains("autoCaptureOnAppear: false"))
    }

    @Test func theChatSendCapturesOnlyThroughTheGateAndTheFreeze() throws {
        let chat = try Self.source("Views/Chat/ChatView.swift")
        #expect(chat.contains("screenContextFreeze.blockForSend("))
        #expect(chat.contains("ScreenContextGate.mayCapture("))
        #expect(chat.contains("effectiveScreenContextEnabled(for: effectiveAgentId)"))
        // The only capture call in the chat path is the one handed to the freeze.
        #expect(chat.components(separatedBy: "ScreenContextDistiller.captureForChat()").count - 1 == 1)
        let section = try Self.source("Views/Agent/IntelComputerUseAbilitySection.swift")
        #expect(section.components(separatedBy: "screenContextEnabled = value").count - 1 == 1)
    }
}
