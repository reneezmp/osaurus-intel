//
//  VoiceView.swift
//  osaurus
//
//  Main Voice management view with sub-tabs for setup, voice input settings,
//  VAD mode configuration, and model management.
//

import SwiftUI

// MARK: - Voice Tab Enum

/// Voice sub-tabs. Raw values are stable deep-link ids (`voiceSubTabRequest`,
/// settings-search `subTab`) and are deliberately not renamed when the
/// visible title changes; use `resolved(from:)` to accept older spellings.
enum VoiceTab: String, CaseIterable, AnimatedTabItem {
    case setup = "Setup"
    /// Microphone button inside the chat composer. Raw value predates the
    /// "Chat Voice" title.
    case speechToText = "Speech To Text"
    /// System-wide Transcription Mode plus the shared stop/cleanup behaviour.
    case transcription = "Transcription"
    case textToSpeech = "Text To Speech"
    /// Wake-word agent activation. Raw value predates the "Wake Word" title.
    case vadMode = "VAD Mode"
    case models = "Models"

    var title: String {
        switch self {
        case .setup: return L("Setup")
        case .speechToText: return L("Chat Voice")
        case .transcription: return L("Transcription")
        case .textToSpeech: return L("Text To Speech")
        case .vadMode: return L("Wake Word")
        // Intel: Apple Speech languages and access, not model downloads.
        case .models: return L("Recognition")
        }
    }

    /// Resolves a deep-link raw value, accepting the visible titles and the
    /// legacy names so older settings links and guide paths keep working.
    static func resolved(from rawValue: String) -> VoiceTab? {
        if let tab = VoiceTab(rawValue: rawValue) { return tab }
        switch rawValue.lowercased() {
        case "chat voice", "chat", "speech to text", "stt": return .speechToText
        case "transcription mode", "dictation": return .transcription
        case "wake word", "vad", "vad mode": return .vadMode
        case "tts", "text to speech": return .textToSpeech
        case "recognition", "languages": return .models  // Intel title
        default: return nil
        }
    }
}

// MARK: - Voice View

struct VoiceView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    // Deliberately NOT `@ObservedObject` here. SpeechService republishes
    // on every audio-level meter tick + every load-progress chunk,
    // which would force a re-evaluation of the whole VoiceView shell
    // (header, sidebar tab counts, tab content) at high frequency.
    // The two indicators that actually need live SpeechService state
    // live in dedicated `VoiceStatusIndicator` / audio-meter subviews
    // that observe it locally. `microphonePermissionGranted` is read
    // directly off the singleton — it changes rarely (system prompt)
    // and the next published mutation on `modelManager` will pick up
    // any change for the header subtitle.
    private let speechService = SpeechService.shared
    @ObservedObject private var modelManager = SpeechModelManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var selectedTab: VoiceTab = .setup
    @State private var hasAppeared = false

    /// Whether setup is complete (permissions granted + model downloaded)
    private var isSetupComplete: Bool {
        speechService.microphonePermissionGranted && modelManager.downloadedModelsCount > 0
            && modelManager.selectedModel != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            // Content based on tab
            Group {
                switch selectedTab {
                case .setup:
                    VoiceSetupTab(onComplete: { selectedTab = .speechToText })
                case .speechToText:
                    ChatVoiceSettingsTab()
                case .transcription:
                    TranscriptionSettingsTab()
                case .vadMode:
                    VADModeSettingsTab()
                case .textToSpeech:
                    TTSModeSettingsTab()
                case .models:
                    VoiceModelsTab()
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            // Honour an explicit cross-view request (e.g. from the chat speaker button).
            if let requested = managementState.voiceSubTabRequest,
                let tab = VoiceTab.resolved(from: requested)
            {
                selectedTab = tab
                managementState.voiceSubTabRequest = nil
            } else if isSetupComplete {
                selectedTab = .speechToText
            } else {
                selectedTab = .setup
            }
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .onChange(of: managementState.voiceSubTabRequest) { newValue in
            guard let requested = newValue, let tab = VoiceTab.resolved(from: requested) else { return }
            selectedTab = tab
            managementState.voiceSubTabRequest = nil
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        ManagerHeaderWithTabs(
            title: L("Voice"),
            subtitle: headerSubtitle
        ) {
            VoiceHeaderStatusIndicator(isSetupComplete: isSetupComplete)
        } tabsRow: {
            HeaderTabsRow(
                selection: $selectedTab,
                counts: [:]
            )
        }
    }

    private var headerSubtitle: String {
        if !isSetupComplete {
            return L("Complete setup to enable voice")
        } else if let language = modelManager.selectedModel {
            // Intel: the recognition language and where it runs.
            return "\(language.name) • \(modelManager.totalDownloadedSizeString)"
        } else {
            return L("Voice transcription ready")
        }
    }

}

// MARK: - Voice Status Indicator

/// Header status pill for the Voice tab. Observes `SpeechService` here
/// (instead of at the `VoiceView` root) so the high-frequency
/// `objectWillChange` publishes that drive the model-load progress and
/// audio-level meter only re-render this small pill, not the entire
/// Voice settings shell. Named `…HeaderStatusIndicator` to avoid the
/// public `VoiceStatusIndicator` in `VoiceComponents.swift`.
private struct VoiceHeaderStatusIndicator: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var speechService = SpeechService.shared

    let isSetupComplete: Bool

    var body: some View {
        if speechService.isLoadingModel {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Loading...", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(theme.tertiaryBackground)
            )
        } else if speechService.isModelLoaded {
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.successColor)
                    .frame(width: 8, height: 8)
                Text("Ready", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.successColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(theme.successColor.opacity(0.1))
            )
        } else if !isSetupComplete {
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.warningColor)
                    .frame(width: 8, height: 8)
                Text("Setup Required", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.warningColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(theme.warningColor.opacity(0.1))
            )
        }
    }
}

// MARK: - Recognition Tab (Intel)

/// Intel: upstream's Models tab downloads Parakeet models. Apple Speech has
/// nothing to download, so this tab holds what decides whether voice works:
/// Speech Recognition access, the language, and the opt-in for Apple's
/// servers. See docs/VOICE_INTEL.md.
private struct VoiceModelsTab: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var modelManager = SpeechModelManager.shared
    @State private var allowServer = SpeechConfigurationStore.load().allowServerRecognition
    @State private var selectedId: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                accessSection
                languageSection
                serverSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
            .settingsLandingAnchor("voice.models")
        }
        .onAppear {
            selectedId = modelManager.selectedModel?.id ?? ""
            allowServer = SpeechConfigurationStore.load().allowServerRecognition
            modelManager.refreshDownloadStates()
            Task { await modelManager.refreshDiskStateInBackground() }
        }
    }

    // MARK: Access

    private var accessSection: some View {
        SettingsSection(title: "Speech Recognition", icon: "waveform") {
            HStack(spacing: 12) {
                Image(systemName: accessIcon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(accessColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accessTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "Osaurus transcribes with Apple Speech, which macOS asks you to allow once.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                }
                Spacer()
                accessAction
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1))
            )
        }
    }

    private var accessTitle: String {
        switch modelManager.authorizationStatus {
        case .authorized: return L("Allowed")
        case .denied: return L("Turned off in System Settings")
        case .restricted: return L("Restricted on this Mac")
        default: return L("Not allowed yet")
        }
    }

    private var accessIcon: String {
        modelManager.authorizationStatus == .authorized ? "checkmark.circle.fill" : "exclamationmark.circle"
    }

    private var accessColor: Color {
        modelManager.authorizationStatus == .authorized ? theme.successColor : theme.warningColor
    }

    @ViewBuilder
    private var accessAction: some View {
        switch modelManager.authorizationStatus {
        case .authorized:
            EmptyView()
        case .denied, .restricted:
            Button(L("Open Settings")) { SpeechModelManager.openSpeechRecognitionSettings() }
                .buttonStyle(ThemedBorderedButtonStyle())
        default:
            Button(L("Allow")) {
                if let model = modelManager.selectedModel { modelManager.downloadModel(model) }
            }
            .buttonStyle(ThemedBorderedButtonStyle())
        }
    }

    // MARK: Language

    private var languageSection: some View {
        SettingsSection(title: "Language", icon: "globe") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recognition language", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    Picker("", selection: $selectedId) {
                        ForEach(modelManager.availableModels) { model in
                            Text(verbatim: "\(model.name) · \(model.size)").tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(MenuPickerStyle())
                    .frame(maxWidth: 320)
                    .onChange(of: selectedId) { newValue in
                        guard !newValue.isEmpty, newValue != modelManager.selectedModel?.id else { return }
                        modelManager.setDefaultModel(newValue)
                    }
                }
                if let selected = modelManager.selectedModel {
                    Text(languageStatus(for: selected))
                        .font(.system(size: 11))
                        .foregroundColor(
                            modelManager.effectiveDownloadState(for: selected) == .completed
                                ? theme.tertiaryText : theme.warningColor)
                }
            }
        }
    }

    private func languageStatus(for model: SpeechModel) -> String {
        if model.onDevice {
            return L("Runs on this Mac. Audio never leaves it.")
        }
        return allowServer
            ? L("This language uses Apple's servers: your speech is sent to Apple to be transcribed.")
            : L("This language can't be recognised on this Mac. Allow Apple's servers below, or pick another language.")
    }

    // MARK: Apple's servers

    private var serverSection: some View {
        SettingsSection(title: "Apple's Servers", icon: "network") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsToggle(
                    title: L("Use Apple's servers when needed"),
                    description: L(
                        "Only for languages that can't be recognised on this Mac. Your speech is then sent to Apple. VAD Mode never uses them."
                    ),
                    isOn: $allowServer
                )
                .onChange(of: allowServer) { newValue in
                    var config = SpeechConfigurationStore.load()
                    guard config.allowServerRecognition != newValue else { return }
                    config.allowServerRecognition = newValue
                    SpeechConfigurationStore.save(config)
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        VoiceView()
    }
#endif
