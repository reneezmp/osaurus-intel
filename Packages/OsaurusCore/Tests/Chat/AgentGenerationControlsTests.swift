//
//  AgentGenerationControlsTests.swift
//  osaurusTests
//
//  `W-agent-generation-overrides`: the agent's saved generation settings are
//  frozen with the turn (upstream #3226 / #3233 / #3244, adapted: Intel's
//  request carries `explicitSampling` and `modelOptions`) and mapped per
//  provider by `IntelSamplingWire` (upstream #3226's "provider cannot
//  represent this" rules).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Agent generation controls")
struct AgentGenerationControlsTests {
    private func request(model: String = "gpt-4o-mini") -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: model,
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: nil, max_tokens: nil, stream: true, top_p: nil,
            frequency_penalty: nil, presence_penalty: nil, stop: nil, n: nil,
            tools: nil, tool_choice: nil, session_id: nil
        )
    }

    // MARK: Frozen controls

    @Test("saved agent settings freeze with the turn and reach every rebuilt request")
    func agentSettingsReachEveryRound() {
        let controls = ChatTurnGenerationControls.capture(
            activeModelOptions: [:],
            agentSettings: .init(
                topP: 0.8, topK: 40, minP: 0.05, repetitionPenalty: 1.1,
                frequencyPenalty: 0.3, presencePenalty: 0.4, seed: 17, stop: ["END"]),
            temperature: 0.7
        )
        var requests = [request(), request(), request()]
        for index in requests.indices { controls.apply(to: &requests[index]) }
        for sampling in requests.map(\.explicitSampling) {
            #expect(sampling?.temperature == 0.7)
            #expect(sampling?.topP == 0.8)
            #expect(sampling?.topK == 40)
            #expect(sampling?.minP == 0.05)
            #expect(sampling?.repetitionPenalty == 1.1)
            #expect(sampling?.frequencyPenalty == 0.3)
            #expect(sampling?.presencePenalty == 0.4)
            #expect(sampling?.seed == 17)
            #expect(sampling?.stop == ["END"])
        }
    }

    @Test("floats serialize as the typed decimal, not a widened float")
    func decimalsStayClean() {
        let controls = ChatTurnGenerationControls.capture(
            activeModelOptions: [:], agentSettings: .init(topP: 0.9), temperature: 0.7)
        var req = request()
        controls.apply(to: &req)
        #expect(req.explicitSampling?.temperature == 0.7)
        #expect(req.explicitSampling?.topP == 0.9)
    }

    @Test("nothing explicit means nothing is sent")
    func inheritSendsNothing() {
        let controls = ChatTurnGenerationControls.capture(activeModelOptions: [:])
        var req = request()
        controls.apply(to: &req)
        #expect(req.explicitSampling == nil)
        #expect(req.modelOptions == nil)
    }

    @Test("explicit zero and empty stop are values, not omissions")
    func zeroIsExplicit() {
        let controls = ChatTurnGenerationControls.capture(
            activeModelOptions: [:], agentSettings: .init(topP: 0, topK: 0, seed: 0), temperature: 0)
        var req = request()
        controls.apply(to: &req)
        #expect(req.explicitSampling?.temperature == 0)
        #expect(req.explicitSampling?.topP == 0)
        #expect(req.explicitSampling?.topK == 0)
        #expect(req.explicitSampling?.seed == 0)
        // An empty stop list sends nothing.
        #expect(ChatExplicitSampling(stop: []).isEmpty)
    }

    @Test("per-turn overrides beat agent values, which beat captured defaults")
    func precedence() {
        var controls = ChatTurnGenerationControls.capture(
            activeModelOptions: [:], agentSettings: .init(topP: 0.8, topK: 42), temperature: 0.5, topP: 0.95)
        var req = request()
        controls.apply(to: &req)
        #expect(req.explicitSampling?.topP == 0.8)
        #expect(req.explicitSampling?.topK == 42)

        controls.overrides = .init(temperature: 0.1, topP: 0, topK: 0)
        controls.apply(to: &req)
        #expect(req.explicitSampling?.temperature == 0.1)
        #expect(req.explicitSampling?.topP == 0)
        #expect(req.explicitSampling?.topK == 0)
    }

    @Test("an agent's saved reasoning wins over the picker and rides modelOptions")
    func reasoningProjection() {
        let controls = ChatTurnGenerationControls.capture(
            activeModelOptions: ["reasoningEffort": .string("low"), "disableThinking": .bool(true)],
            agentSettings: .init(enableThinking: true, reasoningEffort: "high")
        )
        var req = request(model: "claude-sonnet-5")
        controls.apply(to: &req)
        #expect(req.modelOptions?["reasoningEffort"]?.stringValue == "high")
        #expect(req.modelOptions?["disableThinking"]?.boolValue == false)
        #expect(controls.reasoningEffort == "high")
    }

    @Test("without agent reasoning the picker's options pass through unchanged")
    func pickerPassThrough() {
        let controls = ChatTurnGenerationControls.capture(
            activeModelOptions: ["disableThinking": .bool(true)],
            agentSettings: .init(topP: 0.5)
        )
        var req = request()
        controls.apply(to: &req)
        #expect(req.modelOptions == ["disableThinking": .bool(true)])
    }

    @Test("a saved reasoning default the model does not advertise is rejected, Inherit is not")
    func dispatchValidation() throws {
        let unknown = "some-unknown-model-xyz"
        let bad = ChatTurnGenerationControls.capture(
            activeModelOptions: [:], agentSettings: .init(reasoningEffort: "high"))
        #expect(throws: (any Error).self) { try bad.validateAgentReasoning(modelID: unknown) }
        let fine = ChatTurnGenerationControls.capture(
            activeModelOptions: [:], agentSettings: .init(topP: 0.5))
        try fine.validateAgentReasoning(modelID: unknown)
        try ChatTurnGenerationControls.capture(activeModelOptions: [:])
            .validateAgentReasoning(modelID: unknown)
    }

    // MARK: Provider mapping

    private func body(
        _ sampling: ChatExplicitSampling?, wire: IntelSamplingWire.Wire,
        rejectsSamplers: Bool = false
    ) throws -> [String: Any] {
        var body: [String: Any] = ["model": "m"]
        try IntelSamplingWire.apply(
            sampling, wire: wire, rejectsSamplers: rejectsSamplers, providerLabel: "Provider",
            into: &body)
        return body
    }

    private let everything = ChatExplicitSampling(
        temperature: 0.7, topP: 0.9, topK: 40, minP: 0.05, repetitionPenalty: 1.1,
        frequencyPenalty: 0.2, presencePenalty: 0.3, seed: 9, stop: ["END"])

    @Test("an OpenAI-compatible endpoint receives every explicit field")
    func chatCompletionsGetsEverything() throws {
        let out = try body(everything, wire: .chatCompletions(acceptsExtensions: true))
        #expect(out["temperature"] as? Double == 0.7)
        #expect(out["top_p"] as? Double == 0.9)
        #expect(out["top_k"] as? Int == 40)
        #expect(out["min_p"] as? Double == 0.05)
        #expect(out["repetition_penalty"] as? Double == 1.1)
        #expect(out["frequency_penalty"] as? Double == 0.2)
        #expect(out["presence_penalty"] as? Double == 0.3)
        #expect(out["seed"] as? Int == 9)
        #expect(out["stop"] as? [String] == ["END"])
    }

    @Test("a body with no explicit sampling is untouched")
    func nothingExplicit() throws {
        let out = try body(nil, wire: .chatCompletions(acceptsExtensions: true))
        #expect(Set(out.keys) == ["model"])
        let empty = try body(.init(), wire: .anthropic)
        #expect(Set(empty.keys) == ["model"])
    }

    @Test("a strict host rejects sampler extensions by name, and still takes the standard fields")
    func strictHost() throws {
        let wire = IntelSamplingWire.Wire.chatCompletions(acceptsExtensions: false)
        #expect(
            throws: IntelSamplingWire.Unsupported(
                provider: "Provider", names: ["top_k", "min_p", "repetition_penalty"])
        ) { try body(everything, wire: wire) }
        var standard = everything
        standard.topK = nil
        standard.minP = nil
        standard.repetitionPenalty = nil
        let out = try body(standard, wire: wire)
        #expect(out["seed"] as? Int == 9)
        #expect(out["top_k"] == nil)
    }

    @Test("OpenAI reasoning models drop temperature, Top P and penalties instead of failing")
    func reasoningModelDrops() throws {
        let out = try body(
            everything, wire: .chatCompletions(acceptsExtensions: true), rejectsSamplers: true)
        #expect(out["temperature"] == nil)
        #expect(out["top_p"] == nil)
        #expect(out["frequency_penalty"] == nil)
        #expect(out["presence_penalty"] == nil)
        #expect(out["seed"] as? Int == 9)
        #expect(out["stop"] as? [String] == ["END"])
    }

    @Test("Anthropic carries temperature, Top P/K and stop, and names the rest")
    func anthropic() throws {
        let supported = ChatExplicitSampling(temperature: 0.2, topP: 0.9, topK: 20, stop: ["X"])
        let out = try body(supported, wire: .anthropic)
        #expect(out["top_k"] as? Int == 20)
        #expect(out["stop"] as? [String] == ["X"])
        #expect(
            throws: IntelSamplingWire.Unsupported(
                provider: "Provider",
                names: ["min_p", "repetition_penalty", "frequency_penalty", "presence_penalty", "seed"])
        ) { try body(everything, wire: .anthropic) }
    }

    @Test("Gemini carries Top K and seed, and names the rest")
    func gemini() throws {
        let out = try body(ChatExplicitSampling(topK: 10, seed: 3), wire: .gemini)
        #expect(out["top_k"] as? Int == 10)
        #expect(out["seed"] as? Int == 3)
        #expect(
            throws: IntelSamplingWire.Unsupported(
                provider: "Provider",
                names: ["min_p", "repetition_penalty", "frequency_penalty", "presence_penalty"])
        ) { try body(everything, wire: .gemini) }
    }

    @Test("the Responses wire drops temperature and Top P quietly and refuses the rest")
    func responses() throws {
        let soft = try body(ChatExplicitSampling(temperature: 0.5, topP: 0.5), wire: .responses)
        #expect(Set(soft.keys) == ["model"])
        #expect(
            throws: IntelSamplingWire.Unsupported(
                provider: "Provider",
                names: [
                    "top_k", "min_p", "repetition_penalty", "frequency_penalty", "presence_penalty",
                    "seed", "stop",
                ])
        ) { try body(everything, wire: .responses) }
    }

    @Test("the wire is chosen from the provider type, with strict hosts and the Responses flag")
    func wireSelection() {
        typealias W = IntelSamplingWire
        #expect(W.wire(providerType: .anthropic, host: "api.anthropic.com", usesResponsesWire: false) == .anthropic)
        #expect(W.wire(providerType: .gemini, host: "x", usesResponsesWire: false) == .gemini)
        #expect(W.wire(providerType: .openAICodex, host: "x", usesResponsesWire: false) == .responses)
        #expect(W.wire(providerType: .openaiLegacy, host: "x", usesResponsesWire: true) == .responses)
        #expect(
            W.wire(providerType: .openaiLegacy, host: "api.openai.com", usesResponsesWire: false)
                == .chatCompletions(acceptsExtensions: false))
        #expect(
            W.wire(providerType: .azureOpenAI, host: "x.openai.azure.com", usesResponsesWire: false)
                == .chatCompletions(acceptsExtensions: false))
        #expect(
            W.wire(providerType: .openaiLegacy, host: "openrouter.ai", usesResponsesWire: false)
                == .chatCompletions(acceptsExtensions: true))
        #expect(
            W.wire(providerType: nil, host: "api.deepseek.com", usesResponsesWire: false)
                == .chatCompletions(acceptsExtensions: true))
    }

    @Test("the error names the provider and the settings")
    func errorMessage() {
        let message = IntelSamplingWire.Unsupported(provider: "Anthropic", names: ["seed", "min_p"])
            .localizedDescription
        #expect(message.contains("Anthropic"))
        #expect(message.contains("seed, min_p"))
    }

    // MARK: Adapters

    @Test("Anthropic Messages gets top_k, but not on a model that deprecates the samplers")
    func anthropicAdapterTopK() throws {
        let body: [String: Any] = [
            "model": "claude-sonnet-4-5", "stream": true, "temperature": 0.2, "top_k": 20,
            "messages": [["role": "user", "content": "hi"]],
        ]
        let out = try IntelAnthropicMessagesAdapter.makeRequest(chatCompletions: body)
        #expect(out["top_k"] as? Int == 20)
        var deprecated = body
        deprecated["model"] = "claude-opus-5"
        let dropped = try IntelAnthropicMessagesAdapter.makeRequest(chatCompletions: deprecated)
        #expect(dropped["top_k"] == nil)
        #expect(dropped["temperature"] == nil)
    }

    @Test("Gemini generationConfig gets topK and seed")
    func geminiAdapter() throws {
        let out = try IntelGeminiAdapter.makeRequest(chatCompletions: [
            "model": "gemini-2.5-flash", "top_k": 12, "seed": 5, "temperature": 0.3,
            "messages": [["role": "user", "content": "hi"]],
        ])
        let generation = try #require(out["generationConfig"] as? [String: Any])
        #expect(generation["topK"] as? Int == 12)
        #expect(generation["seed"] as? Int == 5)
        #expect(generation["temperature"] as? Double == 0.3)
    }
}
