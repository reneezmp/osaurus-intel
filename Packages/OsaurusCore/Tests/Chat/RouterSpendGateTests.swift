//
//  RouterSpendGateTests.swift
//  osaurusTests
//
//  Pins the Osaurus Router credit-spend gate for HTTP-origin requests:
//  key-less loopback callers must not be able to route master-key-signed,
//  credit-billed requests through the Router unless the user explicitly
//  opted in. Keyed callers and app-internal sources are unaffected.
//
//  Intel (2026-10-30, `W-server-api` stage 5b): upstream's policy cases
//  verbatim; the engine cases run Intel's `ChatEngine` against a Router
//  provider pointed at an in-process fixture, and add Intel's rule that
//  the gate applies only inside an HTTP request (`HTTPCallerContext` bound).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct RouterSpendGateTests {

    // MARK: - Pure policy (upstream)

    @Test func blocksUnkeyedHTTPCallerWithoutOptIn() {
        let error = ChatEngine.routerSpendAuthorizationError(
            serviceIsOsaurusRouter: true,
            source: .httpAPI,
            callerHasVerifiedAccessKey: false,
            allowsUnkeyedLoopbackSpend: false
        )
        #expect(error != nil)
        #expect(error?.httpStatus == 403)
    }

    @Test func allowsKeyedHTTPCaller() {
        let error = ChatEngine.routerSpendAuthorizationError(
            serviceIsOsaurusRouter: true,
            source: .httpAPI,
            callerHasVerifiedAccessKey: true,
            allowsUnkeyedLoopbackSpend: false
        )
        #expect(error == nil)
    }

    @Test func allowsUnkeyedCallerWithExplicitOptIn() {
        let error = ChatEngine.routerSpendAuthorizationError(
            serviceIsOsaurusRouter: true,
            source: .httpAPI,
            callerHasVerifiedAccessKey: false,
            allowsUnkeyedLoopbackSpend: true
        )
        #expect(error == nil)
    }

    @Test func neverBlocksAppInternalSources() {
        for source in [RequestSource.chatUI, .plugin, .p2p] {
            let error = ChatEngine.routerSpendAuthorizationError(
                serviceIsOsaurusRouter: true,
                source: source,
                callerHasVerifiedAccessKey: false,
                allowsUnkeyedLoopbackSpend: false
            )
            #expect(error == nil, "source \(source) must not be gated")
        }
    }

    @Test func neverBlocksNonRouterServices() {
        let error = ChatEngine.routerSpendAuthorizationError(
            serviceIsOsaurusRouter: false,
            source: .httpAPI,
            callerHasVerifiedAccessKey: false,
            allowsUnkeyedLoopbackSpend: false
        )
        #expect(error == nil)
    }

    // MARK: - Engine wiring (Intel's engine)

    private func makeEngine() -> ChatEngine {
        let provider = RemoteProvider(
            name: "Osaurus", host: "spend-fixture.invalid", providerProtocol: .https,
            port: nil, basePath: "", customHeaders: [:], authType: .none,
            providerType: .osaurusRouter, enabled: true, autoConnect: false, timeout: 5)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpendFixtureProtocol.self]
        return ChatEngine(
            source: .httpAPI, model: "osaurus/anthropic/claude-opus", provider: provider,
            session: URLSession(configuration: configuration))
    }

    private func makeRequest() -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: "osaurus/anthropic/claude-opus",
            messages: [ChatMessage(role: "user", content: "hi")])
    }

    /// Runs `body` with the key-less loopback opt-in cleared (restored after).
    private func withoutOptIn(_ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: OsaurusRouter.allowUnkeyedLoopbackSpendDefaultsKey)
        defaults.removeObject(forKey: OsaurusRouter.allowUnkeyedLoopbackSpendDefaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: OsaurusRouter.allowUnkeyedLoopbackSpendDefaultsKey)
            }
        }
        try await body()
    }

    /// An unkeyed HTTP caller is refused before any network I/O.
    @Test func streamChatFailsClosedForUnkeyedHTTPOrigin() async {
        SpendFixtureProtocol.reset()
        await withoutOptIn {
            await HTTPCallerContext.$current.withValue(HTTPCallerContext(hasVerifiedAccessKey: false)) {
                do {
                    _ = try await makeEngine().streamChat(request: makeRequest())
                    Issue.record("expected the Router spend refusal")
                } catch let error as ChatEngine.EngineError {
                    #expect(error.httpStatus == 403)
                } catch {
                    Issue.record("unexpected error type: \(error)")
                }
                do {
                    _ = try await makeEngine().completeChat(request: makeRequest())
                    Issue.record("expected the Router spend refusal")
                } catch let error as ChatEngine.EngineError {
                    #expect(error.httpStatus == 403)
                } catch {
                    Issue.record("unexpected error type: \(error)")
                }
            }
        }
        #expect(SpendFixtureProtocol.requestCount == 0)
    }

    /// A keyed caller passes the gate; whatever happens after must not be
    /// the 403 spend refusal.
    @Test func streamChatPassesGateForKeyedHTTPOrigin() async {
        await withoutOptIn {
            await HTTPCallerContext.$current.withValue(HTTPCallerContext(hasVerifiedAccessKey: true)) {
                await expectNoSpendRefusal()
            }
        }
    }

    /// Intel: in-app work (memory distillation, compaction, delegation) builds
    /// engines with the default `.httpAPI` source; with no HTTP request bound
    /// it is the app's own and is never gated.
    @Test func inAppWorkOutsideAnHTTPRequestIsNotGated() async {
        await withoutOptIn {
            #expect(HTTPCallerContext.current == nil)
            await expectNoSpendRefusal()
        }
    }

    @Test func spendRefusalAnswers403OnTheAPI() {
        let status = HTTPHandler.inferenceHTTPStatus(for: ChatEngine.EngineError.routerSpendNotAuthorized)
        #expect(status.status == .forbidden)
        let unknown = HTTPHandler.inferenceHTTPStatus(for: ChatEngine.EngineError(message: "No endpoint for model \"x\"."))
        #expect(unknown.status == .notFound)
    }

    private func expectNoSpendRefusal() async {
        do {
            let stream = try await makeEngine().streamChat(request: makeRequest())
            for try await _ in stream {}
        } catch let error as ChatEngine.EngineError {
            #expect(error.httpStatus != 403, "must not hit the spend gate")
        } catch {
            // A later failure (signing, transport) is fine: the gate passed.
        }
    }
}

private final class SpendFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset() { lock.lock(); count = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "spend-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(
                "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
                    .utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
