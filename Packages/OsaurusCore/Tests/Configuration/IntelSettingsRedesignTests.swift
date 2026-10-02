//
//  IntelSettingsRedesignTests.swift
//  OsaurusCoreTests
//
//  Upstream #2950 Settings redesign on Intel (docs/SETTINGS_REDESIGN_INTEL.md).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel Settings redesign (#2950)")
struct IntelSettingsRedesignTests {
    private static let viewsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Configuration
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // OsaurusCore
        .appendingPathComponent("Views")

    @Test func generalGroupHasConversationAndNoStorageTab() {
        let general = ManagementSection.general.tabs
        #expect(general.first == .settings)
        #expect(general.dropFirst().first == .chat)
        #expect(!general.contains(.storage))
        #expect(ManagementTab.chat.label == L("Conversation"))
    }

    /// The Commands page's New / Edit used to open an "Apple Silicon only"
    /// placeholder; step 5 ported upstream's real editor sheet.
    @Test func slashCommandEditorIsTheRealSheet() throws {
        let source = try String(
            contentsOf: Self.viewsRoot.appendingPathComponent("SlashCommand/SlashCommandEditorSheet.swift"),
            encoding: .utf8)
        #expect(!source.contains("AppleSiliconOnlyTab"))
        #expect(source.contains("TextField(L(\"/command-name\")"))
    }

    @Test func voiceTabsResolveTitlesAndOldNames() {
        #expect(VoiceTab.resolved(from: "Transcription") == .transcription)
        #expect(VoiceTab.resolved(from: "Speech To Text") == .speechToText)
        #expect(VoiceTab.resolved(from: "chat voice") == .speechToText)
        #expect(VoiceTab.resolved(from: "wake word") == .vadMode)
        #expect(VoiceTab.resolved(from: "VAD Mode") == .vadMode)
        #expect(VoiceTab.resolved(from: "recognition") == .models)
        #expect(VoiceTab.models.title == L("Recognition"))
        #expect(VoiceTab.resolved(from: "nonsense") == nil)
    }

    /// Conversation writes only its own fields: the General page's hotkey
    /// and Core Model share the same `ChatConfiguration` and must survive.
    @Test func conversationSaveLeavesGeneralFieldsAlone() {
        let chat = ChatConfiguration()
        chat.coreModelProvider = "provider"
        chat.coreModelName = "core"
        chat.defaultModel = "chat-model"
        let form = ChatSettingsView.SaveableFormState(
            systemPrompt: "Be brief.",
            temperature: " 2.5 ",
            maxTokens: "",
            contextLength: "100",
            topP: "0.9",
            maxToolAttempts: "99",
            disableTools: false,
            clipboard: false,
            autoTitles: false,
            followUps: true,
            backfillDescriptions: true,
            greetingsEnabled: true,
            greetingPersona: GenerativeGreetingService.defaultPersonaInstruction,
            memoryEnabled: true
        )
        ChatSettingsView.apply(form, to: chat)

        #expect(chat.coreModelProvider == "provider")
        #expect(chat.coreModelName == "core")
        #expect(chat.defaultModel == "chat-model")
        #expect(chat.systemPrompt == "Be brief.")
        #expect(chat.temperature == 2)  // clamped
        #expect(chat.maxTokens == nil)  // blank = default
        #expect(chat.contextLength == 2048)  // clamped up
        #expect(chat.topPOverride == 0.9)
        #expect(chat.maxToolAttempts == 50)  // clamped
        #expect(chat.disableTools == false)
        #expect(chat.enableClipboardMonitoring == false)
        #expect(chat.autoGenerateChatTitles == false)
        #expect(chat.backfillAgentDescriptions == true)
        #expect(chat.generativeGreetingsEnabled == true)
        // An unedited built-in persona is stored as "" so future defaults apply.
        #expect(chat.greetingPersona.isEmpty)
    }

    @Test func advancedAnchorsCoverTheirSearchEntries() {
        for entry in SettingsSearchIndex.entries where entry.section == "Advanced" {
            switch entry.tab {
            case .settings: #expect(ConfigurationView.advancedAnchorIds.contains(entry.id))
            case .chat: #expect(ChatSettingsView.advancedAnchorIds.contains(entry.id))
            default: break
            }
        }
        #expect(TTSModeSettingsTab.advancedAnchorIds.contains("voice.tts.engine"))
    }
}
