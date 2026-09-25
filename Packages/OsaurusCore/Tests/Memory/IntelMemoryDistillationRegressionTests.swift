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

    @Test func routerQwenSSEBodyIsFoldedForNonStreamingDistillation() throws {
        let wire = #"""
        data: {"id":"router-qwen","model":"qwen-3-8-max","choices":[{"index":0,"delta":{"role":"assistant","content":"{\"episode\":{"},"finish_reason":null}]}

        data: {"id":"router-qwen","model":"qwen-3-8-max","choices":[{"index":0,"delta":{"content":"\"summary\":\"Rosy SSE\",\"topics\":[\"Router\"]},\"facts\":[],\"entities\":[]}"},"finish_reason":null}]}

        data: {"id":"router-qwen","model":"qwen-3-8-max","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":12,"total_tokens":22}}

        data: [DONE]
        """#
        let response = try ChatEngine.decodeCompletionResponse(Data(wire.utf8))
        let content = try #require(response.choices.first?.message?.content)
        let distilled = MemoryService.shared.parseDistillResponse(content)

        #expect(distilled.episode?.summary == "Rosy SSE")
        #expect(distilled.episode?.topics == ["Router"])
        #expect(response.usage?.total_tokens == 22)
    }

    @Test func textlessRouterSSEBodyRemainsRejected() {
        let wire = """
        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]
        """
        #expect(throws: DecodingError.self) {
            try ChatEngine.decodeCompletionResponse(Data(wire.utf8))
        }
    }

    @Test func liveQwenLengthShapeIsAnOutputLimitNotMissingDecoderSupport() {
        let wire = """
        data: {"choices":[]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}

        data: [DONE]
        """
        do {
            _ = try ChatEngine.decodeCompletionResponse(Data(wire.utf8))
            Issue.record("A textless length-limited completion must fail")
        } catch DecodingError.dataCorrupted(let context) {
            #expect(context.debugDescription.contains("output-token limit"))
        } catch {
            Issue.record("Unexpected decoding error: \(error)")
        }
        let diagnostic = ChatEngine.safeResponseDiagnostic(Data(wire.utf8))
        #expect(diagnostic.contains("frames=2, choices=1"))
        #expect(diagnostic.contains("finishReasons=[\"length\"]"))
    }

    @Test func qwenDistillationGetsBoundedLargerOutputAllowance() {
        #expect(MemoryService.distillationOutputTokenLimit(for: "osaurus/qwen-3-8-max") == 4_096)
        #expect(MemoryService.distillationOutputTokenLimit(for: "osaurus/deepseek-flash") == 1_024)
        #expect(MemoryService.distillationOutputTokenLimit(for: "qwen-3-8-max") == 1_024)
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

    @Test func sseDiagnosticReportsShapeWithoutGeneratedText() {
        let wire = """
        data: {"choices":[{"delta":{},"finish_reason":null}]}

        data: {"choices":[{"delta":{"content":"private memory text"},"finish_reason":"stop"}]}

        data: [DONE]
        """
        let diagnostic = ChatEngine.safeResponseDiagnostic(Data(wire.utf8))
        #expect(diagnostic.contains("frames=2"))
        #expect(diagnostic.contains("contentKinds=[\"string\"]"))
        #expect(diagnostic.contains("deltaKeys=[\"content\"]"))
        #expect(!diagnostic.contains("private memory text"))
    }

    @Test func staleUnofferedToolGetsTerminalFailureText() {
        let result = ChatEngine.unofferedToolResult("search_memory")
        let encoded = StreamingToolHint.encodeDone(
            callId: "stale-call",
            name: "search_memory",
            arguments: #"{"query":"Apple"}"#,
            result: result
        )
        let terminal = StreamingToolHint.decodeDone(encoded)

        #expect(terminal?.callId == "stale-call")
        #expect(terminal?.name == "search_memory")
        #expect(terminal?.result == result)
        #expect(result.contains("not offered"))
    }
}
