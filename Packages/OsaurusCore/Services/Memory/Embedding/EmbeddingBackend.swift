//
//  EmbeddingBackend.swift
//  OsaurusCore (Intel fork)
//
//  Pluggable text→vector embedding for the Intel memory system. The Apple-
//  Silicon build embeds via VecturaKit (MLX/CoreML); that whole library is a
//  no-op stub on Intel, so here embeddings come from either a bundled pure-Swift
//  model2vec embedder (`StaticEmbedder`) or an OpenAI-compatible cloud API
//  (`CloudEmbedder`). See `docs`/the memory plan for the rationale.
//

#if OSAURUS_INTEL
import Foundation

/// A source of text embeddings. Implementations return exactly one
/// L2-normalized vector per input string, each of length `dimension`.
public protocol EmbeddingBackend: Sendable {
    /// Vector length produced by this backend.
    var dimension: Int { get }
    /// Stable `backend:model:dim` identifier, persisted alongside stored vectors
    /// so a backend/model switch can be detected (→ re-embed).
    var identifier: String { get }
    /// Embed a batch of strings. Order of results matches the input order.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public enum EmbeddingError: LocalizedError {
    case modelMissing(String)
    case notConfigured(String)
    case httpError(status: Int, message: String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let p): return "Embedding model resource missing: \(p)"
        case .notConfigured(let d): return "Embedding backend not configured: \(d)"
        case .httpError(let s, let m): return "Embedding API error \(s): \(m)"
        case .malformedResponse(let d): return "Malformed embedding response: \(d)"
        }
    }
}
#endif
