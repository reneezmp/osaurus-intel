//
//  ComputerUseTeardown.swift
//  OsaurusCore - Computer Use
//
//  Stage 5: Stop and quit interrupt a Computer Use run at once. The loop polls
//  its `InterruptToken` at every boundary and a card parked in
//  `ComputerUsePromptQueue` is denied (never approved), so a run cannot sit
//  waiting for an answer nobody will give.
//

import Foundation

public enum ComputerUseTeardown {
    /// Trip the token of every live Computer Use run whose parent chat is one of
    /// `owners` (the session id string, or the `chatwindow-` sentinel of a chat
    /// without a session yet) and deny their pending cards. Returns the number
    /// of runs interrupted.
    @discardableResult
    public static func interruptRuns(ownedBy owners: [String]) -> Int {
        guard !owners.isEmpty else { return 0 }
        let wanted = Set(owners.map { $0.lowercased() })
        var count = 0
        for feed in SubagentFeedRegistry.shared.liveFeeds()
        where feed.kindId == SubagentCapabilityRegistry.computerUse.id {
            guard let parent = feed.parentSessionId?.lowercased(), wanted.contains(parent) else { continue }
            _ = SubagentInterruptCenter.shared.interrupt(feed.toolCallId)
            let callId = feed.toolCallId
            Task { @MainActor in ComputerUsePromptQueue.shared.cancelAll(forToolCallId: callId) }
            count += 1
        }
        return count
    }

    /// Quit: interrupt every registered run and deny every pending card.
    @MainActor
    public static func stopEverything() {
        SubagentInterruptCenter.shared.interruptAll()
        ComputerUsePromptQueue.shared.denyAllPending()
    }
}
