//
//  IntelInsufficientFundsRetryTests.swift
//  OsaurusCoreTests
//
//  Stage 5c row 14 (upstream Classic `ChatSession.noteInsufficientFundsIfNeeded`
//  and friends): a Router 402 shows the friendly line, opens the "out of
//  credits" notice, and after a top-up offers a retry of exactly the blocked
//  turn. Balance reads are injected: no network, identity or keychain.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct IntelInsufficientFundsRetryTests {
    private static let routerError = CloudChatError.httpError(
        provider: "Osaurus Router",
        status: 402,
        message: "{\"error\":{\"code\":\"INSUFFICIENT_FUNDS\",\"message\":\"balance below estimated max cost\"}}"
    )

    private static func makeSession(
        engine: FundsScriptedEngine,
        router: Bool = true,
        balance: BalanceBox
    ) -> ChatSession {
        let session = ChatSession()
        session.chatEngineFactory = { engine }
        session.isRouterBilledForInsufficientFunds = { router }
        session.routerBalanceRefresh = { balance.micro }
        session.routerBalanceMicro = { balance.micro }
        return session
    }

    @Test
    func routerOutOfCredits_showsFriendlyLineAndNotice() async throws {
        try await ChatHistoryTestStorage.run {
            let balance = BalanceBox(micro: 0)
            let session = Self.makeSession(engine: FundsScriptedEngine(failFirst: Self.routerError), balance: balance)

            session.send("Hello")
            try await Self.waitUntil { session.insufficientFundsAlert }

            let assistant = try #require(session.turns.last(where: { $0.role == .assistant }))
            #expect(assistant.content == "Error: You're out of credits. Add credits to continue.")
            #expect(session.insufficientFundsTurnId == assistant.id)
            // Never starts anything by itself: no retry alert yet.
            #expect(!session.topUpRetryAlert)
        }
    }

    @Test
    func topUp_offersRetry_andRetryRegeneratesTheBlockedTurn() async throws {
        try await ChatHistoryTestStorage.run {
            let balance = BalanceBox(micro: 0)
            let engine = FundsScriptedEngine(failFirst: Self.routerError)
            let session = Self.makeSession(engine: engine, balance: balance)

            session.send("Hello")
            try await Self.waitUntil { session.balanceMicroAtInsufficientFunds != nil }

            // A refresh that changes nothing must not prompt.
            session.handleBalanceChangeForRetry()
            #expect(!session.topUpRetryAlert)

            balance.micro = 5_000_000
            session.handleBalanceChangeForRetry()
            #expect(session.topUpRetryAlert)

            session.retryInsufficientFundsTurn()
            #expect(!session.topUpRetryAlert)
            #expect(session.insufficientFundsTurnId == nil)
            try await Self.waitUntil { session.turns.contains { $0.content.contains("Recovered") } }
            #expect(await engine.callCount == 2)
        }
    }

    @Test
    func movingOnClearsTheRetryState() async throws {
        try await ChatHistoryTestStorage.run {
            let balance = BalanceBox(micro: 0)
            let session = Self.makeSession(engine: FundsScriptedEngine(failFirst: Self.routerError), balance: balance)

            session.send("Hello")
            try await Self.waitUntil { session.balanceMicroAtInsufficientFunds != nil }
            session.turns.append(ChatTurn(role: .user, content: "newer message"))

            balance.micro = 5_000_000
            session.handleBalanceChangeForRetry()

            #expect(!session.topUpRetryAlert)
            #expect(session.insufficientFundsTurnId == nil)
        }
    }

    @Test
    func nonRouterSessionAndOtherErrorsDoNotOpenTheNotice() async throws {
        try await ChatHistoryTestStorage.run {
            let balance = BalanceBox(micro: 0)
            let other = ChatSession()
            other.chatEngineFactory = { FundsScriptedEngine(failFirst: Self.routerError) }
            other.routerBalanceRefresh = { balance.micro }
            other.send("Hello")
            try await Self.waitUntil { other.lastStreamError != nil }
            #expect(!other.insufficientFundsAlert)

            let plain = Self.makeSession(
                engine: FundsScriptedEngine(failFirst: URLError(.timedOut)),
                balance: balance
            )
            plain.send("Hello")
            try await Self.waitUntil { plain.lastStreamError != nil }
            #expect(!plain.insufficientFundsAlert)
        }
    }

    private static func waitUntil(_ predicate: @MainActor @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "IntelInsufficientFundsRetryTests", code: 1)
    }
}

@MainActor
private final class BalanceBox {
    var micro: Int64
    init(micro: Int64) { self.micro = micro }
}

/// Fails the first request with `failFirst`, then streams "Recovered".
private actor FundsScriptedEngine: ChatEngineProtocol {
    private let failFirst: Error
    private(set) var callCount = 0

    init(failFirst: Error) { self.failFirst = failFirst }

    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        callCount += 1
        if callCount == 1 { throw failFirst }
        return AsyncThrowingStream { continuation in
            continuation.yield("Recovered")
            continuation.finish()
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "IntelInsufficientFundsRetryTests", code: 2)
    }
}
