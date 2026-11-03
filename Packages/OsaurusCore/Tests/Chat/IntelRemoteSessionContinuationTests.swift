//
//  IntelRemoteSessionContinuationTests.swift
//  OsaurusCoreTests
//
//  `W-identity-mobile` stage 3b (docs/IDENTITY_MOBILE_INTEL.md): a paired
//  phone continuing one of the Mac's chats. Upstream's
//  `RemoteSessionContinuationTests` cases that apply to Intel's chat store
//  (its database replay cases don't), plus the Intel pieces: the run's
//  turns built from its stream, the phone's messages saved as sent, and the
//  chats the phone starts.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct IntelRemoteSessionContinuationTests {

    // MARK: Upstream cases

    @Test func storedTurnsBecomeModelMessages() throws {
        let call = ToolCall(id: "c1", type: "function", function: ToolCallFunction(name: "web_search", arguments: "{}"))
        let user = try #require(
            RemoteSessionContinuation.message(from: ChatTurnData(id: UUID(), role: .user, content: "hi", createdAt: Date())))
        #expect(user.role == "user")
        #expect(user.content == "hi")

        let assistant = try #require(
            RemoteSessionContinuation.message(
                from: ChatTurnData(id: UUID(), role: .assistant, content: "", toolCalls: [call], createdAt: Date())))
        #expect(assistant.tool_calls?.count == 1)
        #expect(assistant.content == nil)

        let toolTurn = try #require(
            RemoteSessionContinuation.message(
                from: ChatTurnData(id: UUID(), role: .tool, content: "result", toolCallId: "c1", createdAt: Date())))
        #expect(toolTurn.tool_call_id == "c1")
    }

    @Test func emptyAndExcludedTurnsAreSkipped() {
        #expect(
            RemoteSessionContinuation.message(
                from: ChatTurnData(id: UUID(), role: .assistant, content: "", createdAt: Date())) == nil)
        #expect(
            RemoteSessionContinuation.message(
                from: ChatTurnData(id: UUID(), role: .system, content: "prompt", createdAt: Date())) == nil)
        var excluded = ChatTurnData(id: UUID(), role: .user, content: "old", createdAt: Date())
        excluded.modelContextExcluded = true
        #expect(RemoteSessionContinuation.message(from: excluded) == nil)
    }

    @Test func runRequestCanStartAChat() throws {
        let json = #"""
            {"messages":[{"role":"user","content":"hi"}],"model":"",
             "osaurus_session_id":"abc","osaurus_create_session":true}
            """#
        let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(request.osaurus_session_id == "abc")
        #expect(request.osaurus_create_session == true)
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!encoded.contains("osaurus_create_session"))
        #expect(!encoded.contains("osaurus_session_id"))
    }

    @Test func aChatThePhoneStartedIsAnOrdinaryChatShownAsThePhones() {
        let started = ChatSessionData(externalSessionKey: RemoteSessionContinuation.phoneChatKey)
        #expect(RemoteSessionContinuation.isFromPairedPhone(started))
        // The marker only counts on an ordinary chat.
        let other = ChatSessionData(source: .http, externalSessionKey: RemoteSessionContinuation.phoneChatKey)
        #expect(!RemoteSessionContinuation.isFromPairedPhone(other))
        #expect(!RemoteSessionContinuation.isFromPairedPhone(ChatSessionData()))
    }

    @Test func onlyThePairedKeyCountsAsThePhone() {
        #expect(!RemoteSessionContinuation.isPairedPhoneKey(nil))
        #expect(!RemoteSessionContinuation.isPairedPhoneKey("not-the-pairing-key"))
        guard let paired = MobilePairingService.shared.pairedKeyNonce else { return }
        #expect(RemoteSessionContinuation.isPairedPhoneKey(paired.uppercased()))
        #expect(!RemoteSessionContinuation.isPairedPhoneKey(paired + "x"))
    }

    // MARK: Intel: history from the chat store

    @Test func historyReplaysTheChatAsTheMacWouldSendIt() {
        let call = ToolCall(id: "c1", type: "function", function: ToolCallFunction(name: "web_search", arguments: "{}"))
        var corrected = ChatTurnData(id: UUID(), role: .assistant, content: "wrong", createdAt: Date())
        corrected.modelContextExcluded = true
        let session = ChatSessionData(turns: [
            ChatTurnData(id: UUID(), role: .user, content: "find it", createdAt: Date()),
            ChatTurnData(
                id: UUID(), role: .assistant, content: "", toolCalls: [call], toolResults: ["c1": "found"],
                createdAt: Date()),
            ChatTurnData(id: UUID(), role: .tool, content: "found", toolCallId: "c1", createdAt: Date()),
            corrected,
            ChatTurnData(id: UUID(), role: .assistant, content: "Here it is", thinking: "looked", createdAt: Date()),
        ])
        ChatSessionsManager.shared.save(session)
        defer { ChatSessionsManager.shared.delete(id: session.id) }

        let history = RemoteSessionContinuation.history(for: session.id, model: "m")
        #expect(history.map(\.role) == ["user", "assistant", "tool", "assistant"])
        #expect(history[3].content == "Here it is")
        #expect(history[3].reasoning_content == "looked")
        #expect(RemoteSessionContinuation.history(for: UUID(), model: "m").isEmpty)
    }

    @Test func aCompactionSummaryStandsInForTheTurnsItCovers() {
        let first = ChatTurnData(id: UUID(), role: .user, content: "long ago", createdAt: Date())
        let second = ChatTurnData(id: UUID(), role: .assistant, content: "old reply", createdAt: Date())
        let third = ChatTurnData(id: UUID(), role: .user, content: "recent", createdAt: Date())
        var session = ChatSessionData(turns: [first, second, third])
        session.conversationSummary = ConversationSummary(
            summaryText: "They talked about the past.", coveredTurnIds: [first.id, second.id],
            modelIdentifier: "m", savedTokensEstimate: 10)
        ChatSessionsManager.shared.save(session)
        defer { ChatSessionsManager.shared.delete(id: session.id) }

        let history = RemoteSessionContinuation.history(for: session.id, model: "m")
        #expect(history.count == 2)
        #expect(history[0].content == session.conversationSummary?.contextMessageText)
        #expect(history[1].content == "recent")
    }

    // MARK: Intel: what a run saves

    @Test func thePhonesMessagesAreSavedAsSent() throws {
        let pixel = Data([0x89, 0x50, 0x4E, 0x47])
        let call = ToolCall(id: "c1", type: "function", function: ToolCallFunction(name: "f", arguments: "{}"))
        let turns = RemoteSessionContinuation.turns(from: [
            ChatMessage(role: "system", content: "dropped"),
            ChatMessage(
                role: "user", content: "look",
                contentParts: [.text("look"), .imageUrl(url: "data:image/png;base64,\(pixel.base64EncodedString())", detail: nil)]),
            ChatMessage(role: "assistant", content: nil, tool_calls: [call]),
            ChatMessage(role: "tool", content: "done", tool_call_id: "c1"),
        ])
        #expect(turns.map(\.role) == [.user, .assistant, .tool])
        #expect(turns[0].content == "look")
        #expect(turns[0].attachments.images == [pixel])
        // The result is also on the call, where the Mac's window reads it.
        #expect(turns[1].toolResults["c1"] == "done")
    }

    @Test func theRunsTranscriptFollowsTheMacsChatWindow() {
        let transcript = PhoneRunTranscript()
        transcript.reasoning("thinking")
        transcript.content("Let me look. ")
        transcript.toolDone(callId: "c1", name: "web_search", arguments: "{}", result: "found")
        transcript.content("Wrong answer")
        transcript.groundedRetry()
        transcript.content("Right answer")
        let turns = transcript.finished()
        #expect(turns.map(\.role) == [.assistant, .tool, .assistant, .assistant])
        #expect(turns[0].content == "Let me look. ")
        #expect(turns[0].thinking == "thinking")
        #expect(turns[0].toolCalls?.first?.id == "c1")
        #expect(turns[0].toolResults["c1"] == "found")
        #expect(turns[1].toolCallId == "c1")
        #expect(turns[2].modelContextExcluded)
        #expect(turns[3].content == "Right answer")
        #expect(!turns[3].modelContextExcluded)
    }

    @Test func aReplyEndingOnAToolLeavesNoEmptyTurn() {
        let transcript = PhoneRunTranscript()
        transcript.toolDone(callId: "c1", name: "complete", arguments: "{}", result: "ok")
        #expect(transcript.finished().map(\.role) == [.assistant, .tool])
        #expect(PhoneRunTranscript().finished().isEmpty)
    }

    // MARK: Intel: the phone's own chats and runs in flight

    @Test func thePhoneStartsAChatOnce() {
        let id = UUID()
        let agentId = UUID()
        defer { ChatSessionsManager.shared.delete(id: id) }
        let asked = [ChatMessage(role: "user", content: "Plan a trip to Lisbon")]
        #expect(RemoteSessionContinuation.startPhoneChat(id, agentId: agentId, messages: asked))
        let session = ChatSessionsManager.shared.session(for: id)
        #expect(session?.title == "Plan a trip to Lisbon")
        #expect(session?.agentId == agentId)
        #expect(session?.turns.isEmpty == true)
        #expect(session.map(RemoteSessionContinuation.isFromPairedPhone) == true)
        // An existing chat is never replaced.
        #expect(!RemoteSessionContinuation.startPhoneChat(id, agentId: agentId, messages: asked))
    }

    @Test func appendWritesToTheStoreWhenNoWindowHasTheChat() async {
        let session = ChatSessionData(turns: [ChatTurnData(id: UUID(), role: .user, content: "a", createdAt: Date())])
        ChatSessionsManager.shared.save(session)
        defer { ChatSessionsManager.shared.delete(id: session.id) }
        await RemoteSessionContinuation.append(
            [ChatTurnData(id: UUID(), role: .assistant, content: "b", createdAt: Date())], to: session.id,
            model: "phone-model")
        let stored = ChatSessionsManager.shared.session(for: session.id)
        #expect(stored?.turns.map(\.content) == ["a", "b"])
        #expect(stored?.selectedModel == "phone-model")
    }

    @Test func phoneRunsAreCountedPerChat() {
        let id = UUID()
        #expect(!RemoteSessionContinuation.isPhoneReplying(id))
        RemoteSessionContinuation.beginPhoneRun(id)
        RemoteSessionContinuation.beginPhoneRun(id)
        RemoteSessionContinuation.endPhoneRun(id)
        #expect(RemoteSessionContinuation.isPhoneReplying(id))
        RemoteSessionContinuation.endPhoneRun(id)
        #expect(!RemoteSessionContinuation.isPhoneReplying(id))
    }
}
