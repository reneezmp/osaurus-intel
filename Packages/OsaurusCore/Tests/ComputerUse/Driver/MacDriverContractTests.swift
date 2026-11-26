//
//  MacDriverContractTests.swift
//  OsaurusCoreTests — Computer Use
//
//  PR0 coverage for the ported macOS driver's pure, app-independent logic
//  (snapshot id format, key-name + modifier vocabulary, capture-mode parsing)
//  and the `MockMacDriver` conformer's scripting/recording contract. The
//  live AX/SkyLight/screenshot paths need a real app + permissions and are
//  exercised by the opt-in eval suite, not here.
//

import Foundation
import Testing

@testable import OsaurusCore


@Suite struct MacDriverCaptureModeTests {
    @Test func testParseDefaultsToSom() throws {
        #expect(CaptureMode.parse(nil) == .som)
        #expect(CaptureMode.parse("garbage") == .som)
        #expect(CaptureMode.parse("AX") == .ax)
        #expect(CaptureMode.parse("vision") == .vision)
    }

    @Test func testCaptureTierMapsAllCases() throws {
        #expect(Set(CaptureTier.allCases) == [.ax, .som, .vision])
    }
}

@Suite struct MockMacDriverContractTests {
    @Test func testDemoDriverPerceivesSeededSnapshot() async throws {
        let driver = MockMacDriver.demo()
        let apps = await driver.listApps()
        #expect((apps.first?.name) == "Demo")

        let pid = apps.first!.pid
        let snapshot = await driver.capture(pid: pid, tier: .ax)
        #expect(snapshot.elements.count == 2)
        #expect((snapshot.elements.first?.role) == "textfield")
        #expect(snapshot.focusedWindowId == 1)
    }

    @Test func testCaptureAdvancesThroughQueueThenHolds() async throws {
        let pid: Int32 = 99
        let first = makeSnapshot(id: 1, pid: pid, labels: ["A"])
        let second = makeSnapshot(id: 2, pid: pid, labels: ["A", "B"])
        let driver = MockMacDriver()
        await driver.enqueueSnapshots([first, second], pid: pid)

        let s1 = await driver.capture(pid: pid, tier: .ax)
        let s2 = await driver.capture(pid: pid, tier: .ax)
        let s3 = await driver.capture(pid: pid, tier: .ax)

        #expect(s1.elements.count == 1)
        #expect(s2.elements.count == 2)
        // Steady state: last snapshot repeats once the queue is exhausted.
        #expect(s3.elements.count == 2)
    }

    @Test func testRecordsElementActionsAndScriptsResults() async throws {
        let driver = MockMacDriver()
        await driver.enqueueActionResults([.failure("boom"), .ok()])

        let r1 = await driver.perform(.click(id: "s1-2"))
        let r2 = await driver.perform(.setValue(id: "s1-1", value: "hi"))

        #expect(!(r1.success))
        #expect(r1.error == "boom")
        #expect(r2.success)

        let recorded = await driver.elementActions
        #expect(recorded.count == 2)
    }

    @Test func testFindFiltersByRoleAndText() async throws {
        let pid: Int32 = 7
        let snap = makeSnapshot(id: 3, pid: pid, labels: ["Sign in", "Cancel"], roles: ["button", "button"])
        let driver = MockMacDriver()
        await driver.enqueueSnapshots([snap], pid: pid)

        let found = await driver.find(
            pid: pid,
            text: "sign",
            roles: ["button"],
            windowId: nil,
            enabledOnly: false,
            limit: 10
        )
        #expect(found.elements.count == 1)
        #expect((found.elements.first?.label) == "Sign in")
    }

    // MARK: Helpers

    private func makeSnapshot(
        id: Int,
        pid: Int32,
        labels: [String],
        roles: [String]? = nil
    ) -> CUSnapshot {
        let elements = labels.enumerated().map { idx, label in
            CUElement(
                id: "s\(id)-\(idx + 1)",
                role: roles?[idx] ?? "button",
                label: label,
                windowId: 1,
                enabled: true,
                x: 0,
                y: idx * 30,
                w: 80,
                h: 24,
                actions: ["press"]
            )
        }
        let window = CUWindowSummary(id: 1, title: "W", focused: true, x: 0, y: 0, w: 800, h: 600)
        return CUSnapshot(
            snapshotId: id,
            pid: pid,
            app: "MockApp",
            focusedWindow: "W",
            tier: .ax,
            truncated: false,
            windows: [window],
            elements: elements,
            image: nil
        )
    }
}
