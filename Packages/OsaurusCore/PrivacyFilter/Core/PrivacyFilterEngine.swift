//
//  PrivacyFilterEngine.swift
//  osaurus / PrivacyFilter
//
//  Single-actor wrapper around the vendored `PrivacyFilterKit`. Owns
//  load-once semantics for the on-device classifier, drives detection
//  (including the optional code-block masking pass), and performs the
//  apply-approved-entities substitution that produces the final
//  outbound string.
//

import Foundation

/// Errors surfaced to callers. Caller code (the request pipeline,
/// settings UI) decides what to do — typically fail-closed on the
/// outbound side (do not send unredacted content) and toggle the
/// master switch off until the bundle is fixed.
public enum PrivacyFilterEngineError: LocalizedError, Equatable {
    case notLoaded
    case bundleMissing(String)
    case detectionFailed(String)
    case selfTestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "Privacy Filter model is not loaded."
        case .bundleMissing(let detail):
            return "Privacy Filter model bundle is incomplete: \(detail)"
        case .detectionFailed(let detail):
            return "Privacy Filter detection failed: \(detail)"
        case .selfTestFailed(let detail):
            return "Privacy Filter self-test failed: \(detail)"
        }
    }
}

@MainActor
public final class PrivacyFilterEngine {
    public static let shared = PrivacyFilterEngine()

    private init() {}

    // Intel (`W-privacy-filter`): upstream loads the MLX classifier here
    // (`PrivacyFilterKit`, plus Rampart). Neither runs on macOS 13 x86_64,
    // so the engine is the rule-based layer only. The API below keeps
    // upstream's shape so the pipeline and settings code port unchanged.

    /// Always false on Intel: there is no model to load.
    public var isLoaded: Bool { false }

    /// Always nil on Intel.
    public var loadedBundleURL: URL? { nil }

    /// Model bundles cannot be loaded on this build.
    public func loadIfNeeded(bundle directory: URL) async throws {
        throw PrivacyFilterEngineError.bundleMissing("model detection needs an Apple Silicon Mac")
    }

    /// No-op: nothing is ever loaded.
    public func unload() {}

    /// Detect PII spans in `text`. Pre-interns each unique original
    /// into `map` so the review sheet can show stable placeholder
    /// tokens. Returns an empty array if nothing is detected.
    ///
    /// When `skipCodeBlocks` is true, fenced and inline code is
    /// masked out before the classifier runs so we don't flag
    /// identifiers inside code as people-names. Detected ranges are
    /// translated back to the original input so callers can highlight
    /// the right characters in the review sheet.
    ///
    /// This is the public surface — it runs the all-built-ins ruleset
    /// so SDK callers stay simple. Internal pipeline callers use the
    /// `detect(in:map:skipCodeBlocks:ruleset:)` overload below to thread
    /// the user's configured ruleset (per-category toggles, presets,
    /// custom rules) through.
    public func detect(
        in text: String,
        map: RedactionMap,
        skipCodeBlocks: Bool = true,
        useModel: Bool = true,
        backend: PrivacyAIBackend = .openai
    ) async throws -> [DetectedEntity] {
        try await detect(
            in: text,
            map: map,
            skipCodeBlocks: skipCodeBlocks,
            ruleset: .allBuiltins(),
            useModel: useModel,
            backend: backend
        )
    }

    /// Internal overload that takes an explicit `EffectiveRuleSet`.
    /// Used by `PrivacyFilterPipeline` to pass the user's current
    /// configuration (which built-ins are on, which presets are
    /// enabled, what custom rules are defined) into the regex layer.
    ///
    /// `useModel` decouples the on-device classifier from the
    /// deterministic regex layer. When false the model is never
    /// invoked and a missing/unloaded kit is NOT an error — the
    /// regex layer runs standalone (the "AI detection off" path that
    /// lets the filter work without the ~2.8 GB bundle). When true
    /// the kit is required and `.notLoaded` is thrown if absent.
    func detect(
        in text: String,
        map: RedactionMap,
        skipCodeBlocks: Bool,
        ruleset: RegexEntityDetector.EffectiveRuleSet,
        useModel: Bool,
        backend: PrivacyAIBackend = .openai
    ) async throws -> [DetectedEntity] {
        // Intel: no model detector exists. `useModel` is accepted for API
        // parity and ignored, so the rule layer runs alone and never throws
        // `.notLoaded` (the pipeline never asks for a model either).
        _ = useModel
        _ = backend

        let (scanText, restore): (String, (Range<String.Index>) -> Range<String.Index>?)
        if skipCodeBlocks {
            let masked = CodeBlockMasker.mask(text)
            scanText = masked.masked
            restore = masked.restoreRange
        } else {
            scanText = text
            restore = { range in range }
        }

        // Model NER layer: not available on Intel (see header).
        let modelPending: [PendingMatch] = []
        let modelRawCount = 0

        // Run the deterministic regex layer on the same scan text so
        // it sees the post-code-block-masked view (we don't want to
        // pull tokens out of code fences). Regex catches well-formed
        // emails / URLs / phones / SSNs / credit cards that the small
        // classifier misses — bare 10-digit phone numbers without
        // separators are the canonical example.
        let regexMatches = RegexEntityDetector.detect(in: scanText, ruleset: ruleset)

        var pending: [PendingMatch] = []
        pending.reserveCapacity(modelPending.count + regexMatches.count)
        // The model's phones pass the same check the regex's do: a bare
        // Unix time or id is no phone, whichever detector saw it.
        pending.append(
            contentsOf: modelPending.filter { match in
                match.category != .phone || RegexEntityDetector.isPlausiblePhone(match.original)
            }
        )
        for match in regexMatches {
            pending.append(
                PendingMatch(
                    category: match.category,
                    original: match.original,
                    range: match.range,
                    source: .regex,
                    label: match.label
                )
            )
        }
        let resolved = Self.mergeMatches(pending)

        // First pass: drop matches whose range maps back through the
        // code-block mask to a `nil` (entirely masked) or that sit
        // inside an app-injected context block (the `[Current Time]`
        // prefix is not user text), and collect the survivors. We do
        // this BEFORE interning so we don't pay for placeholders we're
        // about to throw away.
        let injected = InjectedContextSpans.ranges(in: scanText)
        var droppedInjected = 0
        var droppedMasked = 0
        var surviving: [(category: EntityCategory, original: String, range: Range<String.Index>, label: String?)] =
            []
        surviving.reserveCapacity(resolved.count)
        for match in resolved {
            if InjectedContextSpans.overlaps(match.range, injected) {
                droppedInjected += 1
                continue
            }
            guard let restored = restore(match.range) else {
                droppedMasked += 1
                continue
            }
            surviving.append((match.category, match.original, restored, match.label))
        }
        // Counts only, never text: enough to tell "the model saw nothing"
        // from "it was dropped" when a send goes out with no review.
        print(
            "[PrivacyFilter] Segment: \(scanText.count) chars, model[off] \(modelRawCount) raw / \(modelPending.count) mapped, regex \(regexMatches.count), merged \(resolved.count), dropped \(droppedInjected) injected-context + \(droppedMasked) code-masked, kept \(surviving.count); injected-context spans \(injected.count)"
        )

        // Second pass: batch-intern in a single actor hop. Previous
        // implementation awaited `map.intern(…)` per match — a 30-hit
        // segment cost 30 hops × segment_count. `internBatch` is
        // idempotent per-original (same semantics as `intern`).
        let placeholders = await map.internBatch(
            surviving.map { (original: $0.original, category: $0.category, label: $0.label) }
        )

        var out: [DetectedEntity] = []
        out.reserveCapacity(surviving.count)
        for (idx, match) in surviving.enumerated() {
            out.append(
                DetectedEntity(
                    category: match.category,
                    original: match.original,
                    range: match.range,
                    placeholder: placeholders[idx]
                )
            )
        }
        return out
    }

    /// Model-only NER spans for the screenshot `FrameScrubber` seam. Intel has
    /// no model detector, so this is always empty and callers rely on their
    /// regex layer (fail closed where they must).
    public func modelSpans(in text: String)
        async -> [(category: EntityCategory, range: Range<String.Index>)]
    {
        []
    }

    /// Merge model + regex matches into a non-overlapping set.
    ///
    /// Sort start-ascending, ties by longer span. On overlap, keep
    /// the longer span. When lengths are equal, regex wins for the
    /// high-precision categories (email / url / phone / accountNumber)
    /// where the small classifier is unreliable; the model wins for
    /// person / address / date / secret. This biases toward recall in
    /// the categories where the model demonstrably under-detects
    /// (e.g. bare 10-digit phone numbers in lowercase context) while
    /// still letting the model own ambiguous NER categories.
    fileprivate static func mergeMatches(_ pending: [PendingMatch]) -> [PendingMatch] {
        let regexOwned: Set<EntityCategory> = [.email, .url, .phone, .accountNumber]
        let sorted = pending.sorted { a, b in
            if a.range.lowerBound != b.range.lowerBound {
                return a.range.lowerBound < b.range.lowerBound
            }
            return a.original.count > b.original.count
        }
        var kept: [PendingMatch] = []
        for match in sorted {
            guard let last = kept.last, last.range.overlaps(match.range) else {
                kept.append(match)
                continue
            }
            let newLen = match.original.count
            let oldLen = last.original.count
            let newWins: Bool
            if newLen != oldLen {
                newWins = newLen > oldLen
            } else {
                switch (match.source, last.source) {
                case (.regex, .model):
                    newWins = regexOwned.contains(match.category)
                case (.model, .regex):
                    newWins = !regexOwned.contains(last.category)
                default:
                    newWins = false
                }
            }
            if newWins {
                kept.removeLast()
                kept.append(match)
            }
        }
        return kept
    }

    fileprivate struct PendingMatch {
        let category: EntityCategory
        let original: String
        let range: Range<String.Index>
        let source: Source
        /// Custom placeholder label carried from a custom regex rule;
        /// `nil` for model spans, built-ins, and presets.
        let label: String?
        enum Source { case model, regex }
    }

    /// Apply approved entities to the original text and return the
    /// scrubbed string. Ranges are applied right-to-left so earlier
    /// offsets stay valid as substitutions change string length.
    ///
    /// Unapproved entities are silently skipped — their placeholder
    /// stays in the map so future turns can still reuse it if the
    /// user changes their mind.
    public nonisolated func apply(_ entities: [DetectedEntity], to text: String) -> String {
        let approved =
            entities
            .filter { $0.approved }
            .sorted { $0.range.lowerBound > $1.range.lowerBound }

        var result = text
        for entity in approved {
            // Repeated occurrences of the same original may share a
            // placeholder but only one DetectedEntity carries the
            // canonical range used here. Other occurrences are
            // substituted by the simple find-and-replace fallback
            // below.
            result.replaceSubrange(entity.range, with: entity.placeholder.token)
        }

        // Second pass for repeated occurrences not covered by the
        // detector's range list. Runs left-to-right on the (already
        // partially scrubbed) string and replaces every literal
        // appearance of an approved original with its token. Cheap
        // when there are no duplicates because `range(of:)` short-
        // circuits at the first miss.
        for entity in entities where entity.approved {
            while let found = result.range(of: entity.original) {
                result.replaceSubrange(found, with: entity.placeholder.token)
            }
        }

        return result
    }
}
