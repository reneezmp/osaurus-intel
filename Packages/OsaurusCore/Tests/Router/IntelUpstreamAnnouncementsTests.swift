//
//  IntelUpstreamAnnouncementsTests.swift
//  osaurusTests
//
//  Intel's handling of upstream's Router announcements (#2982): the opt-out,
//  no `app_version`, only `https` links, and upstream's client contract
//  (unsigned GET, 429 → rate limited). docs/ROUTER_ANNOUNCEMENTS_INTEL.md.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct IntelUpstreamAnnouncementsTests {
    private final class FetchCounter: @unchecked Sendable {
        var count = 0
        var versions: [String?] = []
    }

    private func announcement(ctas: [OsaurusRouterAnnouncement.CTA] = []) -> OsaurusRouterAnnouncement {
        OsaurusRouterAnnouncement(id: "a1", slug: "launch", title: "Raptor is live", body: "**Today**", ctas: ctas)
    }

    private func makeService(defaults: UserDefaults, counter: FetchCounter) -> AnnouncementsService {
        let feed = OsaurusRouterAnnouncementsResponse(serverTime: nil, announcements: [announcement()])
        return AnnouncementsService(
            defaults: defaults,
            fetch: { version in
                counter.count += 1
                counter.versions.append(version)
                return feed
            },
            isRouterEnabled: { true }
        )
    }

    @Test func optOutStopsFetchingAndPresenting() async {
        let suite = "intel-announcements-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let counter = FetchCounter()
        let service = makeService(defaults: defaults, counter: counter)

        await service.refreshIfDue(trigger: .launch)
        #expect(counter.count == 1)
        #expect(service.eligibleAnnouncement?.slug == "launch")

        service.optOut()
        #expect(service.isOptedOut)
        #expect(service.eligibleAnnouncement == nil)
        #expect(!service.isFetchDue(trigger: .debug))
        await service.refreshIfDue(trigger: .debug)
        #expect(counter.count == 1)
    }

    @Test func intelSendsNoAppVersionByDefault() async {
        let suite = "intel-announcements-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let counter = FetchCounter()
        await makeService(defaults: defaults, counter: counter).refreshIfDue(trigger: .launch)
        #expect(counter.versions == [nil])
    }

    @Test func onlyHTTPSLinksAreOffered() {
        let a = announcement(ctas: [
            .init(label: "Upvote", kind: "external_url", url: "https://example.com/launch", style: "primary"),
            .init(label: "Credits", kind: "deeplink", url: "osaurus://settings?tab=credits"),
        ])
        #expect(a.actionableCTAs.count == 2)
        let intel = AnnouncementsService.intelCTAs(for: a)
        #expect(intel.map(\.label) == ["Upvote"])
    }

    // MARK: - Client (upstream `OsaurusRouterAPIClientTests` announcement cases)

    @Test func announcementsRequestIsUnsignedGET() async throws {
        AnnouncementsURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/announcements")
            #expect(request.url?.query == nil)
            #expect(request.value(forHTTPHeaderField: "x-wallet-address") == nil)
            #expect(request.value(forHTTPHeaderField: "x-wallet-signature") == nil)
            return (200, Data(#"{"server_time":"2026-10-02T10:00:00Z","announcements":[{"id":"a1","slug":"s","title":"T","body":"B"}]}"#.utf8), [:])
        }
        let response = try await makeClient().announcements(appVersion: nil)
        #expect(response.announcements.map(\.slug) == ["s"])
    }

    @Test func announcementsMapsRateLimit() async throws {
        AnnouncementsURLProtocol.handler = { _ in
            (429, Data(#"{"error":{"code":"RATE_LIMITED","message":"slow down"}}"#.utf8), ["retry-after": "120"])
        }
        do {
            _ = try await makeClient().announcements(appVersion: nil)
            Issue.record("Expected rate-limited error")
        } catch let error as OsaurusRouterAPIError {
            guard case .rateLimited(let retryAfter) = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
            #expect(retryAfter == "120")
        }
    }

    private func makeClient() throws -> OsaurusRouterAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnnouncementsURLProtocol.self]
        // A signer that would mark any signed call; the feed must not use it.
        return OsaurusRouterAPIClient(
            baseURL: try #require(URL(string: "https://router.test")),
            session: URLSession(configuration: config),
            authOverride: { request, _ in
                request.setValue("0xabc", forHTTPHeaderField: "x-wallet-address")
                request.setValue("0x1", forHTTPHeaderField: "x-wallet-signature")
            }
        )
    }
}

private final class AnnouncementsURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data, [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data, headers) = handler(request)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers.merging(["content-type": "application/json"]) { a, _ in a })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
