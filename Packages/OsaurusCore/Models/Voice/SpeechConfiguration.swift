//
//  SpeechConfiguration.swift
//  osaurus
//
//  Configuration model for voice transcription settings.
//
//  Intel: upstream picks a FluidAudio Parakeet model version; Intel
//  transcribes with Apple Speech (`SFSpeechRecognizer`), so the model choice
//  is a recognition language plus an explicit opt-in for Apple's servers
//  when that language can't run on this Mac. See docs/VOICE_INTEL.md.
//

import Foundation

/// Voice transcription stop mode
public enum TranscriptionStopMode: String, Codable, Equatable, CaseIterable, Sendable {
    /// Listens for silence to automatically stop and send
    case automatic
    /// Stays active until manually stopped by the user
    case manual

    public var displayName: String {
        switch self {
        case .automatic: return L("Automatic")
        case .manual: return L("Manual")
        }
    }

    public var description: String {
        switch self {
        case .automatic: return L("Automatically sends message after a brief pause")
        case .manual: return L("Waits for you to manually click the stop button")
        }
    }
}

/// Configuration settings for voice transcription
public struct SpeechConfiguration: Codable, Equatable, Sendable {
    /// Apple Speech recognition language (a locale identifier such as
    /// `en-US`). Empty means the system language.
    public var recognitionLocale: String

    /// Allow Apple's servers when the language can't be recognised on this
    /// Mac. Off by default: audio then never leaves the Mac, and a language
    /// without on-device support is reported as not ready instead.
    public var allowServerRecognition: Bool

    /// Selected audio input device unique ID (nil = system default)
    public var selectedInputDeviceId: String?

    /// Selected audio input source type (microphone or system audio)
    public var selectedInputSource: AudioInputSource

    /// Voice activity detection sensitivity level
    public var sensitivity: VoiceSensitivity

    // MARK: - Voice Input Settings (for ChatView)

    /// Whether voice input is enabled in ChatView
    public var voiceInputEnabled: Bool

    /// How to stop voice recording (automatic silence detection or manual)
    public var transcriptionStopMode: TranscriptionStopMode

    /// Seconds of silence before triggering auto-send (0 = disabled, manual send only)
    public var pauseDuration: Double

    /// Seconds to show confirmation before auto-sending (1-5 seconds)
    public var confirmationDelay: Double

    /// Seconds of silence before closing voice input (0 = disabled, 10-120 seconds)
    public var silenceTimeoutSeconds: Double

    /// Whether to clean up the raw transcription with the core model
    /// (removes filler words like "uh"/"mm", stutters, and self-corrections).
    /// Disable to keep the natural, verbatim transcription.
    ///
    /// Intel: off by default. The core model is a remote provider here, so
    /// cleanup is a paid call that sends every transcript to it.
    public var postProcessTranscription: Bool

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SpeechConfiguration.default
        self.recognitionLocale =
            try container.decodeIfPresent(String.self, forKey: .recognitionLocale)
            ?? defaults.recognitionLocale
        self.allowServerRecognition =
            try container.decodeIfPresent(Bool.self, forKey: .allowServerRecognition)
            ?? defaults.allowServerRecognition
        self.selectedInputDeviceId = try container.decodeIfPresent(String.self, forKey: .selectedInputDeviceId)
        self.selectedInputSource =
            try container.decodeIfPresent(AudioInputSource.self, forKey: .selectedInputSource)
            ?? defaults.selectedInputSource
        self.sensitivity =
            try container.decodeIfPresent(VoiceSensitivity.self, forKey: .sensitivity)
            ?? defaults.sensitivity
        self.voiceInputEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .voiceInputEnabled)
            ?? defaults.voiceInputEnabled
        self.transcriptionStopMode =
            try container.decodeIfPresent(TranscriptionStopMode.self, forKey: .transcriptionStopMode)
            ?? defaults.transcriptionStopMode
        self.pauseDuration =
            try container.decodeIfPresent(Double.self, forKey: .pauseDuration)
            ?? defaults.pauseDuration
        self.confirmationDelay =
            try container.decodeIfPresent(Double.self, forKey: .confirmationDelay)
            ?? defaults.confirmationDelay
        self.silenceTimeoutSeconds =
            try container.decodeIfPresent(Double.self, forKey: .silenceTimeoutSeconds)
            ?? defaults.silenceTimeoutSeconds
        self.postProcessTranscription =
            try container.decodeIfPresent(Bool.self, forKey: .postProcessTranscription)
            ?? defaults.postProcessTranscription
    }

    public init(
        recognitionLocale: String = "",
        allowServerRecognition: Bool = false,
        selectedInputDeviceId: String? = nil,
        selectedInputSource: AudioInputSource = .microphone,
        sensitivity: VoiceSensitivity = .medium,
        voiceInputEnabled: Bool = true,
        transcriptionStopMode: TranscriptionStopMode = .automatic,
        pauseDuration: Double = 1.5,
        confirmationDelay: Double = 2.0,
        silenceTimeoutSeconds: Double = 30.0,
        postProcessTranscription: Bool = false
    ) {
        self.recognitionLocale = recognitionLocale
        self.allowServerRecognition = allowServerRecognition
        self.selectedInputDeviceId = selectedInputDeviceId
        self.selectedInputSource = selectedInputSource
        self.sensitivity = sensitivity
        self.voiceInputEnabled = voiceInputEnabled
        self.transcriptionStopMode = transcriptionStopMode
        self.pauseDuration = pauseDuration
        self.confirmationDelay = confirmationDelay
        self.silenceTimeoutSeconds = silenceTimeoutSeconds
        self.postProcessTranscription = postProcessTranscription
    }

    public static var `default`: SpeechConfiguration {
        SpeechConfiguration(
            recognitionLocale: "",
            allowServerRecognition: false,
            selectedInputDeviceId: nil,
            selectedInputSource: .microphone,
            sensitivity: .medium,
            voiceInputEnabled: true,
            transcriptionStopMode: .automatic,
            pauseDuration: 1.5,
            confirmationDelay: 2.0,
            silenceTimeoutSeconds: 30.0,
            postProcessTranscription: false
        )
    }
}

/// Audio input source type
public enum AudioInputSource: String, Codable, Equatable, CaseIterable, Sendable {
    case microphone
    case systemAudio

    public var displayName: String {
        switch self {
        case .microphone: return L("Microphone")
        case .systemAudio: return L("System Audio")
        }
    }

    public var iconName: String {
        switch self {
        case .microphone: return "mic.fill"
        case .systemAudio: return "speaker.wave.2.fill"
        }
    }
}

/// Voice activity detection sensitivity level
public enum VoiceSensitivity: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high

    public var displayName: String {
        switch self {
        case .low: return L("Low")
        case .medium: return L("Medium")
        case .high: return L("High")
        }
    }

    public var description: String {
        switch self {
        case .low: return L("Requires louder speech, faster response")
        case .medium: return L("Balanced for normal conversation")
        case .high: return L("Picks up quiet speech, waits longer for pauses")
        }
    }

    /// VAD threshold for FluidAudio's Silero VAD (higher = less sensitive)
    public var vadThreshold: Float {
        switch self {
        case .low: return 0.85
        case .medium: return 0.75
        case .high: return 0.55
        }
    }

    /// Intel: speech threshold for the energy detector that stands in for
    /// Silero, on the same scaled RMS as the audio meter (`rms * 10`, 0–1).
    public var energyThreshold: Float {
        switch self {
        case .low: return 0.12
        case .medium: return 0.07
        case .high: return 0.035
        }
    }

    /// Silence duration to consider speech ended (higher = waits longer)
    public var silenceThresholdSeconds: Double {
        switch self {
        case .low: return 0.3
        case .medium: return 0.5
        case .high: return 0.8
        }
    }
}

/// Handles persistence of `SpeechConfiguration` with caching
@MainActor
public enum SpeechConfigurationStore {
    private static var cachedConfig: SpeechConfiguration?

    public static func load() -> SpeechConfiguration {
        if let cached = cachedConfig { return cached }
        let config = loadFromDisk()
        cachedConfig = config
        return config
    }

    public static func save(_ configuration: SpeechConfiguration) {
        cachedConfig = configuration
        saveToDisk(configuration)
        NotificationCenter.default.post(name: .speechConfigurationChanged, object: nil)
    }

    private static func loadFromDisk() -> SpeechConfiguration {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SpeechConfiguration.default
        }
        do {
            return try JSONDecoder().decode(SpeechConfiguration.self, from: Data(contentsOf: url))
        } catch {
            print("[Osaurus] Failed to load SpeechConfiguration: \(error)")
            return SpeechConfiguration.default
        }
    }

    private static func saveToDisk(_ configuration: SpeechConfiguration) {
        let url = configurationFileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save SpeechConfiguration: \(error)")
        }
    }

    private static func configurationFileURL() -> URL {
        OsaurusPaths.speechConfigFile()
    }
}

extension Notification.Name {
    /// Intel: posted by `SpeechConfigurationStore.save` so the recogniser
    /// and the language list pick up a new language or server opt-in.
    public static let speechConfigurationChanged = Notification.Name("osaurus.speechConfigurationChanged")
}
