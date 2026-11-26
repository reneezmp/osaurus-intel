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

    /// Upstream order: no-UI callers are refused first, then the user's global
    /// auto-allow, then the card. An unattended run is NOT in the first group
    /// (so auto-allow still applies, as upstream); the engine refuses it only
    /// after auto-allow, where a card would have been shown.
    @Test func unattendedRunStillHonoursAutoAllowButNeverReachesACard() {
        #expect(!ChatExecutionContext.approvalCardUnanswerable)
        let unattended = ChatExecutionContext.$isUnattendedDispatch.withValue(true) {
            ChatExecutionContext.approvalCardUnanswerable
        }
        #expect(!unattended)
        let external = ChatExecutionContext.$isExternalSurface.withValue(true) {
            ChatExecutionContext.approvalCardUnanswerable
        }
        #expect(external)
        let phoneExternal = ChatExecutionContext.$isExternalSurface.withValue(true) {
            ChatExecutionContext.$hasRemoteReviewer.withValue(true) {
                ChatExecutionContext.approvalCardUnanswerable
            }
        }
        #expect(!phoneExternal)
    }

    /// The service backstop refuses a card for an unattended run: the test
    /// process is headless (already denied), so check the source wiring.
    @Test func promptServiceRefusesUnattendedRunsBeforeQueueing() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Services/ToolPermissionPromptService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.components(separatedBy: "if ChatExecutionContext.isUnattendedDispatch { return .denied }").count == 3)
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
