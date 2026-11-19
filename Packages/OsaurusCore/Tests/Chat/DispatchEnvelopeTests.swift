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

    // MARK: - Watcher run (upstream #2628 prompt)

    private func watcherPrompt(
        _ instructions: String, iteration: Int, folder: String?, changed: [String]
    ) -> String {
        let watcher = WatcherManager.shared.create(
            name: "Envelope Probe \(UUID().uuidString.prefix(6))", instructions: instructions,
            watchPath: folder, isEnabled: false)
        defer { WatcherManager.shared.delete(id: watcher.id) }
        return WatcherManager.shared.buildDispatchPrompt(
            for: watcher, iteration: iteration, resolvedWatchPath: folder, changedPaths: changed)
    }

    @Test
    func watcherRun_bothIterationsRoundTripThePromptTheManagerWrites() throws {
        let instructions = "Sort new invoices into Year/Month folders."
        for iteration in [1, 2] {
            let stored = watcherPrompt(
                instructions, iteration: iteration, folder: "/tmp/inbox", changed: ["a.pdf", "b.pdf (removed)"])
            let env = try #require(DispatchEnvelope.parse(stored, sessionSource: .watcher))
            #expect(env.displayText == instructions)
            guard case let .watcherRun(folder, paths, overflow, it) = env.kind else {
                Issue.record("expected watcherRun")
                return
            }
            #expect(folder == "/tmp/inbox")
            #expect(paths == ["a.pdf", "b.pdf (removed)"] && overflow == 0 && it == iteration)
            #expect(env.badges.first?.label == "Watcher run")
        }
    }

    @Test
    func watcherRun_overflowAndNoFolderRoundTrip() throws {
        let cap = WatcherManager.dispatchPromptChangedPathCap
        let many = (0 ..< cap + 3).map { "f\($0).txt" }
        let stored = watcherPrompt("Sort.", iteration: 1, folder: "/tmp/inbox", changed: many)
        let env = try #require(DispatchEnvelope.parse(stored, sessionSource: .watcher))
        guard case let .watcherRun(_, paths, overflow, _) = env.kind else {
            Issue.record("expected watcherRun")
            return
        }
        #expect(paths.count == cap && overflow == 3)
        let bookmarkOnly = watcherPrompt("Sort.", iteration: 2, folder: nil, changed: [])
        let bare = try #require(DispatchEnvelope.parse(bookmarkOnly, sessionSource: .watcher))
        #expect(bare.displayText == "Sort.")
    }

    /// Chats stored before #2628 used a framing with no folder line.
    @Test
    func watcherRun_legacyFramingStillParses() throws {
        let first =
            "\n\nChanges were detected in the watched folder. Use `file_read` (which lists a directory when given one) and other file tools to inspect the current state of the directory and take action.\n"
        let footer =
            "\nIf all files are already properly organized, return without making changes. Do not re-organize files that are already in their correct location.\n"
        let env = try #require(DispatchEnvelope.parse("Sort." + first + footer, sessionSource: .watcher))
        #expect(env.displayText == "Sort.")
        guard case let .watcherRun(folder, paths, _, it) = env.kind else {
            Issue.record("expected watcherRun")
            return
        }
        #expect(folder == nil && paths.isEmpty && it == 1)
    }

    @Test
    func watcherFramingOnlyParsesInWatcherSessions() {
        let stored = watcherPrompt("Sort.", iteration: 1, folder: "/tmp/inbox", changed: [])
        #expect(DispatchEnvelope.parse(stored, sessionSource: .chat) == nil)
        // The footer alone (no framing) is left as-is rather than guessed at.
        #expect(
            DispatchEnvelope.parse("Hi\n" + WatcherManager.alreadyOrganizedGuidance + "\n", sessionSource: .watcher)
                == nil)
    }

    @Test
    func blocksCarryTheEnvelopeAndKeepTheStoredText() {
        let stored = watcherPrompt("Sort.", iteration: 1, folder: "/tmp/inbox", changed: [])
        let turn = ChatTurn(role: .user, content: stored)
        let block = BlockMemoizer().unrolledBlocks(from: [turn], sessionSource: .watcher)
            .first { $0.id.hasPrefix("user-") }
        guard case let .userMessage(text, _, _, _, envelope) = block?.kind else {
            Issue.record("no user block")
            return
        }
        #expect(text == stored)
        #expect(envelope?.displayText == "Sort.")
        let chat = BlockMemoizer().unrolledBlocks(from: [turn], sessionSource: .chat).first { $0.id.hasPrefix("user-") }
        if case let .userMessage(_, _, _, _, chatEnvelope) = chat?.kind { #expect(chatEnvelope == nil) }
    }
}
