import Foundation
import Testing

@testable import OsaurusCore

@Suite("Pinned fact merge integrity", .serialized)
struct PinnedFactMergeTests {
    private func makeDB() throws -> MemoryDatabase {
        let db = MemoryDatabase()
        try db.openInMemory()
        return db
    }

    @Test("stored provider identity and declared dimension gate cosine")
    func compatibleEmbeddingSpacesRequireFullIdentity() {
        #expect(MemoryConsolidator.compatibleEmbeddingSpaces(
            [1, 0], 2, "static:potion-base-8M:256", [1, 0], 2, "static:potion-base-8M:256"))
        #expect(!MemoryConsolidator.compatibleEmbeddingSpaces(
            [1, 0], 2, "cloud:text-embedding-3-small:256", [1, 0], 2, "cloud:other-model:256"))
        #expect(!MemoryConsolidator.compatibleEmbeddingSpaces(
            [1, 0], 2, "static:potion-base-8M:256", [1, 0], 3, "static:potion-base-8M:256"))
        #expect(!MemoryConsolidator.compatibleEmbeddingSpaces(
            [1, 0], 2, "", [1, 0], 2, ""))
    }

    @Test("wording conflict vetoes negation and ordered singular values")
    func factualConflictVetoesCorrections() {
        #expect(TextSimilarity.factualConflict("User likes tea", "User does not like tea"))
        #expect(TextSimilarity.factualConflict("User's favorite is tea", "User's favorite is coffee"))
        #expect(TextSimilarity.factualConflict("User was born in 1980", "User was born in 1981"))
        #expect(TextSimilarity.factualConflict("User lives in Paris", "User lives in London"))
        #expect(TextSimilarity.factualConflict("User's model is llama", "User's model is mistral"))
        #expect(!TextSimilarity.factualConflict("User's favorite is tea", "The user's favorite is tea"))
    }

    @Test("survivor preserves aggregate metadata with saturation")
    func survivorRetainsEvidenceAndTags() {
        let survivor = PinnedFact(
            id: "winner", agentId: "a", content: "prefers tea", salience: 0.9,
            sourceCount: Int.max, sourceEpisodeId: 9, lastUsed: "2026-09-01T00:00:00Z",
            useCount: Int.max, createdAt: "2026-01-01T00:00:00Z", tagsCSV: "taste, hot")
        let retired = PinnedFact(
            id: "retired", agentId: "a", content: "prefers tea", salience: 0.4,
            sourceCount: 2, sourceEpisodeId: 3, lastUsed: "2026-09-02T00:00:00Z",
            useCount: 5, tagsCSV: "Hot, drink")
        let merged = MemoryConsolidator.mergedPinnedSurvivor(survivor, retired)
        #expect(merged.id == "winner")
        #expect(merged.sourceCount == Int.max)
        #expect(merged.useCount == Int.max)
        #expect(merged.sourceEpisodeId == 3)
        #expect(merged.lastUsed == "2026-09-02T00:00:00Z")
        #expect(merged.tags == ["taste", "hot", "drink"])
    }

    @Test("all metadata updates and duplicate removals commit together")
    func mergeApplicationIsAtomic() throws {
        let db = try makeDB()
        defer { db.close() }
        let winner = PinnedFact(id: "winner", agentId: "a", content: "prefers tea", salience: 0.9)
        let duplicate = PinnedFact(id: "duplicate", agentId: "a", content: "prefers tea", salience: 0.4)
        try db.insertPinnedFact(winner)
        try db.insertPinnedFact(duplicate)
        var merged = winner
        merged.sourceCount = 2
        merged.useCount = 4
        merged.tagsCSV = "taste"

        #expect(throws: Error.self) {
            try db.applyPinnedFactMerges([
                MemoryDatabase.PinnedFactMerge(survivor: merged, droppedIDs: ["duplicate", "missing"])
            ])
        }
        let remaining = try db.loadPinnedFacts(agentId: "a")
        #expect(remaining.count == 2)
        #expect(remaining.first { $0.id == "winner" }?.sourceCount == 1)
        #expect(remaining.first { $0.id == "duplicate" } != nil)
    }

    @Test("transaction preserves metadata updates made after planning")
    func mergeApplicationRefreshesMutableMetadata() throws {
        let db = try makeDB()
        defer { db.close() }
        let winner = PinnedFact(
            id: "winner", agentId: "a", content: "prefers tea", salience: 0.9,
            sourceCount: 1, useCount: 1, tagsCSV: "taste")
        let duplicate = PinnedFact(
            id: "duplicate", agentId: "a", content: "prefers tea", salience: 0.4,
            sourceCount: 2, useCount: 2, tagsCSV: "Taste, drink, DRINK")
        try db.insertPinnedFact(winner)
        try db.insertPinnedFact(duplicate)
        let planned = MemoryConsolidator.mergedPinnedSurvivor(winner, duplicate)

        // Simulate recall activity after the consolidator loaded its snapshot.
        try db.bumpPinnedFactUsage(ids: ["winner", "duplicate"])
        #expect(try db.applyPinnedFactMerges([
            MemoryDatabase.PinnedFactMerge(survivor: planned, droppedIDs: ["duplicate"])
        ]) == 1)

        let remaining = try db.loadPinnedFacts(agentId: "a")
        #expect(remaining.count == 1)
        #expect(remaining[0].sourceCount == 3)
        #expect(remaining[0].useCount == 5)
        #expect(remaining[0].tags == ["taste", "drink"])
    }

    @Test("a stronger bridge survivor rescans earlier non-matches into one plan")
    func bridgeClusterDoesNotCreateOverlappingPlans() async throws {
        let db = MemoryDatabase.shared
        db.close()
        try db.openInMemory()
        defer { db.close() }
        let a = PinnedFact(id: "a", agentId: "bridge", content: "first note", salience: 0.5)
        let b = PinnedFact(id: "b", agentId: "bridge", content: "stronger note", salience: 0.9)
        let x = PinnedFact(id: "x", agentId: "bridge", content: "third note", salience: 0.4)
        try db.insertPinnedFact(a)
        try db.insertPinnedFact(b)
        try db.insertPinnedFact(x)
        // A~B and B~X exceed .75 while A~X does not. B replaces A as the
        // survivor, so a correct planner must rescan X against B rather than
        // emit two plans that both touch B.
        try db.setPinnedFactEmbedding(factId: "a", embedding: [1, 0], provider: "test:bridge:2")
        try db.setPinnedFactEmbedding(factId: "b", embedding: [0.8, 0.6], provider: "test:bridge:2")
        try db.setPinnedFactEmbedding(factId: "x", embedding: [0.28, 0.96], provider: "test:bridge:2")

        #expect(await MemoryConsolidator.shared.mergePinnedFacts(threshold: 0.75) == 2)
        let remaining = try db.loadPinnedFacts(agentId: "bridge")
        #expect(remaining.map(\.id) == ["b"])
        #expect(remaining[0].sourceCount == 3)
    }
}

@Suite("Episode merge integrity")
struct EpisodeMergeIntegrityTests {
    @Test("provider/model mismatch blocks same-dimension episode cosine")
    func incompatibleEpisodeProvidersAreRejected() {
        #expect(!MemoryConsolidator.compatibleEmbeddingSpaces(
            [1, 0, 0], 3, "cloud:text-embedding-3-small:3",
            [1, 0, 0], 3, "cloud:text-embedding-3-large:3"))
    }

    @Test("summary corrections are vetoed before an episode deletion")
    func contradictoryEpisodeSummariesAreRejected() {
        #expect(TextSimilarity.factualConflict(
            "The user does not want notifications.",
            "The user wants notifications."))
        #expect(TextSimilarity.factualConflict(
            "The user was born in 1980.",
            "The user was born in 1981."))
        #expect(TextSimilarity.factualConflict(
            "The user lives in Paris.",
            "The user lives in London."))
    }
}
