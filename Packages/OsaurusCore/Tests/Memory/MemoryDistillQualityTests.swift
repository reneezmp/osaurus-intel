import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

/// Distillate quality on the shapes the bb10 native replay left in its memory
/// DB (`handoff-20261026T0926Z/memory.sqlite`): a user's one-off instruction
/// pinned verbatim, identity "facts" that only say a fact is missing, and
/// function-word FTS matches that recalled the instruction for an unrelated
/// question.
///
/// Intel (2026-10-27): upstream #3210's file against `IntelMemoryService`.
/// The two end-to-end tests that script the core model through
/// `setDistillGenerateOverrideForTests` / `flushSessionAndWait` are omitted:
/// Intel's distiller calls `CloudChatEngine` and has neither seam. The
/// delegated-marker test passes a project id because Intel's distillation is
/// opt-in per agent and a project chat still buffers.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MemoryDistillQualityTests {
    /// Verbatim pinned fact 10924993… (episode 37) from the replay DB.
    private static let staleInstruction =
        "Use file_read to read probe.json in the working folder. Return its current value without modifying any file."

    // MARK: - Screen

    @Test func verbatimUserTurnIsNotPinnedButRestatedFactsAre() {
        let parsed = MemoryService.DistillResult(
            pinnedCandidates: [
                .init(content: Self.staleInstruction, salience: 0.8, tags: []),
                .init(content: "  use FILE_READ to read probe.json in the working folder.  return its current value without modifying any file  ", salience: 0.8, tags: []),
                .init(content: "User prefers metric units.", salience: 0.7, tags: ["preference"]),
            ])
        let screened = MemoryDistillateScreen.screen(
            parsed, userMessages: [Self.staleInstruction, "I prefer metric units"])
        #expect(screened.pinnedCandidates.map(\.content) == ["User prefers metric units."])
    }

    @Test func absenceStatementsFromTheReplayAreRejected() {
        for fact in [
            "User's name is not specified", "User works at not specified", "No identity-relevant facts found",
            "No identity facts found", "Unknown", "N/A", "User's location is unknown",
        ] {
            #expect(MemoryDistillateScreen.isAbsenceStatement(fact), "\(fact)")
        }
    }

    @Test func verbatimDurableStatementsAndPreferencesRemainPinned() {
        let facts = [
            "My sailboat is named Peregrine Dusk.",
            "My name is Eric.",
            "I prefer metric units.",
            "Use metric units for measurements.",
        ]
        let parsed = MemoryService.DistillResult(pinnedCandidates: facts.map {
            .init(content: $0, salience: 0.7, tags: [])
        })
        let screened = MemoryDistillateScreen.screen(parsed, userMessages: facts)
        #expect(screened.pinnedCandidates.map(\.content) == facts)
        #expect(MemoryDistillateScreen.screen(
            .init(pinnedCandidates: [.init(content: Self.staleInstruction, salience: 0.8, tags: [])]),
            userMessages: [Self.staleInstruction]
        ).pinnedCandidates.isEmpty)
    }

    @Test func realFactsThatMentionAbsenceSurvive() {
        for fact in [
            "User's name is Eric", "User is not available on weekends",
            "User wants no information shared with third parties", "User works at Unknown Worlds Entertainment",
            "User has no pets",
            "User wants their salary not disclosed to coworkers",
            "User prefers forms where optional information is not provided",
            "User studies reports about no identity facts found",
        ] {
            #expect(!MemoryDistillateScreen.isAbsenceStatement(fact), "\(fact)")
        }
    }

    @Test func failedDelegatedMarkerWriteDoesNotEnqueueUserAttributedSignal() async throws {
        try await ChatHistoryTestStorage.run {
            MemoryConfigurationStore.invalidateCache()
            MemoryDatabase.shared.close()
            try MemoryDatabase.shared.open()
            defer {
                MemoryDatabase.shared.close()
                MemoryConfigurationStore.invalidateCache()
            }
            var config = MemoryConfiguration.default
            config.enabled = true
            config.extractionMode = .manual
            MemoryConfigurationStore.save(config)
            let connection = try EncryptedSQLiteOpener.open(
                path: OsaurusPaths.memoryDatabaseFile().path, key: try StorageKeyManager.shared.currentKey())
            defer { sqlite3_close(connection) }
            let trigger = """
                CREATE TRIGGER reject_delegated_marker BEFORE INSERT ON delegated_conversations
                BEGIN SELECT RAISE(ABORT, 'controlled delegated marker failure'); END;
                """
            try #require(sqlite3_exec(connection, trigger, nil, nil, nil) == SQLITE_OK)
            let conversation = UUID().uuidString
            let agent = UUID().uuidString
            let project = UUID()
            let before = await MemoryService.shared.bufferTelemetry()
            await MemoryService.shared.bufferTurn(userMessage: "Delegating agent instructions",
                assistantMessage: "Worker result", agentId: agent, conversationId: conversation,
                projectId: project, provenance: .delegated)
            #expect(try MemoryDatabase.shared.loadPendingSignals(conversationId: conversation).isEmpty)
            #expect(try !MemoryDatabase.shared.isDelegatedConversation(conversation))
            let after = await MemoryService.shared.bufferTelemetry()
            #expect(after.insertFailures == before.insertFailures + 1)
            try #require(sqlite3_exec(connection, "DROP TRIGGER reject_delegated_marker", nil, nil, nil) == SQLITE_OK)
            // Positive control: the same common buffer accepts a normal user
            // turn once marker failure has prevented the delegated enqueue.
            await MemoryService.shared.bufferTurn(userMessage: "My own statement",
                assistantMessage: "Noted", agentId: agent, conversationId: conversation, projectId: project)
            #expect(try MemoryDatabase.shared.loadPendingSignals(conversationId: conversation).count == 1)
            #expect(try !MemoryDatabase.shared.isDelegatedConversation(conversation))

            // And a delegated turn that does record its marker is attributed.
            let delegatedConversation = UUID().uuidString
            await MemoryService.shared.bufferTurn(userMessage: "Delegating agent instructions",
                assistantMessage: "Worker result", agentId: agent, conversationId: delegatedConversation,
                projectId: project, provenance: .delegated)
            #expect(try MemoryDatabase.shared.isDelegatedConversation(delegatedConversation))
            #expect(try MemoryDatabase.shared.loadPendingSignals(conversationId: delegatedConversation).count == 1)
        }
    }

    // MARK: - FTS recall terms

    @Test func functionWordsNoLongerRecallAnUnrelatedInstruction() throws {
        let db = MemoryDatabase()
        try db.openInMemory()
        defer { db.close() }
        try db.insertPinnedFact(PinnedFact(agentId: "a", content: Self.staleInstruction, salience: 0.8))
        try db.insertPinnedFact(PinnedFact(agentId: "a", content: "The user's sailboat is named Peregrine Dusk.", salience: 0.6))

        // "the", "of" and "is" used to OR-match the instruction.
        #expect(try db.searchPinnedFactsText(query: "What is the capital of France?", agentId: "a").isEmpty)
        // Content words still recall, with function words around them.
        let boat = try db.searchPinnedFactsText(query: "What is the name of my boat?", agentId: "a")
        #expect(boat.map(\.content) == ["The user's sailboat is named Peregrine Dusk."])
    }

    @Test func memoryAndKnowledgeDropTheSameFunctionWords() {
        #expect(MemoryDatabase.ftsMatchQuery("What is the capital of France?") == "\"capital\"* OR \"France\"*")
        #expect(KnowledgeDatabase.ftsMatchQuery("What is the capital of France?") == "\"capital\"* OR \"France\"*")
        // A query made only of function words keeps them, so it still matches.
        #expect(MemoryDatabase.ftsMatchQuery("to be or not") == "\"to\"* OR \"be\"* OR \"or\"* OR \"not\"*")
    }

    /// Intel: upstream #1815's knowledge half. Intel AND-joined unquoted
    /// terms, so a full-sentence question had to match every word in one chunk.
    @Test func knowledgeQueryIsOrPrefixedAndQuoted() {
        #expect(
            KnowledgeDatabase.ftsMatchQuery("How do refunds work for customers?")
                == "\"refunds\"* OR \"work\"* OR \"customers\"*")
        #expect(KnowledgeDatabase.ftsMatchQuery("AI v2") == "\"AI\"* OR \"v2\"*")
        #expect(KnowledgeDatabase.ftsMatchQuery("(*) ?") == nil)
    }
}
