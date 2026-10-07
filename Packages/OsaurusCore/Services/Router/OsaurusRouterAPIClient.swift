import Foundation

actor OsaurusRouterAPIClient {
    static let shared = OsaurusRouterAPIClient()

    private let baseURL: URL
    private let session: URLSession
    private let searchSession: URLSession
    private let signer: OsaurusRouterAuthSigner
    private let authOverride: (@Sendable (inout URLRequest, Data?) async throws -> Void)?
    private let decoder: JSONDecoder

    init(
        baseURL: URL = OsaurusRouter.defaultBaseURL,
        session: URLSession? = nil,
        searchSession: URLSession? = nil,
        signer: OsaurusRouterAuthSigner = OsaurusRouterAuthSigner(),
        authOverride: (@Sendable (inout URLRequest, Data?) async throws -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.signer = signer
        self.authOverride = authOverride
        self.session = session ?? Self.makeSession()
        self.searchSession = searchSession ?? session ?? Self.makeSearchSession()
        self.decoder = JSONDecoder()
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        return GlobalProxySettings.makeSession(base: config)
    }

    static func makeSearchSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        return GlobalProxySettings.makeSession(base: config)
    }

    func health() async throws {
        let url = try url(path: "/health")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
    }

    func balance() async throws -> OsaurusRouterBalanceResponse {
        try await get("/credits/balance")
    }

    func checkout(amountMicro: String) async throws -> OsaurusRouterCheckoutResponse {
        struct Body: Encodable { let amount_micro: String }
        return try await post("/credits/checkout", body: Body(amount_micro: amountMicro))
    }

    func redeemCode(_ code: String) async throws -> OsaurusRouterRedeemCodeResponse {
        struct Body: Encodable { let code: String }
        return try await post("/credits/redeem", body: Body(code: code))
    }

    func models() async throws -> [OsaurusRouterModel] {
        let response: OsaurusRouterModelListResponse = try await get("/models")
        return response.data
    }

    func estimate(model: String, inputTokens: Int, maxTokens: Int) async throws -> OsaurusRouterEstimateResponse {
        struct Body: Encodable {
            let model: String
            let input_tokens: Int
            let max_tokens: Int
        }
        return try await post(
            "/credits/estimate",
            body: Body(model: model, input_tokens: inputTokens, max_tokens: maxTokens)
        )
    }

    func usage(limit: Int = 50, cursor: String? = nil) async throws -> OsaurusRouterUsageResponse {
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await get("/credits/usage", queryItems: queryItems)
    }

    func transactions(limit: Int = 50, cursor: String? = nil) async throws -> OsaurusRouterTransactionsResponse {
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await get("/credits/transactions", queryItems: queryItems)
    }

    func webSearch(_ body: OsaurusRouterWebSearchRequestBody) async throws -> OsaurusRouterWebSearchResponse {
        try await post(
            "/v1/search", body: body, session: searchSession,
            idempotencyKey: body.idempotency_key)
    }

    func webContents(_ body: OsaurusRouterWebContentsRequestBody) async throws -> OsaurusRouterWebContentsResponse {
        try await post(
            "/v1/contents", body: body, session: searchSession,
            idempotencyKey: body.idempotency_key)
    }

    func webSettings() async throws -> OsaurusRouterWebSettingsResponse {
        try await get("/credits/web-settings")
    }

    func updateWebSettings(autoPayEnabled: Bool) async throws -> OsaurusRouterWebSettingsResponse {
        struct Body: Encodable { let auto_pay_enabled: Bool }
        return try await post("/credits/web-settings", body: Body(auto_pay_enabled: autoPayEnabled))
    }

    func webUsage(limit: Int = 50, cursor: String? = nil) async throws -> OsaurusRouterWebUsageResponse {
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty { queryItems.append(.init(name: "cursor", value: cursor)) }
        return try await get("/credits/web-usage", queryItems: queryItems)
    }

    func signedJSONRequest(method: String, path: String, body: Data? = nil) async throws -> URLRequest {
        let url = try url(path: path)
        return try await signedJSONRequest(method: method, url: url, body: body)
    }

    func signedJSONRequest(method: String, url: URL, body: Data? = nil) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        try await sign(request: &request, body: body)
        return request
    }

    private func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        let url = try url(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await sign(request: &request, body: Data())
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        return try decoder.decode(T.self, from: data)
    }

    private func post<Body: Encodable, T: Decodable>(
        _ path: String,
        body: Body,
        session overrideSession: URLSession? = nil,
        idempotencyKey: String? = nil
    ) async throws -> T {
        let bodyData = try JSONEncoder.osaurusCanonical(prettyPrinted: false).encode(body)
        var request = try await signedJSONRequest(method: "POST", path: path, body: bodyData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        let (data, response) = try await perform(request, session: overrideSession)
        try ensureOK(data: data, response: response)
        return try decoder.decode(T.self, from: data)
    }

    /// `GET /announcements?app_version=…` — the live community announcements.
    /// Unauthenticated (onboarding users have no wallet yet) and IP
    /// rate-limited; a 429 surfaces as `.rateLimited(retryAfter:)` so the
    /// caller can back off. `appVersion` lets operators bound an
    /// announcement to a build range (Intel sends none; see
    /// `AnnouncementsService`).
    func announcements(appVersion: String?) async throws -> OsaurusRouterAnnouncementsResponse {
        var queryItems: [URLQueryItem] = []
        if let appVersion, !appVersion.isEmpty {
            queryItems.append(URLQueryItem(name: "app_version", value: appVersion))
        }
        let url = try url(path: "/announcements", queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        return try decoder.decode(OsaurusRouterAnnouncementsResponse.self, from: data)
    }

    private func perform(_ request: URLRequest, session overrideSession: URLSession? = nil) async throws -> (Data, URLResponse) {
        // Activity log: every signed control-plane call (account, credits,
        // workspaces, media, pairing) is cloud egress. Hosted search and
        // contents are excluded here because `SearchActivityLogger` records
        // them as web-search / URL-extract rows with the query and URLs.
        let logged = Self.shouldLogControlPlaneCall(path: request.url?.path)
        let attribution = logged ? InsightsService.ActivityAttribution.current() : .none
        let started = Date()
        do {
            let result = try await (overrideSession ?? session).data(for: request)
            if logged {
                Self.logControlPlaneCall(
                    request: request, response: result.1 as? HTTPURLResponse,
                    responseBytes: result.0.count, error: nil,
                    durationMs: Date().timeIntervalSince(started) * 1000, attribution: attribution)
            }
            return result
        } catch {
            if logged {
                Self.logControlPlaneCall(
                    request: request, response: nil, responseBytes: nil, error: error.localizedDescription,
                    durationMs: Date().timeIntervalSince(started) * 1000, attribution: attribution)
            }
            throw OsaurusRouterAPIError.transport(error.localizedDescription)
        }
    }

    /// Hosted search/contents are logged by the search layer with richer
    /// facts; everything else on the Router is a control-plane call. The
    /// unauthenticated announcements feed and health probe carry no account
    /// data (no wallet headers, no body) and are excluded like theme fetches
    /// and the appcast.
    nonisolated static func shouldLogControlPlaneCall(path: String?) -> Bool {
        guard let path else { return true }
        return path != "/v1/search" && path != "/v1/contents"
            && path != "/announcements" && path != "/health"
    }

    /// Plain-language purpose for a Router path, so the activity row reads
    /// "Credits balance" rather than a bare URL.
    nonisolated static func controlPlanePurpose(path: String) -> String {
        let p = path.lowercased()
        if p.contains("/workspace") { return L("Workspaces") }
        if p.contains("/credit") || p.contains("/balance") || p.contains("/billing") { return L("Credits") }
        if p.contains("/media") { return L("Media generation") }
        if p.contains("/pair") || p.contains("/relay") { return L("Secure channel pairing") }
        if p.contains("/account") || p.contains("/identity") || p.contains("/me") { return L("Account") }
        if p.contains("/models") { return L("Model catalog") }
        return L("Router control plane")
    }

    nonisolated static func logControlPlaneCall(
        request: URLRequest,
        response: HTTPURLResponse?,
        responseBytes: Int?,
        error: String?,
        durationMs: Double,
        attribution: InsightsService.ActivityAttribution
    ) {
        let path = request.url?.path ?? "/"
        let host = request.url?.host
        let status = response?.statusCode ?? (error == nil ? 200 : 0)
        let isError = error != nil || !(200 ..< 300).contains(status)
        var details: [String: String] = [
            "purpose": controlPlanePurpose(path: path),
            "method": request.httpMethod ?? "GET",
        ]
        if let query = request.url?.query, !query.isEmpty { details["query_string"] = query }
        if let error { details["error"] = error }
        InsightsService.logEgress(
            category: .routerControl,
            source: .system,
            method: request.httpMethod ?? "GET",
            path: path,
            statusCode: status,
            durationMs: durationMs,
            egress: EgressInfo(
                destinationLabel: L("Osaurus Router"),
                destinationHost: host,
                bytesSent: request.httpBody?.count ?? 0,
                bytesReceived: responseBytes,
                dataClasses: ["account"],
                details: details
            ),
            errorMessage: isError ? (error ?? "HTTP \(status)") : nil,
            attribution: attribution
        )
    }


    private func sign(request: inout URLRequest, body: Data?) async throws {
        if let authOverride {
            try await authOverride(&request, body)
        } else {
            try await signer.sign(request: &request, body: body)
        }
    }

    private func ensureOK(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OsaurusRouterAPIError.invalidResponse
        }
        guard !(200 ..< 300).contains(http.statusCode) else { return }

        if let envelope = try? decoder.decode(OsaurusRouterErrorEnvelope.self, from: data) {
            throw OsaurusRouterAPIError.from(
                code: envelope.error.code,
                message: envelope.error.message,
                status: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "retry-after")
            )
        }

        let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
        throw OsaurusRouterAPIError.server(code: "HTTP_\(http.statusCode)", message: message, status: http.statusCode)
    }

    private func url(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw OsaurusRouterAPIError.invalidURL
        }
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        components.path = normalizedPath
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw OsaurusRouterAPIError.invalidURL
        }
        return url
    }
}
