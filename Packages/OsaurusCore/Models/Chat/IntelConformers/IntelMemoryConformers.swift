//
//  IntelMemoryConformers.swift
//  OsaurusCore (Intel fork)
//
//  Intel memory search/index service. Replaces the upstream VecturaKit-backed
//  `MemorySearchService` (VecturaKit is a no-op stub on Intel): transcript turns
//  are embedded with the pure-Swift/cloud `EmbeddingClient` and stored as float32
//  BLOBs in the (now-compiled, SQLCipher-encrypted) transcript table; recall is
//  brute-force cosine via Accelerate, with FTS5 text search as a fallback when no
//  embedder is configured or no vectors exist yet.
//

#if OSAURUS_INTEL
import Accelerate
import Foundation

final class MemorySearchService: @unchecked Sendable {
    static let shared = MemorySearchService()
    private init() {}

    /// Open the memory DB (if enabled) and prewarm the local embedder so the
    /// first recall isn't delayed by a model download.
    func initialize() async {
        let cfg = MemoryConfigurationStore.load()
        guard cfg.enabled else { return }
        do {
            try MemoryDatabase.shared.open()
        } catch {
            MemoryLogger.database.warning("Intel memory DB open failed: \(error)")
        }
        await EmbeddingClient.shared.prewarm(for: cfg)
    }

    /// Embed a freshly-inserted transcript turn and persist its vector (matched
    /// by composite key). No-op when memory or embeddings are disabled.
    func indexTranscriptTurn(_ turn: TranscriptTurn) async {
        let cfg = MemoryConfigurationStore.load()
        guard cfg.enabled, cfg.embeddingProvider != "none" else { return }
        let content = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        do {
            guard let vec = try await EmbeddingClient.shared.embedOne(content, config: cfg),
                !vec.isEmpty
            else { return }
            let provider = EmbeddingClient.shared.activeIdentifier(for: cfg) ?? "unknown"
            try MemoryDatabase.shared.setTranscriptEmbedding(
                agentId: turn.agentId, conversationId: turn.conversationId,
                chunkIndex: turn.chunkIndex, embedding: vec, provider: provider)
        } catch {
            MemoryLogger.database.warning("Intel indexTranscriptTurn failed: \(error)")
        }
    }

    /// Semantic recall over stored transcript embeddings (cosine top-k), with an
    /// FTS5 text-search fallback when embeddings are unavailable.
    func searchTranscript(
        query: String, agentId: String? = nil, days: Int = 365, topK: Int = 10
    ) async -> [TranscriptTurn] {
        let cfg = MemoryConfigurationStore.load()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if cfg.embeddingProvider != "none",
            let qvec = try? await EmbeddingClient.shared.embedOne(trimmed, config: cfg),
            !qvec.isEmpty,
            let rows = try? MemoryDatabase.shared.loadEmbeddedTranscript(
                agentId: agentId, days: days, limit: 1000), !rows.isEmpty
        {
            let scored =
                rows
                .compactMap { row -> (TranscriptTurn, Float)? in
                    guard row.vector.count == qvec.count else { return nil }
                    return (row.turn, Self.cosine(qvec, row.vector))
                }
                .sorted { $0.1 > $1.1 }
            return Array(scored.prefix(topK).map { $0.0 })
        }

        return
            (try? MemoryDatabase.shared.searchTranscriptText(
                query: trimmed, agentId: agentId, days: days, limit: topK)) ?? []
    }

    /// Clearing memory deletes the DB file directly (see the Intel Memory view),
    /// which removes stored vectors too — so there's nothing extra to wipe here.
    func clearIndex() async {}

    /// Cosine similarity. Inputs are typically L2-normalized (static + OpenAI
    /// embeddings are), but we divide by norms to be safe.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 1e-12 ? dot / denom : 0
    }
}
#endif
