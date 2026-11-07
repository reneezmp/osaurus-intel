//
//  IntelCovReauditGapTests.swift
//  osaurusTests
//
//  `W-cov-reaudit` stage 2 (docs/COV_REAUDIT.md): upstream fixes Intel's own
//  copies were missing.
//  - #1940 / #3051: forced `tool_choice` downgraded where the provider
//    rejects it (DeepSeek thinking mode, newer Claude generations).
//  - #2154: a window frame on a vanished display is recovered.
//  - #2388 / #2392 / #2516: a user Stop is recorded as `cancelled`, the
//    record survives the trailing-blank trim and the save, and an empty
//    cancelled turn renders "Interrupted".
//  - #2084: loading the built-in Data Visualizer skill loads `render_chart`.
//  (#1275, skill path containment, is upstream's
//  `SkillStoreFileContainmentTests`.)
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct IntelToolChoiceSanitizeTests {
    private func sanitize(
        _ choice: ToolChoiceOption?, provider: RemoteProviderType?, host: String = "",
        model: String, thinkingDisabled: Bool = false
    ) -> ToolChoiceOption? {
        ChatEngine.sanitizedToolChoice(
            choice, providerType: provider, host: host, model: model, thinkingDisabled: thinkingDisabled)
    }

    @Test func deepSeekThinkingDowngradesForcedChoices() {
        #expect(sanitize(.required, provider: .openaiLegacy, host: "api.deepseek.com", model: "deepseek-v4-pro") == .auto)
        #expect(sanitize(.required, provider: nil, host: "api.deepseek.com", model: "deepseek-v4-flash") == .auto)
        #expect(sanitize(ToolChoiceOption.none, provider: .openaiLegacy, host: "api.deepseek.com", model: "deepseek-v4-pro") == ToolChoiceOption.none)
        #expect(sanitize(.auto, provider: .openaiLegacy, host: "api.deepseek.com", model: "deepseek-v4-pro") == .auto)
    }

    @Test func deepSeekWithThinkingDisabledKeepsForcedChoices() {
        #expect(
            sanitize(.required, provider: .openaiLegacy, host: "api.deepseek.com", model: "deepseek-v4-pro", thinkingDisabled: true)
                == .required)
    }

    @Test func otherProvidersKeepForcedChoices() {
        #expect(sanitize(.required, provider: .openaiLegacy, host: "api.openai.com", model: "gpt-5.1") == .required)
        #expect(sanitize(.required, provider: .anthropic, host: "api.anthropic.com", model: "claude-haiku-4-5") == .required)
    }

    @Test func newerClaudeRejectsForcedChoicesEverywhere() {
        #expect(sanitize(.required, provider: .anthropic, host: "api.anthropic.com", model: "claude-opus-5-5") == .auto)
        #expect(sanitize(.required, provider: .openaiLegacy, host: "openrouter.ai", model: "anthropic/claude-sonnet-5.5") == .auto)
    }
}

@Suite
struct IntelWindowFrameRecoveryTests {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)

    @Test func frameOnScreenIsUsable() {
        #expect(IntelWindowFrameRecovery.isUsable(NSRect(x: 100, y: 100, width: 900, height: 600), screenFrames: [screen]))
    }

    @Test func frameOnAVanishedDisplayIsNot() {
        // Where an external monitor to the right used to be.
        #expect(!IntelWindowFrameRecovery.isUsable(NSRect(x: 2000, y: 100, width: 900, height: 600), screenFrames: [screen]))
        // Barely overlapping: under 100 points visible.
        #expect(!IntelWindowFrameRecovery.isUsable(NSRect(x: 1390, y: 100, width: 900, height: 600), screenFrames: [screen]))
    }

    @Test func collapsedFrameIsNot() {
        #expect(!IntelWindowFrameRecovery.isUsable(NSRect(x: 100, y: 100, width: 150, height: 600), screenFrames: [screen]))
    }
}

@Suite(.serialized)
@MainActor
struct IntelCancelledTurnTests {
    @Test func stopBeforeTheFirstReplyLeavesACancelledMarker() {
        let session = ChatSession()
        session.turns = [ChatTurn(role: .user, content: "hello")]
        session.isStreaming = true
        session.stop()
        let last = session.turns.last
        #expect(last?.role == .assistant)
        #expect(last?.terminalStopReason == "cancelled")
    }

    @Test func aProgrammaticStopLeavesNoMarker() {
        let session = ChatSession()
        session.turns = [ChatTurn(role: .user, content: "hello")]
        session.isStreaming = true
        session.stop(preservesCancelledMarker: false)
        #expect(session.turns.last?.role == .user)
    }

    @Test func stopWithNothingRunningLeavesNoMarker() {
        let session = ChatSession()
        session.turns = [ChatTurn(role: .user, content: "hello")]
        session.stop()
        #expect(session.turns.count == 1)
    }

    @Test func theStopReasonIsSaved() throws {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.terminalStopReason = "cancelled"
        let data = try JSONEncoder().encode(ChatTurnData(from: turn))
        let decoded = try JSONDecoder().decode(ChatTurnData.self, from: data)
        #expect(decoded.terminalStopReason == "cancelled")
        #expect(ChatTurn(from: decoded).terminalStopReason == "cancelled")
    }

    @Test func anEmptyCancelledTurnRendersInterrupted() {
        let cancelled = ChatTurn(role: .assistant, content: "")
        cancelled.terminalStopReason = "cancelled"
        let blocks = BlockMemoizer().blocks(from: [ChatTurn(role: .user, content: "hi"), cancelled], agentName: "A")
        let texts = blocks.compactMap { block -> String? in
            if case let .paragraph(_, text, _, _) = block.kind { return text }
            return nil
        }
        #expect(texts.contains { $0.hasPrefix("Interrupted") })
    }

    @Test func aCancelledTurnWithAnAnswerRendersTheAnswerOnly() {
        let cancelled = ChatTurn(role: .assistant, content: "Partial answer")
        cancelled.terminalStopReason = "cancelled"
        let blocks = BlockMemoizer().blocks(from: [ChatTurn(role: .user, content: "hi"), cancelled], agentName: "A")
        let texts = blocks.compactMap { block -> String? in
            if case let .paragraph(_, text, _, _) = block.kind { return text }
            return nil
        }
        #expect(!texts.contains { $0.hasPrefix("Interrupted") })
    }
}

@Suite
struct IntelBuiltInSkillToolDependencyTests {
    @Test func dataVisualizerSkillLoadsRenderChart() async throws {
        let catalog = CapabilityCatalog(
            tools: [],
            skills: [.init(name: "Data Visualizer", description: "Charts")],
            groups: []
        )
        let tool = CapabilitiesTool(catalogProvider: { _ in catalog })
        let result = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await tool.execute(argumentsJSON: #"{"ids":["skill/Data Visualizer"]}"#)
        }
        #expect(!ToolEnvelope.isError(result))
        #expect(result.contains("render_chart"))
    }
}
