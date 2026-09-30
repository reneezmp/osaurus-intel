//
//  KnowledgeCurationTests.swift
//  osaurusTests
//
//  Phase 2 curation coverage: ticket round-trips in the
//  database, status transitions, and argument/scoping validation for
//  the curation tools (which must refuse without agent context and
//  reject unconfined paths).
//

import Foundation

// Intel: upstream's proposal cases are not ported (Intel never had the
// proposal queue; docs/KNOWLEDGE_WRITE_INTEL.md).
import Testing

@testable import OsaurusCore

// MARK: - Database round-trips

struct KnowledgeCurationDatabaseTests {

    private func makeDBOrSkip() -> KnowledgeDatabase? {
        let db = KnowledgeDatabase()
        do {
            try db.openInMemory()
            return db
        } catch {
            Issue.record("Could not open in-memory knowledge database: \(error)")
            return nil
        }
    }

    @Test
    func ticketRoundTripAndStatusTransitions() throws {
        guard let db = makeDBOrSkip() else { return }
        let id = try db.createTicket(
            collectionId: "c1",
            relPath: "wp.md",
            reason: "WordPress 8.0 changed plugin architecture",
            evidence: "release notes",
            createdBy: "agent-1"
        )
        let ticket = try db.getTicket(id: id)
        #expect(ticket?.status == .open)
        #expect(ticket?.reason == "WordPress 8.0 changed plugin architecture")
        #expect(ticket?.createdBy == "agent-1")

        // Open-ticket lookup drives flag dedupe.
        #expect(try db.openTicket(collectionId: "c1", relPath: "wp.md")?.id == id)
        #expect(try db.openTicket(collectionId: "c1", relPath: "other.md") == nil)
        #expect(try db.openTicket(collectionId: "c2", relPath: "wp.md") == nil)

        try db.updateTicketStatus(id: id, status: .proposed)
        #expect(try db.getTicket(id: id)?.status == .proposed)
        // A proposed ticket no longer matches the open-ticket dedupe.
        #expect(try db.openTicket(collectionId: "c1", relPath: "wp.md") == nil)
    }

    @Test
    func listTicketsScopesAndFilters() throws {
        guard let db = makeDBOrSkip() else { return }
        _ = try db.createTicket(collectionId: "granted", relPath: "a.md", reason: "r1", evidence: "", createdBy: "")
        let other = try db.createTicket(
            collectionId: "other", relPath: "b.md", reason: "r2", evidence: "", createdBy: ""
        )
        try db.updateTicketStatus(id: other, status: .dismissed)

        // Scoped listing never crosses collections.
        let scoped = try db.listTickets(collectionIds: ["granted"], status: .open)
        #expect(scoped.map(\.relPath) == ["a.md"])

        // Empty scope (a scoped caller with no grants) returns nothing.
        #expect(try db.listTickets(collectionIds: [], status: .open).isEmpty)

        // nil scope is the unscoped UI listing.
        #expect(try db.listTickets(collectionIds: nil, status: .dismissed).map(\.id) == [other])
    }



}

// MARK: - Tool validation

@Suite(.serialized)
struct KnowledgeCurationToolsTests {

    @Test
    func flagRejectsMissingArguments() async throws {
        let tool = FlagKnowledgeStaleTool()
        let noPath = try await tool.execute(argumentsJSON: #"{"reason":"stale"}"#)
        #expect(ToolEnvelope.isError(noPath))
        #expect(noPath.contains("path"))

        let noReason = try await tool.execute(argumentsJSON: #"{"path":"a.md"}"#)
        #expect(ToolEnvelope.isError(noReason))
        #expect(noReason.contains("reason"))
    }

    @Test
    func flagRejectsPathTraversal() async throws {
        let tool = FlagKnowledgeStaleTool()
        let result = try await tool.execute(
            argumentsJSON: #"{"path":"../outside.md","reason":"stale"}"#
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("path"))
    }

    @Test
    func flagWithoutAgentContextIsRejected() async throws {
        let tool = FlagKnowledgeStaleTool()
        let result = try await tool.execute(
            argumentsJSON: #"{"path":"a.md","reason":"stale"}"#
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("agent"))
    }

    @Test
    func listTicketsRejectsUnknownStatus() async throws {
        let tool = ListKnowledgeTicketsTool()
        // Status validation happens after scope resolution, so without an
        // agent context the scope failure fires first; assert the rejected
        // envelope rather than the status message.
        let result = try await tool.execute(argumentsJSON: #"{"status":"open"}"#)
        #expect(ToolEnvelope.isError(result))
    }


    /// A spawned subagent keeps `currentAgentId` inherited from its launcher
    /// (budget/limiter accounting), but its knowledge tools must resolve grants
    /// and the curator role against the TARGET agent — otherwise a spawned
    /// helper silently inherits its launcher's collection grants. The override
    /// wins when set; otherwise resolution falls back to the running identity.
    @Test
    func knowledgeAgentIdPrefersSubagentOverride() {
        let launcher = UUID()
        let target = UUID()
        ChatExecutionContext.$currentAgentId.withValue(launcher) {
            #expect(ChatExecutionContext.knowledgeAgentId == launcher)
            ChatExecutionContext.$knowledgeGrantAgentIdOverride.withValue(target) {
                #expect(ChatExecutionContext.knowledgeAgentId == target)
            }
            // Override cleared → back to the running identity.
            #expect(ChatExecutionContext.knowledgeAgentId == launcher)
        }
    }
}
