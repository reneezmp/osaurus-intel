//
//  IntelUnattendedRunTests.swift
//  OsaurusCoreTests
//
//  `W-background-runs-sync` stage 3: upstream's `isUnattendedDispatch`
//  (#1815) on Intel, with the owner policy that a schedule, self-scheduled
//  wake-up or watcher run can never approve anything on its own. Upstream
//  lets such a run reach the card; Intel refuses every `.ask` call in it.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Unattended background runs")
struct IntelUnattendedRunTests {

    private func request(_ source: SessionSource, external: Bool = false) -> DispatchRequest {
        DispatchRequest(prompt: "go", source: source, externalSurface: external)
    }

    @Test func scheduleSelfScheduleAndWatcherRunsAreUnattended() {
        for source in [SessionSource.schedule, .selfSchedule, .watcher] {
            #expect(BackgroundTaskManager.resolvedUnattendedDispatch(for: request(source)))
        }
    }

    @Test func chatPluginAndHTTPRunsAreNotUnattended() {
        for source in [SessionSource.chat, .plugin, .http] {
            #expect(!BackgroundTaskManager.resolvedUnattendedDispatch(for: request(source)))
        }
    }

    @Test func externalSurfaceIsNeverMarkedUnattended() {
        #expect(!BackgroundTaskManager.resolvedUnattendedDispatch(for: request(.schedule, external: true)))
    }

    @Test func aHelperOfAnUnattendedRunStaysUnattended() {
        let inherited = ChatExecutionContext.$isUnattendedDispatch.withValue(true) {
            BackgroundTaskManager.resolvedUnattendedDispatch(for: request(.delegation))
        }
        #expect(inherited)
        #expect(!BackgroundTaskManager.resolvedUnattendedDispatch(for: request(.delegation)))
    }

    @Test func unattendedRunCannotAnswerAnApprovalCard() {
        #expect(!ChatExecutionContext.approvalCardUnanswerable)
        let unattended = ChatExecutionContext.$isUnattendedDispatch.withValue(true) {
            ChatExecutionContext.approvalCardUnanswerable
        }
        #expect(unattended)
        // The owner's phone answers external runs; it never makes a schedule attended.
        let phoneSchedule = ChatExecutionContext.$isUnattendedDispatch.withValue(true) {
            ChatExecutionContext.$hasRemoteReviewer.withValue(true) {
                ChatExecutionContext.approvalCardUnanswerable
            }
        }
        #expect(phoneSchedule)
        let phoneExternal = ChatExecutionContext.$isExternalSurface.withValue(true) {
            ChatExecutionContext.$hasRemoteReviewer.withValue(true) {
                ChatExecutionContext.approvalCardUnanswerable
            }
        }
        #expect(!phoneExternal)
    }

    @Test func refusalTextNamesTheUnattendedRun() {
        let reason = ChatExecutionContext.$isUnattendedDispatch.withValue(true) { ChatEngine.unapprovedReason }
        #expect(reason.contains("scheduled or watcher run"))
        #expect(ChatEngine.unapprovedReason == "you declined to run it this time")
    }

    @Test func mcpElicitationCancelsInAnUnattendedRun() {
        #expect(MCPElicitationCoordinator.currentTaskCanPrompt)
        let unattended = ChatExecutionContext.$isUnattendedDispatch.withValue(true) {
            MCPElicitationCoordinator.currentTaskCanPrompt
        }
        #expect(!unattended)
    }
}
