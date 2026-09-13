import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct OsaurusRouterSearchBackendTests {
    @Test func hostedGateRequiresConsentAndExcludesMedia() {
        func gate(_ category: String, enabled: Bool = true) -> Bool {
            SearchProviderManager.shouldTryHostedSearch(
                category: category,
                hostedSearchEnabled: enabled,
                routerEnabled: true,
                identityExists: true,
                hostedAvailable: true
            )
        }
        #expect(gate(SearchCategory.web))
        #expect(gate(SearchCategory.news))
        #expect(!gate(SearchCategory.web, enabled: false))
        #expect(!gate(SearchCategory.images))
        #expect(!gate("video"))
    }

    @Test func searchSendsSameIdempotencyKeyInBodyAndHeader() async throws {
        let backend = try makeBackend { request in
            #expect(request.url?.path == "/v1/search")
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "logical-search")
            let body = request.httpBodyStreamData ?? request.httpBody ?? Data()
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["idempotency_key"] as? String == "logical-search")
            return (200, Data(#"{"results":[]}"#.utf8), ["content-type": "application/json"])
        }
        _ = await backend.search(
            SearchRequest(query: "capybara"), idempotencyKey: "logical-search")
    }

    @Test func contentsSendsSameIdempotencyKeyInBodyAndHeader() async throws {
        let backend = try makeBackend { request in
            #expect(request.url?.path == "/v1/contents")
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "logical-contents")
            let body = request.httpBodyStreamData ?? request.httpBody ?? Data()
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["idempotency_key"] as? String == "logical-contents")
            return (200, Data(#"{"results":[],"statuses":[]}"#.utf8), ["content-type": "application/json"])
        }
        _ = await backend.contents(
            urls: ["https://example.com/article"], idempotencyKey: "logical-contents")
    }

    @Test func privateTargetsAreRejectedByExtractionPreflight() {
        #expect(SearchHTML.resolvedUnsafeExtractionURLReason("http://127.0.0.1/private") != nil)
        #expect(SearchHTML.resolvedUnsafeExtractionURLReason("http://localhost/private") != nil)
        #expect(SearchHTML.resolvedUnsafeExtractionURLReason("https://example.com/article") == nil)
    }

    @Test func searchAndExtractSchemaAcceptsDirectURLWithoutRequiredQuery() {
        guard case .object(let root)? = SearchAndExtractTool().parameters,
              case .object(let properties)? = root["properties"]
        else {
            Issue.record("search_and_extract schema was not an object")
            return
        }
        #expect(properties["url"] != nil)
        #expect(root["required"] == nil)
    }

    private func makeBackend(
        handler: @escaping @Sendable (URLRequest) throws -> (Int, Data, [String: String])
    ) throws -> OsaurusRouterSearchBackend {
        PremiumSearchURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PremiumSearchURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let baseURL = try #require(URL(string: "https://router.test"))
        let client = OsaurusRouterAPIClient(
            baseURL: baseURL,
            session: session,
            authOverride: { request, _ in
                request.setValue("0xabc", forHTTPHeaderField: "x-wallet-address")
            }
        )
        return OsaurusRouterSearchBackend(
            client: client, availability: RouterWebSearchAvailability())
    }

}

private final class PremiumSearchURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        (@Sendable (URLRequest) throws -> (Int, Data, [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    var httpBodyStreamData: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 1024)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
