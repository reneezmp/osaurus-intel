//
//  IntelPrivacyUITests.swift
//  osaurus / PrivacyFilter Tests
//
//  `W-privacy-filter` stage 4 (Intel): the Privacy tab's wiring and the
//  "Incompatible: needs an Apple Silicon Mac" policy for the two MLX detectors.
//  Synthetic data only; no network, keychain or `~/.osaurus`.
//

import Foundation
import Testing

@testable import OsaurusCore

private final class RunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("Privacy tab (Intel)")
struct IntelPrivacyUITests {

    @Test("Privacy tab sits in General and resolves from deep links")
    func managementTabEntry() {
        #expect(ManagementSection.general.tabs.contains(.privacy))
        #expect(ManagementTab.resolved(from: "privacy") == .privacy)
        #expect(ManagementTab.privacy.label == "Privacy")
        #expect(ManagementTab.privacy.isAvailableOnIntel)
    }

    @Test("Privacy sub-tabs resolve upstream ids and visible titles")
    func subTabResolution() {
        #expect(PrivacyTab.resolved(from: "overview") == .overview)
        #expect(PrivacyTab.resolved(from: "Filter") == .overview)
        #expect(PrivacyTab.resolved(from: "providers") == .overview)
        #expect(PrivacyTab.resolved(from: "rules") == .rules)
        #expect(PrivacyTab.resolved(from: "model") == .model)
        #expect(PrivacyTab.resolved(from: "Models") == .model)
        #expect(PrivacyTab.resolved(from: "storage") == nil)  // forwarded to General by the view
        #expect(PrivacyTab.allCases.count == 3)
    }

    @Test("No model detector is runnable on Intel")
    func modelDetectorsIncompatible() {
        #expect(PrivacyDetectorSupport.modelDetectorsRunnable == false)
    }

    @Test("Settings search finds the Privacy Filter switch and opens the Filter sub-tab")
    func searchEntries() throws {
        let entry = try #require(SettingsSearchIndex.entries.first { $0.id == "privacy.filter.enabled" })
        #expect(entry.tab == .privacy)
        #expect(entry.subTab == "overview")
        let rules = try #require(SettingsSearchIndex.entries.first { $0.id == "privacy.rules.custom" })
        #expect(rules.subTab == "rules")
        #expect(SettingsSearchIndex.search("scrub pii").contains { $0.id == "privacy.filter.enabled" })
        // Activity Log stays under General on Intel.
        let log = try #require(SettingsSearchIndex.entries.first { $0.id == "privacy.activityLog.retention" })
        #expect(log.tab == .settings)
    }

    @MainActor
    @Test("Debounced save runs on flush")
    func debouncerFlushRunsPendingWork() {
        let debouncer = PrivacyViewSaveDebouncer()
        let ran = RunCounter()
        debouncer.schedule { ran.bump() }
        debouncer.flush()
        #expect(ran.count == 1)
        debouncer.flush()
        #expect(ran.count == 1)
    }

    @MainActor
    @Test("A registered chat presenter gets the review: Approve sends the scrubbed set, Cancel sends nothing")
    func presenterApproveAndCancel() async {
        let guard_ = await acquirePrivacyStoreSandbox("IntelPrivacyUITests")
        defer { guard_.release() }
        PrivacyFilterStore.save(PrivacyFilterConfiguration())

        let service = PrivacyReviewService.shared
        let map = RedactionMap(conversationID: UUID())
        let placeholder = await map.intern("Alice", as: .person)
        let text = "Alice"
        let detection = DetectedEntity(
            category: .person,
            original: "Alice",
            range: text.startIndex ..< text.endIndex,
            placeholder: placeholder,
            approved: true
        )

        var presented = 0
        var approve = true
        let token = service.registerPresenter { state in
            presented += 1
            if approve { state.confirm() } else { state.cancel() }
        }
        defer { service.unregisterPresenter(token) }

        let approved = await service.review(detections: [detection], sessionId: "intel-ui-approve")
        if case .approved(let kept) = approved {
            #expect(kept.count == 1)
        } else {
            Issue.record("Expected .approved, got \(approved)")
        }

        approve = false
        let canceled = await service.review(detections: [detection], sessionId: "intel-ui-cancel")
        if case .canceled = canceled {
        } else {
            Issue.record("Expected .canceled, got \(canceled)")
        }
        #expect(presented == 2)
    }
}
