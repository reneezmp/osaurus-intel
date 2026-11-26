//
//  ComputerUseLoopActTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Coverage for the act-time robustness added for Electron apps (Slack):
//   • the coordinate fallback fired when a click resolves against the snapshot
//     value copy but fails at the LIVE AX layer (stale/removed ref — the
//     signature Electron failure), and
//   • the capture-tier escalation when even that fallback can't land, and
//   • the snapshot-cache retention depth that keeps a just-shown mark
//     resolvable across the several captures the loop makes per turn.
//
//  Driven through `ComputerUseLoop.act` directly with `MockMacDriver`, so no
//  live model is needed.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite struct ComputerUseLoopActTests {

    /// A cell at (100,200) sized 80x20 → center (140,210). The fallback should
    /// click that center.
    private func makeElement() -> CUElement {
        CUElement(id: "s1-13", role: "cell", label: "Jared", x: 100, y: 200, w: 80, h: 20)
    }

    private func clickAction() -> AgentAction {
        AgentAction(verb: .click, target: AgentTarget(mark: 13), note: "Open Jared")
    }

    private func grantedAvailability(screenRecording: Bool = true) -> MacDriverAvailability {
        MacDriverAvailability(accessibility: true, screenRecording: screenRecording, skyLight: true)
    }

    @Test func testClickRetriesAtElementCenterWhenLiveRefRemoved() async {
        let pid: Int32 = 4242
        let driver = MockMacDriver()
        // The AX-addressed click fails because the live ref is gone (Electron);
        // the coordinate fallback at the element's last-known center succeeds.
        await driver.enqueueActionResults([
            CUActionResult(success: false, error: "gone", removed: true),
            CUActionResult.ok(),
        ])

        var currentTier: CaptureTier = .ax
        var pendingFrame: CUImage?
        var lastView: AgentView?
        var lastSnapshot: CUSnapshot?
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "g")

        let out = await ComputerUseLoop.act(
            action: clickAction(),
            element: makeElement(),
            pid: pid,
            driver: driver,
            availability: grantedAvailability(),
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrame,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: 1
        )

        let coordActions = await driver.coordinateActions
        #expect(coordActions.count == 1, "Exactly one coordinate-click fallback expected")
        guard case let .click(x, y, _, _, clickPid)? = coordActions.first else {
            Issue.record("Expected a coordinate click fallback"); return
        }
        #expect(x == 140)
        #expect(y == 210)
        #expect(clickPid == pid)
        #expect(metrics.coordinateFallbacks == 1)
        #expect(out.contains("Input was posted") && !out.contains("Action failed"), "Fallback posted the input (the mock view never changes, so it stays unverified); got: \(out)")
        // A landed fallback means no need to escalate.
        #expect(currentTier == .ax)
    }

    @Test func testPersistentStaleEscalatesCaptureTier() async {
        let pid: Int32 = 4242
        let driver = MockMacDriver()
        // Both the AX click and the coordinate fallback fail removed.
        await driver.enqueueActionResults([
            CUActionResult(success: false, error: "gone", removed: true),
            CUActionResult(success: false, error: "still gone", removed: true),
        ])

        var currentTier: CaptureTier = .ax
        var pendingFrame: CUImage?
        var lastView: AgentView?
        var lastSnapshot: CUSnapshot?
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "g")

        _ = await ComputerUseLoop.act(
            action: clickAction(),
            element: makeElement(),
            pid: pid,
            driver: driver,
            availability: grantedAvailability(),
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrame,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: 1
        )

        #expect(metrics.coordinateFallbacks == 1)
        #expect(currentTier == .som, "A click still stale after the fallback should escalate ax→som")
        #expect(metrics.maxTier == .som)
    }

    @Test func testSetValueRetriesViaCoordinateFocusWhenRefRemoved() async {
        let pid: Int32 = 4242
        let driver = MockMacDriver()
        // set_value fails (live ref removed), the focus click lands, the
        // pid-context type that replaces the value lands too.
        await driver.enqueueActionResults([
            CUActionResult(success: false, error: "gone", removed: true),  // setValue
            CUActionResult.ok(),  // focus coordinate click
            CUActionResult.ok(),  // typeText retry
        ])

        var currentTier: CaptureTier = .ax
        var pendingFrame: CUImage?
        var lastView: AgentView?
        var lastSnapshot: CUSnapshot?
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "g")

        let out = await ComputerUseLoop.act(
            action: AgentAction(verb: .setValue, target: AgentTarget(mark: 13), text: "Jared"),
            element: makeElement(),
            pid: pid,
            driver: driver,
            availability: grantedAvailability(),
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrame,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: 1
        )

        let coordActions = await driver.coordinateActions
        #expect(coordActions.count == 1, "A focus coordinate-click should precede the retry")
        let elementActions = await driver.elementActions
        #expect(elementActions.count == 2, "set_value then the pid-context type retry")
        guard case let .typeText(id, typePid, text, replace) = elementActions.last else {
            Issue.record("Expected a typeText retry; got \(elementActions)"); return
        }
        #expect(id == nil, "The retry must drop the stale id and type in pid context")
        #expect(typePid == pid)
        #expect(text == "Jared")
        #expect(replace)
        #expect(metrics.coordinateFallbacks == 1)
        #expect(out.contains("Input was posted") && !out.contains("Action failed"), "Fallback posted the input (the mock view never changes, so it stays unverified); got: \(out)")
        #expect(currentTier == .ax, "A landed fallback means no need to escalate")
    }

    @Test func testClearRetriesViaCoordinateFocusWhenRefRemoved() async {
        let pid: Int32 = 4242
        let driver = MockMacDriver()
        await driver.enqueueActionResults([
            CUActionResult(success: false, error: "gone", removed: true),  // clearField
            CUActionResult.ok(),  // focus coordinate click
            CUActionResult.ok(),  // typeText("") retry
        ])

        var currentTier: CaptureTier = .ax
        var pendingFrame: CUImage?
        var lastView: AgentView?
        var lastSnapshot: CUSnapshot?
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "g")

        _ = await ComputerUseLoop.act(
            action: AgentAction(verb: .clear, target: AgentTarget(mark: 13)),
            element: makeElement(),
            pid: pid,
            driver: driver,
            availability: grantedAvailability(),
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrame,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: 1
        )

        let elementActions = await driver.elementActions
        guard case let .typeText(id, _, text, replace) = elementActions.last else {
            Issue.record("Expected a typeText retry; got \(elementActions)"); return
        }
        #expect(id == nil)
        #expect(text == "", "clear is a wholesale replace with empty text")
        #expect(replace)
        #expect(metrics.coordinateFallbacks == 1)
    }

    @Test func testTypeRetriesViaCoordinateFocusWhenRefRemoved() async {
        let pid: Int32 = 4242
        let driver = MockMacDriver()
        await driver.enqueueActionResults([
            CUActionResult(success: false, error: "gone", removed: true),  // typeText(id)
            CUActionResult.ok(),  // focus coordinate click
            CUActionResult.ok(),  // typeText(nil) retry
        ])

        var currentTier: CaptureTier = .ax
        var pendingFrame: CUImage?
        var lastView: AgentView?
        var lastSnapshot: CUSnapshot?
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "g")

        _ = await ComputerUseLoop.act(
            action: AgentAction(verb: .type, target: AgentTarget(mark: 13), text: "hi", replace: false),
            element: makeElement(),
            pid: pid,
            driver: driver,
            availability: grantedAvailability(),
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrame,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: 1
        )

        let coordActions = await driver.coordinateActions
        #expect(coordActions.count == 1)
        let elementActions = await driver.elementActions
        guard case let .typeText(id, _, text, replace) = elementActions.last else {
            Issue.record("Expected a typeText retry; got \(elementActions)"); return
        }
        #expect(id == nil, "The retry types into the focused field in pid context")
        #expect(text == "hi")
        #expect(!(replace), "The original append (replace=false) semantics are preserved")
        #expect(metrics.coordinateFallbacks == 1)
    }

    @Test func testTextVerificationWaitsForSettledAXValue() async {
        let pid: Int32 = 4242
        let window = CUWindowSummary(
            id: 7,
            title: "Untitled",
            focused: true,
            x: 0,
            y: 0,
            w: 600,
            h: 400
        )
        func snapshot(_ id: Int, _ value: String) -> CUSnapshot {
            CUSnapshot(
                snapshotId: id,
                pid: pid,
                app: "TextEdit",
                focusedWindow: "Untitled",
                tier: .ax,
                truncated: false,
                windows: [window],
                elements: [
                    CUElement(
                        id: "s\(id)-1",
                        role: "textarea",
                        value: value,
                        path: "Window[Untitled] > textarea",
                        windowId: 7,
                        focused: true,
                        enabled: true
                    )
                ],
                image: nil
            )
        }

        let driver = MockMacDriver(
            snapshots: [
                pid: [
                    snapshot(2, "Hello agai"),
                    snapshot(3, "Hello again"),
                ]
            ]
        )
        let original = CUElement(
            id: "s1-1",
            role: "textarea",
            value: "Hello from OracHQ",
            path: "Window[Untitled] > textarea",
            windowId: 7,
            focused: true,
            enabled: true
        )
        var currentTier: CaptureTier = .ax
        var pendingFrame: CUImage?
        var lastView: AgentView?
        var lastSnapshot: CUSnapshot?
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "g")

        let out = await ComputerUseLoop.act(
            action: AgentAction(
                verb: .type,
                target: AgentTarget(mark: 1),
                text: "Hello again",
                replace: true
            ),
            element: original,
            pid: pid,
            driver: driver,
            availability: grantedAvailability(),
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrame,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: 1
        )

        let captureCount = await driver.captureCount
        #expect(captureCount == 2)
        #expect(out.contains(#"= "Hello again""#), "The settled value must reach the planner: \(out)")
        #expect(!(out.contains(#"= "Hello agai""#)), "A transient prefix must not reach the planner: \(out)")
        #expect(lastSnapshot?.snapshotId == 3)
    }

    // MARK: - New verbs (Phase 2)

    private func actNoFallbackHelper(_ action: AgentAction, destination: CUElement? = nil) async -> (
        driver: MockMacDriver, out: String
    ) {
        let pid: Int32 = 4242
        let driver = MockMacDriver()
        var currentTier: CaptureTier = .ax
        var pendingFrame: CUImage?
        var lastView: AgentView?
        var lastSnapshot: CUSnapshot?
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "g")
        let out = await ComputerUseLoop.act(
            action: action,
            element: makeElement(),
            destinationElement: destination,
            pid: pid,
            driver: driver,
            availability: grantedAvailability(),
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrame,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: 1
        )
        return (driver, out)
    }

    @Test func testDoubleClickPerformsDoubleClickOnElement() async {
        let (driver, out) = await actNoFallbackHelper(
            AgentAction(verb: .doubleClick, target: AgentTarget(mark: 13))
        )
        let actions = await driver.elementActions
        guard case let .click(id, button, double)? = actions.first else {
            Issue.record("Expected an element click; got \(actions)"); return
        }
        #expect(id == "s1-13")
        #expect(button == .left)
        #expect(double, "double_click must set doubleClick:true")
        #expect(out.contains("Input was posted") && !out.contains("Action failed"), "Driver success with an unchanged mock view must read as posted-but-unverified; got: \(out)")
    }

    @Test func testRightClickPerformsRightClickOnElement() async {
        let (driver, _) = await actNoFallbackHelper(
            AgentAction(verb: .rightClick, target: AgentTarget(mark: 13))
        )
        let actions = await driver.elementActions
        guard case let .click(_, button, double)? = actions.first else {
            Issue.record("Expected an element click; got \(actions)"); return
        }
        #expect(button == .right, "right_click must use the right button")
        #expect(!(double))
    }

    @Test func testDragUsesCoordinateDragBetweenCenters() async {
        // start center (140,210); destination cell at (300,400) 80x20 → (340,410).
        let dest = CUElement(id: "s1-20", role: "cell", label: "Trash", x: 300, y: 400, w: 80, h: 20)
        let (driver, out) = await actNoFallbackHelper(
            AgentAction(verb: .drag, target: AgentTarget(mark: 13), to: AgentTarget(mark: 20)),
            destination: dest
        )
        let coords = await driver.coordinateActions
        guard case let .drag(sx, sy, ex, ey, dragPid)? = coords.first else {
            Issue.record("Expected a coordinate drag; got \(coords)"); return
        }
        #expect(sx == 140)
        #expect(sy == 210)
        #expect(ex == 340)
        #expect(ey == 410)
        #expect(dragPid == 4242)
        #expect(out.contains("Input was posted") && !out.contains("Action failed"), "Driver success with an unchanged mock view must read as posted-but-unverified; got: \(out)")
    }

    @Test func testDoubleClickRetriesAtCenterWhenRefRemoved() async {
        let pid: Int32 = 4242
        let driver = MockMacDriver()
        await driver.enqueueActionResults([
            CUActionResult(success: false, error: "gone", removed: true),  // element double-click
            CUActionResult.ok(),  // coordinate fallback
        ])
        var currentTier: CaptureTier = .ax
        var pendingFrame: CUImage?
        var lastView: AgentView?
        var lastSnapshot: CUSnapshot?
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "g")
        _ = await ComputerUseLoop.act(
            action: AgentAction(verb: .doubleClick, target: AgentTarget(mark: 13)),
            element: makeElement(),
            pid: pid,
            driver: driver,
            availability: grantedAvailability(),
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrame,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: 1
        )
        let coords = await driver.coordinateActions
        guard case let .click(x, y, button, double, _)? = coords.first else {
            Issue.record("Expected a coordinate-click fallback; got \(coords)"); return
        }
        #expect(x == 140)
        #expect(y == 210)
        #expect(button == .left)
        #expect(double, "The double_click fallback must preserve doubleClick:true")
        #expect(metrics.coordinateFallbacks == 1)
    }

    @Test func testNoEscalationWithoutScreenRecording() async {
        let pid: Int32 = 4242
        let driver = MockMacDriver()
        await driver.enqueueActionResults([
            CUActionResult(success: false, error: "gone", removed: true),
            CUActionResult(success: false, error: "still gone", removed: true),
        ])

        var currentTier: CaptureTier = .ax
        var pendingFrame: CUImage?
        var lastView: AgentView?
        var lastSnapshot: CUSnapshot?
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "g")

        _ = await ComputerUseLoop.act(
            action: clickAction(),
            element: makeElement(),
            pid: pid,
            driver: driver,
            availability: grantedAvailability(screenRecording: false),
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrame,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: 1
        )

        #expect(currentTier == .ax, "No Screen Recording means there is no tier to escalate to")
    }
}

@Suite struct AccessibilityManagerRetentionTests {
    @Test func testRetainsSixSnapshotGenerations() {
        let mgr = AccessibilityManager.shared
        var ids: [Int] = []
        for _ in 0 ..< 7 { ids.append(mgr.beginNewSnapshot(pid: 31337)) }

        // The oldest of seven consecutive generations rotates out (retain 6),
        // so the whole snapshot is gone → stale.
        guard case .stale = mgr.lookup(id: "s\(ids[0])-1") else {
            Issue.record("Oldest snapshot should have been evicted (stale)"); return
        }

        // The newest six are retained. Element 1 was never stored in these
        // empty snapshots, so lookup reports `removed` (snapshot present, id
        // absent) — the signal that the generation is still cached, distinct
        // from the evicted `stale` above.
        for id in ids.suffix(6) {
            guard case .removed = mgr.lookup(id: "s\(id)-1") else {
                Issue.record("Retained snapshot \(id) should report removed, not stale"); return
            }
        }
    }
}
