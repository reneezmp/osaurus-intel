//
//  IntelAgentLoopTerminal.swift
//  osaurus
//
//  How a model step that ended without a tool call is classified, and the
//  bounded recovery for the shapes that are not a finished answer
//  (`W-cov-reaudit` stage 3c: upstream #1681, #2167, #2344, #2235).
//
//  `AgentLoopModelStep`, `AgentLoopVisibleResponsePolicy` and the messages in
//  the `AgentToolLoop` extension are upstream's (`AgentToolLoop.swift` at
//  bce907045), verbatim. Upstream's loop driver, `AgentToolLoop.run`, is
//  replaced on Intel by `CloudChatEngine`'s own tool loop, so
//  `IntelTerminalRecovery` maps each classified step to what that driver does
//  on the chat surface:
//    * empty turn: re-ask with `emptyTurnNotice` (twice), then a visible
//      fallback (#1681);
//    * reasoning only, after tool work this run or with tools offered: one
//      fresh retry, the reasoning-only attempt kept on screen but out of
//      model history (#2167, #2344), then a visible fallback;
//    * output-token limit without a tool call: the honest limit notice;
//    * anything else: a finished answer.
//  The engine passes no visible content, so upstream's announce-only and
//  continuation-request recoveries (#2480) are skipped, which upstream
//  documents as unchanged behaviour (left for stage 5).
//

import Foundation

/// What one model step produced, as classified by the surface.
enum AgentLoopModelStep {
    /// The stream/completion finished with plain text — the run is done.
    case finalResponse
    /// The model emitted one or more tool calls to execute this iteration.
    case toolCalls([ServiceToolInvocation])
    /// The surface absorbed a transient failure (e.g. provider truncation
    /// mid-tool-args) and wants the same iteration replayed without
    /// charging the iteration budget.
    case retryWithoutCharge
    /// The runtime hit its output-token ceiling after beginning a streamed
    /// tool envelope but before committing an executable invocation. Unlike
    /// ordinary length exhaustion, this is a typed protocol failure and gets
    /// one bounded retry with smaller-call guidance.
    case truncatedToolCall(toolName: String?, argumentCharacters: Int)
    /// The model step produced NO visible text AND no tool calls — an empty
    /// turn (an immediate EOS / 0-token generation). The driver attempts a
    /// bounded recovery (a corrective nudge, then retry) instead of ending
    /// the run silently; on exhaustion it emits a fallback message via
    /// `AgentLoopHooks.emitFallbackText` so the user never sees nothing and
    /// the loop can never spin on a deterministically-empty model.
    case emptyResponse
    /// The runtime reached the configured output-token limit without a tool
    /// call. Visible partial content or reasoning may be present, but the
    /// authoritative terminal reason says generation was incomplete.
    case lengthExhausted
    /// The stream ended after emitting reasoning but no user-visible answer,
    /// or the runtime reported that the reasoning envelope never closed.
    /// Agent runs require a normal final answer after reasoning/tool work, so
    /// an explicitly recovery-capable surface may perform one bounded retry;
    /// other surfaces end with a typed incomplete result instead of presenting
    /// the reasoning card as a completed response.
    case incompleteReasoning
    /// The runtime reported an unclosed reasoning envelope after already
    /// emitting user-visible content. Streaming surfaces cannot retract that
    /// content, so transparently replaying would concatenate two attempts.
    /// End honestly without an automatic retry.
    case incompleteVisibleResponse
    /// The model emitted visible text that ANNOUNCES an imminent tool call
    /// ("Let me write the first batch:") and then stopped without emitting
    /// one, while tools were on the table. Ending here is what makes a small
    /// model look like its tools are silently failing: the user reads a
    /// promise to act, no call runs, and the next turn the model reports the
    /// tool "isn't executing". Recoverable — the driver nudges and retries,
    /// and because the announcement is a preamble rather than an answer, the
    /// retry's tool call reads as the natural continuation of it.
    case announcedToolCall
    /// The turn ended by asking the user for permission to carry on ("would
    /// you like me to continue?") instead of carrying on. Only a stall when
    /// tracked work is still pending — the driver checks that before
    /// recovering, so a genuine question to the user still ends the run.
    /// `clarify` is the tool for real questions; this shape is the model
    /// handing back a turn it was asked to finish.
    case continuationRequest

    /// Classify a naturally completed model step from its rendered channels
    /// and authoritative terminal stop reason.
    ///
    /// A reasoning-only natural `stop` is not a complete agent response. The
    /// reasoning rail is visible diagnostic work, while the user-facing answer
    /// belongs in content. This distinction matters after tools: a reported
    /// 29K-character Gemma thought block had no answer, but its saved artifact
    /// lacked terminal provenance, so this classifier relies on live stop and
    /// envelope state rather than inferring completion from reasoning alone.
    /// - Parameter toolsWereOffered: whether the model could have called
    ///   something on this step. A reasoning-only stop is a legitimate finish
    ///   for a bundle that returns on its reasoning rail with nothing to call,
    ///   but when tools were on the table and the model produced neither an
    ///   answer nor a call, the user is left with a thought bubble and no way
    ///   forward — see osaurus#2327, where Ornith reasons "I have a tool called
    ///   get_current_time… Let me call it." and then emits `<|im_end|>`.
    ///   `requiresVisibleFinalResponse` cannot cover that case: it is
    ///   `hasStructuredToolWork || isRemoteAgentTarget`, both false on the very
    ///   first turn, which is exactly when this happens.
    /// - Parameter content: the rendered visible content, used only to tell an
    ///   answer apart from a bare announcement of an un-made tool call. Pass
    ///   `nil` from surfaces that cannot cheaply materialise it; the
    ///   announce-only recovery is then skipped and behaviour is unchanged.
    static func classifyTerminal(
        contentIsBlank: Bool,
        thinkingIsBlank: Bool,
        stopReason: String?,
        unclosedReasoning: Bool = false,
        requiresVisibleFinalResponse: Bool,
        toolsWereOffered: Bool = false,
        content: String? = nil
    ) -> Self {
        if stopReason == "length" {
            return .lengthExhausted
        }
        if requiresVisibleFinalResponse
            && unclosedReasoning && !contentIsBlank
        {
            return .incompleteVisibleResponse
        }
        if requiresVisibleFinalResponse
            && (unclosedReasoning || (contentIsBlank && !thinkingIsBlank))
        {
            return .incompleteReasoning
        }
        if contentIsBlank, thinkingIsBlank {
            return .emptyResponse
        }
        // Reasoning, no answer, no call — with tools available. Recoverable
        // rather than complete: ending here presents the reasoning card as the
        // response, which the classifier's own contract says it is not.
        if contentIsBlank, toolsWereOffered {
            return .incompleteReasoning
        }
        // Visible text, no call, tools available — check whether that text is
        // an answer, a request to be allowed to carry on, or only a preamble
        // to a call the model never emitted.
        if toolsWereOffered, let content {
            if isContinuationRequest(content) { return .continuationRequest }
            if isAnnounceOnly(content) { return .announcedToolCall }
        }
        return .finalResponse
    }

    /// Whether visible content ends by asking permission to keep going.
    ///
    /// Matches only the closing line, and only an explicit ask about
    /// CONTINUING — not questions in general. A model that asks something
    /// substantive ("which version of the toolkit do you mean?") is doing the
    /// right thing and must still end the turn.
    static func isContinuationRequest(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("?") else { return false }
        guard trimmed.components(separatedBy: "```").count % 2 == 1 else { return false }

        let lines = trimmed.split(whereSeparator: \.isNewline)
        guard let last = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return false }
        return Self.continuationRequestPhrases.contains { last.contains($0) }
    }

    /// Ways a model asks to be let off the hook mid-task. Lowercased,
    /// matched anywhere in the closing line.
    private static let continuationRequestPhrases: [String] = [
        "would you like me to continue", "want me to continue", "shall i continue",
        "should i continue", "do you want me to continue", "shall i proceed",
        "should i proceed", "would you like me to proceed", "want me to proceed",
        "shall i keep going", "should i keep going", "want me to keep going",
        "would you like me to keep going", "ok to continue", "okay to continue",
    ]

    /// Whether visible content reads as a preamble to a tool call rather than
    /// an answer to the user.
    ///
    /// Deliberately narrow, because a false positive suppresses a legitimate
    /// final answer and spends a retry. The signal is the LAST non-empty line:
    /// a finished answer does not end on a colon (a colon promises something
    /// follows, and when something does follow the colon is no longer last),
    /// and does not end on a bare first-person statement of what the model is
    /// about to do. Both shapes dominate the announce-only turns in
    /// osaurus#2439, where every "Let me write the first batch:" ended the run.
    static func isAnnounceOnly(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // An unbalanced fence means the visible tail is inside a code block,
        // where a trailing colon carries no discourse meaning.
        guard trimmed.components(separatedBy: "```").count % 2 == 1 else { return false }

        let lines = trimmed.split(whereSeparator: \.isNewline)
        guard
            let last = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines),
            !last.isEmpty
        else { return false }
        // Structural tails (list items, tables, fences, quotes) are answer
        // content even when they happen to end in a colon.
        guard let first = last.first,
            !"-*>|#`+".contains(first)
        else { return false }

        if last.hasSuffix(":") { return true }
        // A colon WITH content after it is the answer itself ("I will
        // summarize what the sources agree on: cocoa polyphenols bind…"),
        // never a promise of a call (cross-family control, 2026-09-06).
        if last.contains(": ") { return false }

        // "Let me check the result" / "I'll write these now" as the whole
        // closing line, with no answer after it. Bounded length keeps this
        // from matching a long sentence that merely opens with "I'll".
        // Bound raised from 120: a 128-character promise ("I'll search for
        // more accessible sources with the scientific data, including the
        // 71% inhibition figure and peer-reviewed studies.") closed an Ornith
        // turn as a final answer on 2026-09-06 (run 121436 R1).
        // The sign-off exclusions apply to the line rule as well: "I'll be
        // honest: the evidence is mixed…" is an answer, not a promise (caught
        // by the cross-family control on 2026-09-06).
        let lowered = last.lowercased()
        if last.count <= Self.announcementLengthBound,
            Self.announcementPrefixes.contains(where: { lowered.hasPrefix($0) }),
            !Self.closingSignOffPrefixes.contains(where: { lowered.hasPrefix($0) })
        {
            return true
        }

        // The same announcement as the closing SENTENCE of a status line:
        // "The Wellkr site blocks retrieval. Let me try the Verywell Health
        // article and the Quantum Cacao source." ended an Ornith research run
        // with `stop` and no call. A verb allowlist (try/fetch/check/read/…)
        // then missed the next three endings of the same model on the folder-
        // attached run (2026-09-06, session 58544EC9): "I have solid sources
        // now. Let me get one more with scientific detail…", "I have enough
        // sources. Let me write the research report to the host files
        // folder.", "No, I haven't written the file yet. Let me do that now."
        // — each accepted as a final answer while file_write was available.
        // The closing sentence is therefore judged by its OPENER (a first-
        // person "about to act" phrase) with an explicit sign-off exclusion
        // list ("let me know…", "I'll be here…", "I will wait…"), so a promise
        // of work is recovered whatever the verb, and a sign-off stays final.
        guard let sentence = Self.closingSentence(of: last), sentence.count <= Self.announcementLengthBound
        else { return false }
        let loweredSentence = sentence.lowercased()
        guard Self.closingActionOpeners.contains(where: { loweredSentence.hasPrefix($0) }) else { return false }
        return !Self.closingSignOffPrefixes.contains(where: { loweredSentence.hasPrefix($0) })
    }

    /// The last sentence of a line: the text after the final ". ", "! " or
    /// "? " boundary. `nil` when the line is a single sentence (the line rule
    /// already judged it).
    private static func closingSentence(of line: String) -> String? {
        // A boundary is a terminator followed by whitespace OR directly by
        // an uppercase letter: announce-only retries stream into the same
        // bubble with no separator ("…to my document.I'll append…", run
        // 130916 R2), and a split only on ". " left the whole 250-character
        // tail as one "sentence", so the third announcement was accepted
        // as the final answer.
        var cut: String.Index? = nil
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if ch == "." || ch == "!" || ch == "?" {
                let next = line.index(after: index)
                if next < line.endIndex, line[next].isWhitespace || line[next].isUppercase {
                    cut = next
                }
            }
            index = line.index(after: index)
        }
        guard let cut else { return nil }
        let tail = line[cut...].trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }

    /// Longest line / closing sentence still read as an announcement. Long
    /// enough for a promise that names its sources and figures, short enough
    /// that a paragraph opening with "I'll" is still an answer.
    static let announcementLengthBound = 200

    /// First-person "about to act" openers for the closing-sentence rule.
    /// Lowercased, matched as prefixes of the final sentence only.
    private static let closingActionOpeners: [String] = [
        "let me ", "now let me ", "next, let me ", "next let me ", "first, let me ", "first let me ",
        "i'll ", "i will ", "i'm going to ", "i am going to ", "next, i'll ", "next i'll ",
    ]

    /// Closing sentences that open like an announcement but are sign-offs or
    /// requests to the user, never a promised call: they stay final.
    private static let closingSignOffPrefixes: [String] = [
        "let me know", "let me be ", "let me explain", "let me clarify", "let me summarize", "let me summarise",
        "i'll summarize", "i'll summarise", "i will summarize", "i will summarise", "i'll explain", "i will explain",
        "i'll answer", "i will answer", "i'll note", "i will note", "i'll say ", "i will say ",
        "i'll be ", "i will be ", "i'll let you know", "i will let you know", "i'll wait", "i will wait",
        "i'll stand by", "i will stand by", "i'll leave ", "i will leave ", "i'll stop ", "i will stop ",
        "i'll hold ", "i will hold ", "i'll need ", "i will need ", "i'll have to ", "i will have to ",
        "i'll refrain", "i will refrain", "i'll defer", "i will defer",
    ]

    /// Openers of a first-person "about to act" line. Lowercased, matched as
    /// prefixes of the final line only.
    private static let announcementPrefixes: [String] = [
        "let me ", "let's ", "now let me ", "i'll ", "i will ", "i am going to ",
        "i'm going to ", "next, i'll ", "next i'll ", "first, let me ", "first let me ",
    ]

    /// Preserve visible partial output, remove only terminal whitespace, and
    /// append the truthful output-cap notice. A whitespace-only completion
    /// becomes the notice itself instead of a giant blank bubble.
    static func contentWithLengthFallback(_ content: String, fallback: String) -> String {
        guard let lastVisible = content.lastIndex(where: { !$0.isWhitespace }) else {
            return fallback
        }
        return String(content[...lastVisible]) + "\n\n" + fallback
    }
}

/// Whether a surface owes the user a normal visible answer after a
/// reasoning-only model stop. Merely advertising tool schemas is not evidence
/// that an agent/tool workflow occurred: ordinary direct chats may expose
/// baseline tools while a reasoning-only bundle intentionally returns on its
/// reasoning rail. Structured tool work in this logical run and remote-agent
/// execution are the two contracts that require a visible final response.
enum AgentLoopVisibleResponsePolicy {
    static func requiresVisibleFinalResponse(
        hasStructuredToolWork: Bool,
        isRemoteAgentTarget: Bool
    ) -> Bool {
        hasStructuredToolWork || isRemoteAgentTarget
    }
}

// MARK: - Upstream messages (AgentToolLoop.swift, verbatim)

extension AgentToolLoop {

    /// Max consecutive empty (0-token / no-tool) turns to nudge-and-retry
    /// before giving up and emitting the fallback. Small: the nudge changes
    /// the prompt so even a temperature-0 model that just emitted EOS will
    /// almost always produce text on the next attempt; the cap guarantees
    /// the loop can never spin on a deterministically-empty model.
    static let maxEmptyTurnRetries = 2

    /// Staged before an empty-turn retry. Telling the model its last turn
    /// produced nothing (and to answer or call a tool) perturbs the prompt
    /// enough to break the immediate-EOS state that caused the empty turn.
    static let emptyTurnNotice =
        "[System Notice] Your previous turn produced no output. Respond to the user's request now, or call a tool to make progress. Do not reply with an empty message."

    /// Emitted to the user when even the nudged retries produced nothing, so
    /// an empty turn never surfaces as a silent "No visible text was produced".
    static let emptyTurnFallback =
        "I wasn't able to generate a response to that. Please try rephrasing your request."

    static let emptyToolTaskFallback =
        "The model returned empty output after tool execution. The agent task may be incomplete; retry with less context or continue from the latest tool result."

    static let lengthExhaustedFallback =
        "The model reached the configured output-token limit before naturally completing an answer or tool call. "
        + "The agent task is incomplete; increase Max Tokens, disable Thinking for this task, "
        + "or continue from the latest tool result."

    /// Only one natural continuation generation is allowed after a
    /// reasoning-only assistant step. The surface preserves that real step in
    /// history and starts a fresh output buffer; the driver does not fabricate
    /// a user/system message or alter decode controls.
    static let maxIncompleteReasoningRetries = 1

    static let incompleteReasoningFallback =
        "The model ended in reasoning without producing a user-visible final answer. "
        + "The agent task may be incomplete; retry with Thinking disabled or continue from the latest tool result."

    /// Honest chat fallback when a structured current-run Todo remains
    /// unfinished at the hard agent-step cap. This is driven by typed Todo
    /// state, never by classifying the model's prose.
    static func unfinishedTodoCapFallback(pending: Int) -> String {
        "The agent reached the configured step limit with \(pending) todo item\(pending == 1 ? "" : "s") still unfinished. The task is incomplete; continue from the latest completed step or increase Max Tool Attempts under Settings → Conversation → Advanced."
    }

    /// Visible text for a capped run whose wrap-up turn produced no visible
    /// content at all (thinking only, or nothing). Not a summary of the work
    /// — the model did not write one — just the truthful state.
    static let iterationCapEmptyWrapUpText =
        "The configured tool-call limit was reached before a final answer was written. "
        + "The tool results above are the state of the work; send a message to continue."

    /// Final, transient control notice for the one tool-free summarization
    /// request issued after the hard iteration cap (upstream #2235).
    static let iterationCapWrapUpNotice =
        "[System Notice] The configured tool-call limit has been reached. "
        + "No more tools are available in this response. Give the user an honest final status "
        + "using only tool results already present. Do not emit or imitate a tool call or "
        + "tool-result payload, do not claim an unexecuted step succeeded, and explicitly "
        + "identify any requested step that remains unfinished."
}

// MARK: - Intel: the driver's terminal recovery

/// Upstream `AgentToolLoop.run`'s handling of a step that ended without a
/// tool call, as `CloudChatEngine` applies it to one chat run. Retries are
/// not charged against the tool-round budget (upstream decrements the
/// iteration for each).
struct IntelTerminalRecovery: Equatable {
    enum Action: Equatable {
        /// A finished answer (the grounded checks still run on it).
        case finish
        /// Re-send the same request with this transient notice.
        case retry(notice: String)
        /// Keep the attempt on screen but out of model history, and stream a
        /// fresh attempt from the same history.
        case retryInFreshTurn
        /// End the run with this text after what is already on screen.
        case finishWithText(String)
    }

    private(set) var consecutiveEmptyTurns = 0
    private(set) var incompleteReasoningRetries = 0

    /// A round with tool calls resets the empty-turn budget (upstream resets
    /// it on every productive step).
    mutating func noteToolRound() {
        consecutiveEmptyTurns = 0
    }

    mutating func action(for step: AgentLoopModelStep, completedToolWork: Bool) -> Action {
        switch step {
        case .emptyResponse:
            consecutiveEmptyTurns += 1
            if consecutiveEmptyTurns <= AgentToolLoop.maxEmptyTurnRetries {
                return .retry(notice: AgentToolLoop.emptyTurnNotice)
            }
            return .finishWithText(
                completedToolWork ? AgentToolLoop.emptyToolTaskFallback : AgentToolLoop.emptyTurnFallback)
        case .lengthExhausted:
            return .finishWithText(AgentToolLoop.lengthExhaustedFallback)
        case .incompleteReasoning:
            if incompleteReasoningRetries < AgentToolLoop.maxIncompleteReasoningRetries {
                incompleteReasoningRetries += 1
                return .retryInFreshTurn
            }
            return .finishWithText(AgentToolLoop.incompleteReasoningFallback)
        case .incompleteVisibleResponse:
            return .finishWithText(AgentToolLoop.incompleteReasoningFallback)
        case .finalResponse, .announcedToolCall, .continuationRequest, .toolCalls, .retryWithoutCharge,
            .truncatedToolCall:
            return .finish
        }
    }

    /// The fallback as it follows the round's visible text: after a blank
    /// line, or alone when nothing visible streamed (upstream
    /// `contentWithLengthFallback` / `appendContentAndNotify`).
    static func appendedText(_ text: String, afterVisible visible: String) -> String {
        visible.contains(where: { !$0.isWhitespace }) ? "\n\n" + text : text
    }
}
