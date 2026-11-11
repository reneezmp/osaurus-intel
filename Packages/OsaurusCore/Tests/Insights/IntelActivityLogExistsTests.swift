//
//  IntelActivityLogExistsTests.swift
//  osaurusTests
//
//  `ActivityLogStore.exists` answers presence with a bare `SELECT 1`, without
//  decoding the row's payload (upstream #3289).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ActivityLogStore presence checks")
struct IntelActivityLogExistsTests {
    @Test func existsByTurnAndRequestId() throws {
        let store = ActivityLogStore()
        try store.openInMemory()
        let turn = UUID()
        _ = try store.append(
            RequestLog(
                source: .chatUI, turnId: turn, requestId: "req-1",
                method: "POST", path: "/chat/completions", statusCode: 200, durationMs: 5,
                requestBody: "{}", responseBody: "ok", model: "m"
            )
        )
        #expect(try store.exists(turnId: turn))
        #expect(!(try store.exists(turnId: UUID())))
        #expect(try store.exists(requestId: "req-1"))
        #expect(!(try store.exists(requestId: "nope")))
    }
}
