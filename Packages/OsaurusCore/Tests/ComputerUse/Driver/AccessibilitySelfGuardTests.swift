//
//  AccessibilitySelfGuardTests.swift
//  OsaurusCoreTests — Computer Use
//
//  The native driver must never resolve Osaurus's OWN accessibility tree on the
//  off-main driver queue: querying our own elements re-enters AppKit/SwiftUI
//  accessibility in-process, evaluating SwiftUI `body` and tripping its
//  main-thread assertion when it runs off the main thread (the production
//  AppHang/crash this guard fixes). Every AX entry point therefore treats self
//  as "nothing to perceive". These tests pin the self-identity check and the
//  empty/nil contract each entry point returns for our own pid; the live AX
//  behavior is exercised by the opt-in eval suite, not here.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct AccessibilitySelfGuardTests {
    @Test func isSelfMatchesOwnPidOnly() throws {
        #expect(AccessibilityManager.isSelf(AccessibilityManager.selfPid))
        #expect(AccessibilityManager.selfPid == ProcessInfo.processInfo.processIdentifier)
        // A pid that can't be ours (no process owns Int32.max).
        #expect(!AccessibilityManager.isSelf(Int32.max))
        // launchd is pid 1 and is never us.
        #expect(!AccessibilityManager.isSelf(1))
    }

    @Test func traverseReturnsEmptyForSelf() throws {
        let result = AccessibilityManager.shared.traverse(
            filter: ElementFilter(pid: AccessibilityManager.selfPid)
        )
        #expect(result.pid == AccessibilityManager.selfPid)
        #expect(result.elements.isEmpty)
        #expect(result.elementCount == 0)
        #expect(result.windows.isEmpty)
        #expect(!result.truncated)
        #expect(!result.app.isEmpty, "self result should still name the app")
    }

    @Test func listWindowsReturnsEmptyForSelf() throws {
        #expect(listWindowsForPid(AccessibilityManager.selfPid).windows.isEmpty)
    }

    @Test func focusedContentAndDeltaReturnNilForSelf() throws {
        #expect(computeFocusedContent(pid: AccessibilityManager.selfPid) == nil)
        #expect(computeFocusDelta(pid: AccessibilityManager.selfPid) == nil)
    }

    @Test func prepareForAccessibilityIsNoOpForSelf() throws {
        #expect(
            !AccessibilityManager.shared.prepareForAccessibility(pid: AccessibilityManager.selfPid),
            "preparing our own pid must be a no-op (never set AX flags on ourselves)"
        )
    }
}
