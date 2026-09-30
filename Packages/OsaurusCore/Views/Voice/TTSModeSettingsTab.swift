//
//  TTSModeSettingsTab.swift
//  osaurus
//
//  Settings UI for text-to-speech.
//  Toggle TTS, pick engine and voice, preview.
//
//  Intel: the on-device engine is the macOS system voices (no model to
//  download), with a voice list and speaking rate in place of PocketTTS's
//  voices and temperature. The server engine is upstream's.
//

import SwiftUI

struct TTSModeSettingsTab: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var ttsService = TTSService.shared

    @State private var config: TTSConfiguration = .default
    @State private var hasLoadedSettings = false
    @State private var remoteAPIKey: String = ""

    private enum ConnectionTestState: Equatable {
        case idle, testing, success
        case failure(String)
    }
    @State private var connectionTest: ConnectionTestState = .idle
    @State private var previewText: String = "Hello from Osaurus. Text to speech is now ready."
    @State private var previewMessageId = UUID()

    /// Installed system voices, loaded once when the tab appears.
    @State private var systemVoices: [SystemVoiceCatalog.Entry] = []

    private func loadSettings() {
        config = TTSConfigurationStore.load()
        // Keychain reads are blocking XPC; fetch off-main and fill the field
        // when it lands. Skip the update when unchanged so the `.onChange`
        // save/reset handlers don't fire from our own load.
        TTSRemoteAPIKeyStore.load { key in
            let value = key ?? ""
            if value != remoteAPIKey { remoteAPIKey = value }
        }
    }

    private func saveSettings() {
        TTSConfigurationStore.save(config)
    }

    private var canPreview: Bool {
        config.enabled && ttsService.isModelReady
            && !previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                enableCard

                if config.enabled && config.provider == .system {
                    voiceCard
                }

                if config.enabled && ttsService.isModelReady {
                    previewCard
                }

                // Upstream #2950: engine choice + remote server fields are
                // power-user knobs; the system voices need none of them.
                if config.enabled {
                    advancedSection
                }

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if !hasLoadedSettings {
                loadSettings()
                hasLoadedSettings = true
            }
            ttsService.refreshModelState()
            if systemVoices.isEmpty { systemVoices = SystemVoiceCatalog.availableVoices() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ttsConfigurationChanged)) { _ in
            loadSettings()
        }
    }

    // MARK: - Enable Card

    private var enableCard: some View {
        SettingsSection(title: "Text-to-Speech", icon: "speaker.wave.2") {
            SettingsToggle(
                title: L("Enable Text-to-Speech"),
                description: config.enabled
                    ? "Speaker button appears on assistant messages"
                    : "Enable to read assistant replies aloud",
                isOn: $config.enabled
            )
            .onChange(of: config.enabled) { _ in saveSettings() }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(theme.accentColor)

                Text(
                    config.provider == .system
                        ? "Uses the voices built into macOS, on this Mac. Add more voices in System Settings → Accessibility → Spoken Content."
                        : "Sends text to any server implementing the OpenAI /v1/audio/speech API, such as openai-edge-tts or Kokoro.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.accentColor.opacity(0.1))
            )
        }
    }

    // MARK: - Voice Card

    private var voiceCard: some View {
        SettingsSection(title: "Voice", icon: "person.wave.2") {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Voice", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    Picker("", selection: $config.voice) {
                        Text("Automatic (match the reply's language)", bundle: .module).tag("")
                        if !config.voice.isEmpty, !systemVoices.contains(where: { $0.id == config.voice }) {
                            Text(verbatim: SystemVoiceCatalog.displayName(for: config.voice)).tag(config.voice)
                        }
                        ForEach(systemVoices) { voice in
                            Text(verbatim: SystemVoiceCatalog.label(for: voice)).tag(voice.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(MenuPickerStyle())
                    .frame(maxWidth: 320)
                    .onChange(of: config.voice) { _ in saveSettings() }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Speed", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                        Text(String(format: "%.2fx", config.rate))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                    }
                    Slider(value: $config.rate, in: 0.5 ... 2.0, step: 0.05) { editing in
                        if !editing { saveSettings() }
                    }
                }
                .settingsLandingAnchor("voice.tts.rate")
            }
        }
    }

    // MARK: - Advanced (engine + remote server)

    nonisolated static let advancedAnchorIds: Set<String> = ["voice.tts.engine", "voice.tts.remote"]

    private var advancedSection: some View {
        SettingsAdvancedDisclosure(anchorIds: Self.advancedAnchorIds) {
            SettingsPickerRow(
                title: "Engine",
                description: "The macOS system voices need no setup. Choose a server to use any OpenAI-compatible speech API.",
                anchorId: "voice.tts.engine",
                style: .menu,
                selection: $config.provider,
                options: [
                    .init(TTSProvider.system, L("On This Mac (System Voices)")),
                    .init(TTSProvider.openAICompatible, L("OpenAI-Compatible Server")),
                ]
            )
            .onChange(of: config.provider) { _ in saveSettings() }

            if config.provider == .openAICompatible {
                remoteServerCard
                    .settingsLandingAnchor("voice.tts.remote")
            }
        }
    }

    // MARK: - Remote Server Card

    private var remoteServerCard: some View {
        SettingsSection(title: "voice.tts.remote.title", icon: "network") {
            VStack(alignment: .leading, spacing: 16) {
                labeledField(L("Endpoint")) {
                    TextField(TTSConfiguration.defaultRemoteEndpoint, text: $config.remoteEndpoint)
                        .onChange(of: config.remoteEndpoint) { _ in
                            connectionTest = .idle
                            saveSettings()
                        }
                }

                labeledField(L("Model")) {
                    TextField(TTSConfiguration.defaultRemoteModel, text: $config.remoteModel)
                        .onChange(of: config.remoteModel) { _ in
                            connectionTest = .idle
                            saveSettings()
                        }
                }

                labeledField(L("Voice")) {
                    TextField(TTSConfiguration.defaultRemoteVoice, text: $config.remoteVoice)
                        .onChange(of: config.remoteVoice) { _ in
                            connectionTest = .idle
                            saveSettings()
                        }
                }

                labeledField(L("API Key")) {
                    SecureField(L("Optional"), text: $remoteAPIKey)
                        .onChange(of: remoteAPIKey) { newValue in
                            connectionTest = .idle
                            TTSRemoteAPIKeyStore.save(newValue)
                        }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Speed", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                        Text(String(format: "%.2fx", config.remoteSpeed))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                    }
                    Slider(value: $config.remoteSpeed, in: 0.25 ... 4.0, step: 0.05) { editing in
                        if !editing { saveSettings() }
                    }
                }

                connectionTestRow

                if let error = ttsService.lastRemoteError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundColor(theme.errorColor)
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(theme.errorColor)
                    }
                }
            }
        }
    }

    private var connectionTestRow: some View {
        HStack(spacing: 10) {
            switch connectionTest {
            case .idle, .testing:
                EmptyView()
            case .success:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.successColor)
                    Text("Connected", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.successColor)
                }
            case .failure(let message):
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                        .lineLimit(3)
                }
            }

            Spacer()

            Button(action: runConnectionTest) {
                // The spinner replaces the label inside the button; the
                // zero-opacity label keeps the button width stable so the
                // layout doesn't jump while testing.
                ZStack {
                    Text("Test Connection", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.isDark ? theme.primaryBackground : .white)
                        .opacity(connectionTest == .testing ? 0 : 1)
                    if connectionTest == .testing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            connectionTest == .testing
                                ? theme.tertiaryBackground : theme.accentColor)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(connectionTest == .testing)
        }
    }

    private func runConnectionTest() {
        guard connectionTest != .testing else { return }
        connectionTest = .testing
        let trimmedKey = remoteAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = OpenAICompatibleTTSClient(
            endpoint: config.remoteEndpoint,
            model: config.remoteModel,
            voice: config.remoteVoice,
            speed: config.remoteSpeed,
            apiKey: trimmedKey.isEmpty ? nil : trimmedKey
        )
        Task {
            do {
                try await client.verifyConnection()
                connectionTest = .success
            } catch {
                connectionTest = .failure(error.localizedDescription)
            }
        }
    }

    private func labeledField(_ title: String, @ViewBuilder field: () -> some View) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            Spacer()
            field()
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .font(.system(size: 12))
                .frame(maxWidth: 260)
        }
    }

    // MARK: - Preview Card

    private var previewCard: some View {
        SettingsSection(title: "Preview", icon: "play.circle") {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $previewText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.tertiaryBackground)
                    )

                HStack {
                    Spacer()
                    Button(action: {
                        if ttsService.playingMessageId == previewMessageId {
                            ttsService.stop()
                        } else {
                            ttsService.toggleSpeak(text: previewText, messageId: previewMessageId)
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(
                                systemName: ttsService.playingMessageId == previewMessageId
                                    ? "stop.fill" : "play.fill"
                            )
                            Text(
                                ttsService.playingMessageId == previewMessageId ? "Stop" : "Play",
                                bundle: .module
                            )
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.isDark ? theme.primaryBackground : .white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(canPreview ? theme.accentColor : theme.tertiaryBackground)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!canPreview)
                }
            }
        }
    }
}

#if DEBUG
    struct TTSModeSettingsTab_Previews: PreviewProvider {
        static var previews: some View {
            TTSModeSettingsTab()
                .frame(width: 720, height: 640)
        }
    }
#endif
