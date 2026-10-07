//
//  IntelUpstreamBatch1007Tests.swift
//  osaurusTests
//
//  Intel ports from the 2026-10-07 upstream audit
//  (docs/UPSTREAM_AUDIT_2026-10-07.md).
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct IntelUpstreamBatch1007Tests {
    // MARK: #2922 — cleaned, cached visible content

    @Test("Finished replies hide a leaked tool-call JSON block; the cache follows edits")
    func visibleContentCleansAndInvalidates() {
        let leaked = #"Done.\n{"name": "file_read", "arguments": {"path": "a.txt"}}"#
        let turn = ChatTurn(role: .assistant, content: leaked)
        #expect(!turn.visibleContent.contains("file_read"))
        turn.appendContent(" More text.")
        #expect(turn.visibleContent.contains("More text."))
        turn.content = "Plain answer"
        #expect(turn.visibleContent == "Plain answer")
        // User turns are never cleaned.
        let user = ChatTurn(role: .user, content: leaked)
        #expect(user.visibleContent == leaked)
    }

    @Test("The transcript shows the raw stream while it arrives, the cleaned text after")
    func paragraphUsesVisibleContentWhenDone() {
        let leaked = #"Answer.\n{"name": "file_read", "arguments": {"path": "a.txt"}}"#
        let turn = ChatTurn(role: .assistant, content: leaked)
        func paragraph(_ streaming: UUID?) -> String? {
            BlockMemoizer().unrolledBlocks(from: [turn], streamingTurnId: streaming).compactMap { block in
                if case let .paragraph(_, text, _, _) = block.kind { return text }
                return nil
            }.first
        }
        #expect(paragraph(turn.id) == leaked)
        #expect(paragraph(nil)?.contains("file_read") == false)
    }

    // MARK: #3007 — schedules never reattach

    @Test("Dispatch requests reattach by default; schedules opt out")
    func reattachFlag() {
        #expect(DispatchRequest(prompt: "x", externalSessionKey: "k").reattachSession)
        #expect(!DispatchRequest(prompt: "x", externalSessionKey: "k", reattachSession: false).reattachSession)
    }

    // MARK: #3018 — busy port retry

    @Test("A busy port is recognised in NIO's and POSIX's wording")
    func addressInUse() {
        struct E: Error, CustomStringConvertible { let description: String }
        #expect(AppDelegate.isAddressInUse(E(description: "bind(descriptor:ptr:bytes:): Address already in use (errno: 48)")))
        #expect(!AppDelegate.isAddressInUse(E(description: "Permission denied")))
        #expect(AppDelegate.serverBindAttempts == 6)
    }

    // MARK: #2239 (found) — shared event loop group

    @Test("The server restarts on the shared event loop group and stops in bounded time")
    func serverRestartsOnSharedGroup() async throws {
        let server = OsaurusServer()
        try await server.start(.init(host: "127.0.0.1", port: 0, trustLoopback: true))
        let started = Date()
        #expect(await server.stop(gracefully: false))
        #expect(Date().timeIntervalSince(started) < 3)
        try await server.start(.init(host: "127.0.0.1", port: 0, trustLoopback: true))
        _ = await server.stop(gracefully: false)
        #expect(ConnectionLimitHandler.maxConcurrentConnections == 512)
    }
}
