//
//  ModelPickerOptionsControl.swift
//  osaurus
//
//  Upstream's options-control state for the chat model picker's third column
//  (upstream keeps these types in `ModelPickerView.swift`; Intel's
//  `ModelPickerView` is its own Ventura rewrite, so they live here).
//
//  Intel: no catalog `ModelReasoningCapabilities` (Codex live catalog), so the
//  control carries only profile options; effort rows use the segment label as
//  their help text.
//

import Foundation

/// Semantic Thinking row state for the picker's options column. The stored
/// boolean (including inverted options like `disableThinking`) is resolved
/// by the owner, never in the view.
struct ModelPickerThinkingControl {
    /// Effective on/off state the row shows: the explicit persisted choice
    /// when present, otherwise the model's default.
    let isEnabled: Bool
    /// Whether an explicit persisted override exists.
    let isExplicit: Bool
    /// Persist a semantic enabled state; nil removes the override.
    let onSetEnabled: (Bool?) -> Void
    var supportsUnspecifiedDefault: Bool = false
}

/// Inline model-options state for the picker's selected model: the semantic
/// Thinking row plus every other option the model's profile exposes.
struct ModelPickerOptionsControl {
    var thinking: ModelPickerThinkingControl? = nil
    /// Non-thinking option definitions, in profile order.
    let options: [ModelOptionDefinition]
    /// Explicit persisted values. Missing keys mean "use the default".
    let values: [String: ModelOptionValue]
    /// Display-only defaults (profile defaults). Never sent.
    let defaults: [String: ModelOptionValue]
    /// Persist one option; nil removes the explicit override.
    let onChange: (String, ModelOptionValue?) -> Void

    var isEmpty: Bool { options.isEmpty && thinking == nil }

    /// Selected segment: explicit choice, then the display default, then the
    /// first segment.
    func effectiveSegmentId(for option: ModelOptionDefinition) -> String? {
        if let explicit = values[option.id]?.stringValue { return explicit }
        if let fallback = defaults[option.id]?.stringValue { return fallback }
        if case .segmented(let segments) = option.kind { return segments.first?.id }
        return nil
    }

    /// Toggle state: explicit choice, then the display default, then the
    /// definition's default.
    func effectiveToggleValue(for option: ModelOptionDefinition) -> Bool {
        if let explicit = values[option.id]?.boolValue { return explicit }
        if let fallback = defaults[option.id]?.boolValue { return fallback }
        if case .toggle(let defaultValue) = option.kind { return defaultValue }
        return false
    }
}
