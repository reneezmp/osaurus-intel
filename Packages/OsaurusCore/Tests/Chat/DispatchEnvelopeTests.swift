//
//  DispatchEnvelopeTests.swift
//  osaurusTests
//
//  Upstream's round-trip tests for the kinds Intel produces (plain text,
//  self-scheduled runs), plus Intel's watcher framing. Channel and delegated
//  envelopes are staged with their producers (docs/CHAT_UX_INTEL.md).
//

import Foundation
import Testing

@testable import OsaurusCore

/// Round-trips each dispatch producer through `DispatchEnvelope.parse` so
/// the display text is exactly the human-authored input and the badge row
/// sees the right provenance. If a producer template changes without the
/// shared constant, these fail.
@MainActor
struct DispatchEnvelopeTests {

    // MARK: - Plain text never parses (upstream)

    @Test
    func plainTypedMessage_returnsNil() {
        for source in SessionSource.allCases {
            #expect(DispatchEnvelope.parse("hello there", sessionSource: source) == nil)
            #expect(DispatchEnvelope.parse("", sessionSource: source) == nil)
            #expect(DispatchEnvelope.parse("   \n", sessionSource: source) == nil)
        }
    }

    @Test
    func partialMarkers_returnNil() {
        #expect(DispatchEnvelope.parse("[Self-scheduled run] but no instructions header", sessionSource: .selfSchedule) == nil)
    }

    // MARK: - Self-scheduled run (upstream)

    private func entry(_ instructions: String) -> NextRunEntry {
        NextRunEntry(
            agentId: UUID(),
            scheduledAt: Date(timeIntervalSince1970: 1_800_000_000),
            instructions: instructions,
            scheduledBy: .agent
        )
    }

    @Test
    func selfScheduledRun_withoutPreviousRun() throws {
        let raw = NextRunScheduler.composeDispatchPrompt(entry: entry("Check the inbox and triage."), previousRun: nil)
        let env = try #require(DispatchEnvelope.parse(raw, sessionSource: .selfSchedule))
        #expect(env.displayText == "Check the inbox and triage.")
        guard case let .selfScheduledRun(scheduledBy, scheduledAt, previousRun) = env.kind else {
            Issue.record("expected selfScheduledRun, got \(String(describing: env.kind))")
            return
        }
        #expect(scheduledBy == "agent")
        #expect(scheduledAt?.isEmpty == false)
        #expect(previousRun == nil)
        #expect(env.badges.first?.label == "Self-scheduled")
        #expect(env.badges.count == 2)
    }

    @Test
    func selfScheduledRun_withPreviousRun_carriesSentenceInTooltip() throws {
        let previous = AgentRunRecord(
            id: UUID(),
            agentId: UUID(),
            triggerKind: .schedule,
            triggerPayload: "{}",
            instructions: "earlier",
            startedAt: Date(timeIntervalSince1970: 1_799_990_000),
            endedAt: Date(timeIntervalSince1970: 1_799_990_500),
            status: .success
        )
        let raw = NextRunScheduler.composeDispatchPrompt(
            entry: entry("Follow up on the deploy.\nThen post a summary."),
            previousRun: previous
        )
        let env = try #require(DispatchEnvelope.parse(raw, sessionSource: .selfSchedule))
        #expect(env.displayText == "Follow up on the deploy.\nThen post a summary.")
        guard case let .selfScheduledRun(_, _, previousRun) = env.kind else { return }
        #expect(previousRun?.hasPrefix(NextRunScheduler.previousRunLinePrefix) == true)
        #expect(env.badges.first?.tooltip?.contains("Your previous run") == true)
    }

    @Test
    func selfScheduledRequestIsAFreshTitledSession() async {
        let request = await NextRunScheduler.makeDispatchRequest(for: entry("Tidy up."))
        #expect(request.externalSessionKey == nil)
        #expect(request.source == .selfSchedule)
        #expect(request.title?.hasPrefix("Self-scheduled run — ") == true)
        #expect(request.prompt.hasPrefix(NextRunScheduler.selfScheduledRunPrefix))
    }

    // MARK: - Watcher run (Intel framing)

    @Test
    func watcherRun_bothIterations() throws {
        let instructions = "Sort new invoices into Year/Month folders."
        for (framing, iteration) in [(WatcherManager.firstRunFraming, 1), (WatcherManager.followUpFraming, 2)] {
            let stored = instructions + framing + WatcherManager.idempotencyFooter
            let env = try #require(DispatchEnvelope.parse(stored, sessionSource: .watcher))
            #expect(env.displayText == instructions)
            guard case let .watcherRun(_, paths, overflow, it) = env.kind else {
                Issue.record("expected watcherRun")
                return
            }
            #expect(paths.isEmpty && overflow == 0 && it == iteration)
            #expect(env.badges.map(\.label) == ["Watcher run"])
            #expect(env.badges.first?.tooltip == (iteration == 1 ? "First pass" : "Follow-up pass"))
        }
    }

    @Test
    func watcherFramingOnlyParsesInWatcherSessions() {
        let stored = "Sort." + WatcherManager.firstRunFraming + WatcherManager.idempotencyFooter
        #expect(DispatchEnvelope.parse(stored, sessionSource: .chat) == nil)
        // A footer alone (no framing) is left as-is rather than guessed at.
        #expect(DispatchEnvelope.parse("Hi" + WatcherManager.idempotencyFooter, sessionSource: .watcher) == nil)
    }

    @Test
    func blocksCarryTheEnvelopeAndKeepTheStoredText() {
        let stored = "Sort." + WatcherManager.firstRunFraming + WatcherManager.idempotencyFooter
        let turn = ChatTurn(role: .user, content: stored)
        let block = BlockMemoizer().unrolledBlocks(from: [turn], sessionSource: .watcher)
            .first { $0.id.hasPrefix("user-") }
        guard case let .userMessage(text, _, envelope) = block?.kind else {
            Issue.record("no user block")
            return
        }
        #expect(text == stored)
        #expect(envelope?.displayText == "Sort.")
        let chat = BlockMemoizer().unrolledBlocks(from: [turn], sessionSource: .chat).first { $0.id.hasPrefix("user-") }
        if case let .userMessage(_, _, chatEnvelope) = chat?.kind { #expect(chatEnvelope == nil) }
    }
}
