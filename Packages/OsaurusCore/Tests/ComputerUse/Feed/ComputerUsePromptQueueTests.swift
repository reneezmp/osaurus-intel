//
//  ComputerUsePromptQueueTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Audit-remediation coverage for the consent surface (P1 "the Stop that
//  doesn't stop" + the confirm-overlay affordances):
//    • A pending confirm resolves as DENIED when the run is torn down
//      (`cancelAll`) — so the feed's Stop button works even while a card is up.
//    • A pending confirm resolves as DENIED when the awaiting Task is
//      cancelled (`withTaskCancellationHandler`), so the loop never hangs.
//    • "Approve, don't ask again" auto-approves same-or-lower-effect actions in
//      the same app for the rest of the run, while higher-effect actions still
//      prompt.
//    • The just-in-time cloud-vision consent prompt resolves and is
//      teardown-safe.
//
//  Drives `ComputerUsePromptQueue.shared` (a MainActor singleton) with
//  per-test tool-call ids so tests don't interfere.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite
struct ComputerUsePromptQueueTests {
    private var queue: ComputerUsePromptQueue { .shared }

    private func preview(_ app: String = "Notes", effect: EffectClass = .edit) -> ActionPreview {
        ActionPreview(
            appName: app,
            actionLabel: "Type",
            targetLabel: "Body",
            effect: effect,
            note: nil
        )
    }

    /// Spin the run loop until `predicate` holds (the parked child task has run)
    /// or we time out. Sleeping yields the MainActor so the suspended
    /// `requestConfirmation` task gets a turn to append to `pending`.
    private func waitUntil(
        _ predicate: () -> Bool,
        timeout: TimeInterval = 2.0,
        _ what: String = "condition",
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > timeout {
                Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
    }

    private func pendingId(forToolCallId id: String) -> UUID? {
        queue.pending.first { $0.toolCallId == id }?.id
    }

    // MARK: Confirm resolution

    @Test func approveResolvesTrue() async {
        let id = "approve-\(UUID().uuidString)"
        let task = Task { await self.queue.requestConfirmation(self.preview(), toolCallId: id) }
        await waitUntil({ self.pendingId(forToolCallId: id) != nil }, "the prompt to park")
        guard let reqId = pendingId(forToolCallId: id) else { return }
        queue.resolve(id: reqId, approved: true)
        let approved = await task.value
        #expect(approved)
        #expect(pendingId(forToolCallId: id) == nil)
    }

    @Test func declineResolvesFalse() async {
        let id = "decline-\(UUID().uuidString)"
        let task = Task { await self.queue.requestConfirmation(self.preview(), toolCallId: id) }
        await waitUntil({ self.pendingId(forToolCallId: id) != nil }, "the prompt to park")
        guard let reqId = pendingId(forToolCallId: id) else { return }
        queue.resolve(id: reqId, approved: false)
        let approved = await task.value
        #expect(!approved)
    }

    // MARK: Stop-during-confirm

    /// The feed's Stop calls `cancelAll(forToolCallId:)`; a confirm that's still
    /// on screen must resolve as DENIED and clear, so the loop unblocks.
    @Test func cancelAllResolvesPendingConfirmAsDenied() async {
        let id = "stop-\(UUID().uuidString)"
        let task = Task { await self.queue.requestConfirmation(self.preview(), toolCallId: id) }
        await waitUntil({ self.pendingId(forToolCallId: id) != nil }, "the prompt to park")
        queue.cancelAll(forToolCallId: id)
        let approved = await task.value
        #expect(!approved)
        #expect(pendingId(forToolCallId: id) == nil)
    }

    /// Structured cancellation of the awaiting Task (the loop's own teardown
    /// path) resolves the suspended call as DENIED via the cancellation handler.
    @Test func taskCancellationResolvesConfirmAsDenied() async {
        let id = "cancel-\(UUID().uuidString)"
        let task = Task { await self.queue.requestConfirmation(self.preview(), toolCallId: id) }
        await waitUntil({ self.pendingId(forToolCallId: id) != nil }, "the prompt to park")
        task.cancel()
        let approved = await task.value
        #expect(!approved)
        await waitUntil({ self.pendingId(forToolCallId: id) == nil }, "the prompt to clear")
    }

    // MARK: Approve-remaining

    @Test func approveRemainingAutoApprovesSameOrLowerEffectInApp() async {
        let id = "auto-\(UUID().uuidString)"

        // First edit in Notes → approve the rest.
        let first = Task { await self.queue.requestConfirmation(self.preview(), toolCallId: id) }
        await waitUntil({ self.pendingId(forToolCallId: id) != nil }, "the first prompt to park")
        guard let firstId = pendingId(forToolCallId: id) else { return }
        queue.resolveApprovingRest(id: firstId)
        let firstApproved = await first.value
        #expect(firstApproved)

        // A second edit in the same app auto-approves WITHOUT ever parking.
        let secondApproved = await queue.requestConfirmation(preview(), toolCallId: id)
        #expect(secondApproved)
        #expect(pendingId(forToolCallId: id) == nil)

        // A higher-effect action (consequential) still prompts.
        let third = Task {
            await self.queue.requestConfirmation(
                self.preview("Notes", effect: .consequential),
                toolCallId: id
            )
        }
        await waitUntil({ self.pendingId(forToolCallId: id) != nil }, "the consequential prompt to park")
        guard let thirdId = pendingId(forToolCallId: id) else { return }
        queue.resolve(id: thirdId, approved: false)
        let thirdApproved = await third.value
        #expect(!thirdApproved)

        // Auto-approve is scoped per app: a different app still prompts.
        let other = Task {
            await self.queue.requestConfirmation(self.preview("Mail"), toolCallId: id)
        }
        await waitUntil({ self.pendingId(forToolCallId: id) != nil }, "the other-app prompt to park")
        queue.cancelAll(forToolCallId: id)
        _ = await other.value
    }

    // MARK: Cloud-vision consent

    @Test func consentResolvesToChoice() async {
        let id = "consent-\(UUID().uuidString)"
        let task = Task { await self.queue.requestCloudVisionConsent(toolCallId: id) }
        await waitUntil(
            { self.queue.pendingConsent.contains { $0.toolCallId == id } },
            "the consent prompt to park"
        )
        guard let reqId = queue.pendingConsent.first(where: { $0.toolCallId == id })?.id else { return }
        queue.resolveConsent(id: reqId, choice: .allowOnce)
        let choice = await task.value
        #expect(choice == .allowOnce)
        #expect(!queue.pendingConsent.contains { $0.toolCallId == id })
    }

    @Test func cancelAllResolvesPendingConsentAsDeny() async {
        let id = "consent-stop-\(UUID().uuidString)"
        let task = Task { await self.queue.requestCloudVisionConsent(toolCallId: id) }
        await waitUntil(
            { self.queue.pendingConsent.contains { $0.toolCallId == id } },
            "the consent prompt to park"
        )
        queue.cancelAll(forToolCallId: id)
        let choice = await task.value
        #expect(choice == .deny)
    }
}
