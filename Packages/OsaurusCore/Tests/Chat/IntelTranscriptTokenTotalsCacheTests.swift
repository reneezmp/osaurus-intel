//
//  IntelTranscriptTokenTotalsCacheTests.swift
//  osaurusTests
//
//  Intel: upstream #3112 against Intel's ChatSession. The transcript token
//  totals behind the context readout are memoized, and must still follow
//  every change that affects them: a new `turns` array, a compaction
//  summary, and in-place edits to a turn (streamed content, thinking, tool
//  results, attachments) that never reassign the array.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct IntelTranscriptTokenTotalsCacheTests {

    private func uncached(_ session: ChatSession) -> (Int, Int) {
        let output = ContextBudgetManager.estimateOutputTokens(for: session.turns)
        let conversation =
            IntelContextCompaction.conversationTokens(
                turns: session.turns, summary: session.conversationSummary) - output
        return (output, conversation)
    }

    private func expectMatches(_ session: ChatSession, sourceLocation: SourceLocation = #_sourceLocation) {
        let cached = session.transcriptTokenTotals()
        let fresh = uncached(session)
        #expect(cached.outputTokens == fresh.0, sourceLocation: sourceLocation)
        #expect(cached.conversationTokens == fresh.1, sourceLocation: sourceLocation)
    }

    @Test func totalsFollowInPlaceTurnEdits() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let user = ChatTurn(role: .user, content: "Question " + String(repeating: "q", count: 400))
            let assistant = ChatTurn(role: .assistant, content: "Answer")
            session.turns = [user, assistant]
            expectMatches(session)
            let before = session.transcriptTokenTotals()

            // Streaming appends to the live turn without reassigning `turns`.
            assistant.appendContent(String(repeating: "a", count: 4_000))
            expectMatches(session)
            #expect(session.transcriptTokenTotals().outputTokens > before.outputTokens)

            assistant.appendThinking(String(repeating: "t", count: 2_000))
            expectMatches(session)

            let afterThinking = session.transcriptTokenTotals()
            assistant.toolResults["call-1"] = String(repeating: "r", count: 8_000)
            expectMatches(session)
            #expect(session.transcriptTokenTotals().conversationTokens > afterThinking.conversationTokens)
        }
    }

    @Test func totalsFollowTurnsAndSummaryChanges() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.turns = [ChatTurn(role: .user, content: "Hi")]
            expectMatches(session)
            let small = session.transcriptTokenTotals()

            session.turns.append(
                ChatTurn(role: .assistant, content: String(repeating: "x", count: 6_000)))
            expectMatches(session)
            #expect(session.transcriptTokenTotals().outputTokens > small.outputTokens)

            session.turns = []
            expectMatches(session)
            #expect(session.transcriptTokenTotals().outputTokens == 0)
        }
    }

    @Test func repeatedReadsHitTheCache() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.turns = [
                ChatTurn(role: .user, content: "Question"),
                ChatTurn(role: .assistant, content: String(repeating: "a", count: 1_000)),
            ]
            let first = session.transcriptTokenTotals()
            let revision = ChatTurn.tokenEstimateRevision
            for _ in 0 ..< 5 {
                let again = session.transcriptTokenTotals()
                #expect(again.outputTokens == first.outputTokens)
                #expect(again.conversationTokens == first.conversationTokens)
            }
            // Reading never bumps the revision; only edits do.
            #expect(ChatTurn.tokenEstimateRevision == revision)
        }
    }
}
