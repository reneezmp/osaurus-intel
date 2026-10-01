//
//  TranscriptionCleanupService.swift
//  osaurus
//
//  Runs raw voice transcription through the core model to remove filler words
//  and fix punctuation. Always falls back to the raw text on any failure so
//  we never lose the user's words.
//
//  Intel: upstream calls `CoreModelService` (MLX / Foundation Models on this
//  Mac) with a local MLX fallback. Intel's core model is the remote Memory /
//  Core Model provider, reached through `ChatEngine` like every other Intel
//  one-shot call — so cleanup is a paid call that sends the transcript to
//  that provider, which is why `postProcessTranscription` is off by default
//  on Intel. Same prompt, guards and fallbacks as upstream.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.osaurus", category: "transcription_cleanup")

@MainActor
public final class TranscriptionCleanupService {
    public static let shared = TranscriptionCleanupService()

    /// Resolves the model and returns its reply. Tests inject their own.
    typealias Generator = @Sendable (_ systemPrompt: String, _ userPrompt: String, _ maxTokens: Int) async throws
        -> String

    var generator: Generator = { systemPrompt, userPrompt, maxTokens in
        guard let model = await IntelAgentDescriptionGenerator.resolveModel(agentModel: nil) else {
            throw CleanupUnavailable()
        }
        let request = ChatCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: userPrompt),
            ],
            temperature: 0.1,
            max_tokens: maxTokens
        )
        let response = try await ChatEngine.$activityPurpose.withValue("transcription_cleanup") {
            try await ChatEngine(model: model).completeChat(request: request)
        }
        return response.choices.first?.message?.content ?? ""
    }

    struct CleanupUnavailable: Error {}

    private static let systemPrompt = """
        You clean up voice-to-text transcripts. Remove only non-lexical hesitation \
        sounds: "uh", "um", "uhh", "umm", "mm", "mmm", "er", "erm", "ah", "hmm" when \
        they appear as standalone fillers. Also remove stuttered word repetitions \
        (e.g. "I I went" → "I went") and immediate self-corrections (e.g. "go to — \
        I mean visit the store" → "visit the store"). Fix punctuation and \
        capitalization. Do NOT remove real words like "like", "you know", "I mean", \
        "so", "well", "right", "actually" — these can carry meaning and the speaker \
        may have intended them. Preserve the speaker's wording and meaning exactly \
        — do not paraphrase, summarize, rephrase, or add content. Return only the \
        cleaned transcript with no preamble, quotes, or commentary.
        """

    private static let minWordsForCleanup = 3
    private static let minHallucinationRatio: Double = 0.3
    static let cleanupTimeout: TimeInterval = 10

    init() {}

    /// Cleans `rawText` with the core model. Always returns a usable string —
    /// falls back to `rawText` on short input, no model available, timeout,
    /// error, or suspiciously short output.
    public func clean(_ rawText: String) async -> String {
        debugLog("[cleanup] --- clean() called ---")

        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmed.split(separator: " ").count
        guard wordCount >= Self.minWordsForCleanup else {
            debugLog("[cleanup] SKIP: too short (\(wordCount) words < \(Self.minWordsForCleanup))")
            return rawText
        }

        // wrap input in a delimiter so the model treats it as data not instructions
        let userPrompt = """
            Clean up the following transcript. Return only the cleaned text.

            <transcript>
            \(trimmed)
            </transcript>
            """

        let start = Date()
        let generator = self.generator
        let systemPrompt = Self.systemPrompt
        let timeout = Self.cleanupTimeout
        let maxTokens = max(256, trimmed.count)
        do {
            let response = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await generator(systemPrompt, userPrompt, maxTokens)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw CancellationError()
                }
                let first = try await group.next() ?? ""
                group.cancelAll()
                return first
            }
            return postProcess(response: response, rawText: rawText, trimmed: trimmed, start: start, source: "core")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            debugLog(
                "[cleanup] ERROR after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription) — using raw"
            )
            return rawText
        }
    }

    // MARK: - Shared post-processing

    private func postProcess(response: String, rawText: String, trimmed: String, start: Date, source: String) -> String
    {
        let elapsed = Date().timeIntervalSince(start)
        debugLog(
            "[cleanup] \(source) response in \(String(format: "%.2f", elapsed))s (\(response.count) chars): \(response)"
        )

        // strip streaming sentinel (\u{FFFE}) and anything that follows — MLX emits
        // trailing metadata like "\u{FFFE}stats:28;44.0129" after the actual text.
        let stripped: String
        if let sentinelRange = response.range(of: "\u{FFFE}") {
            stripped = String(response[..<sentinelRange.lowerBound])
        } else {
            stripped = response
        }

        let cleaned = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            debugLog("[cleanup] FALLBACK: empty response, using raw")
            return rawText
        }
        if trimmed.count > 50,
            Double(cleaned.count) / Double(trimmed.count) < Self.minHallucinationRatio
        {
            debugLog(
                "[cleanup] FALLBACK: hallucination guard (cleaned \(cleaned.count) / raw \(trimmed.count) = \(String(format: "%.2f", Double(cleaned.count) / Double(trimmed.count)))), using raw"
            )
            return rawText
        }
        debugLog("[cleanup] SUCCESS (\(source)): returning cleaned text")
        return cleaned
    }
}
