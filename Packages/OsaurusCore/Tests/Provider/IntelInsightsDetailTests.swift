//
//  IntelInsightsDetailTests.swift
//  osaurusTests
//
//  Stage 5d slice 10 (docs/COV_REAUDIT_STAGE5D_PROVIDER.md rows 36-38):
//  the Insights row's real finish reason, and the redacted replay evidence a
//  failed discovery keeps for the Providers "Request evidence" row. Every
//  network call goes through an injected transport; nothing touches the
//  keychain, a provider or the Router.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct IntelInsightsFinishReasonTests {
    @Test func wireReasonsMapToTheInsightsEnum() {
        #expect(ChatEngine.insightsFinishReason(wire: "stop") == .stop)
        #expect(ChatEngine.insightsFinishReason(wire: "length") == .length)
        #expect(ChatEngine.insightsFinishReason(wire: "LENGTH") == .length)
        #expect(ChatEngine.insightsFinishReason(wire: "tool_calls") == .toolCalls)
        #expect(ChatEngine.insightsFinishReason(wire: "function_call") == .toolCalls)
        #expect(ChatEngine.insightsFinishReason(wire: "content_filter") == .stop)
        #expect(ChatEngine.insightsFinishReason(wire: nil) == .stop)
    }

    @Test func pendingToolCallsWinOverTheProvidersWord() {
        #expect(ChatEngine.insightsFinishReason(wire: "stop", hasToolCalls: true) == .toolCalls)
        #expect(ChatEngine.insightsFinishReason(wire: nil, hasToolCalls: true) == .toolCalls)
    }
}

private func evidenceTransport(status: Int, body: String) -> IntelProviderDiscoveryExtras.Transport {
    { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["x-request-id": "req-1"])!
        return (Data(body.utf8), response)
    }
}

private func evidenceProvider(_ host: String) -> RemoteProvider {
    RemoteProvider(
        name: "Slice10 \(host)", host: host, providerProtocol: .https, port: nil, basePath: "/v1",
        customHeaders: ["X-Gateway-Token": "sekret-token-value"],
        authType: .none, providerType: .openaiLegacy, enabled: true, autoConnect: false, timeout: 5,
        secretHeaderKeys: ["X-Gateway-Token"])
}

@Suite(.serialized)
@MainActor
struct IntelReplayDiagnosticsTests {
    @Test func failedDiscoveryKeepsRedactedEvidenceAndSuccessClearsIt() async {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            let p = evidenceProvider("evidence.invalid")
            manager._testInstallConnectedProvider(p, discoveredModels: [])
            defer {
                manager.discoveryTransport = IntelProviderDiscoveryExtras.defaultTransport
                manager._testRemoveProviders(ids: [p.id])
            }
            manager.discoveryTransport = evidenceTransport(
                status: 401, body: #"{"error":{"message":"Incorrect API key provided"}}"#)
            await manager.refreshModels(for: p.id)
            let bundle = manager.providerStates[p.id]?.lastReplayDiagnostics
            #expect(bundle?.phase == "model_discovery")
            #expect(bundle?.response?.statusCode == 401)
            #expect(bundle?.summary.contains("HTTP 401") == true)
            let text = bundle?.pasteboardText ?? ""
            #expect(text.contains("Incorrect API key provided"))
            #expect(!text.contains("sekret-token-value"))

            manager.discoveryTransport = evidenceTransport(status: 200, body: #"{"data":[{"id":"m1"}]}"#)
            await manager.refreshModels(for: p.id)
            #expect(manager.providerStates[p.id]?.isConnected == true)
            #expect(manager.providerStates[p.id]?.lastReplayDiagnostics == nil)
        }
    }

    @Test func transportFailureRecordsATransportErrorBundle() async {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            let p = evidenceProvider("offline.invalid")
            manager._testInstallConnectedProvider(p, discoveredModels: [])
            defer {
                manager.discoveryTransport = IntelProviderDiscoveryExtras.defaultTransport
                manager._testRemoveProviders(ids: [p.id])
            }
            manager.discoveryTransport = { _ in throw URLError(.notConnectedToInternet) }
            await manager.refreshModels(for: p.id)
            let bundle = manager.providerStates[p.id]?.lastReplayDiagnostics
            #expect(bundle?.response == nil)
            #expect(bundle?.transportURLErrorCode == URLError.notConnectedToInternet.rawValue)
            #expect(bundle?.summary.contains("transport error") == true)
            #expect(manager.providerStates[p.id]?.lastFailureWasTransient == true)
        }
    }
}
