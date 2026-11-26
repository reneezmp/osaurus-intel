//
//  BackgroundDriverRouteTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Regression guard for the SkyLight + CGEvent.postToPid double-delivery:
//  SkyLight's status is not a delivery acknowledgement: a completed call can
//  deliver even when it returns zero. These tests pin each synthesized event to
//  exactly one app-class-selected transport via injected spies (no live app or
//  Accessibility permission required).
//

import CoreGraphics
import Testing

@testable import OsaurusCore

@Suite
struct BackgroundDriverRouteTests {

    /// Counts posts per transport. `@unchecked Sendable`: only ever mutated on
    /// the calling thread inside a single synchronous driver call.
    private final class TransportSpy: @unchecked Sendable {
        var skyLight = 0
        var postToPid = 0
        var hid = 0
    }

    private func makeDriver(
        spy: TransportSpy,
        skyLightAvailable: Bool,
        chromium: Bool = false,
        skyLightAccepted: Bool = true
    ) -> BackgroundDriver {
        var t = BackgroundDriver.Transports.live
        t.isWindowServerVisible = { _ in true }
        t.skyLightAvailable = { skyLightAvailable }
        t.skyLightPost = { _, _ in
            spy.skyLight += 1; return skyLightAccepted
        }
        t.postToPid = { _, _ in spy.postToPid += 1 }
        t.hidPost = { _ in spy.hid += 1 }
        t.isChromium = { _ in chromium }
        t.focusWithoutRaise = { _ in }
        return BackgroundDriver(transports: t)
    }

    @Test func cocoaKeyPressUsesOnlyPublicPerPidEvenWhenSkyLightExists() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: true)

        let result = driver.pressKey(pid: 4242, keyCode: 0)

        #expect(result.success)
        #expect(spy.skyLight == 0, "Cocoa must not receive a private transport attempt")
        #expect(spy.postToPid == 2, "keyDown + keyUp use public CoreGraphics once each")
        #expect(spy.hid == 0)
        #expect(driver.lastRoute == .perPid)
    }

    @Test func cocoaTypePostsEachCharacterExactlyOnceViaPublicPerPid() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: true)

        let result = driver.type(pid: 4242, text: "hello world")

        #expect(result.success)
        // 11 characters × (keyDown + keyUp) = 22 posts on one transport.
        #expect(spy.skyLight == 0)
        #expect(spy.postToPid == 22, "the double-delivery bug would also call SkyLight")
        #expect(spy.hid == 0)
    }

    @Test func cocoaClickPostsDownUpViaPublicPerPidWithoutPrivateAttempt() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: true)

        let result = driver.click(pid: 4242, point: CGPoint(x: 10, y: 10))

        #expect(result.success)
        #expect(spy.skyLight == 0)
        #expect(spy.postToPid == 2)
        #expect(spy.hid == 0)
        #expect(driver.lastRoute == .perPid)
    }

    @Test func cocoaPerPidRouteDoesNotDependOnSkyLightAvailability() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: false)

        let result = driver.pressKey(pid: 4242, keyCode: 0)

        #expect(result.success)
        #expect(spy.skyLight == 0)
        #expect(spy.postToPid == 2, "keyDown + keyUp via the CoreGraphics fallback")
        #expect(spy.hid == 0)
        #expect(driver.lastRoute == .perPid)
    }

    @Test func cocoaNeverCallsSkyLightEvenWhenItsStubWouldReturnFalse() {
        let spy = TransportSpy()
        let driver = makeDriver(
            spy: spy,
            skyLightAvailable: true,
            skyLightAccepted: false
        )

        let result = driver.pressKey(pid: 4242, keyCode: 0)

        #expect(result.success)
        #expect(spy.skyLight == 0)
        #expect(spy.postToPid == 2)
        #expect(spy.hid == 0)
        #expect(driver.lastRoute == .perPid)
    }

    @Test func chromiumSkyLightCallIsTerminalEvenWhenStatusIsFalse() {
        let spy = TransportSpy()
        let driver = makeDriver(
            spy: spy,
            skyLightAvailable: true,
            chromium: true,
            skyLightAccepted: false
        )

        let result = driver.pressKey(pid: 4242, keyCode: 0)

        #expect(result.success)
        // Primer down/up plus key down/up each use SkyLight exactly once. The
        // returned Bool is deliberately not used for a same-event fallback.
        #expect(spy.skyLight == 4)
        #expect(spy.postToPid == 0)
        #expect(spy.hid == 0)
        #expect(driver.lastRoute == .skyLight)
    }

    // MARK: - Chromium / Electron HID escalation

    @Test func chromiumKeyPressEscalatesToHidWhenSkyLightUnavailable() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: false, chromium: true)

        let result = driver.pressKey(pid: 4242, keyCode: 0)

        #expect(result.success)
        // Chromium web content silently drops per-pid events, so the fallback
        // path escalates to the HID tap rather than posting a per-pid event
        // that never lands. `pressKey` first runs the Chromium user-activation
        // primer (a -1,-1 decoy down/up pair), so: 2 decoy + keyDown + keyUp.
        #expect(spy.postToPid == 0, "per-pid is unreliable for Chromium; must escalate to HID")
        #expect(spy.hid == 4, "decoy click pair + keyDown + keyUp, all via the HID tap")
        #expect(spy.skyLight == 0)
        #expect(driver.lastRoute == .hidFallback)
    }

    @Test func chromiumPrefersSkyLightWhenAvailable() {
        // SkyLight is trusted by Chromium renderers, so when it's available
        // there is no cursor-warping HID needed.
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: true, chromium: true)

        let result = driver.pressKey(pid: 4242, keyCode: 0)

        #expect(result.success)
        // Decoy click pair (2) + keyDown + keyUp (2), all via SkyLight.
        #expect(spy.skyLight == 4)
        #expect(spy.hid == 0, "no HID warp needed when SkyLight is available")
        #expect(spy.postToPid == 0)
        #expect(driver.lastRoute == .skyLight)
    }

    @Test func chromiumClickEscalatesDecoyAndRealClickToHid() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: false, chromium: true)

        let result = driver.click(pid: 4242, point: CGPoint(x: 10, y: 10))

        #expect(result.success)
        // Decoy (-1,-1) down/up + real down/up = 4 events, all via HID since
        // SkyLight is unavailable and per-pid won't deliver to the renderer.
        #expect(spy.hid == 4)
        #expect(spy.postToPid == 0)
        #expect(driver.lastRoute == .hidFallback)
    }
}
