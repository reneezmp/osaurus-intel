//
//  RemoteSessionContinuation.swift
//  osaurus
//
//  Lets a paired phone continue one of the Mac's own chats: `/agents/{id}/run`
//  with `osaurus_session_id` loads that session's turns as model context and
//  appends the new turns back into it (upstream MOBILE_PROTOCOL §14.5).
//
//  Writes go through the open chat window when there is one, so a Mac window
//  showing that chat updates live; otherwise straight to the store, whose
//  published sessions refresh History.
//
//  Intel (`W-identity-mobile` stage 3b, docs/IDENTITY_MOBILE_INTEL.md):
//  - Intel's chats live in `ChatSessionsManager` (one JSON file each), not
//    upstream's `ChatSessionStore` database.
//  - `history` builds model messages the way Intel's chat window does
//    (`turnToMessage`), compaction summary included.
//  - The run's own turns are built from its stream (`PhoneRunTranscript`):
//    Intel's engine runs the tool loop and only streams the result.
//  - No hosted workspace rows (workspaces are deferred), so every stored
//    chat is the owner's and `adoptHostedPhoneChat` has nothing to adopt.
//  - Image exchanges (`appendImageExchange`, stage 3c) write the reply as
//    `![prompt](file://…)` links, which Intel's chat renders and
//    `SessionTurnImages` serves to the phone.
//

import Foundation

@MainActor
enum RemoteSessionContinuation {

    // MARK: - Context

    /// The stored conversation as model messages, oldest first, as the Mac's
    /// chat window would send it: a valid compaction summary stands in for
    /// the turns it covers, corrected answers and system turns are left out
    /// (the run composes its own system prompt).
    static func history(for sessionId: UUID, model: String) -> [ChatMessage] {
        guard let session = ChatSessionsManager.shared.session(for: sessionId) else { return [] }
        let turns = session.turns
        var messages: [ChatMessage] = []
        var skip = 0
        if let summary = session.conversationSummary, !summary.coveredTurnIds.isEmpty,
            summary.coveredTurnIds.count <= turns.count,
            zip(summary.coveredTurnIds, turns).allSatisfy({ $0 == $1.id })
        {
            messages.append(ChatMessage(role: "user", content: summary.contextMessageText))
            skip = summary.coveredTurnIds.count
        }
        let supportsImages = HTTPHandler.modelSupportsImages(
            modelId: model, pickerItems: ModelPickerItemCache.shared.items)
        for turn in turns.dropFirst(skip) {
            if let message = message(from: turn, supportsImages: supportsImages) { messages.append(message) }
        }
        return messages
    }

    static func message(from turn: ChatTurnData, supportsImages: Bool = false) -> ChatMessage? {
        // Turns the Mac took out of model history (a corrected answer) stay
        // out (upstream).
        if turn.modelContextExcluded { return nil }
        switch turn.role {
        case .assistant:
            let blank = turn.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasCalls = !(turn.toolCalls?.isEmpty ?? true)
            guard !blank || !turn.thinking.isEmpty || hasCalls else { return nil }
            return ChatMessage(
                role: "assistant",
                content: blank ? nil : turn.content,
                tool_calls: hasCalls ? turn.toolCalls : nil,
                reasoning_content: turn.thinking.isEmpty ? nil : turn.thinking
            )
        case .tool:
            return ChatMessage(role: "tool", content: turn.content, tool_call_id: turn.toolCallId)
        case .user:
            return ChatSession.buildUserChatMessage(
                content: turn.content,
                attachments: turn.attachments,
                supportsImages: supportsImages,
                supportsAudio: false,
                supportsVideo: false
            )
        default:
            return nil
        }
    }

    /// The phone's own request messages as stored turns (upstream
    /// `ChatHistoryWriter.turns(from:)`). System messages are dropped; tool
    /// results stay as their own `.tool` turns and are also recorded on the
    /// assistant turn that made the call, as a Mac chat records them. Inline
    /// images are kept, as a Mac chat keeps its own.
    ///
    /// These are the messages as the phone sent them, before the run adds
    /// memory or the voice-call note, so neither is ever saved (upstream
    /// #3070 and #3106 take them back off instead).
    nonisolated static func turns(from messages: [ChatMessage]) -> [ChatTurnData] {
        let now = Date()
        var turns: [ChatTurnData] = []
        for message in messages where message.role != "system" {
            let role = MessageRole(rawValue: message.role) ?? .assistant
            let turn = ChatTurnData(
                id: UUID(),
                role: role,
                content: message.content ?? "",
                attachments: role == .user ? message.imageDataFromParts.map(Attachment.image) : [],
                toolCalls: message.tool_calls,
                toolCallId: message.tool_call_id,
                thinking: message.reasoning_content ?? "",
                createdAt: now,
                completedAt: role == .assistant ? now : nil
            )
            if role == .tool, let callId = message.tool_call_id,
                let owner = turns.lastIndex(where: {
                    $0.role == .assistant && ($0.toolCalls?.contains { $0.id == callId } ?? false)
                }),
                turns[owner].toolResults[callId] == nil
            {
                turns[owner].toolResults[callId] = turn.content
            }
            turns.append(turn)
        }
        return turns
    }

    // MARK: - Appending a run's turns

    /// How often, and for how long at most, `append` waits for the Mac to
    /// finish a reply in the same chat.
    private static let streamPollInterval: UInt64 = 250_000_000
    private static let streamWaitLimit: TimeInterval = 600

    /// Appends a phone run's turns to the chat. `model` becomes the stored
    /// chat's model, as when the Mac runs a turn under a different one.
    static func append(_ turns: [ChatTurnData], to sessionId: UUID, model: String?) async {
        guard !turns.isEmpty else { return }
        MobileConnectLog.hostedRun(
            "continuation appending \(turns.count) turn(s) to \(sessionId) after the run "
                + "(open in a window=\(ChatWindowManager.shared.session(forSessionId: sessionId) != nil))"
        )

        // The Mac may be replying in this same chat. Splicing the phone's
        // turns in now would put them ahead of that reply, in the transcript
        // and in the next run's context, so they wait for it — they can't be
        // refused, the phone already has its answer. `truncate` refuses
        // (`.busy`) instead, as nothing is lost by retrying later.
        let deadline = Date().addingTimeInterval(streamWaitLimit)
        while let live = ChatWindowManager.shared.session(forSessionId: sessionId), live.isStreaming,
            Date() < deadline
        {
            try? await Task.sleep(nanoseconds: streamPollInterval)
        }

        // An open window owns the live transcript: append there and let its
        // own save path persist, so the visible chat updates immediately.
        // Its model stays its own: setting `selectedModel` on a live window
        // also writes the choice back to the agent, as if picked there.
        if let live = ChatWindowManager.shared.session(forSessionId: sessionId) {
            live.appendHostedTurns(turns)
            live.save()
            return
        }

        guard var session = ChatSessionsManager.shared.session(for: sessionId) else { return }
        session.turns.append(contentsOf: turns)
        session.updatedAt = Date()
        if let model, !model.isEmpty, model != "default" {
            session.selectedModel = model
        }
        ChatSessionsManager.shared.save(session)
    }

    /// Appends an image model's exchange from the phone (upstream §12.5):
    /// the prompt, with any source images, then a reply holding the
    /// generated files the way the Mac's chat shows them, so both sides
    /// render it.
    static func appendImageExchange(
        prompt: String,
        sourceImages: [Data],
        generated: [URL],
        to sessionId: UUID,
        model: String
    ) async {
        // A new phone chat whose first message is this image prompt.
        if let agentId = pendingImageChats.removeValue(forKey: sessionId), !generated.isEmpty,
            !isContinuable(sessionId)
        {
            _ = startPhoneChat(sessionId, agentId: agentId, messages: [ChatMessage(role: "user", content: prompt)])
        }
        guard !generated.isEmpty, isContinuable(sessionId) else { return }
        let now = Date()
        // The prompt as the link's alt text, minus the brackets and line
        // breaks that would end it early, or no reader (the Mac's markdown,
        // `SessionTurnImages`, the phone) would find the image.
        let alt = prompt.map { "[]\n\r".contains($0) ? " " : String($0) }.joined()
        let reply = generated.map { "![\(alt)](\($0.absoluteString))" }.joined(separator: "\n\n")
        let turns = [
            ChatTurnData(
                id: UUID(), role: .user, content: prompt, attachments: sourceImages.map(Attachment.image),
                createdAt: now),
            ChatTurnData(id: UUID(), role: .assistant, content: reply, createdAt: now, completedAt: now),
        ]
        await append(turns, to: sessionId, model: model)
    }

    /// Image prompts starting a phone chat, by chat id, with the agent to
    /// start it under. The chat is created once the image is in, with it.
    private static var pendingImageChats: [UUID: UUID] = [:]

    /// The phone starts chat `sessionId` with an image prompt (§14.5).
    /// Honoured for the paired phone's key and an agent this Mac has.
    static func notePhoneImageChat(_ sessionId: UUID, agentId: UUID, keyNonce: String?) {
        guard isPairedPhoneKey(keyNonce), AgentManager.shared.agent(for: agentId) != nil else { return }
        pendingImageChats[sessionId] = agentId
    }

    // MARK: - Truncate, delete

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

        // An open window owns the live transcript, as in `append`: cut it
        // there, or its next save would put the turns back.
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

    // MARK: - Whose chat

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

    /// Whether the caller's access key is the one the phone was paired with.
    static func isPairedPhoneKey(_ keyNonce: String?) -> Bool {
        guard let keyNonce, let paired = MobilePairingService.shared.pairedKeyNonce else { return false }
        return keyNonce.lowercased() == paired.lowercased()
    }

    // MARK: - Phone runs in flight

    /// Phone runs under way, by chat: until their turns are in, the Mac's
    /// own composer holds a send for that chat, so turns never interleave.
    private static var phoneRuns: [UUID: Int] = [:]

    static func isPhoneReplying(_ sessionId: UUID) -> Bool { phoneRuns[sessionId] != nil }

    static func beginPhoneRun(_ sessionId: UUID) {
        phoneRuns[sessionId, default: 0] += 1
        // "Running…" on the chat in History, as for a reply the Mac makes.
        SessionActivityMonitor.shared.reportSession(sessionId, status: .working)
    }

    /// The run's turns are in: a send the Mac held for this chat goes now.
    static func endPhoneRun(_ sessionId: UUID) {
        guard let count = phoneRuns[sessionId] else { return }
        if count > 1 {
            phoneRuns[sessionId] = count - 1
            return
        }
        phoneRuns.removeValue(forKey: sessionId)
        SessionActivityMonitor.shared.reportSession(sessionId, status: nil)
        ChatWindowManager.shared.session(forSessionId: sessionId)?.sendHeldForPhone()
    }

    // MARK: - Chats the phone starts

    /// Starts the chat the phone named `sessionId` on its first run
    /// (upstream MOBILE_PROTOCOL §14.5), titled from what was asked. The run
    /// appends its turns when it ends, as for any continued chat. False when
    /// the id is already taken: an existing chat is never replaced.
    static func startPhoneChat(_ sessionId: UUID, agentId: UUID, messages: [ChatMessage]) -> Bool {
        guard ChatSessionsManager.shared.session(for: sessionId) == nil else { return false }
        let asked = turns(from: messages.filter { $0.role == "user" })
        let session = ChatSessionData(
            id: sessionId,
            title: ChatSessionData.generateTitle(from: asked),
            // As a hosted phone row does, so `GET /sessions?agent_id=` lists it.
            agentId: agentId,
            externalSessionKey: phoneChatKey
        )
        ChatSessionsManager.shared.save(session)
        MobileConnectLog.write("phone started chat \(sessionId)")
        return true
    }
}

/// A phone run's own turns, built from what it streams (Intel): the engine
/// runs the tool loop and streams text, reasoning and each finished tool
/// call, so the run keeps the transcript the way the Mac's chat window does
/// for the same stream — a tool result closes the assistant turn, adds the
/// `.tool` turn, and the reply carries on in a new assistant turn.
final class PhoneRunTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [ChatTurnData] = []
    private var current = PhoneRunTranscript.newAssistantTurn()

    private static func newAssistantTurn() -> ChatTurnData {
        ChatTurnData(id: UUID(), role: .assistant, content: "", createdAt: Date())
    }

    func content(_ text: String) {
        lock.withLock { current.content += text }
    }

    func reasoning(_ text: String) {
        lock.withLock { current.thinking += text }
    }

    func toolDone(callId: String, name: String, arguments: String, result: String) {
        lock.withLock {
            let call = ToolCall(
                id: callId, type: "function", function: ToolCallFunction(name: name, arguments: arguments))
            current.toolCalls = (current.toolCalls ?? []) + [call]
            current.toolResults[callId] = result
            current.completedAt = Date()
            turns.append(current)
            turns.append(
                ChatTurnData(id: UUID(), role: .tool, content: result, toolCallId: callId, createdAt: Date()))
            current = Self.newAssistantTurn()
        }
    }

    /// The answer was ungrounded and a corrected one follows: it stays
    /// visible but leaves model history, as in the Mac's chat.
    func groundedRetry() {
        lock.withLock {
            current.modelContextExcluded = true
            current.completedAt = Date()
            turns.append(current)
            current = Self.newAssistantTurn()
        }
    }

    /// Every turn so far, the reply in progress included unless it is empty.
    func finished() -> [ChatTurnData] {
        lock.withLock {
            var last = current
            let blank = last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard !blank || !last.thinking.isEmpty || !(last.toolCalls?.isEmpty ?? true) else { return turns }
            last.completedAt = Date()
            return turns + [last]
        }
    }
}
