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
//  - Venice (2026-10-28, `W-media-generation`): `/models?type=all` splits
//    chat ids from the billable image/video catalog (`VeniceModelDiscovery`).
//
//  All take a `transport` so tests never reach the network.
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

    // MARK: - Venice (`W-media-generation`)

    /// Upstream `RemoteProviderService.isVeniceProvider`: by exact host.
    static func isVeniceProvider(_ provider: RemoteProvider) -> Bool {
        provider.host.lowercased() == "api.venice.ai"
    }

    /// Upstream `fetchVeniceModelsDiscovery`: Venice's `/models?type=all`
    /// also lists billable image/video models. Text ids go to chat; the
    /// rest becomes the provider's media catalog. nil on any failure, so
    /// the caller falls back to the plain `/models` probe (chat only).
    static func fetchVeniceModelsDiscovery(
        provider: RemoteProvider,
        headers: [String: String],
        transport: Transport = defaultTransport
    ) async -> VeniceModelDiscovery? {
        guard let url = provider.url(for: "/models?type=all") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        for (name, value) in headers where isSafeHeader(name: name, value: value) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return try VeniceModelDiscovery.decode(data, providerID: provider.id, providerName: provider.name)
        } catch {
            NSLog("[RemoteProviderManager] Venice media discovery failed, using /models only: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Headers and manual model fallback (upstream `RemoteProviderService`)

    /// Rejects header names/values `URLRequest` can choke on — CR/LF (header
    /// injection / request splitting) and other C0 controls or DEL — and
    /// empty names, so a malformed custom header is dropped, not sent.
    static func isSafeHeader(name: String, value: String) -> Bool {
        if name.isEmpty { return false }
        let hasControl: (String) -> Bool = { text in
            text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        }
        return !hasControl(name) && !hasControl(value)
    }

    /// Upstream `manualModelDiscoveryFallback`: the typed model ids of an
    /// OpenAI-compatible (OpenAI, Responses, Azure) provider, trimmed and
    /// de-duplicated case-insensitively; nil for other types or no ids.
    static func manualModels(providerType: RemoteProviderType, manualModelIds: [String]) -> [String]? {
        guard providerType == .openaiLegacy || providerType == .openResponses || providerType == .azureOpenAI
        else { return nil }
        var seen = Set<String>()
        var manual: [String] = []
        for raw in manualModelIds {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { continue }
            manual.append(value)
        }
        return manual.isEmpty ? nil : manual
    }

    /// Upstream `canUseManualModelDiscoveryFallback` + fallback: an
    /// OpenAI-compatible server without a usable `/models` route (these
    /// statuses) still connects when the user typed model ids.
    static func manualModelFallback(
        providerType: RemoteProviderType, statusCode: Int, manualModelIds: [String]
    ) -> [String]? {
        guard [400, 404, 405, 406, 410, 415, 422, 501].contains(statusCode) else { return nil }
        return manualModels(providerType: providerType, manualModelIds: manualModelIds)
    }

    // MARK: - Discovery errors and decoding (upstream `RemoteProviderService`)

    /// Upstream `RemoteProviderServiceError.requestFailed` for discovery: the
    /// provider answered with an HTTP error (or a body that is not a model
    /// list). The message is the provider's own, so a bad key reads as a bad
    /// key instead of "connected, 0 models".
    struct RequestFailed: LocalizedError {
        let message: String
        var errorDescription: String? {
            L("Request failed: \(ProviderDiagnosticRedactor.safe(message, maxLength: 500))")
        }
    }

    /// Upstream `RemoteProviderServiceError.noModelsAvailable` (a Gemini key
    /// that lists no chat models).
    struct NoModelsAvailable: LocalizedError {
        var errorDescription: String? { L("No models available from provider") }
    }

    /// Upstream `extractErrorMessage` for a discovery body: a JSON error
    /// reads as its message; anything else is shown raw (capped) behind the
    /// HTTP status so a gateway error page is still identifiable.
    static func discoveryErrorMessage(statusCode: Int, body: Data) -> String {
        let text = String(data: body, encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "HTTP \(statusCode): Unknown error" }
        if (try? JSONSerialization.jsonObject(with: body)) is [String: Any] {
            return extractAPIErrorMessage(trimmed)
        }
        return "HTTP \(statusCode): \(extractAPIErrorMessage(trimmed))"
    }

    /// Upstream `fetchGeminiModels`: only models that support
    /// `generateContent`, with the `models/` prefix stripped; an empty result
    /// is an error.
    static func geminiModelIds(from data: Data) throws -> [String] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RequestFailed(message: "Invalid /models response")
        }
        let models = (json["models"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
            guard let methods = entry["supportedGenerationMethods"] as? [String],
                methods.contains("generateContent"),
                let name = entry["name"] as? String
            else { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
        }
        guard !models.isEmpty else { throw NoModelsAvailable() }
        return models
    }

    /// Upstream `decodeOpenAICompatibleModelsDiscovery` (2xx part) for a
    /// `/models` body. A list that cannot be read falls back to the typed
    /// model ids when the provider type allows it, else throws, so a wrong
    /// URL that answers 200 with a web page is not "connected, 0 models".
    /// `{"data": null}` (Ollama with no models) is a valid empty list.
    static func decodeModelList(
        data: Data, providerType: RemoteProviderType, manualModelIds: [String]
    ) throws -> (ids: [String], contextLengths: [String: Int]) {
        if providerType == .gemini {
            return (try geminiModelIds(from: data), [:])
        }
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if json["data"] is NSNull { return ([], [:]) }
            if let arr = json["data"] as? [[String: Any]] {
                var ids: [String] = []
                var lengths: [String: Int] = [:]
                for entry in arr {
                    guard let id = entry["id"] as? String else { continue }
                    ids.append(id)
                    if let n = RemoteProviderManager.advertisedContextLength(in: entry) { lengths[id] = n }
                }
                return (ids, lengths)
            }
            if let arr = json["models"] as? [[String: Any]] {
                return (arr.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }, [:])
            }
        }
        if let manual = manualModels(providerType: providerType, manualModelIds: manualModelIds) {
            return (manual, [:])
        }
        throw RequestFailed(message: "Invalid /models response")
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
