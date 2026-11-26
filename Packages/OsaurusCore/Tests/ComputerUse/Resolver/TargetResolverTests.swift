//
//  TargetResolverTests.swift
//  OsaurusCoreTests — Computer Use
//
//  The one place mark→id resolution + staleness handling lives. These cover
//  the three outcomes the loop's retry/escalation policy keys off:
//   • resolved   — a confident unique element (by mark, then describe),
//   • reobserve  — probably exists but this view can't pin it (out-of-range
//                  mark, stale mark, ambiguous/zero describe), and
//   • deadEnd    — unusable as given (empty target).
//
//  Pure + model-free: build a view/snapshot in memory and resolve against it.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite struct TargetResolverTests {

    // MARK: - Fixtures

    private func el(_ id: String, _ role: String, _ label: String?, value: String? = nil) -> CUElement {
        CUElement(id: id, role: role, label: label, value: value)
    }

    private func make(_ elements: [CUElement]) -> (view: AgentView, snapshot: CUSnapshot) {
        let snap = CUSnapshot(
            snapshotId: 1,
            pid: 1,
            app: "App",
            focusedWindow: nil,
            tier: .ax,
            truncated: false,
            windows: [],
            elements: elements,
            image: nil
        )
        return (AgentView.build(from: snap, previous: nil), snap)
    }

    private func assertResolved(
        _ res: TargetResolution,
        id expected: String
    ) {
        guard case .resolved(let elementId, _) = res else {
            Issue.record("Expected resolved \(expected); got \(res)")
            return
        }
        #expect(elementId == expected)
    }

    private func reobserveReason(_ res: TargetResolution) -> String? {
        if case .reobserve(let r) = res { return r }
        return nil
    }

    private func deadEndReason(_ res: TargetResolution) -> String? {
        if case .deadEnd(let r) = res { return r }
        return nil
    }

    // MARK: - Mark resolution

    @Test func testResolvesByMark() {
        let (view, snap) = make([el("a", "button", "Go"), el("b", "textfield", "Search")])
        assertResolved(TargetResolver.resolve(AgentTarget(mark: 1), view: view, snapshot: snap), id: "a")
        assertResolved(TargetResolver.resolve(AgentTarget(mark: 2), view: view, snapshot: snap), id: "b")
    }

    @Test func testOutOfRangeMarkReobserves() {
        let (view, snap) = make([el("a", "button", "Go")])
        let reason = reobserveReason(
            TargetResolver.resolve(AgentTarget(mark: 99), view: view, snapshot: snap)
        )
        #expect(reason != nil)
        #expect(reason?.localizedCaseInsensitiveContains("current view") ?? false)
    }

    @Test func testStaleMarkReobserves() {
        // Mark exists in the (older) view, but the live snapshot no longer has
        // its id — the signature stale case the loop re-perceives on.
        let (view, _) = make([el("a", "button", "Go")])
        let liveSnap = CUSnapshot(
            snapshotId: 2,
            pid: 1,
            app: "App",
            focusedWindow: nil,
            tier: .ax,
            truncated: false,
            windows: [],
            elements: [el("z", "button", "Go")],  // different id
            image: nil
        )
        let reason = reobserveReason(
            TargetResolver.resolve(AgentTarget(mark: 1), view: view, snapshot: liveSnap)
        )
        #expect(reason?.localizedCaseInsensitiveContains("stale") ?? false, "got: \(reason ?? "nil")")
    }

    @Test func testOutOfRangeMarkWithDescribeFallbackResolves() {
        let (view, snap) = make([el("a", "button", "Send")])
        // Mark is bogus but the describe rescues it.
        assertResolved(
            TargetResolver.resolve(AgentTarget(mark: 99, describe: "Send"), view: view, snapshot: snap),
            id: "a"
        )
    }

    // MARK: - Describe resolution

    @Test func testDescribeUniqueResolves() {
        let (view, snap) = make([el("a", "button", "Go"), el("b", "textfield", "Search")])
        assertResolved(
            TargetResolver.resolve(AgentTarget(describe: "Search"), view: view, snapshot: snap),
            id: "b"
        )
    }

    @Test func testExactLabelBeatsSubstring() {
        // "Save" must resolve to the exact "Save", not the "Save As" substring.
        let (view, snap) = make([el("a", "button", "Save"), el("b", "button", "Save As")])
        assertResolved(
            TargetResolver.resolve(AgentTarget(describe: "Save"), view: view, snapshot: snap),
            id: "a"
        )
    }

    @Test func testAmbiguousDescribeReobserves() {
        let (view, snap) = make([
            el("a", "button", "Reply to all"),
            el("b", "button", "Reply to sender"),
        ])
        let reason = reobserveReason(
            TargetResolver.resolve(AgentTarget(describe: "reply"), view: view, snapshot: snap)
        )
        #expect(reason != nil)
        #expect(reason?.localizedCaseInsensitiveContains("matches 2") ?? false, "got: \(reason ?? "nil")")
    }

    @Test func testZeroMatchDescribeReobserves() {
        let (view, snap) = make([el("a", "button", "Go")])
        let reason = reobserveReason(
            TargetResolver.resolve(AgentTarget(describe: "nonexistent"), view: view, snapshot: snap)
        )
        #expect(reason?.localizedCaseInsensitiveContains("nothing matches") ?? false)
    }

    // MARK: - Dead ends

    @Test func testNilTargetDeadEnds() {
        let (view, snap) = make([el("a", "button", "Go")])
        #expect(deadEndReason(TargetResolver.resolve(nil, view: view, snapshot: snap)) != nil)
    }

    @Test func testEmptyTargetDeadEnds() {
        let (view, snap) = make([el("a", "button", "Go")])
        let res = TargetResolver.resolve(AgentTarget(mark: nil, describe: ""), view: view, snapshot: snap)
        #expect(deadEndReason(res) != nil)
    }
}
