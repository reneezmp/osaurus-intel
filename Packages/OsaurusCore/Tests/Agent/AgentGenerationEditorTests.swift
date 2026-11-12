//
//  AgentGenerationEditorTests.swift
//  OsaurusCoreTests
//
//  `W-agent-generation-overrides`: ported from upstream Classic's
//  `AgentGenerationEditorTests` (#3233, #3246). Template-parameter, speculation
//  and `ResponsesInferenceRequest` cases are local-runtime and not compiled on
//  Intel; the request precedence cases run against Intel's frozen controls
//  (`ChatTurnGenerationControlsAgentTests`).
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentGenerationEditorTests {
    @Test("picker saves refresh untouched fields without losing unsaved text or chips")
    func externalSaveRebasesDraft() throws {
        let previous = AgentGenerationDraft(
            temperature: 0.4, maxTokens: 512,
            settings: .init(topP: 0.8, stop: ["old"], reasoningEffort: "high"))
        var draft = previous
        draft.topP.text = "0.73"
        draft.pendingStopSequence = "pending"
        let latest = AgentGenerationDraft(
            temperature: 0.6, maxTokens: 1024,
            settings: .init(topP: 0.9, stop: ["new"], reasoningEffort: "low"))

        draft.mergeSavedChanges(from: previous, to: latest)

        #expect(draft.reasoningEffort == "low")
        #expect(try draft.temperature.float(named: "Temperature") == 0.6)
        #expect(try draft.maxTokens.integer(named: "Max Tokens") == 1024)
        #expect(try draft.topP.float(named: "Top P") == 0.73)
        #expect(try draft.stopSequencesIncludingPending() == ["old", "pending"])

        draft.mergeSavedChanges(from: latest, to: .init())
        #expect(draft.reasoningEffort.isEmpty)
        #expect(!draft.temperature.isCustom)
        #expect(draft.topP.text == "0.73")
        #expect(draft.pendingStopSequence == "pending")
    }

    @Test("an unsaved reasoning edit survives an external Off save as one control")
    func externalSavePreservesReasoningEdit() {
        let previous = AgentGenerationDraft(settings: .init(reasoningEffort: "high"))
        var draft = previous
        draft.reasoningEffort = "low"
        let latest = AgentGenerationDraft(settings: .init(enableThinking: false))

        draft.mergeSavedChanges(from: previous, to: latest)

        #expect(draft.reasoningEffort == "low")
        #expect(draft.thinking == "inherit")
        var untouched = previous
        untouched.mergeSavedChanges(from: previous, to: latest)
        #expect(untouched.thinking == "off")
        #expect(untouched.reasoningEffort.isEmpty)
    }

    @Test("an external picker update never erases an invalid unsaved sampler value")
    func externalSavePreservesInvalidText() {
        let previous = AgentGenerationDraft(settings: .init(topP: 0.9, reasoningEffort: "high"))
        var draft = previous
        draft.topP.text = "not a number"
        let latest = AgentGenerationDraft(settings: .init(topP: 0.8, reasoningEffort: "none"))

        draft.mergeSavedChanges(from: previous, to: latest)

        #expect(draft.reasoningEffort == "none")
        #expect(draft.topP.text == "not a number")
        #expect(throws: (any Error).self) { try draft.validated() }
    }

    @Test("enabling custom stop sequences starts with the inherited no-override value")
    func customJSONStartsWithInheritedValues() throws {
        var draft = AgentGenerationDraft()
        draft.stop.setCustom(true, inheritedText: AgentGenerationField.stop.seedText)
        #expect(draft.stop.text == "[]")
        let values = try draft.validated()
        #expect(values.settings?.stop == [])
        draft.stop.setCustom(false)
        #expect(try draft.validated().settings == nil)
    }

    @Test("custom toggles preserve existing edits and saved values")
    func customJSONPreservesEdits() throws {
        var draft = AgentGenerationDraft(settings: .init(stop: ["END"]))
        let saved = try draft.validated().settings
        let original = draft
        draft.stop.setCustom(false)
        draft.stop.setCustom(true, inheritedText: "[]")
        #expect(draft == original)
        #expect(try draft.validated().settings == saved)
    }

    @Test("blank custom value validation names the visible Inherit choice")
    func blankValidationUsesCustomLabel() {
        var value = AgentGenerationFieldDraft()
        value.isCustom = true
        value.text = " \n "
        do {
            _ = try value.value(named: "Stop sequences")
            Issue.record("Blank custom value must not save")
        } catch {
            #expect(
                error.localizedDescription
                    == "Enter a value for Stop sequences, or select Inherit to use defaults.")
        }
    }

    @Test("a pending stop chip is saved with the draft")
    func pendingStopIsSaved() throws {
        var draft = AgentGenerationDraft(settings: .init(stop: ["a"]))
        draft.pendingStopSequence = "b"
        #expect(try draft.stopSequencesIncludingPending() == ["a", "b"])
        try draft.commitStopSequence()
        #expect(draft.pendingStopSequence.isEmpty)
        #expect(try draft.validated().settings?.stop == ["a", "b"])
    }

    @Test("inherit and explicit zero/false survive the agent editor")
    func draftRoundTrip() throws {
        let settings = AgentGenerationSettings(
            topP: 0, topK: 0, minP: 0,
            repetitionPenalty: 1, presencePenalty: 0, seed: 0, stop: [],
            enableThinking: false, reasoningEffort: "xhigh")
        let draft = AgentGenerationDraft(temperature: 0, maxTokens: 128, settings: settings)
        let values = try draft.validated()
        #expect(values.temperature == 0)
        #expect(values.maxTokens == 128)
        #expect(values.settings == settings)
        #expect(draft.overrideCount == 11)
        let inherited = try AgentGenerationDraft().validated()
        #expect(inherited.temperature == nil)
        #expect(inherited.maxTokens == nil)
        #expect(inherited.settings == nil)
    }

    @Test("invalid custom text never becomes an inherited setting")
    func invalidCustomValuesReject() throws {
        for input in ["", "NaN", "infinity", "not a number"] {
            var draft = AgentGenerationDraft()
            draft.topP.isCustom = true
            draft.topP.text = input
            #expect(throws: (any Error).self) { try draft.validated() }
        }
        var draft = AgentGenerationDraft()
        draft.topK = .init("1.2")
        #expect(throws: (any Error).self) { try draft.validated() }
        draft.topK.isCustom = false
        #expect(try draft.validated().settings == nil)
        var tokens = AgentGenerationDraft()
        tokens.maxTokens = .init("0")
        #expect(throws: (any Error).self) { try tokens.validated() }
    }

    @Test("only the selected model's exact effort ids are accepted")
    func exactCapabilities() throws {
        let choices = AgentGenerationReasoningChoices(
            efforts: ["low", "medium", "xhigh"].map { .init(id: $0, label: $0) },
            supportsThinking: false)
        try choices.validate(settings: .init(reasoningEffort: "xhigh"))
        #expect(throws: (any Error).self) { try choices.validate(settings: .init(reasoningEffort: "high")) }
        #expect(throws: (any Error).self) { try choices.validate(settings: .init(enableThinking: false)) }
        let noControls = AgentGenerationReasoningChoices(efforts: [], supportsThinking: false)
        try noControls.validate(settings: .init())
        #expect(throws: (any Error).self) { try noControls.validate(settings: .init(reasoningEffort: "low")) }
        try AgentGenerationReasoningChoices(efforts: [], supportsThinking: true)
            .validate(settings: .init(enableThinking: false))
    }

    @Test("choices follow the same profiles the model picker uses")
    func choicesFromProfiles() {
        // Qwen has the canonical Thinking toggle and no effort ladder.
        let qwen = AgentGenerationReasoningChoices.resolve(modelID: "qwen3-8b")
        #expect(qwen.supportsThinking)
        #expect(!qwen.hasEfforts)
        // An unknown model advertises nothing.
        let unknown = AgentGenerationReasoningChoices.resolve(modelID: "some-unknown-model-xyz")
        #expect(!unknown.supportsThinking)
        #expect(!unknown.hasEfforts)
    }
}
