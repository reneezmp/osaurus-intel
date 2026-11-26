//
//  InsightsImageRedactionTests.swift
//  OsaurusCoreTests — Chat
//
//  Audit-remediation coverage (P2): inline base64 image payloads (e.g.
//  Computer Use screenshots, scrubbed or not) must not be retained verbatim in
//  the Chat-UI Insights request-body buffer. `ChatEngine.redactInlineImagePayloads`
//  replaces the payload with a short marker while leaving the request shape —
//  and ordinary text content — intact for debugging.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct InsightsImageRedactionTests {
    @Test func redactsInlineBase64ImagePayload() {
        let payload = String(repeating: "A", count: 200)
        let json = "{\"image_url\":{\"url\":\"data:image/png;base64,\(payload)\"}}"
        let out = ChatEngine.redactInlineImagePayloads(in: json)

        #expect(!out.contains(payload), "the raw base64 payload must not survive")
        #expect(out.contains(";base64,"), "the request shape (the data-URL prefix) is kept")
        #expect(out.contains("[redacted 200-char image]"))
    }

    @Test func leavesOrdinaryTextContentIntact() {
        // No data-URL payload → returned unchanged (the panel still inspects text).
        let json = "{\"content\":\"Reach me about base64 encoding at jane@example.com\"}"
        #expect(ChatEngine.redactInlineImagePayloads(in: json) == json)
    }

    @Test func ignoresShortBase64LikeStrings() {
        // Below the 64-char threshold there's no image to redact.
        let json = "{\"url\":\"data:image/png;base64,AAAABBBBCCCC\"}"
        #expect(ChatEngine.redactInlineImagePayloads(in: json) == json)
    }

    @Test func redactsEveryImageInTheRequest() {
        let p1 = String(repeating: "B", count: 80)
        let p2 = String(repeating: "C", count: 120)
        let json =
            "[\"data:image/jpeg;base64,\(p1)\",\"data:image/png;base64,\(p2)\"]"
        let out = ChatEngine.redactInlineImagePayloads(in: json)

        #expect(!out.contains(p1))
        #expect(!out.contains(p2))
        #expect(out.contains("[redacted 80-char image]"))
        #expect(out.contains("[redacted 120-char image]"))
    }
}
