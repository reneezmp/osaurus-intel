//
//  SessionAPIMappingTests.swift
//  OsaurusCoreTests
//
//  Mapping the Mac's stored chat sessions onto the JSON the Osaurus Connect
//  phone reads (`GET /sessions`, `GET /sessions/{id}`).
//
//  Intel (2026-10-30, `W-server-api` stage 5a): upstream's mapping cases.
//  Intel's turns don't store thinking time or per-call tool durations, so
//  those fields are checked as null. The cases about replaying a chat as a
//  run's history, phone-started chats and the paired key come with
//  `W-identity-mobile`.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SessionAPIMappingTests {
    @Test func queryItemsParsesFiltersAndDecodesPercentEscapes() {
        let items = HTTPHandler.queryItems(from: "/sessions?agent_id=ABC&limit=25&title=hello%20there")
        #expect(items["agent_id"] == "ABC")
        #expect(items["limit"] == "25")
        #expect(items["title"] == "hello there")
        #expect(HTTPHandler.queryItems(from: "/sessions").isEmpty)
    }

    @Test func assistantTurnCarriesThinkingAndToolCalls() throws {
        let call = ToolCall(
            id: "call-1",
            type: "function",
            function: ToolCallFunction(name: "web_search", arguments: #"{"q":"x"}"#)
        )
        let turn = ChatTurnData(
            id: UUID(),
            role: .assistant,
            content: "Here you go",
            toolCalls: [call],
            toolResults: ["call-1": "ok"],
            thinking: "weighing options",
            createdAt: Date(),
            generationTokenCount: 42
        )
        let dto = try #require(HTTPHandler.turn(for: turn))
        #expect(dto.role == "assistant")
        #expect(dto.content == "Here you go")
        #expect(dto.thinking == "weighing options")
        #expect(dto.thinking_duration_ms == nil)
        #expect(dto.token_count == 42)
        let calls = try #require(dto.tool_calls)
        #expect(calls.count == 1)
        #expect(calls[0].name == "web_search")
        #expect(calls[0].result == "ok")
        #expect(calls[0].duration_ms == nil)
    }

    @Test func toolResultTurnsAreFoldedAway() {
        let turn = ChatTurnData(id: UUID(), role: .tool, content: "raw result", toolCallId: "call-1", createdAt: Date())
        #expect(HTTPHandler.turn(for: turn) == nil)
    }

    @Test func userTurnReportsAttachmentsWithoutInliningThem() throws {
        let turn = ChatTurnData(id: UUID(), role: .user, content: "look at this", createdAt: Date())
        let dto = try #require(HTTPHandler.turn(for: turn))
        #expect(dto.role == "user")
        #expect(dto.attachment_count == 0)
        #expect(dto.thinking == nil)
        #expect(dto.tool_calls == nil)
    }

    @MainActor
    @Test func summaryCarriesTheHistoryListFields() {
        let session = ChatSessionData(
            title: "Bitcoin price",
            selectedModel: "qwen3",
            turns: [],
            pinned: true
        )
        let dto = HTTPHandler.summary(for: session)
        #expect(dto.id == session.id.uuidString)
        #expect(dto.title == "Bitcoin price")
        #expect(dto.selected_model == "qwen3")
        #expect(dto.pinned)
        #expect(!dto.archived)
        #expect(dto.source == "chat")
        #expect(dto.origin == "mac")
    }

    @MainActor
    @Test func truncatingAnUnknownChatChangesNothing() {
        #expect(RemoteSessionContinuation.truncate(UUID(), fromTurnId: UUID()) == .sessionNotFound)
    }
}
