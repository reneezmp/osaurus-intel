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
//    * announce-only turn ("Let me write the file:") with tools offered, or
//      "would you like me to continue?" with a todo unfinished: re-ask with
//      the nudge, keeping the text in history (#2480), then, for an
//      announcement, one tool-free status step (`wrapsUpIncompleteWork`);
//    * a denied or `rejected` tool call (`shouldStopAfterToolOutcome`) ends
//      the run instead of re-asking the model; a replayed retrieval failure
//      ends it with one tool-free status step.
//  (`W-cov-reaudit` stage 5c slice 3, rows 5 to 9.)
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

    /// Max consecutive announce-only turns to nudge-and-retry. Lower than the
    /// empty-turn budget: each retry leaves the announcement visible in the
    /// transcript, so repeated attempts read as the model talking to itself.
    /// If two nudges don't produce a call, the model is not going to make one
    /// and the announcement is accepted as the (poor) final answer.
    static let maxAnnouncedToolCallRetries = 2

    /// Staged before an announce-only retry. Names the specific failure — the
    /// model believes it already issued the call — because the generic
    /// "produced no output" nudge does not fit a turn that produced text.
    static let announcedToolCallNotice =
        "[System Notice] Your previous turn described a tool call but did not actually emit one, so nothing ran. "
        + "No file was written and no command executed. Emit the tool call itself now, as a real call — "
        + "do not describe it, narrate it, or claim it already ran."

    /// What the announce-only nudge may truthfully say about tools the model
    /// cannot call right now (upstream `AnnouncedToolCallRecovery`):
    /// - `exposed`: callable now, as-is.
    /// - `loadable`: registered, and `loaderName` would actually grant it.
    /// - `workspaceBlocked`: the file/shell tools that need a workspace
    ///   attached to THIS chat; no loader helps, only the user can.
    struct AnnouncedToolCallRecovery: Equatable, Sendable {
        var exposed: Set<String> = []
        var loadable: Set<String> = []
        var loaderName: String = "capabilities"
        var workspaceBlocked: Set<String> = []

        var isEmpty: Bool { exposed.isEmpty && loadable.isEmpty && workspaceBlocked.isEmpty }
    }

    /// The announce-only nudge, naming what the model can do about the tool
    /// it described (upstream `announcedToolCallNotice(recovery:)`).
    static func announcedToolCallNotice(recovery: AnnouncedToolCallRecovery?) -> String {
        guard let recovery, !recovery.isEmpty else { return announcedToolCallNotice }
        var text = announcedToolCallNotice
        if !recovery.exposed.isEmpty {
            text += " The tools you can call right now in this chat are: "
                + recovery.exposed.sorted().joined(separator: ", ") + "."
        }
        if !recovery.loadable.isEmpty {
            text += " These tools exist but are not loaded yet; call \(recovery.loaderName) with ids "
                + "[\"tool/<name>\"] first, then emit the call: "
                + recovery.loadable.sorted().joined(separator: ", ") + "."
        }
        if !recovery.workspaceBlocked.isEmpty {
            text += " " + recovery.workspaceBlocked.sorted().joined(separator: ", ")
                + " need a workspace attached to THIS chat and there is none, so no call can write, read or run "
                + "files here; do not announce that again. "
            // The picker-backed ask is the one actionable step when it is in
            // the schema; otherwise the user has to reach for the chip.
            if recovery.exposed.contains(PromptWorkingFolderTool.toolName) {
                text += "Call prompt_working_folder now to open a folder picker for the user — the run "
                    + "continues with the file tools once they pick; if they cancel, the turn ends "
                    + "with a notice and the content can go directly in your next answer"
            } else {
                text += "Tell the user to attach a folder via the Folder chip "
                    + "(or enable Autonomous execution) and give them the content directly in your answer"
            }
            text += recovery.exposed.contains("share_artifact") ? " (share_artifact can carry it)." : "."
        }
        text += " If what you described needs a tool in none of these groups, say plainly that you cannot do it "
            + "in this chat and give the user the result you have."
        return text
    }

    /// How many times a run will push back on "shall I continue?" before
    /// letting the question stand.
    static let maxContinuationRequestRetries = 2

    /// Staged before a continuation-request retry. States the standing
    /// authorization explicitly and names the pending count so "continue"
    /// has a concrete referent.
    static func continuationRequestNotice(pending: Int) -> String {
        let items = pending == 1 ? "1 item remains" : "\(pending) items remain"
        return
            "[System Notice] You asked whether to continue. Yes — continue. The user's request "
            + "already authorized this work and \(items) unchecked on your todo. Do not ask "
            + "again: proceed with the next pending item now. If you are genuinely blocked on "
            + "something only the user can decide, call `clarify` with the specific question "
            + "instead of asking in prose."
    }

    /// Visible text when the truthful-status step after incomplete work
    /// produced no visible content. Not a summary — just the honest state.
    static let incompleteWorkEmptyWrapUpText =
        "The run stopped before the requested work was complete. "
        + "The tool results above are the state of the work; send a message to continue."

    /// The one tool-free status step after announce-only recovery ran out:
    /// the model described its next action `announcements` times without
    /// calling a tool.
    static func announceExhaustedWrapUpNotice(announcements: Int) -> String {
        "[System Notice] You described the next action \(announcements) times without making a tool call, "
            + "so nothing further ran. No more tools are available in this response. Report truthfully: "
            + "what was completed (keep every result already above), what remains undone, and what blocked "
            + "the step you kept announcing. Do not promise to do it next, and do not claim it was done. "
            + "This response ends the turn: do not promise any further action (fetching, writing, verifying) — "
            + "the user decides what happens next."
    }

    /// The one tool-free status step after the same retrieval failed and was
    /// replayed until the run had to stop. Distinguishes the cached replay
    /// from the real network attempts so the model does not report the replay
    /// as a retry.
    static func repeatedRetrievalWrapUpNotice(tool: String, failures: Int) -> String {
        "[System Notice] The identical `\(tool)` retrieval has failed \(failures) times. "
            + "The last result was a cached replay of the earlier failure, not a new network request, "
            + "and this response cannot retry it. No more tools are available in this response. "
            + "Report truthfully: what was completed (keep every successful result already above), "
            + "what remains undone, and that this source is blocked. Do not promise to try again, "
            + "and do not claim the failed page was read. This response ends the turn: do not promise any "
            + "further action (fetching, writing, verifying) — the user decides what happens next."
    }

    /// Chat's visible close for a stopped turn (`emitToolRejectionText`).
    static let toolRejectionPrefix = "The requested action was not completed."

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

    // There is deliberately no cap on streamed tool-call argument size; the
    // model's own output-token ceiling is the only limit, and when that cuts a
    // call short `truncatedToolCallNotice` says so (upstream).
    static let maxTruncatedToolCallRetries = 1

    static func truncatedToolCallNotice(toolName: String?, argumentCharacters: Int) -> String {
        let tool = toolName?.isEmpty == false ? "`\(toolName!)`" : "tool"
        return
            "[System Notice] The previous \(tool) call reached the model output limit after "
            + "\(argumentCharacters) argument characters and did not execute. "
            + "Retry now with `file_write` content under "
            + "\(WorkspaceToolContract.recommendedWriteChunkCharacters) characters. "
            + "Write a viable first chunk, then use `file_write` with `mode: \"append\"` "
            + "for every later chunk."
    }

    static let truncatedToolCallFallback =
        "The model repeatedly reached its output limit inside an unfinished tool call. "
        + "The task is incomplete; retry with a higher Max Tokens setting or smaller file-write chunks."

    /// Staged once per run, the first time a data-movement step is refunded,
    /// so the model learns it can lean on bulk loads without burning budget.
    static func dataMovementReliefNotice(cap: Int) -> String {
        "[System Notice] Bulk data-movement steps (db_import, or db_insert/db_upsert with `rows[]`) don't count against your tool-call budget — up to \(cap) such steps. Prefer them for loading or moving large data."
    }

    /// Upstream's per-run cap on refunded data-movement steps
    /// (`maxDataMovementSteps: min(16, maxIterations)`).
    static func maxDataMovementSteps(maxIterations: Int) -> Int { min(16, max(0, maxIterations)) }

    /// True for a successful bulk DB load that is refunded by the
    /// data-movement budget instead of charged against the tool-round limit.
    /// Held / deduped replays and failures never qualify (upstream
    /// `isSuccessfulDataMovement`).
    static func isSuccessfulDataMovement(
        name: String, argumentsJSON: String, result: String, wasHeld: Bool
    ) -> Bool {
        guard !wasHeld, !result.hasPrefix("⛔️"), isDataMovementCall(name: name, argsJSON: argumentsJSON) else {
            return false
        }
        return envelopeReportsSuccess(result)
    }

    /// `db_import`, or `db_insert` / `db_upsert` in their bulk (`rows[]`)
    /// form. Single-row writes are organic agent work and stay charged.
    static func isDataMovementCall(name: String, argsJSON: String) -> Bool {
        switch name {
        case "db_import":
            return true
        case "db_insert", "db_upsert":
            guard let data = argsJSON.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let rows = obj["rows"] as? [Any]
            else { return false }
            return !rows.isEmpty
        default:
            return false
        }
    }

    /// A tool-result envelope that reports `"ok": true`.
    static func envelopeReportsSuccess(_ result: String) -> Bool {
        guard let data = result.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (obj["ok"] as? Bool) == true
    }

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

// MARK: - Intel: stop policy after a tool outcome (upstream `shouldStopAfterToolOutcome`)

/// One executed (or refused, or replayed) call of a tool round, as the stop
/// policy sees it (upstream `AgentLoopToolOutcome`).
struct IntelToolOutcome {
    var toolName: String
    var argumentsJSON: String
    var result: String
    /// A held / replayed result instead of a run.
    var wasDeduped: Bool
    var wasError: Bool
}

extension AgentToolLoop {
    /// Upstream's chat stop policy: malformed arguments, missing paths,
    /// timeouts, and retryable execution failures go back to the model for one
    /// correction. Explicit user denials and policy/security refusals stop
    /// immediately. Repeating an identical failing call also stops.
    ///
    /// Intel adaptation: the engine's own denial text (`⛔️ "x" was not run`)
    /// is an untyped failure; upstream's denial is a typed `user_denied`
    /// envelope, so both stop. A terminal desktop-subagent failure also
    /// stops (row 30, `isTerminalDesktopSubagentFailure`).
    static func shouldStopAfterToolOutcome(_ outcome: IntelToolOutcome, heldErrorReplays: Int = 0) -> Bool {
        guard outcome.wasError || ToolEnvelope.isError(outcome.result) || outcome.result.hasPrefix("⛔️") else {
            return false
        }
        if outcome.wasDeduped {
            // A replayed retrieval failure is not a side effect, and the
            // escalation notice staged with the replay tells the model to
            // change the source: let it land once; the same call replayed
            // AGAIN ends the run.
            if AgentTaskState.isRetrievalAsIsFailureTool(outcome.toolName), heldErrorReplays <= 1 {
                return false
            }
            return true
        }
        if isRecoverableTodoContractResult(outcome.result) { return false }
        if isTerminalDesktopSubagentFailure(toolName: outcome.toolName, result: outcome.result) {
            return true
        }
        guard let data = outcome.result.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kind = object["kind"] as? String
        else {
            // Legacy/untyped failures are hard to correct safely.
            return outcome.wasError || outcome.result.hasPrefix("⛔️")
        }
        if kind == ToolEnvelope.Kind.userDenied.rawValue || kind == ToolEnvelope.Kind.rejected.rawValue {
            return true
        }
        return false
    }

    /// Upstream `isTerminalDesktopSubagentFailure`: interactive desktop
    /// subagents can partially affect external state before returning a
    /// terminal failure. Once one reports a canonical, non-retryable failure,
    /// chat must not ask the parent model to guess what happened or launch
    /// another blind automation attempt. `invalid_args`, `not_found` and
    /// `unavailable` stay recoverable (nothing has run, or the parent can fix
    /// the call). Same three tool names as upstream; `computer_use` is
    /// listed for parity and waits for `W-computer-use` to exist on Intel.
    static func isTerminalDesktopSubagentFailure(toolName: String, result: String) -> Bool {
        guard ["computer_use", "applescript", "mac_query"].contains(toolName) else { return false }
        guard ToolEnvelope.isError(result),
            let data = result.data(using: .utf8),
            let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            envelope["retryable"] as? Bool == false,
            let rawKind = envelope["kind"] as? String,
            let kind = ToolEnvelope.Kind(rawValue: rawKind)
        else { return false }
        switch kind {
        case .invalidArgs, .notFound, .unavailable:
            return false
        case .rejected, .timeout, .executionError, .toolNotFound, .userDenied, .permissionDenied:
            return true
        }
    }

    /// Upstream `completedDesktopSummaryBeforeMalformedRepeat`: a desktop
    /// subagent already succeeded and the very next step emits only a
    /// malformed repeat of the same tool (its primary required field
    /// missing, reported as an `invalid_tool_arguments` marker). Returns the
    /// prior call's real summary so the run finishes with it instead of
    /// executing a second desktop mutation. Not a general repair: every other
    /// malformed call still executes and reaches the model.
    static func completedDesktopSummaryBeforeMalformedRepeat(
        toolName: String, argumentsJSON: String, state: AgentTaskState
    ) -> String? {
        let requiredField: String
        switch toolName {
        case "computer_use": requiredField = "goal"
        case "applescript": requiredField = "task"
        case "mac_query": requiredField = "question"
        default: return nil
        }
        guard
            let argsData = argumentsJSON.data(using: .utf8),
            let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any],
            args["_error"] as? String == "invalid_tool_arguments",
            args["_tool"] as? String == toolName,
            args["_field"] as? String == requiredField,
            let priorEnvelope = state.lastResultEnvelope,
            ToolEnvelope.isSuccess(priorEnvelope),
            let priorData = priorEnvelope.data(using: .utf8),
            let prior = try? JSONSerialization.jsonObject(with: priorData) as? [String: Any],
            prior["tool"] as? String == toolName,
            let result = prior["result"] as? [String: Any],
            let rawSummary = result["summary"] as? String
        else { return nil }
        let summary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    /// Upstream's todo-contract rejections (the model is expected to correct
    /// these; they never end the run).
    static func isRecoverableTodoContractResult(_ result: String) -> Bool {
        guard ToolEnvelope.isError(result),
            let data = result.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let reason = object["reason"] as? String
        else { return false }
        return
            [
                "task_tracking_required", "todo_progress_update_required", "todo_no_progress",
                CompleteTool.staleSessionTodoReason,
            ].contains(reason)
    }

    /// Upstream `repeatedRetrievalWrapUp`: a stop caused by a replayed
    /// retrieval failure becomes a truthful status step instead of the error
    /// sentence. Nil for every other stop.
    static func repeatedRetrievalWrapUpNotice(for outcome: IntelToolOutcome, replays: Int) -> String? {
        guard outcome.wasDeduped, AgentTaskState.isRetrievalAsIsFailureTool(outcome.toolName) else { return nil }
        return repeatedRetrievalWrapUpNotice(tool: outcome.toolName, failures: replays + 1)
    }

    /// What the stopped turn shows (`emitToolRejectionText`): the canonical
    /// message after the fixed sentence.
    static func toolRejectionText(for result: String) -> String {
        var message = ToolEnvelope.failureMessage(result)
        if message.hasPrefix("⛔️") {
            message = String(message.dropFirst("⛔️".count)).trimmingCharacters(in: .whitespaces)
        }
        let prefix = L("The requested action was not completed.")
        return message.isEmpty ? prefix : prefix + " " + message
    }
}

/// Engine to chat, in-band: how the run ended when the chat must react
/// (`\u{FFFE}` family, so text-only consumers drop it).
enum StreamingRunEndHint {
    private static let rejectedPrefix = "\u{FFFE}run-rejected:"
    private static let wrapUpPrefix = "\u{FFFE}run-wrapup:"

    /// A denied or `rejected` tool call ended the run; `text` is what the
    /// closing line shows.
    static func encodeToolRejected(text: String) -> String { rejectedPrefix + text }
    static func decodeToolRejected(_ delta: String) -> String? {
        delta.hasPrefix(rejectedPrefix) ? String(delta.dropFirst(rejectedPrefix.count)) : nil
    }

    /// The run ended on incomplete work: stream one tool-free status step
    /// with this notice (upstream `RunResult.wrapUpNotice`).
    static func encodeWrapUp(notice: String) -> String { wrapUpPrefix + notice }
    static func decodeWrapUp(_ delta: String) -> String? {
        delta.hasPrefix(wrapUpPrefix) ? String(delta.dropFirst(wrapUpPrefix.count)) : nil
    }
}

/// Upstream `ToolRegistry.announcedToolCallRecovery`, from Intel's catalog:
/// the same rules as the scope gate's `tool_not_found` envelope, so the
/// nudge never promises a load the gate would refuse.
enum IntelAnnouncedRecovery {
    static func make(exposed: Set<String>, catalog: CapabilityCatalog) -> AgentToolLoop.AnnouncedToolCallRecovery {
        var recovery = AgentToolLoop.AnnouncedToolCallRecovery(exposed: exposed)
        recovery.workspaceBlocked = IntelToolScopeGate.coreWorkspaceToolNames.subtracting(exposed)
        // A load needs the loader in the request (the envelope's `canLoad`).
        if exposed.contains(CapabilitiesTool.toolName) {
            recovery.loadable = Set(catalog.tools.map(\.name))
                .subtracting(exposed).subtracting(IntelToolScopeGate.coreWorkspaceToolNames)
        }
        return recovery
    }
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
        /// Re-send with this notice, keeping the round's visible text in
        /// model history (announce-only, continuation request): the model
        /// must see what it said to be told it did not do it.
        case retryKeepingText(notice: String)
        /// End the run on incomplete work; the chat streams one tool-free
        /// status step with this notice (upstream `wrapUpNotice`).
        case wrapUp(notice: String)
    }

    private(set) var consecutiveEmptyTurns = 0
    private(set) var incompleteReasoningRetries = 0
    private(set) var truncatedToolCallRetries = 0
    private(set) var consecutiveAnnouncedToolCalls = 0
    private(set) var consecutiveContinuationRequests = 0

    /// A round with tool calls resets the empty-turn, announce and
    /// continuation budgets (upstream resets them on every productive step).
    mutating func noteToolRound() {
        consecutiveEmptyTurns = 0
        consecutiveAnnouncedToolCalls = 0
        consecutiveContinuationRequests = 0
    }

    /// - Parameters:
    ///   - pendingTodo: unfinished items of the session's todo (a
    ///     continuation request is a stall only when this is above zero).
    ///   - announcedRecovery: what the announce nudge may say is callable or
    ///     loadable; read only for an announce-only step.
    mutating func action(
        for step: AgentLoopModelStep,
        completedToolWork: Bool,
        pendingTodo: Int = 0,
        announcedRecovery: AgentToolLoop.AnnouncedToolCallRecovery? = nil
    ) -> Action {
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
        case .truncatedToolCall(let toolName, let argumentCharacters):
            // Upstream: one bounded retry with a smaller-chunks notice, then
            // the honest fallback. The cut call never ran and never enters
            // the model's history.
            truncatedToolCallRetries += 1
            if truncatedToolCallRetries <= AgentToolLoop.maxTruncatedToolCallRetries {
                return .retry(
                    notice: AgentToolLoop.truncatedToolCallNotice(
                        toolName: toolName, argumentCharacters: argumentCharacters))
            }
            return .finishWithText(AgentToolLoop.truncatedToolCallFallback)
        case .announcedToolCall:
            // Upstream: nudge twice (not charged), then the announcement is
            // not an answer, so one tool-free status step reports the truth.
            consecutiveAnnouncedToolCalls += 1
            if consecutiveAnnouncedToolCalls <= AgentToolLoop.maxAnnouncedToolCallRetries {
                return .retryKeepingText(notice: AgentToolLoop.announcedToolCallNotice(recovery: announcedRecovery))
            }
            return .wrapUp(
                notice: AgentToolLoop.announceExhaustedWrapUpNotice(announcements: consecutiveAnnouncedToolCalls))
        case .continuationRequest:
            // With nothing pending it is a real question: the user gets it.
            guard pendingTodo > 0 else { return .finish }
            consecutiveContinuationRequests += 1
            if consecutiveContinuationRequests <= AgentToolLoop.maxContinuationRequestRetries {
                return .retryKeepingText(notice: AgentToolLoop.continuationRequestNotice(pending: pendingTodo))
            }
            return .finish
        case .finalResponse, .toolCalls, .retryWithoutCharge:
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
