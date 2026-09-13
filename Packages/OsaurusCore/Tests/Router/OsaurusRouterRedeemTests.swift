import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel Router code redemption", .serialized)
struct OsaurusRouterRedeemTests {
    @Test func requestUsesExactEndpointAndCanonicalCode() async throws {
        RedeemFixtureProtocol.configure(
            body: #"{"redeemed":true,"already_redeemed":false,"campaign_kind":"promo","amount_micro":"5000000","referral_pending":false,"redemption_message":"50,000 credits added."}"#,
            status: 200
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedeemFixtureProtocol.self]
        let client = OsaurusRouterAPIClient(
            baseURL: URL(string: "https://router-redeem.invalid")!,
            session: URLSession(configuration: configuration),
            authOverride: { _, _ in }
        )

        let response = try await client.redeemCode("LAUNCH25")
        #expect(response.amountMicro == "5000000")
        #expect(RedeemFixtureProtocol.request?.url?.path == "/credits/redeem")
        #expect(RedeemFixtureProtocol.request?.httpMethod == "POST")
        #expect(String(data: RedeemFixtureProtocol.requestBody ?? Data(), encoding: .utf8) == #"{"code":"LAUNCH25"}"#)
    }

    @Test func responseMessageIsBoundedForPresentation() async throws {
        let longMessage = String(repeating: "x", count: 900)
        let response = OsaurusRouterRedeemCodeResponse(
            redeemed: true,
            alreadyRedeemed: false,
            campaignKind: "promo",
            amountMicro: "0",
            referralPending: false,
            redemptionMessage: longMessage
        )
        let service = await RedeemCodeService(redeem: { _ in response }, refreshBalance: {})
        await MainActor.run { service.code = "  SAFE-CODE  " }
        #expect(await MainActor.run { service.normalizedCode } == "SAFE-CODE")
        #expect(await RedeemCodeService.presentationSafe(response).redemptionMessage.count == 500)
    }
}

private final class RedeemFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseBody = ""
    nonisolated(unsafe) private static var statusCode = 200
    nonisolated(unsafe) private static var capturedRequest: URLRequest?
    nonisolated(unsafe) private static var capturedBody: Data?

    static var request: URLRequest? { lock.withLock { capturedRequest } }
    static var requestBody: Data? { lock.withLock { capturedBody } }

    static func configure(body: String, status: Int) {
        lock.withLock {
            responseBody = body
            statusCode = status
            capturedRequest = nil
            capturedBody = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "router-redeem.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            var data = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            body = data
        }
        let payload: (String, Int) = Self.lock.withLock {
            Self.capturedRequest = request
            Self.capturedBody = body
            return (Self.responseBody, Self.statusCode)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: payload.1, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.0.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
