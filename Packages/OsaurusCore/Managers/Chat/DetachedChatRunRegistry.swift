//
//  DetachedChatRunRegistry.swift
//  osaurus
//
//  Intel stand-in for the part of upstream's `BackgroundTaskManager`
//  registry that keeps a chat running after its tab or window closes
//  (upstream `adoptSession` / `liveTask(forSessionId:)`, #2630). Intel's
//  `BackgroundTaskManager` only runs dispatched work (schedules, watchers),
//  so a reply still streaming in a closed tab is held here instead.
//
//  The run itself needs no help to finish: `ChatSession.send` holds the
//  session strongly until the run ends and saves on completion. What this
//  registry adds is the live instance's identity. Reopening that chat while
//  it still runs attaches the same `ChatSession` (the stream keeps rendering)
//  instead of loading a stale copy from disk, so two instances never race
//  each other's saves. A session paused on a clarify question is held the
//  same way, so its question is still there when the chat is reopened.
//

import Combine
import Foundation

@MainActor
final class DetachedChatRunRegistry {
    static let shared = DetachedChatRunRegistry()

    private var runs: [ObjectIdentifier: ChatSession] = [:]
    private var watchers: [ObjectIdentifier: AnyCancellable] = [:]

    /// Whether a closing session still has work in flight: a reply
    /// streaming, or a run paused on a clarify question.
    static func hasWorkInFlight(_ session: ChatSession) -> Bool {
        session.isStreaming || session.awaitingClarify != nil
    }

    /// Hold a closing tab's session until its run ends. Returns false, and
    /// holds nothing, when the session is idle (the caller then saves and
    /// stops it as usual).
    @discardableResult
    func adopt(_ session: ChatSession) -> Bool {
        guard Self.hasWorkInFlight(session) else { return false }
        let key = ObjectIdentifier(session)
        guard runs[key] == nil else { return true }
        runs[key] = session
        watchers[key] = session.$isStreaming
            .combineLatest(session.$awaitingClarify.map { $0 != nil })
            .dropFirst()
            .filter { streaming, clarifying in !streaming && !clarifying }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak session] _ in
                guard let self, let session else { return }
                self.finish(session)
            }
        return true
    }

    /// The held instance of a saved chat, if one is still running.
    func liveSession(forSessionId sessionId: UUID) -> ChatSession? {
        runs.values.first { $0.sessionId == sessionId }
    }

    /// Hand a held session back to a tab that is reopening it.
    func take(_ session: ChatSession) {
        let key = ObjectIdentifier(session)
        runs.removeValue(forKey: key)
        watchers.removeValue(forKey: key)?.cancel()
    }

    /// Sessions currently held.
    var sessions: [ChatSession] { Array(runs.values) }

    /// The run ended with no tab showing it. `completeRunCleanup` already
    /// saved; save again so a clarify answer or late title lands too.
    private func finish(_ session: ChatSession) {
        take(session)
        if !session.turns.isEmpty { session.save() }
    }

    #if DEBUG
        func removeAllForTesting() {
            watchers.values.forEach { $0.cancel() }
            watchers.removeAll()
            runs.removeAll()
        }
    #endif
}
