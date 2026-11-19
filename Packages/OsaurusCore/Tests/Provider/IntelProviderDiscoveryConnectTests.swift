//
//  IntelProviderDiscoveryConnectTests.swift
//  osaurusTests
//
//  Stage 5d slice 4 (docs/COV_REAUDIT_STAGE5D_PROVIDER.md rows 16, 17, 18,
//  28, 43): model discovery errors and retry, the Router connect, parallel
//  refresh, Gemini model lists, disconnect, and the xAI token refresh.
//  Every network call goes through an injected transport or a URLProtocol
//  fixture; nothing touches the keychain, a provider or the Router.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Pure decoding (rows 16, 28)

@Suite
struct IntelDiscoveryDecodeTests {
    @Test func geminiKeepsGenerateContentModelsAndStripsThePrefix() throws {
        let body = """
            {"models":[
              {"name":"models/gemini-2.5-pro","supportedGenerationMethods":["generateContent","countTokens"]},
              {"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]},
              {"name":"models/imagen","supportedGenerationMethods":null},
              {"name":"gemini-bare","supportedGenerationMethods":["generateContent"]}
            ]}
            """
        let ids = try IntelProviderDiscoveryExtras.geminiModelIds(from: Data(body.utf8))
        #expect(ids == ["gemini-2.5-pro", "gemini-bare"])
    }

    @Test func geminiWithNoChatModelsIsAnError() {
        let body = #"{"models":[{"name":"models/e","supportedGenerationMethods":["embedContent"]}]}"#
        #expect(throws: IntelProviderDiscoveryExtras.NoModelsAvailable.self) {
            try IntelProviderDiscoveryExtras.geminiModelIds(from: Data(body.utf8))
        }
    }

    @Test func httpErrorMessageIsTheProvidersOwn() {
        let json = Data(#"{"error":{"message":"Incorrect API key provided","code":"invalid_api_key"}}"#.utf8)
        #expect(
            IntelProviderDiscoveryExtras.discoveryErrorMessage(statusCode: 401, body: json)
                == "Incorrect API key provided (code: invalid_api_key)")
        let html = Data("<html>Bad gateway</html>".utf8)
        #expect(
            IntelProviderDiscoveryExtras.discoveryErrorMessage(statusCode: 502, body: html)
                == "HTTP 502: <html>Bad gateway</html>")
        #expect(
            IntelProviderDiscoveryExtras.discoveryErrorMessage(statusCode: 500, body: Data())
                == "HTTP 500: Unknown error")
    }

    @Test func unreadableListFallsBackToTypedIdsOrThrows() throws {
        let page = Data("<html>login</html>".utf8)
        let manual = try IntelProviderDiscoveryExtras.decodeModelList(
            data: page, providerType: .openaiLegacy, manualModelIds: [" a ", "A", "b"])
        #expect(manual.ids == ["a", "b"])
        #expect(throws: IntelProviderDiscoveryExtras.RequestFailed.self) {
            try IntelProviderDiscoveryExtras.decodeModelList(
                data: page, providerType: .openaiLegacy, manualModelIds: [])
        }
        // Ollama serialises an empty catalog as `"data": null`: valid, empty.
        let empty = try IntelProviderDiscoveryExtras.decodeModelList(
            data: Data(#"{"data":null}"#.utf8), providerType: .openaiLegacy, manualModelIds: [])
        #expect(empty.ids.isEmpty)
    }

    @Test func manualFallbackStatusesAndTypes() {
        for status in [400, 404, 405, 406, 410, 415, 422, 501] {
            #expect(
                IntelProviderDiscoveryExtras.manualModelFallback(
                    providerType: .azureOpenAI, statusCode: status, manualModelIds: ["d"]) == ["d"])
        }
        for status in [401, 403, 429, 500, 502] {
            #expect(
                IntelProviderDiscoveryExtras.manualModelFallback(
                    providerType: .openaiLegacy, statusCode: status, manualModelIds: ["d"]) == nil)
        }
        #expect(
            IntelProviderDiscoveryExtras.manualModelFallback(
                providerType: .anthropic, statusCode: 404, manualModelIds: ["d"]) == nil)
    }
}

// MARK: - Manager discovery, retry, Router connect, disconnect (rows 16, 17, 43)

private actor Script {
    var responses: [(Int, [String: String], String)]
    var requests = 0
    var inFlight = 0
    var sawAllInFlight = false
    let expected: Int
    init(_ responses: [(Int, [String: String], String)] = [], expected: Int = 0) {
        self.responses = responses
        self.expected = expected
    }
    func next() -> (Int, [String: String], String) {
        requests += 1
        return responses.isEmpty ? (200, [:], "{\"data\":[]}") : responses.removeFirst()
    }
    func enter() { inFlight += 1; if inFlight >= expected { sawAllInFlight = true } }
    func leave() { inFlight -= 1 }
    func count() -> Int { requests }
    func sawAll() -> Bool { sawAllInFlight }
}

private func transport(_ script: Script) -> IntelProviderDiscoveryExtras.Transport {
    { request in
        let (status, headers, body) = await script.next()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Data(body.utf8), response)
    }
}

@MainActor
private final class Sleeps {
    var delays: [TimeInterval] = []
}

private func provider(
    _ host: String, type: RemoteProviderType = .openaiLegacy, manual: [String] = []
) -> RemoteProvider {
    RemoteProvider(
        name: "Slice4 \(host)", host: host, providerProtocol: .https, port: nil, basePath: "/v1",
        authType: .none, providerType: type, enabled: true, autoConnect: false, timeout: 5,
        manualModelIds: manual)
}

private func routerModel(_ id: String) throws -> OsaurusRouterModel {
    let json = """
        {"id":"\(id)","provider":"x","context_length":1000,"input_micro_per_mtok":"1","output_micro_per_mtok":"1",
         "input_display":"$1","output_display":"$1","stale":false}
        """
    return try JSONDecoder().decode(OsaurusRouterModel.self, from: Data(json.utf8))
}

@Suite(.serialized)
@MainActor
struct IntelProviderDiscoveryManagerTests {

    @Test func badKeyShowsTheProvidersMessageNotConnectedWithZeroModels() async {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            let p = provider("badkey.invalid")
            manager._testInstallConnectedProvider(p, discoveredModels: ["stale"])
            defer {
                manager.discoveryTransport = IntelProviderDiscoveryExtras.defaultTransport
                manager._testRemoveProviders(ids: [p.id])
            }
            manager.discoveryTransport = transport(
                Script([(401, [:], #"{"error":{"message":"Incorrect API key provided"}}"#)]))
            await manager.refreshModels(for: p.id)
            let state = manager.providerStates[p.id]
            #expect(state?.isConnected == false)
            #expect(state?.lastError?.contains("Incorrect API key provided") == true)
            #expect(state?.discoveredModels.isEmpty == true)
            #expect(state?.lastFailureWasTransient == false)
        }
    }

    @Test func rateLimitIsRetriedWithRetryAfterCappedAtFifteenSeconds() async {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            let p = provider("limited.invalid")
            manager._testInstallConnectedProvider(p, discoveredModels: [])
            let sleeps = Sleeps()
            let script = Script([
                (429, ["Retry-After": "7"], "{}"),
                (503, ["Retry-After": "86400"], "{}"),
                (200, [:], #"{"data":[{"id":"m1"},{"id":"m2"}]}"#),
            ])
            manager.discoveryTransport = transport(script)
            manager.testRetrySleepOverride = { sleeps.delays.append($0) }
            defer {
                manager.discoveryTransport = IntelProviderDiscoveryExtras.defaultTransport
                manager.testRetrySleepOverride = nil
                manager._testRemoveProviders(ids: [p.id])
            }
            await manager.refreshModels(for: p.id)
            #expect(await script.count() == 3)
            #expect(sleeps.delays == [7, 15])
            #expect(manager.providerStates[p.id]?.discoveredModels == ["m1", "m2"])
            #expect(manager.providerStates[p.id]?.isConnected == true)
        }
    }

    @Test func rateLimitGivesUpAfterThreeAttemptsAsATransientFailure() async {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            let p = provider("limited2.invalid")
            manager._testInstallConnectedProvider(p, discoveredModels: [])
            let script = Script([(503, [:], "{}"), (503, [:], "{}"), (503, [:], "{}"), (200, [:], "{}")])
            manager.discoveryTransport = transport(script)
            manager.testRetrySleepOverride = { _ in }
            defer {
                manager.discoveryTransport = IntelProviderDiscoveryExtras.defaultTransport
                manager.testRetrySleepOverride = nil
                manager._testRemoveProviders(ids: [p.id])
            }
            await manager.refreshModels(for: p.id)
            #expect(await script.count() == 3)
            #expect(manager.providerStates[p.id]?.isConnected == false)
            #expect(manager.providerStates[p.id]?.lastFailureWasTransient == true)
        }
    }

    @Test func typedModelIdsServeWhenModelsRouteIsMissing() async {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            let p = provider("manual.invalid", manual: ["my-model"])
            manager._testInstallConnectedProvider(p, discoveredModels: [])
            defer {
                manager.discoveryTransport = IntelProviderDiscoveryExtras.defaultTransport
                manager._testRemoveProviders(ids: [p.id])
            }
            manager.discoveryTransport = transport(Script([(404, [:], "not found")]))
            await manager.refreshModels(for: p.id)
            #expect(manager.providerStates[p.id]?.isConnected == true)
            #expect(manager.providerStates[p.id]?.discoveredModels == ["my-model"])
        }
    }

    @Test func refreshAllModelsRunsProvidersInParallel() async {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            let providers = (0 ..< 3).map { provider("parallel\($0).invalid") }
            for p in providers { manager._testInstallConnectedProvider(p, discoveredModels: []) }
            let script = Script(expected: 3)
            // Each request waits (bounded) until all three are in flight: a
            // sequential refresh never reaches three.
            manager.discoveryTransport = { request in
                await script.enter()
                for _ in 0 ..< 100 where !(await script.sawAll()) {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                await script.leave()
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(#"{"data":[{"id":"m"}]}"#.utf8), response)
            }
            defer {
                manager.discoveryTransport = IntelProviderDiscoveryExtras.defaultTransport
                manager._testRemoveProviders(ids: providers.map(\.id))
            }
            await manager.refreshAllModels()
            #expect(await script.sawAll())
            for p in providers { #expect(manager.providerStates[p.id]?.discoveredModels == ["m"]) }
        }
    }

    @Test func geminiDiscoveryFiltersAndStrips() async {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            let p = provider("gemini.invalid", type: .gemini)
            manager._testInstallConnectedProvider(p, discoveredModels: [])
            defer {
                manager.discoveryTransport = IntelProviderDiscoveryExtras.defaultTransport
                manager._testRemoveProviders(ids: [p.id])
            }
            manager.discoveryTransport = transport(
                Script([
                    (
                        200, [:],
                        #"{"models":[{"name":"models/gemini-x","supportedGenerationMethods":["generateContent"]},{"name":"models/emb","supportedGenerationMethods":["embedContent"]}]}"#
                    )
                ]))
            await manager.refreshModels(for: p.id)
            #expect(manager.providerStates[p.id]?.discoveredModels == ["gemini-x"])
        }
    }

    @Test func testConnectionReportsTheProvidersMessage() async {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            manager.discoveryTransport = transport(
                Script([(401, [:], #"{"error":{"message":"Invalid key"}}"#)]))
            defer { manager.discoveryTransport = IntelProviderDiscoveryExtras.defaultTransport }
            do {
                _ = try await manager.testConnection(
                    host: "test.invalid", providerProtocol: .https, port: nil, basePath: "/v1",
                    authType: .none, apiKey: nil, headers: [:])
                Issue.record("expected a failure")
            } catch {
                #expect(error.localizedDescription.contains("Invalid key"))
            }
        }
    }

    // MARK: Router connect (row 17)

    @Test func routerConnectRetriesTransientFailuresThenConnects() async throws {
        try await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            let id = RemoteProviderManager.osaurusRouterProviderId
            let model = try routerModel("test-model-a")
            var calls = 0
            let sleeps = Sleeps()
            manager.testRouterModelsOverride = {
                calls += 1
                if calls == 1 { throw OsaurusRouterAPIError.rateLimited(retryAfter: "4") }
                if calls == 2 { throw URLError(.notConnectedToInternet) }
                return [model]
            }
            manager.testRetrySleepOverride = { sleeps.delays.append($0) }
            defer {
                manager.testRouterModelsOverride = nil
                manager.testRetrySleepOverride = nil
                manager._testRemoveProviders(ids: [id])
            }
            await manager.connectOsaurusRouterWithRetry()
            #expect(calls == 3)
            #expect(sleeps.delays == [4, 2])
            #expect(manager.providerStates[id]?.isConnected == true)
            #expect(manager.providerStates[id]?.discoveredModels == ["test-model-a"])
            #expect(manager.providerStates[id]?.lastError == nil)
        }
    }

    @Test func routerConnectFailureLeavesARealErrorAndTheTransientFlag() async {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            let id = RemoteProviderManager.osaurusRouterProviderId
            var calls = 0
            manager.testRouterModelsOverride = {
                calls += 1
                throw URLError(.notConnectedToInternet)
            }
            manager.testRetrySleepOverride = { _ in }
            defer {
                manager.testRouterModelsOverride = nil
                manager.testRetrySleepOverride = nil
                manager._testRemoveProviders(ids: [id])
            }
            await manager.connectOsaurusRouterWithRetry()
            #expect(calls == RemoteProviderManager.osaurusRouterConnectMaxAttempts)
            let state = manager.providerStates[id]
            #expect(state?.isConnected == false)
            #expect(state?.lastError?.isEmpty == false)
            #expect(state?.lastFailureWasTransient == true)
        }
    }

    @Test func routerTerminalFailureIsNotRetried() async {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            let id = RemoteProviderManager.osaurusRouterProviderId
            var calls = 0
            manager.testRouterModelsOverride = {
                calls += 1
                throw OsaurusRouterAPIError.noIdentity
            }
            manager.testRetrySleepOverride = { _ in }
            defer {
                manager.testRouterModelsOverride = nil
                manager.testRetrySleepOverride = nil
                manager._testRemoveProviders(ids: [id])
            }
            await manager.connectOsaurusRouterWithRetry()
            #expect(calls == 1)
            #expect(manager.providerStates[id]?.lastFailureWasTransient == false)
            #expect(manager.providerStates[id]?.isConnected == false)
        }
    }

    // MARK: disconnect (row 43)

    @Test func disconnectClearsTheStateAndModels() async {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            let p = provider("disc.invalid")
            manager._testInstallConnectedProvider(p, discoveredModels: ["a", "b"])
            defer { manager._testRemoveProviders(ids: [p.id]) }
            manager.disconnect(providerId: p.id)
            #expect(manager.providerStates[p.id]?.isConnected == false)
            #expect(manager.providerStates[p.id]?.discoveredModels.isEmpty == true)
        }
    }

    @Test func retryAfterHintAndTransientClassification() {
        #expect(RemoteProviderManager.retryAfterHint(from: CloudChatError.rateLimited(retryAfter: 9, statusCode: 429)) == 9)
        #expect(RemoteProviderManager.retryAfterHint(from: OsaurusRouterAPIError.rateLimited(retryAfter: "3")) == 3)
        #expect(RemoteProviderManager.retryAfterHint(from: URLError(.timedOut)) == nil)
        #expect(RemoteProviderManager.isTransientConnectError(OsaurusRouterAPIError.server(code: "x", message: "m", status: 502)))
        #expect(!RemoteProviderManager.isTransientConnectError(OsaurusRouterAPIError.server(code: "x", message: "m", status: 404)))
        #expect(!RemoteProviderManager.isTransientConnectError(OsaurusRouterAPIError.unauthorized))
        #expect(RemoteProviderManager.isTransientConnectError(CloudChatError.rateLimited(retryAfter: nil, statusCode: 503)))
    }
}

// MARK: - xAI OAuth refresh (row 18)

@Suite(.serialized)
struct IntelXAICredentialsTests {
    private actor Store {
        var tokens: RemoteProviderOAuthTokens?
        var saves = 0
        var permanentFailures: [UUID] = []
        init(_ tokens: RemoteProviderOAuthTokens?) { self.tokens = tokens }
        func load() -> RemoteProviderOAuthTokens? { tokens }
        func save(_ value: RemoteProviderOAuthTokens) { tokens = value; saves += 1 }
        func flag(_ id: UUID) { permanentFailures.append(id) }
        func counts() -> (Int, [UUID]) { (saves, permanentFailures) }
    }

    private func tokens(_ access: String, expired: Bool) -> RemoteProviderOAuthTokens {
        RemoteProviderOAuthTokens(
            accessToken: access, refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(expired ? -60 : 3600), accountId: "")
    }

    private func credentials(
        _ store: Store, refresh: @escaping @Sendable (RemoteProviderOAuthTokens) async throws -> RemoteProviderOAuthTokens
    ) -> IntelXAICredentials {
        IntelXAICredentials(
            load: { _ in await store.load() }, refresh: refresh,
            save: { value, _ in await store.save(value); return true },
            onPermanentFailure: { await store.flag($0) })
    }

    @Test func expiredTokenIsRefreshedAndSaved() async throws {
        let store = Store(tokens("old", expired: true))
        let creds = credentials(store) { _ in self.tokens("new", expired: false) }
        let result = try await creds.tokens(for: UUID())
        #expect(result.accessToken == "new")
        #expect(await store.counts().0 == 1)
    }

    @Test func freshTokenIsUsedAsIs() async throws {
        let store = Store(tokens("live", expired: false))
        let creds = credentials(store) { _ in
            Issue.record("must not refresh")
            return RemoteProviderOAuthTokens(accessToken: "x", refreshToken: "", expiresAt: Date(), accountId: "")
        }
        #expect(try await creds.tokens(for: UUID()).accessToken == "live")
    }

    @Test func permanentRefreshFailureFlagsTheProvider() async {
        let store = Store(tokens("old", expired: true))
        let id = UUID()
        let creds = credentials(store) { _ in
            throw XAIOAuthError.tokenRequestFailed("HTTP 400: {\"error\":\"invalid_grant\"}")
        }
        await #expect(throws: (any Error).self) { try await creds.tokens(for: id) }
        #expect(await store.counts().1 == [id])
    }

    @Test func transientRefreshFailureDoesNotFlag() async {
        let store = Store(tokens("old", expired: true))
        let creds = credentials(store) { _ in throw URLError(.timedOut) }
        await #expect(throws: (any Error).self) { try await creds.tokens(for: UUID()) }
        #expect(await store.counts().1.isEmpty)
    }

    @Test func missingTokensThrow() async {
        let creds = credentials(Store(nil)) { $0 }
        await #expect(throws: (any Error).self) { try await creds.tokens(for: UUID()) }
    }

    @Test func engineSendsTheRefreshedBearer() async throws {
        let store = Store(tokens("stale", expired: true))
        let creds = credentials(store) { _ in self.tokens("fresh", expired: false) }
        XAIFixtureProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [XAIFixtureProtocol.self]
        let provider = RemoteProvider(
            name: "Grok", host: "xai-fixture.invalid", providerProtocol: .https, port: nil,
            basePath: "/v1", customHeaders: ["X-Custom": "kept"], authType: .xaiOAuth,
            providerType: .openaiLegacy, enabled: true, autoConnect: false, timeout: 5)
        let engine = ChatEngine(
            provider: provider, session: URLSession(configuration: configuration), xaiCredentials: creds)
        let request = ChatCompletionRequest(
            model: "grok-4", messages: [ChatMessage(role: "user", content: "hi")])
        var out = ""
        for try await delta in try await engine.streamChat(request: request) { out += delta }
        #expect(out == "ok")
        let sent = try #require(XAIFixtureProtocol.lastHeaders)
        #expect(sent["Authorization"] == "Bearer fresh")
        #expect(sent["X-Custom"] == "kept")
    }
}

private final class XAIFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var headers: [String: String]?
    static var lastHeaders: [String: String]? { lock.lock(); defer { lock.unlock() }; return headers }
    static func reset() { lock.lock(); headers = nil; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "xai-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.headers = request.allHTTPHeaderFields
        Self.lock.unlock()
        let text = """
            data: {"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}

            data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

            data: [DONE]

            """
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
