//
//  RemoteSessionContinuation.swift
//  osaurus
//
//  Intel's part of upstream's `RemoteSessionContinuation`
//  (`Services/MobileConnect/`): what the session routes need
//  (`W-server-api` stage 5a, docs/SERVER_API_INTEL.md) — deleting and
//  truncating a chat the owner may continue, and recognising a chat the
//  paired phone started.
//
//  The rest of upstream's file (replaying a chat as a run's history,
//  appending a phone run's turns, phone runs in flight, pairing-key checks,
//  hosted workspace rows) comes with `W-identity-mobile`. Intel's chats carry
//  no workspace context (workspaces are deferred), so every stored chat is
//  the owner's and may be continued.
//

import Foundation

@MainActor
enum RemoteSessionContinuation {

    enum TruncateOutcome: Equatable {
        case removed(Int)
        /// Unknown, or a chat the phone may not continue (a teammate's).
        case sessionNotFound
        case turnNotFound
        /// The Mac is running this chat right now.
        case busy
    }

    /// Drops `turnId` and everything after it, so the phone can retry a
    /// reply the way the Mac's Regenerate does: the phone re-sends the
    /// prompt, and the run appends it and the new reply again
    /// (upstream MOBILE_PROTOCOL §14.8).
    static func truncate(_ sessionId: UUID, fromTurnId turnId: UUID) -> TruncateOutcome {
        guard isContinuable(sessionId) else { return .sessionNotFound }

        // An open window owns the live transcript: cut it there, or its next
        // save would put the turns back.
        if let live = ChatWindowManager.shared.session(forSessionId: sessionId) {
            guard !live.isStreaming else { return .busy }
            guard let removed = live.truncateHostedTurns(fromTurnId: turnId) else { return .turnNotFound }
            live.save()
            return .removed(removed)
        }

        guard var session = ChatSessionsManager.shared.session(for: sessionId) else { return .sessionNotFound }
        guard let index = session.turns.firstIndex(where: { $0.id == turnId }) else { return .turnNotFound }
        let removed = session.turns.count - index
        session.turns.removeSubrange(index...)
        session.updatedAt = Date()
        ChatSessionsManager.shared.save(session)
        ChatWindowManager.shared.syncOpenSessions(id: sessionId) { _ in }
        return .removed(removed)
    }

    /// Deletes the chat for good, as the Mac's History Delete does
    /// (upstream MOBILE_PROTOCOL §14.10). False for an unknown id.
    static func delete(_ sessionId: UUID) -> Bool {
        guard isContinuable(sessionId) else { return false }
        ChatWindowManager.shared.deleteSession(id: sessionId)
        return true
    }

    /// Whether this session can be continued by the owner's phone. Upstream
    /// excludes chats served for a workspace teammate; Intel has none, so
    /// every stored chat qualifies.
    static func isContinuable(_ sessionId: UUID) -> Bool {
        ChatSessionsManager.shared.session(for: sessionId) != nil
    }

    /// Whether `session` is one the phone started (upstream). Upstream also
    /// counts older hosted workspace rows, which Intel never has.
    nonisolated static func isFromPairedPhone(_ session: ChatSessionData) -> Bool {
        session.source == .chat && session.externalSessionKey == phoneChatKey
    }

    /// Marks a chat the phone started. It is otherwise an ordinary chat:
    /// no workspace stamp, so the Mac can open and continue it as its own.
    nonisolated static let phoneChatKey = "osaurus-connect-phone"
}
