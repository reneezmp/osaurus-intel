import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Intel Gate 5B approval queue", .serialized)
struct IntelConfigApprovalQueueTests {
    private func plan() -> IntelDeclarativeConfigurationPlan {
        let after = DefaultAgentConfiguration(displayName: "After")
        return IntelDeclarativeConfigurationPlan(
            id: UUID(),
            currentStateFingerprint: "current",
            targetStateFingerprint: "target",
            changes: [
                .init(path: "default_agent.name", before: "Before", after: "After")
            ],
            target: after
        )
    }

    @Test
    func requestCarriesExactPlanAndResolvesApproved() async {
        let queue = IntelConfigApprovalQueue()
        let expected = plan()
        let task = Task { await queue.requestApproval(plan: expected, sessionID: "chat-a", timeout: 5) }

        while queue.pending.isEmpty { await Task.yield() }
        #expect(queue.pending.first?.plan == expected)
        #expect(queue.pending.first?.sessionID == "chat-a")
        let id = queue.pending[0].id
        queue.resolve(id: id, outcome: .approved)
        #expect(await task.value == .approved)
        #expect(queue.pending.isEmpty)
    }

    @Test
    func cancellationRemovesRequestAndReturnsCancelled() async {
        let queue = IntelConfigApprovalQueue()
        let task = Task { await queue.requestApproval(plan: plan(), sessionID: "chat-a", timeout: 5) }
        while queue.pending.isEmpty { await Task.yield() }

        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(queue.pending.isEmpty)
    }

    @Test
    func timeoutReturnsTimedOut() async {
        let queue = IntelConfigApprovalQueue()
        let outcome = await queue.requestApproval(plan: plan(), sessionID: "chat-a", timeout: 0.01)
        #expect(outcome == .timedOut)
        #expect(queue.pending.isEmpty)
    }

    @Test
    func cancelAllResolvesEveryCaller() async {
        let queue = IntelConfigApprovalQueue()
        let first = Task { await queue.requestApproval(plan: plan(), sessionID: "chat-a", timeout: 5) }
        let second = Task { await queue.requestApproval(plan: plan(), sessionID: "chat-b", timeout: 5) }
        while queue.pending.count < 2 { await Task.yield() }

        queue.cancelAll()
        #expect(await first.value == .cancelled)
        #expect(await second.value == .cancelled)
        #expect(queue.pending.isEmpty)
    }

    @Test
    func mountedSurfaceTrackingDoesNotGoNegative() {
        let queue = IntelConfigApprovalQueue()
        #expect(queue.hasMountedSurface(for: "chat-a") == false)
        queue.surfaceDidUnmount(sessionID: "chat-a")
        queue.surfaceDidMount(sessionID: "chat-a")
        queue.surfaceDidMount(sessionID: "chat-a")
        #expect(queue.hasMountedSurface(for: "chat-a"))
        #expect(queue.hasMountedSurface(for: "chat-b") == false)
        queue.surfaceDidUnmount(sessionID: "chat-a")
        queue.surfaceDidUnmount(sessionID: "chat-a")
        queue.surfaceDidUnmount(sessionID: "chat-a")
        #expect(queue.hasMountedSurface(for: "chat-a") == false)
    }
}
