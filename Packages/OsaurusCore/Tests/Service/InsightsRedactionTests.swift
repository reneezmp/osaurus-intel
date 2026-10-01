//
//  InsightsRedactionTests.swift
//  OsaurusCoreTests
//
//  Verifies the defense-in-depth credential scrubber that runs before any
//  request body is written into the request log ring buffer. The scrubber
//  exists so a future caller that forgets to redact a `/pair` (or other
//  token-bearing) response still does not leak `osk-v1` keys to disk.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("InsightsService.redactCredentials")
struct InsightsRedactionTests {

    @Test
    func redactsApiKeyValueInJSON() {
        let body = #"{"agentAddress":"0xabc","apiKey":"osk-v1.payload.signature","isPermanent":true}"#
        let scrubbed = InsightsService.redactCredentials(body)
        #expect(!scrubbed.contains("osk-v1.payload.signature"))
        #expect(scrubbed.contains("<redacted>"))
        // Surrounding structure is preserved.
        #expect(scrubbed.contains("\"agentAddress\":\"0xabc\""))
        #expect(scrubbed.contains("\"isPermanent\":true"))
    }

    @Test
    func redactsBearerHeaderValue() {
        let body = "Authorization: Bearer osk-v1.aaa.bbb"
        let scrubbed = InsightsService.redactCredentials(body)
        #expect(!scrubbed.contains("osk-v1.aaa.bbb"))
        #expect(scrubbed.contains("Bearer <redacted>"))
    }

    @Test
    func redactsBearerInJSONStringifiedHeader() {
        let body = #"{"headers":{"Authorization":"Bearer osk-v1.qwe.rty"}}"#
        let scrubbed = InsightsService.redactCredentials(body)
        #expect(!scrubbed.contains("osk-v1.qwe.rty"))
    }

    @Test
    func leavesOrdinaryStringsAlone() {
        let body = #"{"role":"user","content":"hello"}"#
        let scrubbed = InsightsService.redactCredentials(body)
        #expect(scrubbed == body)
    }

    @Test
    func redactsMultipleOccurrences() {
        // Two JSON-style values in the same blob — both should be scrubbed.
        let body = #"["osk-v1.aaa.bbb","osk-v1.ccc.ddd"]"#
        let scrubbed = InsightsService.redactCredentials(body)
        #expect(!scrubbed.contains("osk-v1.aaa.bbb"))
        #expect(!scrubbed.contains("osk-v1.ccc.ddd"))
    }

    @Test
    func bareTokenInProseIsLeftAlone() {
        // The redactor is intentionally narrow: it scrubs `Bearer <token>`
        // and JSON-string-quoted token values but does NOT touch tokens that
        // appear bare in arbitrary prose. Logging callers are expected to
        // structure secrets as one of the recognised shapes.
        let body = "diagnostic line mentioning osk-v1.foo.bar"
        let scrubbed = InsightsService.redactCredentials(body)
        #expect(scrubbed == body)
    }

    // Upstream's hardened redactor (#1961, #2683): bare `sk-` keys, unquoted
    // header forms and Workspaces attestation fields. The attestation case is
    // upstream's `AgentScopePolicyTests` check; Intel doesn't compile that suite.

    @Test
    func insightsRedactorCatchesAttestationAndWalletSignatureValues() {
        let body =
            #"{"team_redeem":{"attestation":"eyJhIjoxfQ.c2ln","wallet_signature":"0xabcdef","agent_address":"0xabc"}}"#
        let redacted = InsightsService.redactCredentials(body)
        #expect(!redacted.contains("eyJhIjoxfQ.c2ln"))
        #expect(!redacted.contains("0xabcdef"))
        #expect(redacted.contains(#""attestation":"<redacted>""#))
        #expect(redacted.contains(#""wallet_signature":"<redacted>""#))
        #expect(redacted.contains("0xabc"))
    }

    @Test
    func redactsUnquotedHeaderCredentials() {
        let body = "x-api-key: plainsecret123\napi-key=othersecret456\nx-goog-api-key: AIzaSecret789"
        let scrubbed = InsightsService.redactCredentials(body)
        #expect(!scrubbed.contains("plainsecret123"))
        #expect(!scrubbed.contains("othersecret456"))
        #expect(!scrubbed.contains("AIzaSecret789"))
        #expect(scrubbed.contains("x-api-key: <redacted>"))
        #expect(scrubbed.contains("api-key=<redacted>"))
    }

    @Test
    func redactsBareProviderKeyInProse() {
        let body = "request failed for key sk-ant-api03-abcdefghijkl while streaming"
        let scrubbed = InsightsService.redactCredentials(body)
        #expect(!scrubbed.contains("sk-ant-api03-abcdefghijkl"))
        #expect(scrubbed.contains("for key <redacted> while"))
    }

    @Test
    func bearerAuthorizationKeepsSchemeWord() {
        let body = #"{"Authorization":"Bearer sk-proj-abcdefghijkl"}"#
        let scrubbed = InsightsService.redactCredentials(body)
        #expect(!scrubbed.contains("sk-proj-abcdefghijkl"))
        #expect(scrubbed.contains("Bearer <redacted>"))
    }
}
