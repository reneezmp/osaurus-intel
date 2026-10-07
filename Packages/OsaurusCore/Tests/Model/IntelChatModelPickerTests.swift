//
//  IntelChatModelPickerTests.swift
//  osaurusTests
//
//  Intel wiring for upstream's column picker (docs/MODEL_PICKER_INTEL.md):
//  the pill's effort suffix, semantic Thinking writes, option-column
//  defaults and the Ventura key monitor's key mapping.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct IntelChatModelPickerTests {
    @Test("The pill shows the explicit effort, else the profile default")
    func reasoningSuffix() {
        #expect(ModelProfileRegistry.inlineReasoningSuffixLabel(for: "gpt-6-astra", values: [:]) == "Medium")
        #expect(
            ModelProfileRegistry.inlineReasoningSuffixLabel(
                for: "gpt-6-astra", values: ["reasoningEffort": .string("high")]) == "High")
        #expect(ModelProfileRegistry.inlineReasoningSuffixLabel(for: "gpt-4.1", values: [:]) == nil)
    }

    @Test("Inverted Thinking options store the opposite boolean")
    func thinkingStoredOption() {
        // Qwen 3's profile thinks through an inverted `disableThinking`.
        let on = ModelProfileRegistry.thinkingStoredOption(for: "qwen3-32b", enabled: true)
        #expect(on?.id == "disableThinking")
        #expect(on?.value == .bool(false))
        #expect(ModelProfileRegistry.thinkingStoredOption(for: "qwen3-32b", enabled: false)?.value == .bool(true))
        #expect(ModelProfileRegistry.thinkingStoredOption(for: "gpt-4.1", enabled: true) == nil)
    }

    @Test("The options control falls back from explicit to default to the first segment")
    func optionsControlDefaults() {
        let option = ModelOptionDefinition(
            id: "reasoningEffort", label: "Reasoning Effort",
            kind: .segmented([
                ModelOptionSegment(id: "low", label: "Low"), ModelOptionSegment(id: "medium", label: "Medium"),
            ]))
        func control(_ values: [String: ModelOptionValue], _ defaults: [String: ModelOptionValue]) -> ModelPickerOptionsControl {
            ModelPickerOptionsControl(options: [option], values: values, defaults: defaults, onChange: { _, _ in })
        }
        #expect(control(["reasoningEffort": .string("low")], ["reasoningEffort": .string("medium")])
            .effectiveSegmentId(for: option) == "low")
        #expect(control([:], ["reasoningEffort": .string("medium")]).effectiveSegmentId(for: option) == "medium")
        #expect(control([:], [:]).effectiveSegmentId(for: option) == "low")
        #expect(control([:], [:]).isEmpty == false)
    }

    @Test("Card key monitor maps arrows and both Return keys, nothing else")
    func keyMapping() {
        typealias M = PickerCardKeyMonitor.MonitorView
        #expect(M.key(for: 126) == .up)
        #expect(M.key(for: 125) == .down)
        #expect(M.key(for: 123) == .left)
        #expect(M.key(for: 124) == .right)
        #expect(M.key(for: 36) == .return)
        #expect(M.key(for: 76) == .return)
        #expect(M.key(for: 53) == nil)  // Escape stays with the presenter
    }
}
