//
//  FireworksModelDiscoveryTests.swift
//  osaurusTests
//
//  Covers Fireworks gateway catalog discovery: host detection and
//  serverless-chat filtering of catalog pages.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Fireworks model discovery")
struct FireworksModelDiscoveryTests {

    @Test func fireworksHost_isDetectedForOpenAICompatibleProviders() {
        #expect(IntelProviderDiscoveryExtras.isFireworksProvider(makeProvider(host: "api.fireworks.ai")))
        #expect(IntelProviderDiscoveryExtras.isFireworksProvider(makeProvider(host: "API.Fireworks.AI")))
        #expect(
            IntelProviderDiscoveryExtras.isFireworksProvider(
                makeProvider(host: "api.fireworks.ai/inference", basePath: "/v1")
            )
        )
    }

    @Test func nonFireworksHost_isNotDetected() {
        #expect(!IntelProviderDiscoveryExtras.isFireworksProvider(makeProvider(host: "api.openai.com")))
        #expect(!IntelProviderDiscoveryExtras.isFireworksProvider(makeProvider(host: "fireworks.ai.evil.com")))
        #expect(!IntelProviderDiscoveryExtras.isFireworksProvider(makeProvider(host: "notfireworks.ai")))
    }

    @Test func fireworksHost_isNotDetectedForNonOpenAICompatibleProviders() {
        #expect(
            !IntelProviderDiscoveryExtras.isFireworksProvider(
                makeProvider(host: "api.fireworks.ai", providerType: .anthropic)
            )
        )
    }

    @Test func catalogPage_filtersToServerlessChatModels() throws {
        let body = Data(
            """
            {
              "models": [
                {
                  "name": "accounts/fireworks/models/llama-v3p1-70b-instruct",
                  "state": "READY",
                  "supportsServerless": true,
                  "conversationConfig": {"style": "openai"}
                },
                {
                  "name": "accounts/fireworks/models/not-serverless",
                  "state": "READY",
                  "supportsServerless": false,
                  "conversationConfig": {}
                },
                {
                  "name": "accounts/fireworks/models/no-chat-embedding",
                  "state": "READY",
                  "supportsServerless": true
                },
                {
                  "name": "accounts/fireworks/models/embedding-with-chat-template",
                  "state": "READY",
                  "kind": "EMBEDDING_MODEL",
                  "supportsServerless": true,
                  "conversationConfig": {"style": "jinja"}
                },
                {
                  "name": "accounts/fireworks/models/still-uploading",
                  "state": "UPLOADING",
                  "supportsServerless": true,
                  "conversationConfig": {}
                }
              ],
              "nextPageToken": "token-2",
              "totalSize": 400
            }
            """.utf8
        )

        let page = try IntelProviderDiscoveryExtras.decodeFireworksCatalogPage(data: body)

        #expect(page.models == ["accounts/fireworks/models/llama-v3p1-70b-instruct"])
        #expect(page.nextPageToken == "token-2")
    }

    @Test func catalogPage_toleratesMissingModelsAndToken() throws {
        let page = try IntelProviderDiscoveryExtras.decodeFireworksCatalogPage(data: Data("{}".utf8))

        #expect(page.models.isEmpty)
        #expect(page.nextPageToken == nil)
    }

    private func makeProvider(
        host: String,
        basePath: String = "/inference/v1",
        providerType: RemoteProviderType = .openaiLegacy
    ) -> RemoteProvider {
        RemoteProvider(
            name: "fireworks.ai",
            host: host,
            providerProtocol: .https,
            port: nil,
            basePath: basePath,
            authType: .apiKey,
            providerType: providerType
        )
    }

    // MARK: - Intel: catalog merge and fallback through a stub transport

    private static func reply(_ status: Int, _ body: String) -> IntelProviderDiscoveryExtras.Transport {
        { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func augment_mergesCatalogAfterTheAccountsOwnModels() async {
        let page = #"{"models":[{"name":"accounts/fireworks/models/a","state":"READY","supportsServerless":true,"conversationConfig":{}},{"name":"acct/mine","state":"READY","supportsServerless":true,"conversationConfig":{}}]}"#
        let merged = await IntelProviderDiscoveryExtras.augmentFireworks(
            discovered: ["acct/mine"], headers: [:], transport: Self.reply(200, page))
        #expect(merged == ["acct/mine", "accounts/fireworks/models/a"])
    }

    @Test func augment_keepsModelsOnlyWhenTheCatalogFails() async {
        let merged = await IntelProviderDiscoveryExtras.augmentFireworks(
            discovered: ["acct/mine"], headers: [:], transport: Self.reply(403, "{}"))
        #expect(merged == ["acct/mine"])
    }
}
