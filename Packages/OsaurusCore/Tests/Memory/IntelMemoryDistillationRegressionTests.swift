import Foundation
import Testing
@testable import OsaurusCore

struct IntelMemoryDistillationRegressionTests {
    @Test func routerQwenTextPartsDecodeIntoDistillation() throws {
        let wire = #"""
        {"choices":[{"message":{"role":"assistant","content":[{"type":"text","text":"{\"episode\":{\"summary\":\"Rosy remembers\",\"topics\":[\"Intel-safe\"]},\"facts\":[],\"entities\":[]}"}]}}]}
        """#
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: Data(wire.utf8))
        let content = try #require(response.choices.first?.message?.content)
        let distilled = MemoryService.shared.parseDistillResponse(content)
        #expect(distilled.episode?.summary == "Rosy remembers")
        #expect(distilled.episode?.topics == ["Intel-safe"])
    }

    @Test func nonTextCompletionPartsRemainRejected() {
        let wire = #"{"choices":[{"message":{"content":[{"type":"image_url","text":"reject"}]}}]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ChatCompletionResponse.self, from: Data(wire.utf8))
        }
    }

    @Test func coldDiscoveryExceptionIsNarrowlyScoped() {
        let router = RemoteProvider(name: "Osaurus", host: "router.osaurus.ai",
                                    providerType: .osaurusRouter, enabled: true, autoConnect: false)
        var disabled = router
        disabled.enabled = false
        let ordinary = RemoteProvider(name: "Osaurus", host: "fixture.invalid",
                                      providerType: .openaiLegacy, enabled: true, autoConnect: false)
        #expect(IntelRemoteModelEligibility.canRouteQualifiedModelDuringDiscovery(
            "osaurus/qwen-3-8-max", through: router))
        #expect(!IntelRemoteModelEligibility.canRouteQualifiedModelDuringDiscovery(
            "qwen-3-8-max", through: router))
        #expect(!IntelRemoteModelEligibility.canRouteQualifiedModelDuringDiscovery(
            "other/qwen-3-8-max", through: router))
        #expect(!IntelRemoteModelEligibility.canRouteQualifiedModelDuringDiscovery(
            "osaurus/qwen-3-8-max", through: disabled))
        #expect(!IntelRemoteModelEligibility.canRouteQualifiedModelDuringDiscovery(
            "osaurus/qwen-3-8-max", through: ordinary))
    }

    @Test func managedRouterQualificationRemainsAvailableBeforeProviderInstallation() {
        // This helper reads the real Router preference. Its identifier check is
        // still exact: a custom provider name and a bare model cannot inherit
        // the managed Router's cold-launch exception.
        #expect(
            IntelRemoteModelEligibility.canRouteManagedRouterModelDuringColdLaunch(
                "osaurus/qwen-3-8-max"
            ) == OsaurusRouter.isEnabled
        )
        #expect(!IntelRemoteModelEligibility.canRouteManagedRouterModelDuringColdLaunch(
            "qwen-3-8-max"
        ))
        #expect(!IntelRemoteModelEligibility.canRouteManagedRouterModelDuringColdLaunch(
            "other/qwen-3-8-max"
        ))
    }

    @Test func rawProviderDiagnosticIsRedactedAndBounded() {
        let secret = "sk-memory-fixture-secret"
        let wire = #"{"authorization":"Bearer \#(secret)","payload":"\#(String(repeating: "x", count: 8_000))"}"#
        let diagnostic = ChatEngine.safeResponseDiagnostic(Data(wire.utf8))

        #expect(diagnostic.contains("<redacted>"))
        #expect(diagnostic.hasSuffix("[truncated]"))
        #expect(!diagnostic.contains(secret))
        #expect(diagnostic.count < 4_200)
    }
}
