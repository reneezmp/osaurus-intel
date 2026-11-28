//
//  ScreenContextChipTests.swift
//  OsaurusCoreTests — Computer Use
//
//  The composer's read-only "Screen context from <app>" chip (upstream Classic).
//  Fakes and source guards only: nothing here captures the screen, checks or
//  requests Accessibility, or touches `~/.osaurus`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Screen context composer chip")
struct ScreenContextChipTests {

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("chip shows only for an empty chat of an agent that shares screen context")
    func gate() {
        typealias C = FloatingInputCard
        #expect(C.screenContextChipMayShow(isEmptyChat: true, screenContextEnabled: true))
        #expect(!C.screenContextChipMayShow(isEmptyChat: false, screenContextEnabled: true))
        #expect(!C.screenContextChipMayShow(isEmptyChat: true, screenContextEnabled: false))
        #expect(!C.screenContextChipMayShow(isEmptyChat: false, screenContextEnabled: false))
    }

    @Test("the chip only reads state: no capture, no permission request")
    func chipNeverCapturesOrRequests() throws {
        let src = try Self.source("Views/Chat/FloatingInputCard.swift")
        let start = try #require(src.range(of: "struct ScreenContextIndicator"))
        let end = try #require(src.range(of: "private var selectorRow", range: start.upperBound ..< src.endIndex))
        let body = String(src[start.lowerBound ..< end.lowerBound])
        for banned in ["requestAccess", "request(", "captureForChat", "ScreenContextDistiller", "AXIsProcessTrustedWithOptions", "prompt"] {
            #expect(!body.contains(banned), "chip must not use \(banned)")
        }
        #expect(body.contains("permissionStates[.accessibility]"))
        #expect(body.contains("lastNonSelfAppName"))
    }

    @Test("ChatContentView passes the empty-chat signal to the composer")
    func emptyChatSignal() throws {
        let src = try Self.source("Views/Chat/ChatContentView.swift")
        #expect(src.contains("isEmptyChat: !observedSession.hasVisibleThreadMessages"))
    }

    @Test("the preview counts masked items only when the Privacy Filter is on")
    func previewMaskedCountGuarded() throws {
        let src = try Self.source("Views/Settings/ScreenContextPreview.swift")
        #expect(src.contains("guard config.enabled, !text.isEmpty"))
        #expect(src.contains("would be masked before cloud send"))
    }
}
