//
//  IntelChatSessionStreamErrorTests.swift
//  OsaurusCoreTests
//
//  Stage 5c row 15 (upstream Classic `ChatSession.send`'s catch blocks): a
//  Stop that lands mid-reply keeps the user turn and writes no error line; a
//  stream that fails after text has streamed keeps that text and adds the
//  error below it. (`ChatSessionStopTests` is excluded on Intel, so these
//  live here.)
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct IntelChatSessionStreamErrorTests {
    @Test
    func stop_midStreamLeavesNoErrorLine() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.chatEngineFactory = {
                ThrowsAfterTextChatEngine(error: CancellationError(), delay: .milliseconds(150))
            }

            session.send("Hello")
            try await Self.waitUntil(timeout: .seconds(3)) {
                session.turns.contains { $0.role == .assistant && $0.content.contains("Partial answer") }
            }
            session.stop()
            try await Task.sleep(for: .milliseconds(500))

            #expect(session.turns.first?.role == .user)
            #expect(session.turns.first?.content == "Hello")
            #expect(!session.turns.contains { $0.content.contains("Error:") })
            #expect(session.lastStreamError == nil)
        }
    }

    @Test
    func send_midStreamErrorIsAppendedBelowStreamedText() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.chatEngineFactory = {
                ThrowsAfterTextChatEngine(error: URLError(.networkConnectionLost), delay: .milliseconds(300))
            }

            session.send("Hello")
            try await Self.waitUntil(timeout: .seconds(5)) { session.lastStreamError != nil }

            let assistant = try #require(session.turns.last(where: { $0.role == .assistant }))
            #expect(assistant.content.hasPrefix("Partial answer"))
            let streamed = assistant.content.range(of: "Partial answer")
            let error = assistant.content.range(of: "Error:")
            #expect(streamed != nil && error != nil)
            if let streamed, let error { #expect(streamed.lowerBound < error.lowerBound) }
        }
    }

    @Test
    func send_errorBeforeAnyTextStandsAlone() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.chatEngineFactory = {
                ThrowsAfterTextChatEngine(error: URLError(.timedOut), delay: .milliseconds(20), text: nil)
            }

            session.send("Hello")
            try await Self.waitUntil(timeout: .seconds(5)) { session.lastStreamError != nil }

            let assistant = try #require(session.turns.last(where: { $0.role == .assistant }))
            #expect(assistant.content.hasPrefix("Error:"))
        }
    }

    @Test
    func theErrorLineFollowsStreamedTextAfterABlankLine() {
        #expect(ChatSession.streamErrorContent(streamed: "", message: "boom") == "Error: boom")
        #expect(ChatSession.streamErrorContent(streamed: "  \n", message: "boom") == "Error: boom")
        #expect(ChatSession.streamErrorContent(streamed: "Partial", message: "boom") == "Partial\n\nError: boom")
    }

    private static func waitUntil(timeout: Duration, _ predicate: @MainActor @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "IntelChatSessionStreamErrorTests", code: 3)
    }
}

private actor ThrowsAfterTextChatEngine: ChatEngineProtocol {
    let error: Error
    let delay: Duration
    let text: String?

    init(error: Error, delay: Duration, text: String? = "Partial answer") {
        self.error = error
        self.delay = delay
        self.text = text
    }

    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        let error = error, delay = delay, text = text
        return AsyncThrowingStream { continuation in
            if let text { continuation.yield(text) }
            Task {
                try? await Task.sleep(for: delay)
                continuation.finish(throwing: error)
            }
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "IntelChatSessionStreamErrorTests", code: 4)
    }
}
