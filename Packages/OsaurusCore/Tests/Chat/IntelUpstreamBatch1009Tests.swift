//
//  IntelUpstreamBatch1009Tests.swift
//  osaurusTests
//
//  Intel adaptations from the 2026-10-09 upstream batch
//  (docs/UPSTREAM_AUDIT_2026-10-09.md).
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelUpstreamBatch1009Tests {
    // MARK: - #3055 OpenRouter upstream errors (upstream's test bodies)

    @Test func errorMessageSurfacesOpenRouterUpstreamRaw() {
        let body =
            #"{"error":{"message":"Provider returned error","code":400,"metadata":{"raw":"{\"message\":\"tool_choice: type \\\"tool\\\" and \\\"any\\\" are not supported for this model.\"}","provider_name":"Amazon Bedrock"}}}"#
        let extracted = extractAPIErrorMessage(body)
        #expect(extracted.contains("Provider returned error"))
        #expect(extracted.contains("are not supported for this model"))
        #expect(extracted.contains("(code: 400)"))
    }

    @Test func errorMessagePlainTextOpenRouterRaw() {
        let body = #"{"error":{"message":"Provider returned error","metadata":{"raw":"upstream exploded"}}}"#
        #expect(extractAPIErrorMessage(body) == "Provider returned error: upstream exploded")
    }

    @Test func errorMessageKeepsOrdinaryBodies() {
        #expect(extractAPIErrorMessage(#"{"error":{"message":"bad key"}}"#) == "bad key")
        #expect(
            extractAPIErrorMessage(#"{"error":{"message":"bad key","code":"invalid_api_key"}}"#)
                == "bad key (code: invalid_api_key)")
        #expect(extractAPIErrorMessage(#"{"message":"flat"}"#) == "flat")
        #expect(extractAPIErrorMessage("  plain text  ") == "plain text")
    }
}

// MARK: - #3057 plugin card secret check runs off the main thread

/// Reads `ToolSecretsKeychain`, so it only runs under the keychain-disabled
/// test gate, where every secret lookup returns nil without a keychain call.
@Suite(.enabled(if: KeychainQueryHelpers.disablesKeychainForProcess))
struct IntelPluginSecretsStatusTests {
    @Test func reportsMissingRequiredSecrets() async {
        let required = [PluginManifest.SecretSpec(id: "api_key", label: "API Key")]
        let missing = await PluginSecretsStatus.anyAgentMissing(
            specs: required, pluginId: "intel.tests.plugin", agentIds: [Agent.defaultId])
        #expect(missing)
    }

    @Test func optionalSecretsOrNoAgentsAreNotMissing() async {
        let optional = [PluginManifest.SecretSpec(id: "api_key", label: "API Key", required: false)]
        let required = [PluginManifest.SecretSpec(id: "api_key", label: "API Key")]
        let optionalMissing = await PluginSecretsStatus.anyAgentMissing(
            specs: optional, pluginId: "intel.tests.plugin", agentIds: [Agent.defaultId])
        let noAgentsMissing = await PluginSecretsStatus.anyAgentMissing(
            specs: required, pluginId: "intel.tests.plugin", agentIds: [])
        #expect(!optionalMissing)
        #expect(!noAgentsMissing)
    }
}
