//
//  EmbeddingClient.swift
//  OsaurusCore (Intel fork)
//
//  Resolves the active embedding backend from `MemoryConfiguration` and embeds
//  text. The bundled static (model2vec) embedder is loaded once and cached —
//  it pins ~30 MB of matrix in RAM, so we don't rebuild it per call.
//

#if OSAURUS_INTEL
import Foundation

public actor EmbeddingClient {
    public static let shared = EmbeddingClient()

    private var staticEmbedder: StaticEmbedder?

    /// The backend for the given config, or nil when embeddings are disabled
    /// (`embeddingProvider == "none"` → recall falls back to FTS5 text search).
    /// For the static backend this triggers a one-time model download on first
    /// use (cached thereafter); the actor serializes so it downloads only once.
    public func backend(for config: MemoryConfiguration) async throws -> EmbeddingBackend? {
        switch config.embeddingProvider {
        case "none":
            return nil
        case "cloud":
            guard let endpoint = config.cloudEmbeddingEndpoint, !endpoint.isEmpty,
                let model = config.cloudEmbeddingModel, !model.isEmpty
            else {
                throw EmbeddingError.notConfigured("cloud embedding endpoint/model missing")
            }
            return CloudEmbedder(
                endpoint: endpoint, model: model, dimension: config.embeddingDimensionality)
        default:  // "staticLocal"
            if let e = staticEmbedder { return e }
            // Do NOT auto-download here — recall/index gracefully fall back to
            // FTS5 until the user downloads the model from the Memory tab. This
            // avoids a surprise ~30 MB fetch on first chat.
            guard StaticEmbeddingModel.isAvailable else { return nil }
            let e = try StaticEmbedder(modelDirectory: StaticEmbeddingModel.cacheDirectory)
            staticEmbedder = e
            return e
        }
    }

    /// Explicitly download + cache the static model (user-initiated from the
    /// Memory tab). After this, `backend(for:)` will load it.
    public func downloadStaticModel() async throws {
        _ = try await StaticEmbeddingModel.ensureAvailable()
        staticEmbedder = nil  // force reload on next backend()
    }

    /// Load the static embedder if the model is already cached (no download).
    /// Safe to call at startup when memory is enabled.
    public func prewarm(for config: MemoryConfiguration) async {
        guard config.embeddingProvider == "staticLocal", StaticEmbeddingModel.isAvailable else { return }
        _ = try? await backend(for: config)
    }

    /// The active backend's `identifier` (or nil when disabled), computed from
    /// config WITHOUT forcing a model load/download. Persisted with vectors so a
    /// backend switch can be detected and trigger a re-embed.
    public nonisolated func activeIdentifier(for config: MemoryConfiguration) -> String? {
        switch config.embeddingProvider {
        case "none":
            return nil
        case "cloud":
            guard let model = config.cloudEmbeddingModel, !model.isEmpty else { return nil }
            return "cloud:\(model):\(config.embeddingDimensionality)"
        default:
            return "static:\(StaticEmbeddingModel.modelId):\(StaticEmbeddingModel.dimension)"
        }
    }

    public func embed(_ texts: [String], config: MemoryConfiguration) async throws -> [[Float]] {
        guard let backend = try await backend(for: config) else { return [] }
        return try await backend.embed(texts)
    }

    public func embedOne(_ text: String, config: MemoryConfiguration) async throws -> [Float]? {
        try await embed([text], config: config).first
    }
}
#endif
