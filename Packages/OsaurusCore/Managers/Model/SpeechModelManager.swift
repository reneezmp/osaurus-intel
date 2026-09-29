//
//  SpeechModelManager.swift
//  osaurus
//
//  Intel: upstream manages FluidAudio Parakeet model downloads here. Apple
//  Speech has no models to download, so on Intel a "speech model" is a
//  recognition language, and "downloaded" means usable: Speech Recognition
//  access is granted and the language runs on this Mac (or the user allowed
//  Apple's servers). The published surface matches upstream's so the chat
//  microphone, Transcription Mode and VAD Mode read it unchanged.
//  See docs/VOICE_INTEL.md.
//

import Combine
import Foundation
import Speech
import SwiftUI

/// Download state for a speech model. On Intel `.completed` means usable.
public enum SpeechDownloadState: Equatable {
    case notStarted
    case downloading(progress: Double)
    case completed
    case failed(error: String)
}

/// Intel: one Apple Speech recognition language.
public struct SpeechModel: Identifiable, Equatable, Sendable {
    /// Locale identifier (`en-US`).
    public let id: String
    public let name: String
    public let description: String
    public let size: String
    public let isEnglishOnly: Bool
    /// The Mac's own language.
    public let isRecommended: Bool
    /// Recognition runs on this Mac (no audio sent to Apple).
    public let onDevice: Bool
}

@MainActor
public final class SpeechModelManager: ObservableObject {
    public static let shared = SpeechModelManager()

    // MARK: - Published Properties

    @Published public var availableModels: [SpeechModel] = []
    @Published public var downloadStates: [String: SpeechDownloadState] = [:]
    @Published public var selectedModelId: String?
    @Published public private(set) var authorizationStatus: SFSpeechRecognizerAuthorizationStatus =
        SFSpeechRecognizer.authorizationStatus()
    /// Upstream shows a cleanup banner for old WhisperKit models; never on Intel.
    @Published public var legacyWhisperModelsExist: Bool = false
    @Published public var legacyWhisperModelsSizeString: String?

    private var configurationObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?

    // MARK: - Initialization

    private init() {
        selectedModelId = Self.configuredLocaleId()
        // A placeholder entry for the selected language binds the UI right
        // away; the full language scan (one recogniser per locale) runs off
        // the launch path.
        let selected = selectedModelId ?? Self.systemLocaleId()
        availableModels = [
            SpeechModel(
                id: selected, name: Self.languageName(for: selected), description: "", size: "",
                isEnglishOnly: selected.hasPrefix("en"), isRecommended: true, onDevice: false)
        ]
        Task { [weak self] in await self?.refreshDiskStateInBackground() }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .speechConfigurationChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.selectedModelId = Self.configuredLocaleId()
                self.refreshDownloadStates()
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAuthorization() }
        }
    }

    // MARK: - Languages

    /// Scan Apple Speech's languages off the main thread (creating a
    /// recogniser per locale is cheap but not free), then publish.
    public func refreshDiskStateInBackground() async {
        let systemId = Self.systemLocaleId()
        let scanned = await Task.detached(priority: .utility) { () -> [SpeechModel] in
            SFSpeechRecognizer.supportedLocales()
                .map { locale -> SpeechModel in
                    let id = locale.identifier.replacingOccurrences(of: "_", with: "-")
                    let onDevice = SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
                    return SpeechModel(
                        id: id,
                        name: Self.languageName(for: id),
                        description: onDevice
                            ? L("Runs on this Mac. Audio never leaves it.")
                            : L("Needs Apple's servers on this Mac."),
                        size: onDevice ? L("On this Mac") : L("Apple servers"),
                        isEnglishOnly: id.hasPrefix("en"),
                        isRecommended: Self.sameLanguage(id, systemId),
                        onDevice: onDevice
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.isRecommended != rhs.isRecommended { return lhs.isRecommended }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
        }.value
        if !scanned.isEmpty { availableModels = scanned }
        if selectedModelId == nil || !availableModels.contains(where: { $0.id == selectedModelId }) {
            selectedModelId = Self.bestMatch(for: systemId, in: availableModels.map(\.id))
        }
        refreshDownloadStates()
    }

    /// Recompute which languages are usable with the current permission and
    /// server opt-in.
    public func refreshDownloadStates() {
        refreshAuthorization()
        let allowServer = SpeechConfigurationStore.load().allowServerRecognition
        let authorized = authorizationStatus == .authorized
        var states: [String: SpeechDownloadState] = [:]
        for model in availableModels {
            states[model.id] = authorized && (model.onDevice || allowServer) ? .completed : .notStarted
        }
        downloadStates = states
    }

    public func refreshAuthorization() {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status != authorizationStatus {
            authorizationStatus = status
            refreshDownloadStates()
        }
    }

    /// Called by `SpeechService` after it asked for access.
    public func updateAuthorization(_ status: SFSpeechRecognizerAuthorizationStatus) {
        guard status != authorizationStatus else { return }
        authorizationStatus = status
        refreshDownloadStates()
    }

    /// Set the recognition language and persist.
    public func setDefaultModel(_ modelId: String?) {
        selectedModelId = modelId
        var config = SpeechConfigurationStore.load()
        config.recognitionLocale = modelId ?? ""
        SpeechConfigurationStore.save(config)
    }

    /// The selected language (upstream: the selected downloaded model).
    public var selectedModel: SpeechModel? {
        let id = selectedModelId ?? Self.systemLocaleId()
        return availableModels.first(where: { $0.id == id })
            ?? availableModels.first(where: { Self.sameLanguage($0.id, id) })
    }

    /// Upstream-shaped count: 1 when the selected language is usable, so
    /// "downloadedModelsCount > 0 && selectedModel != nil" still means
    /// "voice is set up".
    public var downloadedModelsCount: Int {
        guard let selected = selectedModel else { return 0 }
        return downloadStates[selected.id] == .completed ? 1 : 0
    }

    public var activeDownloadsCount: Int { 0 }

    public var totalDownloadedSizeString: String {
        guard let selected = selectedModel else { return L("No language") }
        return selected.onDevice ? L("On this Mac") : L("Apple servers")
    }

    // MARK: - "Download" (Intel: set up)

    /// Upstream downloads the model. On Intel this selects the language and
    /// asks for Speech Recognition access, which is all Apple Speech needs.
    public func downloadModel(_ model: SpeechModel) {
        setDefaultModel(model.id)
        Task { @MainActor in
            let status = await SpeechService.requestSpeechRecognitionAuthorization()
            updateAuthorization(status)
            refreshDownloadStates()
            if status == .denied || status == .restricted {
                Self.openSpeechRecognitionSettings()
            }
        }
    }

    public func cancelDownload(_ modelId: String) {}

    public func deleteModel(_ model: SpeechModel) {}

    public func effectiveDownloadState(for model: SpeechModel) -> SpeechDownloadState {
        downloadStates[model.id] ?? .notStarted
    }

    public func refreshLegacyWhisperState() {}
    public func deleteLegacyWhisperModels() {}

    /// System Settings › Privacy & Security › Speech Recognition.
    public static func openSpeechRecognitionSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Locale helpers

    nonisolated public static func languageName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    nonisolated static func systemLocaleId() -> String {
        Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: "@").first ?? "en-US"
    }

    private static func configuredLocaleId() -> String? {
        let stored = SpeechConfigurationStore.load().recognitionLocale.trimmingCharacters(in: .whitespaces)
        return stored.isEmpty ? nil : stored
    }

    nonisolated static func sameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        lhs.lowercased() == rhs.lowercased()
    }

    /// Exact identifier, else the same language in another region
    /// (`pt-BR` for a Mac set to `pt-PT`), else English.
    nonisolated static func bestMatch(for identifier: String, in candidates: [String]) -> String? {
        if let exact = candidates.first(where: { sameLanguage($0, identifier) }) { return exact }
        let language = identifier.split(separator: "-").first.map(String.init)?.lowercased() ?? ""
        if let sameLanguage = candidates.first(where: { $0.lowercased().hasPrefix(language + "-") }) {
            return sameLanguage
        }
        return candidates.first(where: { $0 == "en-US" }) ?? candidates.first
    }
}
