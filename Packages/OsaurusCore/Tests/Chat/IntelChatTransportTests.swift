//
//  IntelChatTransportTests.swift
//  OsaurusCoreTests
//
//  Stage 5d slice 5 (docs/COV_REAUDIT_STAGE5D_PROVIDER.md rows 19, 20;
//  upstream Classic `RemoteProviderService.init`). Session and request
//  shaping only: no request is sent, no proxy or provider is contacted, no
//  keychain. Proxy values are fake and live in a temporary storage root.
//

import CFNetwork
import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel chat transport (5d slice 5)", .serialized)
struct IntelChatTransportTests {
    static func provider(timeout: TimeInterval = 60, disableTimeout: Bool = false) -> RemoteProvider {
        RemoteProvider(
            name: "Fixture", host: "fixture.invalid", providerProtocol: .https,
            port: nil, basePath: "/v1", customHeaders: [:], authType: .none,
            providerType: .openaiLegacy, enabled: true, autoConnect: false,
            timeout: timeout, disableTimeout: disableTimeout)
    }

    static func withProxyRoot(
        proxy: String?, _ body: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-chat-transport-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }
            try OsaurusPaths.ensureExists(OsaurusPaths.config())
            var configuration = ServerConfiguration.default
            configuration.globalProxyURL = proxy
            try JSONEncoder().encode(configuration).write(to: OsaurusPaths.serverConfigFile(), options: .atomic)
            try await body()
        }
    }

    // MARK: Row 19

    @Test("The chat engine's own session honours the global proxy")
    func engineSessionUsesGlobalProxy() async throws {
        try await Self.withProxyRoot(proxy: "https://proxy.example.com:8443") {
            let engine = ChatEngine(provider: Self.provider())
            let session = await engine.transportSession(for: Self.provider())
            let dictionary = session.configuration.connectionProxyDictionary
            #expect(dictionary?[kCFNetworkProxiesHTTPSEnable as String] as? Int == 1)
            #expect(dictionary?[kCFNetworkProxiesHTTPSProxy as String] as? String == "proxy.example.com")
            #expect(dictionary?[kCFNetworkProxiesHTTPSPort as String] as? Int == 8443)
        }
    }

    @Test("No proxy configured means no proxy dictionary")
    func engineSessionWithoutProxy() async throws {
        try await Self.withProxyRoot(proxy: nil) {
            let engine = ChatEngine(provider: Self.provider())
            let session = await engine.transportSession(for: Self.provider())
            #expect(session.configuration.connectionProxyDictionary == nil)
        }
    }

    @Test("An injected session is used as is (fixtures stay offline)")
    func injectedSessionWins() async throws {
        let injected = URLSession(configuration: .ephemeral)
        let engine = ChatEngine(provider: Self.provider(), session: injected)
        let used = await engine.transportSession(for: Self.provider())
        #expect(used === injected)
    }

    // MARK: Row 20

    @Test("Request and resource timeouts follow upstream: max(timeout, 300), max(2x, 600), unbounded when disabled")
    func timeoutValues() {
        #expect(ChatEngine.requestTimeout(for: Self.provider(timeout: 60)) == 300)
        #expect(ChatEngine.requestTimeout(for: Self.provider(timeout: 900)) == 900)
        #expect(
            ChatEngine.requestTimeout(for: Self.provider(timeout: 60, disableTimeout: true))
                == RemoteProvider.unboundedTimeout)
        #expect(ChatEngine.requestTimeout(for: nil) == 300)

        let low = ChatEngine.sessionConfiguration(for: Self.provider(timeout: 60))
        #expect(low.timeoutIntervalForRequest == 300)
        #expect(low.timeoutIntervalForResource == 600)
        let high = ChatEngine.sessionConfiguration(for: Self.provider(timeout: 900))
        #expect(high.timeoutIntervalForRequest == 900)
        #expect(high.timeoutIntervalForResource == 1800)
        let off = ChatEngine.sessionConfiguration(for: Self.provider(timeout: 900, disableTimeout: true))
        #expect(off.timeoutIntervalForRequest == RemoteProvider.unboundedTimeout)
        #expect(off.timeoutIntervalForResource == RemoteProvider.unboundedTimeout)
    }

    @Test("The engine's own session carries the provider's timeouts")
    func engineSessionCarriesTimeouts() async throws {
        try await Self.withProxyRoot(proxy: nil) {
            let provider = Self.provider(timeout: 900)
            let engine = ChatEngine(provider: provider)
            let session = await engine.transportSession(for: provider)
            #expect(session.configuration.timeoutIntervalForRequest == 900)
            #expect(session.configuration.timeoutIntervalForResource == 1800)
        }
    }

    @Test("Streaming and completeChat requests use the provider's request timeout")
    func requestsCarryTimeout() async throws {
        for (provider, expected) in [
            (Self.provider(timeout: 60), 300.0),
            (Self.provider(timeout: 900), 900.0),
            (Self.provider(timeout: 60, disableTimeout: true), RemoteProvider.unboundedTimeout),
        ] {
            TimeoutCaptureProtocol.reset()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [TimeoutCaptureProtocol.self]
            let engine = ChatEngine(provider: provider, session: URLSession(configuration: configuration))
            let request = ChatCompletionRequest(
                model: "fixture-model", messages: [ChatMessage(role: "user", content: "hi")])
            let stream = try await engine.streamChat(request: request)
            for try await _ in stream {}
            _ = try? await engine.completeChat(request: request)
            let seen = TimeoutCaptureProtocol.timeouts()
            #expect(seen.count >= 1)
            #expect(seen.allSatisfy { $0 == expected })
        }
    }
}

private final class TimeoutCaptureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [TimeInterval] = []
    static func reset() { lock.lock(); seen = []; lock.unlock() }
    static func timeouts() -> [TimeInterval] { lock.lock(); defer { lock.unlock() }; return seen }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request.timeoutInterval)
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
