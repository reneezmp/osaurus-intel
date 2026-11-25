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
}
