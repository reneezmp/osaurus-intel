//
//  IntelChatDisplayReauditTests.swift
//  osaurusTests
//
//  `W-cov-reaudit` stage 3b-1 (docs/COV_REAUDIT.md): chat display fixes
//  Intel's own copies were missing.
//  - #1468: Esc cancels an alert or a clarify prompt instead of closing the
//    window, and a dismissed clarify question stays in the transcript.
//  - #1939 / #1655: user messages carry their time and the reply that
//    answered them; replies carry their time for the "…" menu header.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct IntelEscapeCascadeTests {
    private let scope = ThemedAlertScope.chat(UUID())

    @Test func escCancelsTheAlertThroughItsCancelButton() {
        var cancelled = false
        var dismissed = false
        let request = ThemedAlertRequest(
            title: "Keep this chat running?",
            message: nil,
            buttons: [.cancel("Cancel") { cancelled = true }, .primary("Keep") {}],
            onDismiss: { dismissed = true }
        )
        ThemedAlertCenter.shared.present(request, scope: scope)
        #expect(ThemedAlertCenter.shared.cancelActive(scope: scope))
        #expect(cancelled)
        #expect(dismissed)
        #expect(ThemedAlertCenter.shared.active(for: scope) == nil)
    }

    @Test func anAlertWithoutCancelStillSwallowsEsc() {
        let request = ThemedAlertRequest(
            title: "Working…", message: nil, buttons: [.primary("OK") {}], onDismiss: {})
        ThemedAlertCenter.shared.present(request, scope: scope)
        // Handled (so the window underneath doesn't close), alert stays.
        #expect(ThemedAlertCenter.shared.cancelActive(scope: scope))
        #expect(ThemedAlertCenter.shared.active(for: scope)?.id == request.id)
        ThemedAlertCenter.shared.dismiss(scope: scope, id: request.id)
    }

    @Test func noAlertFallsThrough() {
        #expect(!ThemedAlertCenter.shared.cancelActive(scope: .chat(UUID())))
    }

    @Test func userCancelFiresBothCallbacksOnce() {
        var userCancels = 0
        var cancels = 0
        let state = ClarifyPromptState(
            question: "Which file?", onSubmit: { _ in },
            onCancel: { cancels += 1 }, onUserCancel: { userCancels += 1 })
        PromptItem.clarify(state).cancelByUser()
        state.cancelByUser()
        #expect(userCancels == 1)
        #expect(cancels == 1)
    }

    @Test func teardownCancelLeavesNoTrace() {
        var userCancels = 0
        let state = ClarifyPromptState(
            question: "Which file?", onSubmit: { _ in }, onUserCancel: { userCancels += 1 })
        state.cancel()
        #expect(userCancels == 0)
    }

    @Test func aDismissedQuestionStaysInTheTranscript() {
        let session = ChatSession()
        session.turns = [ChatTurn(role: .user, content: "Tidy my notes")]
        session.appendClarifyQuestionTrace(
            ClarifyPayload(question: "Which folder?", options: ["Work", "Home"], allowMultiple: false))
        let last = session.turns.last
        #expect(last?.role == .assistant)
        #expect(last?.content == "Which folder?\n\n- Work\n- Home")
    }
}

@Suite
struct IntelMessageTimestampBlockTests {
    private func userBlock(_ blocks: [ContentBlock]) -> (Date, UUID?)? {
        for block in blocks {
            if case let .userMessage(_, _, timestamp, responseTurnId, _) = block.kind {
                return (timestamp, responseTurnId)
            }
        }
        return nil
    }

    @Test func userMessageCarriesItsTimeAndReply() throws {
        let sent = Date(timeIntervalSince1970: 1_800_000_000)
        let user = ChatTurn(role: .user, content: "hi", createdAt: sent)
        let reply = ChatTurn(role: .assistant, content: "hello")
        let blocks = BlockMemoizer().blocks(from: [user, reply], agentName: "A")
        let (timestamp, responseTurnId) = try #require(userBlock(blocks))
        #expect(timestamp == sent)
        #expect(responseTurnId == reply.id)
    }

    @Test func noReplyYetMeansNoInspect() throws {
        let blocks = BlockMemoizer().blocks(from: [ChatTurn(role: .user, content: "hi")], agentName: "A")
        let (_, responseTurnId) = try #require(userBlock(blocks))
        #expect(responseTurnId == nil)
    }

    @Test func replyActionsCarryTheReplyTime() {
        let answered = Date(timeIntervalSince1970: 1_800_000_100)
        let reply = ChatTurn(role: .assistant, content: "hello", createdAt: answered)
        let blocks = BlockMemoizer().blocks(
            from: [ChatTurn(role: .user, content: "hi"), reply], agentName: "A")
        let times = blocks.compactMap { block -> Date? in
            if case let .assistantActions(_, timestamp) = block.kind { return timestamp }
            return nil
        }
        #expect(times == [answered])
    }

    @Test func aNewReplyChangesTheUserBlock() {
        let now = Date()
        let a = ContentBlockKind.userMessage(
            text: "hi", attachments: [], timestamp: now, responseTurnId: nil, envelope: nil)
        let b = ContentBlockKind.userMessage(
            text: "hi", attachments: [], timestamp: now, responseTurnId: UUID(), envelope: nil)
        #expect(a != b)
        #expect(a == a)
    }
}
