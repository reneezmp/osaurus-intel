//
//  IntelContextCompactionTests.swift
//  OsaurusCoreTests
//
//  Intel context compaction (upstream #136): boundary selection, summary
//  validity, token accounting, the run itself against a fake engine, and
//  persistence on the saved chat.
//

import Foundation
import Testing

@testable import OsaurusCore

private final class SummaryEngine: ChatEngineProtocol, @unchecked Sendable {
    let reply: String
    private(set) var requests: [ChatCompletionRequest] = []
    init(reply: String) { self.reply = reply }

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        requests.append(request)
        return ChatCompletionResponse(
            id: "t", object: "chat.completion", created: 0, model: request.model,
            choices: [
                .init(
                    index: 0,
                    message: .init(role: "assistant", content: reply, tool_calls: nil, reasoning_content: nil),
                    finish_reason: "stop")
            ],
            usage: nil)
    }
}

@MainActor
@Suite("Intel context compaction")
struct IntelContextCompactionTests {
    /// `exchanges` user/assistant pairs with `size`-character messages.
    private func conversation(exchanges: Int, size: Int = 40) -> [ChatTurn] {
        (0 ..< exchanges).flatMap { index in
            [
                ChatTurn(role: .user, content: "Question \(index) " + String(repeating: "q", count: size)),
                ChatTurn(role: .assistant, content: "Answer \(index) " + String(repeating: "a", count: size)),
            ]
        }
    }

    @Test("Short chats have nothing to compact; longer ones keep the last two exchanges")
    func cutIndex() {
        #expect(IntelContextCompaction.compactionCutIndex(turns: conversation(exchanges: 2), existingSummary: nil) == nil)
        let turns = conversation(exchanges: 4)
        // Users at 0,2,4,6 → cut at the second-from-last user turn (index 4).
        #expect(IntelContextCompaction.compactionCutIndex(turns: turns, existingSummary: nil) == 4)
        // A summary already covering that span means nothing new to do.
        let covering = ConversationSummary(
            summaryText: "s", coveredTurnIds: Array(turns.prefix(4)).map(\.id), modelIdentifier: "m",
            savedTokensEstimate: 0)
        #expect(IntelContextCompaction.compactionCutIndex(turns: turns, existingSummary: covering) == nil)
    }

    @Test("A huge two-exchange chat is still compactable by token weight")
    func heavyShortChat() {
        let turns = conversation(exchanges: 2, size: 20_000)
        #expect(IntelContextCompaction.compactionCutIndex(turns: turns, existingSummary: nil) != nil)
    }

    @Test("Editing or deleting a covered turn invalidates the summary")
    func validity() {
        var turns = conversation(exchanges: 4)
        let summary = ConversationSummary(
            summaryText: "s", coveredTurnIds: Array(turns.prefix(4)).map(\.id), modelIdentifier: "m",
            savedTokensEstimate: 0)
        #expect(IntelContextCompaction.summaryIsValid(summary, for: turns))
        turns.remove(at: 1)
        #expect(!IntelContextCompaction.summaryIsValid(summary, for: turns))
        #expect(IntelContextCompaction.activeSummary(summary, for: turns) == nil)
    }

    @Test("Token estimates count the summary instead of the covered turns")
    func tokenAccounting() {
        let turns = conversation(exchanges: 6, size: 2_000)
        let full = IntelContextCompaction.conversationTokens(turns: turns, summary: nil)
        let summary = ConversationSummary(
            summaryText: "Short summary.", coveredTurnIds: Array(turns.prefix(8)).map(\.id), modelIdentifier: "m",
            savedTokensEstimate: 0)
        let compacted = IntelContextCompaction.conversationTokens(turns: turns, summary: summary)
        #expect(compacted < full / 2)
    }

    @Test("Summarize sends the covered transcript and returns a valid summary")
    func summarize() async throws {
        let turns = conversation(exchanges: 4, size: 3_000)
        let engine = SummaryEngine(reply: "  The user asked four questions about q.  ")
        let summary = try await IntelContextCompaction.summarize(
            turns: turns, existingSummary: nil, model: "test-model", engine: engine)
        #expect(summary.summaryText == "The user asked four questions about q.")
        #expect(summary.coveredTurnIds == Array(turns.prefix(4)).map(\.id))
        #expect(summary.savedTokensEstimate > 0)
        #expect(IntelContextCompaction.summaryIsValid(summary, for: turns))
        let user = engine.requests.first?.messages.last?.content ?? ""
        #expect(user.contains("[User]: Question 0"))
        #expect(!user.contains("Question 3"))  // the last two exchanges stay verbatim
    }

    @Test("Empty replies, missing models and tiny chats fail without changes")
    func failures() async {
        let turns = conversation(exchanges: 4, size: 3_000)
        await #expect(throws: IntelContextCompaction.Failure.emptySummary) {
            _ = try await IntelContextCompaction.summarize(
                turns: turns, existingSummary: nil, model: "m", engine: SummaryEngine(reply: "   "))
        }
        await #expect(throws: IntelContextCompaction.Failure.noModel) {
            _ = try await IntelContextCompaction.summarize(
                turns: turns, existingSummary: nil, model: nil, engine: SummaryEngine(reply: "x"))
        }
        await #expect(throws: IntelContextCompaction.Failure.nothingToCompact) {
            _ = try await IntelContextCompaction.summarize(
                turns: self.conversation(exchanges: 1), existingSummary: nil, model: "m",
                engine: SummaryEngine(reply: "x"))
        }
    }

    @Test("The notice appears only near the limit and when there is something to compact")
    func suggestion() {
        let turns = conversation(exchanges: 6, size: 4_000)
        let tokens = IntelContextCompaction.conversationTokens(turns: turns, summary: nil)
        #expect(IntelContextCompaction.shouldSuggest(
            conversationTokens: tokens, contextWindow: tokens, turns: turns, summary: nil))
        #expect(!IntelContextCompaction.shouldSuggest(
            conversationTokens: tokens, contextWindow: tokens * 10, turns: turns, summary: nil))
    }

    @Test("The summary persists on the saved chat; older chats decode without one")
    func persistence() throws {
        let summary = ConversationSummary(
            summaryText: "kept", coveredTurnIds: [UUID()], modelIdentifier: "m", savedTokensEstimate: 12)
        let data = ChatSessionData(title: "t", conversationSummary: summary)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoded = try encoder.encode(data)
        // ISO-8601 drops sub-second precision, so compare the fields that matter.
        let restored = try decoder.decode(ChatSessionData.self, from: encoded).conversationSummary
        #expect(restored?.summaryText == summary.summaryText)
        #expect(restored?.coveredTurnIds == summary.coveredTurnIds)
        #expect(restored?.savedTokensEstimate == 12)

        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "conversationSummary")
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try decoder.decode(ChatSessionData.self, from: old).conversationSummary == nil)
    }

    // MARK: Compaction model, progress and transcript marker (W-chat-ux)

    @Test("The compaction model wins; blank or unset falls back to the chat's model")
    func effectiveModel() {
        #expect(IntelContextCompaction.effectiveModelIdentifier(configured: "p/m", fallback: "chat") == "p/m")
        #expect(IntelContextCompaction.effectiveModelIdentifier(configured: "  ", fallback: "chat") == "chat")
        #expect(IntelContextCompaction.effectiveModelIdentifier(configured: nil, fallback: nil) == nil)
        #expect(IntelContextCompaction.usesChatModelFallback(configured: nil))
        #expect(IntelContextCompaction.usesChatModelFallback(configured: " "))
        #expect(!IntelContextCompaction.usesChatModelFallback(configured: "p/m"))
    }

    @Test("The compaction model is stored as provider and name and copied by adopt")
    func compactionModelSetting() {
        let cfg = ChatConfiguration(hotkey: nil, systemPrompt: "")
        #expect(cfg.compactionModelIdentifier == nil)
        cfg.compactionModelProvider = "deepseek"
        cfg.compactionModelName = "deepseek-chat"
        #expect(cfg.compactionModelIdentifier == "deepseek/deepseek-chat")
        cfg.compactionModelProvider = nil
        #expect(cfg.compactionModelIdentifier == "deepseek-chat")
        let copy = ChatConfiguration(hotkey: nil, systemPrompt: "")
        copy.adopt(cfg)
        #expect(copy.compactionModelName == "deepseek-chat")
    }

    @Test("A run reports preparing, summarizing and applying in order")
    func phases() async throws {
        var seen: [ContextCompactionPhase] = []
        _ = try await IntelContextCompaction.summarize(
            turns: conversation(exchanges: 4, size: 3_000), existingSummary: nil, model: "m",
            engine: SummaryEngine(reply: "summary"), onPhase: { seen.append($0) })
        #expect(seen == [.preparing, .summarizing, .applying])
    }

    @Test("The transcript shows a marker right after the covered turns, only while the summary is valid")
    func transcriptMarker() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let turns = conversation(exchanges: 3)
            session.turns = turns
            let summary = ConversationSummary(
                summaryText: "Earlier: q.", coveredTurnIds: turns.prefix(2).map(\.id),
                modelIdentifier: "p/m", savedTokensEstimate: 1_234)
            session.conversationSummary = summary
            session.rebuildVisibleBlocks()
            let blocks = session.visibleBlocks
            guard let index = blocks.firstIndex(where: { $0.id == "compaction-\(summary.id.uuidString)" }) else {
                Issue.record("no compaction marker")
                return
            }
            #expect(blocks[index].turnId == turns[1].id)
            #expect(blocks[..<index].allSatisfy { Set(turns.prefix(2).map(\.id)).contains($0.turnId) })
            #expect(blocks[(index + 1)...].allSatisfy { $0.turnId != turns[0].id && $0.turnId != turns[1].id })
            if case let .compactionMarker(saved, model, text) = blocks[index].kind {
                #expect(saved == 1_234 && model == "p/m" && text == "Earlier: q.")
            } else {
                Issue.record("wrong kind")
            }

            // Editing a covered turn retires the summary, and the marker goes.
            session.turns[0] = ChatTurn(role: .user, content: "edited")
            session.rebuildVisibleBlocks()
            #expect(!session.visibleBlocks.contains { $0.id.hasPrefix("compaction-") })
        }
    }

    @Test("With no compaction model and no chat model, Compact opens the model dialog")
    func dialogWhenNoModel() async throws {
        try await ChatHistoryTestStorage.run {
            let cfg = ChatConfigurationStore.load()
            let saved = (cfg.compactionModelProvider, cfg.compactionModelName)
            cfg.compactionModelProvider = nil
            cfg.compactionModelName = nil
            defer { (cfg.compactionModelProvider, cfg.compactionModelName) = saved }
            let session = ChatSession()
            session.turns = conversation(exchanges: 4, size: 3_000)
            session.selectedModel = nil
            session.compactConversation()
            #expect(session.compactionState == .needsModelSelection)
            #expect(session.showCompactionDialog)
            session.cancelCompactionDialog()
            #expect(session.compactionState == .idle)
            #expect(!session.showCompactionDialog)
            #expect(!session.hasPendingSendAfterCompaction)
        }
    }

    @Test("The marker shortens token counts like upstream")
    func markerCopy() {
        #expect(NativeCompactionMarkerView.formatTokens(950) == "950")
        #expect(NativeCompactionMarkerView.formatTokens(1_500) == "1.5k")
        #expect(NativeCompactionMarkerView.formatTokens(24_000) == "24k")
    }
}
