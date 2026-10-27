//
//  IntelProviderDiscoveryExtras.swift
//  osaurus
//
//  Intel (2026-10-27, `W-providers-ux`): two discovery refinements upstream
//  keeps in the excluded `RemoteProviderService`, for Intel's own discovery
//  in `RemoteProviderManager` (`probeModelsDiscovery`, `testConnection`).
//
//  - Fireworks: `/inference/v1/models` lists only the account's
//    deployed/default serverless models, so the serverless gateway catalog is
//    merged in (best effort; `/models` stays first and authoritative).
//  - MCP URL pasted as a provider: after `/models` fails with an HTTP error
//    on an OpenAI-compatible provider, an MCP `initialize` handshake at the
//    base URL decides whether to replace the error with guidance pointing at
//    Tools & MCP (`RemoteProviderMCPDetection`).
//
//  Both take a `transport` so tests never reach the network.
//

import Foundation

enum IntelProviderDiscoveryExtras {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let defaultTransport: Transport = { request in
        try await GlobalProxySettings.makeSession().data(for: request)
    }

    // MARK: - Fireworks

    static let fireworksCatalogURL = "https://api.fireworks.ai/v1/accounts/fireworks/models"
    static let fireworksCatalogMaxPages = 25

    /// Fireworks by host (the host may embed a path, e.g.
    /// "api.fireworks.ai/inference"), on an OpenAI-compatible provider.
    static func isFireworksProvider(_ provider: RemoteProvider) -> Bool {
        guard provider.providerType == .openaiLegacy else { return false }
        let host = provider.host.lowercased()
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        return host == "fireworks.ai" || host.hasSuffix(".fireworks.ai")
    }

    /// `/models` results first (the account's own deployments), then catalog
    /// entries, case-insensitively deduplicated.
    static func mergeFireworksModelIds(discovered: [String], catalog: [String]) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []
        for id in discovered + catalog {
            let key = id.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(id)
        }
        return merged
    }

    static func decodeFireworksCatalogPage(data: Data) throws -> (models: [String], nextPageToken: String?) {
        let page = try JSONDecoder().decode(FireworksModelsPage.self, from: data)
        let models = (page.models ?? []).filter { $0.isServerlessChatModel }.map { $0.name }
        return (models, page.nextPageToken)
    }

    /// Page through the serverless gateway catalog. Throws on any HTTP or
    /// decode failure so the caller can fall back to `/models` alone.
    static func fetchFireworksCatalogModels(
        headers: [String: String],
        timeout: TimeInterval = 20,
        transport: Transport = defaultTransport
    ) async throws -> [String] {
        var all: [String] = []
        var pageToken: String?
        for _ in 0 ..< fireworksCatalogMaxPages {
            guard var components = URLComponents(string: fireworksCatalogURL) else { throw URLError(.badURL) }
            var items = [URLQueryItem(name: "pageSize", value: "200")]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = items
            guard let url = components.url else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200 ... 299).contains(http.statusCode) else {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            let page = try decodeFireworksCatalogPage(data: data)
            all.append(contentsOf: page.models)
            guard let next = page.nextPageToken, !next.isEmpty else { break }
            pageToken = next
        }
        return all
    }

    /// `/models` plus the catalog; on any catalog failure, `/models` alone.
    static func augmentFireworks(
        discovered: [String],
        headers: [String: String],
        transport: Transport = defaultTransport
    ) async -> [String] {
        do {
            let catalog = try await fetchFireworksCatalogModels(headers: headers, transport: transport)
            return mergeFireworksModelIds(discovered: discovered, catalog: catalog)
        } catch {
            NSLog("[RemoteProviderManager] Fireworks catalog discovery failed, using /models only: \(error.localizedDescription)")
            return discovered
        }
    }

    // MARK: - MCP URL pasted as a provider

    struct MCPEndpointDetected: LocalizedError {
        var errorDescription: String? { RemoteProviderMCPDetection.guidance() }
    }

    /// Whether `baseURL` answers an MCP `initialize` handshake like an MCP
    /// server. Only for OpenAI-compatible providers; any transport failure
    /// returns false so the original error stands.
    static func looksLikeMCPServer(
        providerType: RemoteProviderType,
        baseURL: URL?,
        headers: [String: String],
        transport: Transport = defaultTransport
    ) async -> Bool {
        guard providerType == .openaiLegacy || providerType == .openResponses, let url = baseURL else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Tighter than discovery: a streamable HTTP server may hold the SSE
        // response open, and this only refines an error message.
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = MCPAuthFailureProbe.handshakeBody()
        guard let (data, response) = try? await transport(request), let http = response as? HTTPURLResponse
        else { return false }
        return RemoteProviderMCPDetection.looksLikeMCPServer(response: http, body: data)
    }
}
