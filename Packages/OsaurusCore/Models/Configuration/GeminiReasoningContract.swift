//
//  GeminiReasoningContract.swift
//  osaurus
//
//  Documented thinking-level contract for Gemini text models.
//
//  Intel (2026-10-27, upstream #3115): verbatim except the picker surface.
//  Upstream hands `capabilities(forModelId:)` to its live reasoning catalog
//  (`ModelReasoningCapabilities` on `ModelPickerItem`), which Intel doesn't
//  have; Intel's picker reads `GeminiReasoningProfile` (ModelOptions.swift),
//  built from the same entries, and `IntelGeminiReasoningRoute` applies
//  `routeHonorsContract` to the selected model's provider. The native
//  `thinkingConfig` is a dictionary written by `IntelGeminiAdapter`.
//

import Foundation

/// Per-model thinking levels for Gemini text models, from Google's thinking
/// docs (ai.google.dev/gemini-api/docs/thinking, audited 2026-10). The level
/// sets differ by model (3 Pro stops at low/high, 3.6 Flash adds `minimal`,
/// 3.8 Flash drops it), so one shared ladder would send values some models
/// reject. Ids are matched by documented prefix; an unlisted Gemini revision
/// gets no control until it is added here, rather than a guessed set.
///
/// Image, TTS, embedding and live models are excluded: they have their own
/// profiles or no thinking control.
enum GeminiReasoningContract {
    enum Control: Equatable, Sendable {
        /// Gemini 3: `thinkingConfig.thinkingLevel` takes the level id.
        case level
        /// Gemini 2.5: `thinkingConfig.thinkingBudget` takes a token count.
        case budget
    }

    struct Entry: Equatable, Sendable {
        let prefix: String
        let levels: [String]
        /// The level the API applies when none is sent. Display-only. Nil
        /// where the docs give no level (2.5 models default to a budget).
        let defaultLevel: String?
        let control: Control
    }

    /// Flash-Lite rows precede their Flash siblings so `-lite` ids never
    /// fall through to the Flash level set.
    static let entries: [Entry] = [
        Entry(prefix: "gemini-3.5-flash-lite", levels: ["minimal", "low", "medium", "high"], defaultLevel: "minimal", control: .level),
        Entry(prefix: "gemini-2.5-flash-lite", levels: ["low", "medium", "high"], defaultLevel: nil, control: .budget),
        Entry(prefix: "gemini-3.8-flash", levels: ["low", "medium", "high"], defaultLevel: "medium", control: .level),
        Entry(prefix: "gemini-3.6-flash", levels: ["minimal", "low", "medium", "high"], defaultLevel: "medium", control: .level),
        Entry(prefix: "gemini-3-flash", levels: ["minimal", "low", "medium", "high"], defaultLevel: "high", control: .level),
        Entry(prefix: "gemini-3.1-pro", levels: ["low", "medium", "high"], defaultLevel: "high", control: .level),
        Entry(prefix: "gemini-3-pro", levels: ["low", "high"], defaultLevel: "high", control: .level),
        Entry(prefix: "gemini-2.5-pro", levels: ["low", "medium", "high"], defaultLevel: nil, control: .budget),
        Entry(prefix: "gemini-2.5-flash", levels: ["low", "medium", "high"], defaultLevel: nil, control: .budget),
    ]

    /// Token budgets for 2.5 models, matching Google's own
    /// `reasoning_effort` mapping on its OpenAI-compatible endpoint.
    static let budgets: [String: Int] = ["low": 1024, "medium": 8192, "high": 24576]

    private static let excludedTokens = ["image", "tts", "embedding", "live", "audio"]

    /// Lowercased id with any provider/route prefix removed
    /// (`openrouter/google/gemini-3.8-flash`, `models/gemini-3.8-flash`).
    static func bareModelId(_ modelId: String) -> String {
        let lower = modelId.lowercased()
        return lower.split(separator: "/").last.map(String.init) ?? lower
    }

    static func entry(forModelId modelId: String) -> Entry? {
        let bare = bareModelId(modelId)
        guard bare.hasPrefix("gemini-"),
            !excludedTokens.contains(where: { bare.contains($0) })
        else { return nil }
        let isLite = bare.contains("-lite")
        return entries.first { entry in
            guard entry.prefix.contains("-lite") == isLite else { return false }
            return bare == entry.prefix || bare.hasPrefix(entry.prefix + "-")
        }
    }

    /// Intel: the level ids and display default for the picker (upstream
    /// returns `ModelReasoningCapabilities` here).
    static func capabilities(forModelId modelId: String) -> (levels: [String], defaultLevel: String?)? {
        guard let entry = entry(forModelId: modelId) else { return nil }
        return (entry.levels, entry.defaultLevel)
    }

    /// Routes that carry the effort to Gemini intact: the native API (via
    /// `thinkingConfig`), Google's OpenAI-compatible endpoint, and
    /// OpenRouter (both read `reasoning_effort`). Other OpenAI-compatible
    /// proxies are not assumed to forward it.
    static func routeHonorsContract(providerType: RemoteProviderType, host: String) -> Bool {
        switch providerType {
        case .gemini:
            return true
        case .openaiLegacy:
            let lowered = host.lowercased()
            return lowered.contains("googleapis.com") || lowered.contains("openrouter.ai")
        case .azureOpenAI, .anthropic, .openResponses, .openAICodex, .osaurus, .osaurusRouter:
            return false
        }
    }

    /// Native `thinkingConfig` for an effort chosen in the picker. Nil when
    /// the model has no documented control or the effort is not one of its
    /// levels, so nothing unaccepted reaches the wire.
    /// Intel: the JSON object (`["thinkingLevel": …]` or
    /// `["thinkingBudget": …]`), since Intel's Gemini request is a dictionary.
    static func thinkingConfig(forModelId modelId: String, effort: String?) -> [String: Any]? {
        guard
            let effort = effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            let entry = entry(forModelId: modelId),
            entry.levels.contains(effort)
        else { return nil }
        switch entry.control {
        case .level:
            return ["thinkingLevel": effort]
        case .budget:
            return budgets[effort].map { ["thinkingBudget": $0] }
        }
    }

    /// Intel: whether the effort reaches this endpoint's wire at all. True
    /// for anything that isn't a Gemini text model (other profiles decide);
    /// for a Gemini text model, the route must honor the contract and the
    /// effort must be one of the model's documented levels.
    static func wireAccepts(
        effort: String, modelId: String, providerType: RemoteProviderType?, host: String
    ) -> Bool {
        guard let entry = entry(forModelId: modelId) else { return true }
        guard let providerType, routeHonorsContract(providerType: providerType, host: host) else { return false }
        return entry.levels.contains(effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
