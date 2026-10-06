//
//  IntelContextCompaction.swift
//  osaurus
//
//  Context compaction for Intel chats (upstream #136, `2ac423378`, adapted).
//  Asks a model to summarize the oldest turns; the resulting
//  `ConversationSummary` replaces those turns in the OUTBOUND messages only.
//  The visible transcript is never rewritten.
//
//  Intel differences from upstream's ContextCompactionService:
//   - Runs only when the user asks (Compact button / `/compact` / the
//     near-limit notice). Every Intel model is a paid cloud model, so there
//     is no silent automatic compaction.
//   - Summarizes with the configured compaction model (Settings ›
//     Conversation › Advanced › Compaction Model), else the chat's current
//     model, through the Intel cloud engine (upstream's model resolution).
//   - Progress shows in the context popover and the composer; results are
//     toasts. The upstream dialog (`CompactionDialogView`) opens only when
//     neither model is known, to pick one.
//   - Boundary selection, summary validity and transcript rendering follow
//     upstream exactly, so a summary written by either build means the same.
//

import Foundation

/// Live progress phases surfaced in the compaction dialog / popover (upstream).
enum ContextCompactionPhase: Equatable, Sendable {
    case preparing
    case summarizing
    case applying

    var label: String {
        switch self {
        case .preparing: return L("Analyzing conversation…")
        case .summarizing: return L("Summarizing older messages…")
        case .applying: return L("Applying summary…")
        }
    }

    /// Coarse progress fraction for the dialog's progress bar.
    var progressFraction: Double {
        switch self {
        case .preparing: return 0.15
        case .summarizing: return 0.55
        case .applying: return 0.9
        }
    }
}

/// Session-scoped compaction UI state (upstream), published by `ChatSession`.
enum ContextCompactionUIState: Equatable {
    case idle
    /// No model known: the dialog is asking the user to pick one.
    case needsModelSelection
    case running(ContextCompactionPhase)
    case completed(savedTokens: Int)
    case failed(message: String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

enum IntelContextCompaction {
    enum Failure: LocalizedError, Equatable {
        case nothingToCompact
        case noModel
        case emptySummary
        case timedOut

        var errorDescription: String? {
            switch self {
            case .nothingToCompact:
                return L("Nothing to compact yet — the recent conversation is already as small as it can get.")
            case .noModel:
                return L("Choose a model for this chat first.")
            case .emptySummary:
                return L("The model returned an empty summary. Nothing was changed.")
            case .timedOut:
                return L("Compaction timed out. Nothing was changed.")
            }
        }
    }

    /// Recent user turns kept verbatim (current + one prior exchange).
    static let recentUserTurnsToKeep = 2
    static let minimumCoveredTurns = 4
    static let minimumCoveredTokens = 4_000
    static let summaryMaxTokens = 1024
    static let timeoutSeconds: Double = 180
    /// Share of the context window at which the composer suggests compacting.
    static let suggestionThreshold = 0.8
    /// Context window assumed when neither the model catalog nor the chat's
    /// Context Length setting knows one (common for cloud models on Intel).
    static let fallbackContextWindow = 128_000

    // MARK: Configuration (upstream ContextCompactionService)

    static func configuredModelIdentifier() -> String? {
        ChatConfigurationStore.load().compactionModelIdentifier
    }

    /// The model a run will use: the configured compaction model, else
    /// `fallback` (the chat's model). Nil only when neither is known.
    static func effectiveModelIdentifier(
        configured: String? = configuredModelIdentifier(),
        fallback: String?
    ) -> String? {
        if let configured, !configured.trimmingCharacters(in: .whitespaces).isEmpty {
            return configured
        }
        if let fallback, !fallback.trimmingCharacters(in: .whitespaces).isEmpty {
            return fallback
        }
        return nil
    }

    /// True when a run would use the chat's model rather than a set one.
    static func usesChatModelFallback(configured: String? = configuredModelIdentifier()) -> Bool {
        guard let configured else { return true }
        return configured.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Persist the dialog's model choice (load-modify-write, like Settings).
    static func saveConfiguredModel(identifier: String) {
        let cfg = ChatConfigurationStore.load()
        let parts = identifier.split(separator: "/", maxSplits: 1)
        if parts.count == 2 {
            cfg.compactionModelProvider = String(parts[0])
            cfg.compactionModelName = String(parts[1])
        } else {
            cfg.compactionModelProvider = nil
            cfg.compactionModelName = identifier
        }
        ChatConfigurationStore.save(cfg)
    }

    // MARK: Boundary and validity (upstream)

    /// Index such that `turns[0..<cut]` is the span a new summary covers, or
    /// nil when compaction has nothing useful to do.
    static func compactionCutIndex(turns: [ChatTurn], existingSummary: ConversationSummary?) -> Int? {
        let userIndices = turns.enumerated().filter { $0.element.role == .user }.map(\.offset)
        guard let lastUserIndex = userIndices.last else { return nil }
        let preferred: Int? =
            userIndices.count >= recentUserTurnsToKeep
            ? userIndices[userIndices.count - recentUserTurnsToKeep] : nil
        let cut: Int = (preferred.map { $0 > 0 } ?? false) ? preferred! : lastUserIndex
        let alreadyCovered = existingSummary?.coveredTurnIds.count ?? 0
        if cut > 0, cut > alreadyCovered,
            cut >= minimumCoveredTurns
                || ContextBudgetManager.estimateTokens(for: Array(turns[0 ..< cut])) >= minimumCoveredTokens
        {
            return cut
        }
        guard turns.last?.role == .assistant,
            turns.count > alreadyCovered,
            ContextBudgetManager.estimateTokens(for: Array(turns[alreadyCovered...])) >= minimumCoveredTokens
        else { return nil }
        return turns.count
    }

    /// The covered ids must still be exactly the transcript's prefix; edits,
    /// regenerations or deletions of covered turns invalidate the summary.
    static func summaryIsValid(_ summary: ConversationSummary, for turns: [ChatTurn]) -> Bool {
        guard !summary.coveredTurnIds.isEmpty, summary.coveredTurnIds.count <= turns.count else { return false }
        for (index, coveredId) in summary.coveredTurnIds.enumerated() where turns[index].id != coveredId {
            return false
        }
        return true
    }

    /// The summary if it still applies to `turns`, else nil.
    static func activeSummary(_ summary: ConversationSummary?, for turns: [ChatTurn]) -> ConversationSummary? {
        guard let summary, summaryIsValid(summary, for: turns) else { return nil }
        return summary
    }

    /// Estimated tokens the conversation costs per request, counting the
    /// summary in place of the turns it covers.
    static func conversationTokens(turns: [ChatTurn], summary: ConversationSummary?) -> Int {
        guard let summary = activeSummary(summary, for: turns) else {
            return ContextBudgetManager.estimateTokens(for: turns)
        }
        let uncovered = Array(turns[summary.coveredTurnIds.count...])
        return ContextBudgetManager.estimateTokens(for: uncovered)
            + ContextBudgetManager.estimateTokens(for: summary.contextMessageText)
    }

    /// Whether to show the "getting long" notice.
    static func shouldSuggest(
        conversationTokens: Int, contextWindow: Int?, turns: [ChatTurn], summary: ConversationSummary?
    ) -> Bool {
        let window = contextWindow ?? fallbackContextWindow
        guard window > 0, Double(conversationTokens) >= suggestionThreshold * Double(window) else { return false }
        return compactionCutIndex(turns: turns, existingSummary: activeSummary(summary, for: turns)) != nil
    }

    // MARK: Run

    /// Summarize the oldest turns with `model`. Throws `Failure` values for
    /// the user-facing cases.
    @MainActor
    static func summarize(
        turns: [ChatTurn],
        existingSummary: ConversationSummary?,
        model: String?,
        engine: (any ChatEngineProtocol)? = nil,
        onPhase: ((ContextCompactionPhase) -> Void)? = nil
    ) async throws -> ConversationSummary {
        onPhase?(.preparing)
        let existing = activeSummary(existingSummary, for: turns)
        guard let model, !model.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure.noModel }
        guard let cut = compactionCutIndex(turns: turns, existingSummary: existing) else {
            throw Failure.nothingToCompact
        }
        let covered = Array(turns[0 ..< cut])
        let transcript = renderTranscript(covered: covered, existingSummary: existing, charBudget: 240_000)
        let request = ChatCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: userPrompt(transcript: transcript)),
            ],
            temperature: 0.2,
            max_tokens: summaryMaxTokens
        )
        let chatEngine = engine ?? ChatEngine(model: model)
        onPhase?(.summarizing)
        let response = try await withThrowingTaskGroup(of: ChatCompletionResponse.self) { group in
            // Insights: a compaction row in the chat's name (upstream logs
            // `/internal/compaction` with the conversation's source).
            group.addTask {
                try await ChatEngine.$activityPurpose.withValue("compaction") {
                    try await ChatEngine.$activitySource.withValue(.chatUI) {
                        try await chatEngine.completeChat(request: request)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
        let text = (response.choices.first?.message?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptySummary }
        onPhase?(.applying)

        let draft = ConversationSummary(
            summaryText: text, coveredTurnIds: covered.map(\.id), modelIdentifier: model, savedTokensEstimate: 0)
        let saved = max(
            0,
            ContextBudgetManager.estimateTokens(for: covered)
                - ContextBudgetManager.estimateTokens(for: draft.contextMessageText))
        return ConversationSummary(
            id: draft.id, summaryText: text, coveredTurnIds: draft.coveredTurnIds,
            createdAt: draft.createdAt, modelIdentifier: model, savedTokensEstimate: saved)
    }

    // MARK: Prompt (upstream)

    static let systemPrompt = """
        You are a conversation compaction engine. You produce a dense, factual summary of \
        the older portion of a chat between a user and an AI assistant so that the \
        conversation can continue with the summary in place of those messages.

        Requirements:
        - Preserve the user's original task/request and any explicit constraints verbatim where possible.
        - Record key facts, decisions, and answers established so far.
        - Record important tool activity as outcomes (what was searched/read/written and what was found), not step-by-step logs.
        - Record the current state of any in-progress work and what remains to be done.
        - Do NOT invent details. If something was truncated or unclear, say so.
        - Write in compact prose or terse bullet points. No preamble, no closing remarks — output only the summary.
        """

    static func userPrompt(transcript: String) -> String {
        """
        Summarize the following conversation excerpt (oldest part of an ongoing chat):

        ---
        \(transcript)
        ---

        Output only the summary.
        """
    }

    /// Role-labelled transcript of the covered turns; an earlier summary
    /// stands in for the turns it already covers. Head/tail clipped to
    /// `charBudget`.
    @MainActor
    static func renderTranscript(
        covered: [ChatTurn], existingSummary: ConversationSummary?, charBudget: Int
    ) -> String {
        let previouslyCovered = existingSummary.map { Set($0.coveredTurnIds) } ?? []
        var lines: [String] = []
        if let existing = existingSummary {
            lines.append("[Summary of even earlier conversation]:\n\(existing.summaryText)")
        }
        for turn in covered where !previouslyCovered.contains(turn.id) {
            switch turn.role {
            case .user:
                var parts: [String] = []
                for doc in turn.attachments.filter(\.isDocument) {
                    guard let text = doc.loadDocumentContent(), !text.isEmpty else { continue }
                    parts.append("[User attached document \"\(doc.filename ?? "attachment")\"]:\n\(clip(text, to: 60_000))")
                }
                parts.append("[User]: \(clip(turn.content, to: 4_000))")
                lines.append(parts.joined(separator: "\n\n"))
            case .assistant:
                var parts: [String] = []
                if !turn.contentIsBlank { parts.append("[Assistant]: \(clip(turn.content, to: 4_000))") }
                for call in turn.toolCalls ?? [] {
                    parts.append(
                        "[Assistant called tool `\(call.function.name)` with: \(clip(call.function.arguments, to: 400))]")
                }
                if !parts.isEmpty { lines.append(parts.joined(separator: "\n")) }
            case .tool:
                lines.append("[Tool result]: \(clip(turn.content, to: 1_200))")
            default:
                continue
            }
        }
        let transcript = lines.joined(separator: "\n\n")
        guard transcript.count > charBudget else { return transcript }
        let head = String(transcript.prefix(charBudget / 4))
        let tail = String(transcript.suffix(charBudget - charBudget / 4))
        return head + "\n\n[… middle of excerpt omitted for length …]\n\n" + tail
    }

    private static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "… [truncated]"
    }
}
