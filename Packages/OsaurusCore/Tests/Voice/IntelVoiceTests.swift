//
//  IntelVoiceTests.swift
//  OsaurusCoreTests
//
//  `W-voice` (docs/VOICE_INTEL.md): the Intel-specific voice pieces — speech
//  settings, the language picker's matching, the system-voice helpers, the
//  opt-in transcript cleanup, the Speak Tool switch, and the Voice tab. No
//  microphone, recogniser or speaker is touched: Apple Speech and playback
//  are Rosy checks.
//

import AVFoundation
import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel voice", .serialized)
struct IntelVoiceTests {
    // MARK: Speech settings

    @Test("Speech settings default to on-device only, no cleanup, system language")
    func speechDefaults() {
        let config = SpeechConfiguration.default
        #expect(config.recognitionLocale.isEmpty)
        #expect(!config.allowServerRecognition)
        #expect(!config.postProcessTranscription)
    }

    @Test("An upstream speech.json (Parakeet model version) still decodes")
    func upstreamSpeechConfigDecodes() throws {
        let upstream = #"{"modelVersion":"v2","sensitivity":"high","pauseDuration":2.5,"postProcessTranscription":true}"#
        let config = try JSONDecoder().decode(SpeechConfiguration.self, from: Data(upstream.utf8))
        #expect(config.sensitivity == .high)
        #expect(config.pauseDuration == 2.5)
        #expect(config.postProcessTranscription)  // an explicit choice is kept
        #expect(!config.allowServerRecognition)
        #expect(config.recognitionLocale.isEmpty)

        var changed = config
        changed.recognitionLocale = "de-DE"
        changed.allowServerRecognition = true
        let roundTrip = try JSONDecoder().decode(
            SpeechConfiguration.self, from: JSONEncoder().encode(changed))
        #expect(roundTrip == changed)
    }

    @Test("Sensitivity maps to a stricter energy threshold for Low than High")
    func energyThresholds() {
        #expect(VoiceSensitivity.low.energyThreshold > VoiceSensitivity.medium.energyThreshold)
        #expect(VoiceSensitivity.medium.energyThreshold > VoiceSensitivity.high.energyThreshold)
    }

    @Test("The recognition language falls back to the same language, then English")
    func languageMatching() {
        let candidates = ["en-US", "en-GB", "pt-BR", "de-DE"]
        #expect(SpeechModelManager.bestMatch(for: "en-GB", in: candidates) == "en-GB")
        #expect(SpeechModelManager.bestMatch(for: "pt-PT", in: candidates) == "pt-BR")
        #expect(SpeechModelManager.bestMatch(for: "de-AT", in: candidates) == "de-DE")
        #expect(SpeechModelManager.bestMatch(for: "ja-JP", in: candidates) == "en-US")
        #expect(SpeechModelManager.bestMatch(for: "ja-JP", in: []) == nil)
    }

    // MARK: System voices

    @Test("The speed multiplier maps onto AVSpeechUtterance's rate scale")
    func rateMapping() {
        #expect(SystemVoiceCatalog.utteranceRate(multiplier: 1.0) == AVSpeechUtteranceDefaultSpeechRate)
        #expect(SystemVoiceCatalog.utteranceRate(multiplier: 2.0) == AVSpeechUtteranceMaximumSpeechRate)
        #expect(SystemVoiceCatalog.utteranceRate(multiplier: 0.5) == AVSpeechUtteranceMinimumSpeechRate)
        #expect(SystemVoiceCatalog.utteranceRate(multiplier: 9) == AVSpeechUtteranceMaximumSpeechRate)
        #expect(
            SystemVoiceCatalog.utteranceRate(multiplier: 1.5) > AVSpeechUtteranceDefaultSpeechRate)
    }

    @Test("Automatic voice follows the reply's language")
    func dominantLanguage() {
        #expect(
            SystemVoiceCatalog.dominantLanguage(
                of: "Guten Morgen! Heute kaufen wir Reis und Linsen für die ganze Woche.") == "de")
        #expect(
            SystemVoiceCatalog.dominantLanguage(
                of: "Good morning! Today we are buying rice and lentils for the whole week.") == "en")
        #expect(SystemVoiceCatalog.dominantLanguage(of: "") == nil)
    }

    @Test("A stored voice that is no longer installed falls back instead of failing")
    func staleVoiceFallsBack() {
        // "alba" is an upstream PocketTTS voice name, not a system voice.
        let voice = SystemVoiceCatalog.voice(for: "alba", text: "Good morning, this is a test sentence.")
        #expect(voice?.identifier != "alba")
    }

    @Test("Both Intel engines are always ready (nothing to download)")
    @MainActor
    func ttsAlwaysReady() {
        #expect(TTSService.shared.isModelReady)
        #expect(TTSService.shared.modelState == .ready)
    }

    // MARK: Transcript cleanup (opt-in, core model)

    @MainActor
    @Test("Cleanup uses the model's text, skips short input, and keeps raw text on failure")
    func cleanup() async {
        let service = TranscriptionCleanupService()
        let calls = Counter()
        service.generator = { _, userPrompt, _ in
            await calls.increment()
            #expect(userPrompt.contains("<transcript>"))
            return "I went to the store."
        }
        #expect(await service.clean("uh I I went to the store") == "I went to the store.")
        #expect(await service.clean("hi there") == "hi there")  // too short: no call
        #expect(await calls.value == 1)

        service.generator = { _, _, _ in throw URLError(.notConnectedToInternet) }
        #expect(await service.clean("um so we need more rice") == "um so we need more rice")

        // Hallucination guard: a much shorter answer to a long transcript is ignored.
        service.generator = { _, _, _ in "Rice." }
        let long = String(repeating: "we need rice and lentils for the week ", count: 3)
        #expect(await service.clean(long) == long)
    }

    // MARK: Speak Tool

    @Test("The Speak Tool switch round-trips and older agents decode with it off")
    func speakSettingCodable() throws {
        var settings = AgentSettings.defaultDisabled
        #expect(!settings.speakEnabled)
        settings.speakEnabled = true
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AgentSettings.self, from: data).speakEnabled)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "speakEnabled")
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try !JSONDecoder().decode(AgentSettings.self, from: old).speakEnabled)
    }

    @MainActor
    @Test("speak is offered and runs only for a custom agent with the switch and tools on")
    func speakGating() async throws {
        try await ChatHistoryTestStorage.run {
            func make(_ enabled: Bool) -> Agent {
                var agent = Agent(name: "speak-\(UUID().uuidString.prefix(6))", systemPrompt: "x", agentAddress: nil)
                agent.settings.speakEnabled = enabled
                agent.manualToolNames = ["file_read"]  // seeded allowlist without speak
                return agent
            }
            let on = make(true)
            let off = make(false)
            var toolsOff = make(true)
            toolsOff.disableTools = true
            for agent in [on, off, toolsOff] { AgentManager.shared.add(agent) }

            #expect(AgentManager.shared.effectiveSpeakEnabled(for: on.id))
            #expect(!AgentManager.shared.effectiveSpeakEnabled(for: off.id))
            #expect(!AgentManager.shared.effectiveSpeakEnabled(for: toolsOff.id))
            #expect(!AgentManager.shared.effectiveSpeakEnabled(for: Agent.defaultId))

            let offered = await SystemPromptComposer.composeChatContext(agentId: on.id, query: "hi")
            #expect(offered.tools.contains { $0.function.name == "speak" })
            let hidden = await SystemPromptComposer.composeChatContext(agentId: off.id, query: "hi")
            #expect(!hidden.tools.contains { $0.function.name == "speak" })

            let refused = try await ChatExecutionContext.$currentAgentId.withValue(off.id) {
                try await ToolRegistry.shared.execute(name: "speak", argumentsJSON: #"{"text":"Hello"}"#)
            }
            #expect(refused.contains("Speak Tool is off"))

            for agent in [on, off, toolsOff] { _ = await AgentManager.shared.delete(id: agent.id) }
        }
    }

    // MARK: Voice tab

    @Test("The Voice tab is available on Intel and listed under General")
    func voiceTabAvailable() {
        #expect(ManagementTab.voice.isAvailableOnIntel)
        #expect(ManagementSection.general.tabs.contains(.voice))
        #expect(!ManagementSection.unavailable.tabs.contains(.voice))
    }

    @Test("Voice search results open a real Voice sub-tab")
    func voiceSearchSubTabs() {
        let voiceEntries = SettingsSearchIndex.entries.filter { $0.tab == .voice }
        #expect(!voiceEntries.isEmpty)
        for entry in voiceEntries {
            let subTab = try? #require(entry.subTab)
            #expect(subTab.flatMap(VoiceTab.init(rawValue:)) != nil, "\(entry.id)")
        }
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
