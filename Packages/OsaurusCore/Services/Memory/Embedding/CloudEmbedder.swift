//
//  CloudEmbedder.swift
//  OsaurusCore (Intel fork)
//
//  OpenAI-compatible cloud embedder: POST {model, input} to a provider's
//  `/v1/embeddings`. Endpoint + auth are resolved from a matching configured
//  RemoteProvider (host match) + its Keychain key — the same plumbing
//  `CloudChatEngine` uses for chat.
//

#if OSAURUS_INTEL
import Foundation

public final class CloudEmbedder: EmbeddingBackend, @unchecked Sendable {
    public let dimension: Int
    public let identifier: String
    private let endpoint: String
    private let model: String

    public init(endpoint: String, model: String, dimension: Int) {
        self.endpoint = endpoint
        self.model = model
        self.dimension = dimension
        self.identifier = "cloud:\(model):\(dimension)"
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard let url = Self.embeddingsURL(from: endpoint) else {
            throw EmbeddingError.notConfigured("invalid embeddings endpoint: \(endpoint)")
        }
        let headers = await resolveHeaders(host: url.host)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["model": model, "input": texts])

        let (data, response) = try await GlobalProxySettings.makeSession().data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw EmbeddingError.httpError(status: status, message: String(msg.prefix(300)))
        }
        let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        return decoded.data.sorted { $0.index < $1.index }.map { $0.embedding }
    }

    /// Append `/embeddings` to a base like `https://api.openai.com/v1`.
    static func embeddingsURL(from base: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/embeddings") { return URL(string: trimmed) }
        let stripped = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: stripped + "/embeddings")
    }

    @MainActor
    private func resolveHeaders(host: String?) -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        guard let host else { return headers }
        let providers = RemoteProviderManager.shared.configuration.providers.filter { $0.enabled }
        guard let owner = providers.first(where: { $0.host == host }) else { return headers }
        for (k, v) in owner.customHeaders { headers[k] = v }
        if owner.authType == .apiKey,
            let key = RemoteProviderKeychain.getAPIKey(for: owner.id),
            !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch owner.providerType {
            case .anthropic: headers["x-api-key"] = key
            case .gemini: headers["x-goog-api-key"] = key
            default: headers["Authorization"] = "Bearer \(key)"
            }
        }
        return headers
    }

    private struct EmbeddingResponse: Decodable {
        struct Item: Decodable {
            let embedding: [Float]
            let index: Int
        }
        let data: [Item]
    }
}
#endif
