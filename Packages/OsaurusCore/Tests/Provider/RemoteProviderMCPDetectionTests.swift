//
//  RemoteProviderMCPDetectionTests.swift
//  osaurusTests
//
//  Coverage for classifying an MCP server pasted into the API provider form
//  (issue: runalyze.com/mcp added as a custom API provider fails with a bare
//  "Not Found" from `<base>/models`).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Remote provider MCP detection")
struct RemoteProviderMCPDetectionTests {
    private func response(
        status: Int,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com/mcp")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    @Test func detectsJSONRPCErrorBody() {
        // Runalyze answers an unauthenticated initialize like this.
        let body = Data(
            #"{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Missing authentication token."}}"#
                .utf8
        )
        #expect(
            RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(status: 401),
                body: body
            )
        )
    }

    @Test func detectsJSONRPCSuccessBody() {
        let body = Data(
            #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{}}}"#
                .utf8
        )
        #expect(
            RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(status: 200),
                body: body
            )
        )
    }

    @Test func detectsSSEInitializeResponse() {
        let body = Data(
            "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n".utf8
        )
        #expect(
            RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(
                    status: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: body
            )
        )
    }

    @Test func detectsBearerChallengeWithResourceMetadata() {
        #expect(
            RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(
                    status: 401,
                    headers: [
                        "WWW-Authenticate":
                            #"Bearer resource_metadata="https://runalyze.com/.well-known/oauth-protected-resource", scope="mcp.read""#
                    ]
                ),
                body: nil
            )
        )
    }

    @Test func ignoresChatAPIStyleErrors() {
        // OpenAI-style error envelope — not JSON-RPC.
        let openAIError = Data(
            #"{"error":{"message":"Invalid URL (POST /v1)","type":"invalid_request_error"}}"#.utf8
        )
        #expect(
            !RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(status: 404),
                body: openAIError
            )
        )
        // HTML 404 page.
        let html = Data("<html><body>Not Found</body></html>".utf8)
        #expect(
            !RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(status: 404, headers: ["Content-Type": "text/html"]),
                body: html
            )
        )
        // Bare 401 without resource metadata is just auth, not evidence of MCP.
        #expect(
            !RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(status: 401, headers: ["WWW-Authenticate": "Bearer realm=\"api\""]),
                body: nil
            )
        )
        // Empty body, plain status.
        #expect(
            !RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(status: 404),
                body: Data()
            )
        )
    }

    @Test func sseDetectionRequiresEventStreamContentType() {
        let body = Data("data: {\"jsonrpc\":\"2.0\"}\n\n".utf8)
        #expect(
            !RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(status: 200, headers: ["Content-Type": "text/plain"]),
                body: body
            )
        )
    }

    @Test func guidanceMentionsServices() {
        let message = RemoteProviderMCPDetection.guidance()
        #expect(message.contains("MCP server"))
        #expect(message.contains("Services"))
    }

    // MARK: - Intel: the handshake probe used by Intel's discovery

    @Test func probe_flagsAnMCPServerAtTheBaseURL() async {
        let transport: IntelProviderDiscoveryExtras.Transport = { request in
            #expect(request.httpMethod == "POST")
            let body = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"bad"}}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        let hit = await IntelProviderDiscoveryExtras.looksLikeMCPServer(
            providerType: .openaiLegacy, baseURL: URL(string: "https://runalyze.com/mcp"), headers: [:], transport: transport)
        #expect(hit)
        #expect(IntelProviderDiscoveryExtras.MCPEndpointDetected().localizedDescription.contains("Tools & MCP"))
    }

    @Test func probe_ignoresNonOpenAIProvidersAndTransportFailures() async {
        let failing: IntelProviderDiscoveryExtras.Transport = { _ in throw URLError(.timedOut) }
        #expect(!(await IntelProviderDiscoveryExtras.looksLikeMCPServer(
            providerType: .openaiLegacy, baseURL: URL(string: "https://x.test"), headers: [:], transport: failing)))
        #expect(!(await IntelProviderDiscoveryExtras.looksLikeMCPServer(
            providerType: .anthropic, baseURL: URL(string: "https://x.test"), headers: [:], transport: failing)))
    }
}
