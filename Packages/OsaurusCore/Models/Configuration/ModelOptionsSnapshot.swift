//
//  ModelOptionsSnapshot.swift
//  osaurus
//
//  The composer picker's "Model Options" section as data, for the paired
//  phone (upstream MOBILE_PROTOCOL §12.3; `POST`/`PUT /models/options`,
//  `W-server-api` stage 5b). Mirrors FloatingInputCard's
//  `modelPickerOptionsControl`: the semantic Thinking row, then every other
//  option the model's profile exposes. Reads and writes the same per-model
//  `ModelOptionsStore` the Mac composer does, which is also what Intel's
//  engine applies to agent runs.
//
//  Intel's part of upstream's file. Intel's composer has no live catalog
//  reasoning levels (`ModelReasoningCapabilities`), no local-bundle
//  reasoning contract (`LocalReasoningCapability`, `AgentReasoningPolicy`)
//  and no Native MTP row (an Apple-silicon runtime setting), so neither
//  does the snapshot: Thinking shows the explicit choice, as the composer
//  does, defaults are the static profile's, and effort levels carry no
//  catalog description. Intel's option definitions have no help text.
//

import Foundation

struct ModelOptionsSnapshot: Encodable, Equatable {
    struct Thinking: Encodable, Equatable {
        /// Effective state: the explicit choice, else off (Intel's composer).
        let enabled: Bool
        /// Whether an explicit choice is stored (false shows "Default").
        let explicit: Bool
        /// Offers Default / On / Off rather than a plain switch.
        let tristate: Bool
    }

    struct Segment: Encodable, Equatable {
        let id: String
        let label: String
        /// Catalog copy for an effort level, when the provider publishes it.
        let description: String?
    }

    struct Option: Encodable, Equatable {
        let id: String
        let label: String
        let icon: String?
        let help: String?
        /// `segmented | toggle`
        let kind: String
        let segments: [Segment]?
        /// Effective segment id (segmented).
        let selected: String?
        /// Effective state (toggle).
        let on: Bool?
        let explicit: Bool
    }

    let model: String
    let thinking: Thinking?
    let options: [Option]

    /// Option id the phone sends to set the semantic Thinking row.
    static let thinkingOptionId = "thinking"

    enum ApplyError: Error {
        case unknownOption
        case invalidValue
    }

    @MainActor
    static func make(for model: String) -> ModelOptionsSnapshot {
        let values = ModelProfileRegistry.normalizedOptions(
            for: model,
            persisted: ModelOptionsStore.shared.loadOptions(for: model)
        )
        let thinkingId = ModelProfileRegistry.profile(for: model)?.thinkingOption?.id
        let definitions = ModelProfileRegistry.options(for: model)

        var thinking: Thinking?
        if thinkingId != nil {
            let explicit = ModelProfileRegistry.thinkingEnabled(for: model, values: values)
            // Intel's composer leaves `supportsUnspecifiedDefault` off: a plain
            // switch with a reset, not Default / On / Off.
            thinking = Thinking(enabled: explicit ?? false, explicit: explicit != nil, tristate: false)
        }

        let defaults = ModelProfileRegistry.defaults(for: model)
        let options = definitions.filter { $0.id != thinkingId }.map { definition -> Option in
            let explicit = values[definition.id] != nil
            switch definition.kind {
            case .segmented(let segments):
                return Option(
                    id: definition.id,
                    label: definition.label,
                    icon: definition.icon,
                    help: nil,
                    kind: "segmented",
                    segments: segments.map { Segment(id: $0.id, label: $0.label, description: nil) },
                    selected: values[definition.id]?.stringValue
                        ?? defaults[definition.id]?.stringValue
                        ?? segments.first?.id,
                    on: nil,
                    explicit: explicit
                )
            case .toggle(let defaultValue):
                return Option(
                    id: definition.id,
                    label: definition.label,
                    icon: definition.icon,
                    help: nil,
                    kind: "toggle",
                    segments: nil,
                    selected: nil,
                    on: values[definition.id]?.boolValue
                        ?? defaults[definition.id]?.boolValue
                        ?? defaultValue,
                    explicit: explicit
                )
            }
        }
        return ModelOptionsSnapshot(model: model, thinking: thinking, options: options)
    }

    /// Stores one choice the way the Mac composer's picker rows do. A nil
    /// value removes the override so the model's default applies again.
    @MainActor
    static func apply(model: String, optionId: String, value: ModelOptionValue?) throws {
        var updated = ModelProfileRegistry.normalizedOptions(
            for: model,
            persisted: ModelOptionsStore.shared.loadOptions(for: model)
        )
        let thinkingOption = ModelProfileRegistry.profile(for: model)?.thinkingOption
        if optionId == thinkingOptionId {
            guard let thinkingOption else { throw ApplyError.unknownOption }
            if let value {
                guard let enabled = value.boolValue,
                    let stored = ModelProfileRegistry.thinkingStoredOption(for: model, enabled: enabled)
                else { throw ApplyError.invalidValue }
                updated[stored.id] = stored.value
            } else {
                updated.removeValue(forKey: thinkingOption.id)
            }
        } else {
            guard optionId != thinkingOption?.id,
                let definition = ModelProfileRegistry.options(for: model).first(where: { $0.id == optionId })
            else { throw ApplyError.unknownOption }
            if let value {
                switch definition.kind {
                case .segmented(let segments):
                    guard let id = value.stringValue, segments.contains(where: { $0.id == id })
                    else { throw ApplyError.invalidValue }
                case .toggle:
                    guard value.boolValue != nil else { throw ApplyError.invalidValue }
                }
                updated[optionId] = value
            } else {
                updated.removeValue(forKey: optionId)
            }
            if optionId == "reasoningEffort" {
                updated.removeValue(forKey: "disableThinking")
            }
        }
        ModelOptionsStore.shared.saveOptions(updated, for: model)
        NotificationCenter.default.post(name: .modelOptionsChanged, object: model)
    }
}

extension Notification.Name {
    /// A model's stored options changed outside the composer (the paired
    /// phone). `object` is the model id.
    static let modelOptionsChanged = Notification.Name("modelOptionsChanged")
}
