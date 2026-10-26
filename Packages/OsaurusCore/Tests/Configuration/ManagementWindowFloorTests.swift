//
//  ManagementWindowFloorTests.swift
//  osaurusTests
//
//  Regression coverage for Sentry APPLE-MACOS-1ZM (NSGenericException
//  "more Update Constraints in Window passes than there are views"): the
//  settings window's hosting controller must not let SwiftUI drive the
//  window frame — no `NSHostingSizingOptions` at all — while the floor the
//  root enforces still reaches `contentMinSize` through the controller's
//  `preferredMinimumSize`, and keeps following the screen-clamped value
//  `ManagementStateManager` publishes.
//
//  Intel: upstream builds the window through `WindowManager.createWindow`,
//  which Intel doesn't compile. Intel's Settings window is built in
//  `AppDelegate.showManagementWindow` around
//  `AppDelegate.makeManagementHostingController`, so the window here is
//  assembled the same way (titled, full-size content). Upstream's deeplink
//  replacement-controller test is omitted: Intel reuses the window instead.
//

import AppKit
import SwiftUI
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ManagementWindowFloorTests {

    /// Creates the settings window the way the app does and tears it down
    /// so the shared manager is left as found.
    private func withManagementWindow(_ body: (NSWindow, ManagementStateManager) throws -> Void) throws {
        let manager = ManagementStateManager.shared
        manager.updateMinimumContentSize(availableContentSize: .zero)
        let root = Color.clear.frame(
            minWidth: manager.minimumContentSize.width,
            maxWidth: .infinity,
            minHeight: manager.minimumContentSize.height,
            maxHeight: .infinity)
        let (host, subscription) = AppDelegate.makeManagementHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        defer {
            subscription.cancel()
            window.contentViewController = nil
            window.close()
            manager.updateMinimumContentSize(availableContentSize: .zero)
        }
        try body(window, manager)
    }

    private func chrome(of window: NSWindow) -> CGFloat {
        max(0, window.frame.height - window.contentLayoutRect.height)
    }

    @Test("the settings window gives SwiftUI no sizing options")
    func hostingControllerHasNoSizingOptions() throws {
        try withManagementWindow { window, _ in
            let host = try #require(window.contentViewController as? any AppKitOwnedWindowHosting)
            #expect(host.effectiveSizingOptions.isEmpty)
        }
    }

    @Test("the AppKit floor equals the clamped root floor plus titlebar chrome")
    func contentMinSizeMirrorsClampedFloor() throws {
        try withManagementWindow { window, manager in
            window.layoutIfNeeded()
            let expected = manager.minimumContentSize
            #expect(window.contentMinSize.width == expected.width)
            #expect(window.contentMinSize.height == expected.height + chrome(of: window))
            #expect(expected == ManagementStateManager.designMinimumContentSize)
        }
    }

    @Test("re-clamping the floor for a smaller screen updates contentMinSize without SwiftUI")
    func contentMinSizeFollowsPublishedFloor() throws {
        try withManagementWindow { window, manager in
            window.layoutIfNeeded()
            manager.updateMinimumContentSize(availableContentSize: CGSize(width: 800, height: 500))
            // The subscription delivers on the main run loop; drain one turn.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            #expect(manager.minimumContentSize == CGSize(width: 800, height: 500))
            let host = try #require(window.contentViewController as? any AppKitOwnedWindowHosting)
            #expect(host.minimumContentSize == CGSize(width: 800, height: 500))
            // Intel (2026-10-26): under SwiftPM's test helper the window is
            // never shown, and once the main run loop turns AppKit collapses
            // it to 1x1 and clears `contentMinSize` (traced: 940x641 before
            // the turn, 0x0 with frame 1x1 after). The forwarding above is
            // what this test owns; a shown window keeps its floor (Rosy
            // checklist: resize Settings, move it to a smaller screen).
            withKnownIssue("Unshown test window collapses when the run loop turns", isIntermittent: true) {
                #expect(window.contentMinSize.width == 800)
                #expect(window.contentMinSize.height == 500 + chrome(of: window))
            }
        }
    }

    @Test("layout passes never move the window frame when it is below the floor")
    func layoutDoesNotResizeWindowBelowFloor() throws {
        // With `.minSize` on, `NSHostingView.windowDidLayout` resized a window
        // that was smaller than the root's floor; a floor the screen clamps
        // straight back made that a loop. The frame must now be AppKit's alone.
        try withManagementWindow { window, _ in
            let small = NSRect(x: 100, y: 100, width: 300, height: 200)
            window.setFrame(small, display: false)
            for _ in 0 ..< 5 {
                window.layoutIfNeeded()
                window.contentView?.layoutSubtreeIfNeeded()
            }
            #expect(window.frame == small)
        }
    }

}
