//
//  SpeechService.swift
//  osaurus
//
//  Core service for audio transcription.
//
//  Intel: upstream transcribes with FluidAudio (Parakeet ASR + Silero VAD,
//  CoreML, Apple Silicon). Intel keeps upstream's audio capture — input
//  devices, system audio, engine recovery, level meter — and transcribes
//  with Apple Speech (`SFSpeechRecognizer`) instead, segmenting speech with
//  a loudness detector. See docs/VOICE_INTEL.md.
//

@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os
@preconcurrency import Speech
@preconcurrency import ScreenCaptureKit

/// Result of a transcription operation
public struct TranscriptionResult: Sendable {
    public let text: String
    public let durationSeconds: Double?

    public init(text: String, durationSeconds: Double? = nil) {
        self.text = text
        self.durationSeconds = durationSeconds
    }
}

/// Raw audio captured during a live voice turn, preserved separately from the
/// short STT chunks that the streaming worker drains.
public struct LiveVoiceAudioSnapshot: Sendable {
    public let samples: [Float]
    public let sampleRate: Int

    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / Double(sampleRate)
    }

    public func wavData() -> Data {
        var data = Data()
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = Int(bitsPerSample / 8)
        let byteRate = UInt32(sampleRate * Int(channelCount) * bytesPerSample)
        let blockAlign = UInt16(Int(channelCount) * bytesPerSample)
        let pcmByteCount = UInt32(samples.count * bytesPerSample)

        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36) + pcmByteCount)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(pcmByteCount)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let pcm = Int16(clamped * Float(Int16.max))
            data.appendLittleEndian(pcm)
        }

        return data
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { buffer in
            append(contentsOf: buffer)
        }
    }
}

/// Error types for speech operations
public enum SpeechError: Error, LocalizedError {
    case noModelSelected
    case modelNotLoaded
    case modelNotReady
    case transcriptionFailed(String)
    case microphonePermissionDenied
    case audioFileNotFound
    /// Intel: Speech Recognition access was denied in System Settings.
    case speechRecognitionDenied
    /// Intel: Apple Speech doesn't support this language.
    case languageUnavailable(String)
    /// Intel: this language needs Apple's servers, which the user hasn't allowed.
    case onDeviceUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return "No speech recognition language selected. Pick one in Voice settings."
        case .modelNotLoaded:
            return "Speech recognition isn't ready. Finish setup in Voice settings."
        case .modelNotReady:
            return "Speech recognition is not ready."
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .microphonePermissionDenied:
            return "Microphone permission denied. Please grant access in System Settings."
        case .audioFileNotFound:
            return "Audio file not found."
        case .speechRecognitionDenied:
            return
                "Speech Recognition access is off. Allow Osaurus in System Settings → Privacy & Security → Speech Recognition."
        case .languageUnavailable(let language):
            return "Apple Speech doesn't support \(language)."
        case .onDeviceUnavailable(let language):
            return
                "\(language) can't be recognised on this Mac. Allow Apple's servers in Voice settings, or pick another language."
        }
    }
}

// MARK: - Audio Input Device

/// Represents an available audio input device
public struct AudioInputDevice: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

// MARK: - Audio Input Manager

/// Manages audio input device enumeration and selection
@MainActor
public final class AudioInputManager: ObservableObject {
    public static let shared = AudioInputManager()

    @Published public private(set) var availableDevices: [AudioInputDevice] = []

    @Published public var selectedDeviceId: String? {
        didSet {
            if oldValue != selectedDeviceId {
                persistSelection()
            }
        }
    }

    @Published public var selectedInputSource: AudioInputSource = .microphone {
        didSet {
            if oldValue != selectedInputSource {
                persistSelection()
            }
        }
    }

    // MARK: - System Audio Status

    public var isSystemAudioAvailable: Bool {
        SystemAudioCaptureManager.shared.isAvailable
    }

    public var hasSystemAudioPermission: Bool {
        SystemAudioCaptureManager.shared.hasPermission
    }

    public func requestSystemAudioPermission() {
        SystemAudioCaptureManager.shared.requestPermission()
    }

    public func checkSystemAudioPermission() async {
        await SystemAudioCaptureManager.shared.checkPermission()
    }

    private var deviceObservers: [NSObjectProtocol] = []

    private init() {
        loadPersistedSelection()
        refreshDevices()
        setupDeviceObservers()
    }

    deinit {
        for observer in deviceObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public Methods

    public func refreshDevices() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            availableDevices = []
            return
        }

        // Enumerating audio devices (`AVCaptureDevice.DiscoverySession` plus the
        // CoreAudio default-device lookup) makes synchronous XPC calls to the
        // audio HAL that can hang for seconds. Run that off the main actor and
        // publish the Sendable result back.
        Task { @MainActor [weak self] in
            let devices = await Task.detached(priority: .userInitiated) {
                AudioInputManager.discoverInputDevices()
            }.value
            guard let self else { return }
            self.availableDevices = devices
            if let selectedId = self.selectedDeviceId,
                !devices.contains(where: { $0.id == selectedId })
            {
                self.selectedDeviceId = nil
            }
        }
    }

    private nonisolated static func discoverInputDevices() -> [AudioInputDevice] {
        // Intel: `.microphone` / `.external` are macOS 14+; Ventura names
        // the same device types `.builtInMicrophone` / `.externalUnknown`.
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )

        let defaultDeviceId = defaultInputDeviceUID()

        return discoverySession.devices.compactMap { device in
            let name = device.localizedName
            if name.hasPrefix("CADefaultDevice") || name.contains("Aggregate") && name.contains("-") || name.isEmpty {
                return nil
            }

            return AudioInputDevice(
                id: device.uniqueID,
                name: name,
                isDefault: device.uniqueID == defaultDeviceId
            )
        }
    }

    public var selectedDevice: AudioInputDevice? {
        if let selectedId = selectedDeviceId {
            return availableDevices.first { $0.id == selectedId }
        }
        return availableDevices.first { $0.isDefault } ?? availableDevices.first
    }

    public func selectDevice(_ deviceId: String?) {
        selectedDeviceId = deviceId
    }

    // MARK: - Device Observers

    private func setupDeviceObservers() {
        let connectedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice,
                device.hasMediaType(.audio)
            else { return }
            Task { @MainActor in
                self?.refreshDevices()
            }
        }
        deviceObservers.append(connectedObserver)

        let disconnectedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice,
                device.hasMediaType(.audio)
            else { return }
            Task { @MainActor in
                self?.refreshDevices()
            }
        }
        deviceObservers.append(disconnectedObserver)
    }

    // MARK: - CoreAudio Helpers

    private nonisolated static func defaultInputDeviceUID() -> String? {
        var defaultDeviceId = AudioDeviceID()
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultDeviceId
        )

        guard status == noErr else { return nil }

        return deviceUID(for: defaultDeviceId)
    }

    private nonisolated static func deviceUID(for deviceId: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uidUnmanaged: Unmanaged<CFString>?
        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceId,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &uidUnmanaged
        )

        guard status == noErr, let uidUnmanaged = uidUnmanaged else { return nil }
        let uid = uidUnmanaged.takeRetainedValue()
        return uid as String
    }

    public func getAudioDeviceId(for uid: String) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        )

        guard status == noErr, propertySize > 0 else { return nil }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIds = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIds
        )

        guard status == noErr else { return nil }

        for deviceId in deviceIds {
            if let deviceUID = Self.deviceUID(for: deviceId), deviceUID == uid {
                return deviceId
            }
        }

        return nil
    }

    // MARK: - Persistence

    private func loadPersistedSelection() {
        let config = SpeechConfigurationStore.load()
        selectedDeviceId = config.selectedInputDeviceId
        selectedInputSource = config.selectedInputSource
    }

    private func persistSelection() {
        var config = SpeechConfigurationStore.load()
        config.selectedInputDeviceId = selectedDeviceId
        config.selectedInputSource = selectedInputSource
        SpeechConfigurationStore.save(config)
    }
}

// MARK: - System Audio Sample Buffer

private final class SystemAudioSampleBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = OSAllocatedUnfairLock()

    func append(_ newSamples: [Float]) {
        lock.withLock {
            samples.append(contentsOf: newSamples)
        }
    }

    func getAndClear() -> [Float] {
        lock.withLock {
            let current = samples
            samples = []
            return current
        }
    }

    func clear() {
        lock.withLock {
            samples = []
        }
    }
}

// MARK: - System Audio Capture Manager

@MainActor
public final class SystemAudioCaptureManager: NSObject, ObservableObject {
    public static let shared = SystemAudioCaptureManager()

    @Published public private(set) var isAvailable: Bool = true
    @Published public private(set) var hasPermission: Bool = false
    @Published public private(set) var isCapturing: Bool = false

    private let sampleBuffer = SystemAudioSampleBuffer()

    private var stream: SCStream?
    private var streamOutput: SystemAudioStreamOutput?

    private override init() {
        super.init()
    }

    public func checkPermission() async {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            await MainActor.run {
                self.hasPermission = true
            }
        } catch {
            await MainActor.run {
                self.hasPermission = false
            }
        }
    }

    public func requestPermission() {
        Task {
            await checkPermission()
            if !hasPermission {
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    public func startCapture() async throws {
        guard !isCapturing else { return }

        if let existingStream = stream {
            try? await existingStream.stopCapture()
            stream = nil
            streamOutput = nil
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw SpeechError.transcriptionFailed("No display found for audio capture")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16000
        configuration.channelCount = 1

        configuration.width = Int(display.width)
        configuration.height = Int(display.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let output = SystemAudioStreamOutput { [weak self] samples in
            self?.appendSamples(samples)
        }
        self.streamOutput = output

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = newStream

        do {
            try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            try await newStream.startCapture()
            isCapturing = true
            print("[SystemAudioCaptureManager] Started capturing system audio")
        } catch {
            self.stream = nil
            self.streamOutput = nil
            print("[SystemAudioCaptureManager] Failed to start capture: \(error)")
            throw SpeechError.transcriptionFailed(
                "Failed to start system audio capture: \(error.localizedDescription)"
            )
        }
    }

    public func stopCapture() async {
        guard isCapturing, let stream = stream else { return }

        do {
            try await stream.stopCapture()
        } catch {
            print("[SystemAudioCaptureManager] Error stopping capture: \(error)")
        }

        self.stream = nil
        self.streamOutput = nil
        isCapturing = false

        print("[SystemAudioCaptureManager] Stopped capturing system audio")
    }

    public nonisolated func getAndClearSamples() -> [Float] {
        sampleBuffer.getAndClear()
    }

    private nonisolated func appendSamples(_ samples: [Float]) {
        sampleBuffer.append(samples)
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioCaptureManager: SCStreamDelegate {
    public nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[SystemAudioCaptureManager] Stream stopped with error: \(error)")
        Task { @MainActor in
            self.isCapturing = false
            self.stream = nil
            self.streamOutput = nil
        }
    }
}

// MARK: - System Audio Stream Output

private class SystemAudioStreamOutput: NSObject, SCStreamOutput {
    private let onSamples: ([Float]) -> Void

    init(onSamples: @escaping ([Float]) -> Void) {
        self.onSamples = onSamples
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let dataPointer = dataPointer else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let samples: [Float]
        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let floatPointer = dataPointer.withMemoryRebound(
                to: Float.self,
                capacity: length / MemoryLayout<Float>.size
            ) { $0 }
            samples = Array(UnsafeBufferPointer(start: floatPointer, count: length / MemoryLayout<Float>.size))
        } else if asbd.pointee.mBitsPerChannel == 16 {
            let int16Pointer = dataPointer.withMemoryRebound(
                to: Int16.self,
                capacity: length / MemoryLayout<Int16>.size
            ) { $0 }
            samples = (0 ..< (length / MemoryLayout<Int16>.size)).map { Float(int16Pointer[$0]) / Float(Int16.max) }
        } else {
            return
        }

        onSamples(samples)
    }
}

// MARK: - Speech Service

/// Service for audio transcription using Apple Speech (Intel).
///
/// Same published surface as upstream's FluidAudio service, so the chat
/// microphone, Transcription Mode and VAD Mode run unchanged. "Loading a
/// model" means preparing an `SFSpeechRecognizer` for the chosen language;
/// the model id is that language's locale identifier.
@MainActor
public final class SpeechService: ObservableObject {
    public static let shared = SpeechService()

    // MARK: - Published Properties

    @Published public var isTranscribing: Bool = false
    @Published public var isModelLoaded: Bool = false
    @Published public var isLoadingModel: Bool = false
    @Published public var loadedModelId: String?
    @Published public var lastError: String?
    @Published public var microphonePermissionGranted: Bool = false
    @Published public var isRecording: Bool = false
    @Published public var currentTranscription: String = ""
    @Published public var confirmedTranscription: String = ""
    @Published public var audioLevel: Float = 0.0
    @Published public var isSpeechDetected: Bool = false

    /// Intel: whether the loaded recogniser keeps audio on this Mac. False
    /// only when the user allowed Apple's servers for a language without
    /// on-device support.
    @Published public private(set) var recognitionRunsOnDevice: Bool = true
    /// One Insights row per live dictation session (opened at start, closed at stop).
    private var liveTranscriptionJob: MediaActivityLogger.TranscriptionJob?

    /// Intel: Apple Speech without an on-device model recognizes on Apple's
    /// servers, so the activity row names that destination.
    private var transcriptionRemoteLabel: String? {
        recognitionRunsOnDevice ? nil : "Apple Speech"
    }

    /// Intel: words the recogniser should favour (agent names and the wake
    /// phrase, set by VAD Mode).
    public var contextualHints: [String] = []

    // MARK: - Private Properties

    private var recognizer: SFSpeechRecognizer?

    private var activeInputDeviceId: String?
    private var activeInputSource: AudioInputSource?
    private var activeTapFormat: AVAudioFormat?
    private var engineConfigObserver: NSObjectProtocol?
    private var engineHealthTask: Task<Void, Never>?
    private var lastRecoveryTime: Date?
    private var recoveryAttempts: Int = 0
    private let maxRecoveryAttempts = 3
    private let recoveryCooldown: TimeInterval = 5

    // MARK: - Initialization

    private var appActivationObserver: NSObjectProtocol?
    private var configurationObserver: NSObjectProtocol?

    private init() {
        // Read-only state seed. The TCC prompt is deferred to the real
        // capture entry points (see `startStreamingTranscription`) so
        // launch never asks for microphone access on its own.
        checkMicrophonePermission()

        // Re-check on app activation so toggling permission in System
        // Settings flips `microphonePermissionGranted` without relaunch.
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkMicrophonePermission()
            }
        }

        // A new language or server opt-in needs a fresh recogniser.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .speechConfigurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isModelLoaded, !self.isRecording else { return }
                if SpeechModelManager.shared.selectedModel?.id != self.loadedModelId
                    || !self.recognizerMatchesConfiguration()
                {
                    self.unloadModel()
                }
            }
        }
    }

    deinit {
        if let observer = appActivationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Microphone Permission

    public func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphonePermissionGranted = true
        case .notDetermined, .denied, .restricted:
            microphonePermissionGranted = false
        @unknown default:
            microphonePermissionGranted = false
        }
    }

    public func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            await MainActor.run {
                microphonePermissionGranted = true
                AudioInputManager.shared.refreshDevices()
            }
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run {
                microphonePermissionGranted = granted
                if granted {
                    AudioInputManager.shared.refreshDevices()
                }
            }
            return granted
        case .denied, .restricted:
            await MainActor.run { microphonePermissionGranted = false }
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Speech Recognition Permission (Intel)

    /// Ask for Speech Recognition access when it hasn't been decided yet.
    /// Needs `NSSpeechRecognitionUsageDescription` in the app's Info.plist.
    public static func requestSpeechRecognitionAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Model Loading

    /// Prepare Apple Speech for a language (`modelId` is a locale
    /// identifier). Fails when Speech Recognition access is denied, the
    /// language isn't supported, or it needs Apple's servers and the user
    /// hasn't allowed them.
    public func loadModel(_ modelId: String) async throws {
        guard !isLoadingModel else {
            print("[SpeechService] Already loading a model, skipping")
            return
        }

        isLoadingModel = true
        lastError = nil
        recognizer = nil
        isModelLoaded = false
        loadedModelId = nil
        defer { isLoadingModel = false }

        do {
            let status = await Self.requestSpeechRecognitionAuthorization()
            SpeechModelManager.shared.updateAuthorization(status)
            guard status == .authorized else { throw SpeechError.speechRecognitionDenied }

            let config = SpeechConfigurationStore.load()
            let locale = Locale(identifier: modelId)
            guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                throw SpeechError.languageUnavailable(SpeechModelManager.languageName(for: modelId))
            }
            let onDevice = recognizer.supportsOnDeviceRecognition
            guard onDevice || config.allowServerRecognition else {
                throw SpeechError.onDeviceUnavailable(SpeechModelManager.languageName(for: modelId))
            }
            guard recognizer.isAvailable else {
                throw SpeechError.transcriptionFailed(
                    "Speech recognition for \(SpeechModelManager.languageName(for: modelId)) is not available right now."
                )
            }
            recognizer.queue = Self.recognitionQueue
            recognizer.defaultTaskHint = .dictation

            self.recognizer = recognizer
            recognitionRunsOnDevice = onDevice
            isModelLoaded = true
            loadedModelId = modelId
            print("[SpeechService] Apple Speech ready for \(modelId) (on device: \(onDevice))")
        } catch {
            print("[SpeechService] Failed to prepare Apple Speech: \(error)")
            lastError = error.localizedDescription
            isModelLoaded = false
            loadedModelId = nil
            throw error
        }
    }

    /// Recognition callbacks run here rather than on the main queue.
    private static let recognitionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ai.osaurus.speech.recognition"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private func recognizerMatchesConfiguration() -> Bool {
        guard let recognizer else { return false }
        return recognizer.supportsOnDeviceRecognition || SpeechConfigurationStore.load().allowServerRecognition
    }

    /// Unload the current model
    public func unloadModel() {
        recognizer = nil
        isModelLoaded = false
        loadedModelId = nil
        print("[SpeechService] Model unloaded")
    }

    /// Auto-load the model if a default model is selected
    public func autoLoadIfNeeded() async {
        guard let selectedModel = SpeechModelManager.shared.selectedModel else {
            return
        }

        if isModelLoaded && loadedModelId == selectedModel.id {
            return
        }

        // Never raise the Speech Recognition prompt from a background path.
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return }

        do {
            try await loadModel(selectedModel.id)
            print("[SpeechService] Auto-loaded model: \(selectedModel.id)")
        } catch {
            print("[SpeechService] Failed to auto-load model: \(error)")
        }
    }

    /// Ensure a model is loaded, using the default if needed
    public func ensureModelLoaded() async throws {
        if isModelLoaded && recognizer != nil {
            return
        }

        guard let selectedModel = SpeechModelManager.shared.selectedModel else {
            throw SpeechError.noModelSelected
        }

        try await loadModel(selectedModel.id)
    }

    // MARK: - Transcription

    /// Transcribe an audio file
    public func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        try await ensureModelLoaded()

        guard let recognizer else {
            throw SpeechError.modelNotReady
        }

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw SpeechError.audioFileNotFound
        }

        isTranscribing = true
        defer { isTranscribing = false }

        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? nil
        let activity = MediaActivityLogger.beginTranscription(
            model: loadedModelId ?? "unknown",
            audioSeconds: nil,
            audioBytes: fileBytes,
            audioFormat: audioURL.pathExtension.isEmpty ? nil : audioURL.pathExtension.lowercased(),
            mode: "file",
            remoteLabel: transcriptionRemoteLabel
        )

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = recognitionRunsOnDevice
        request.addsPunctuation = true
        request.shouldReportPartialResults = false
        do {
            let text = try await AppleSpeechSegment.recognizeFile(request: request, recognizer: recognizer)
            activity?.finish(transcript: text, language: loadedModelId, error: nil)
            return TranscriptionResult(text: text, durationSeconds: nil)
        } catch {
            activity?.finish(transcript: nil, language: loadedModelId, error: error.localizedDescription)
            throw error
        }
    }

    // MARK: - Streaming Transcription

    private var audioEngine: AVAudioEngine?
    private let audioBuffer = ThreadSafeAudioBuffer()
    private var transcriptionWorker: TranscriptionWorker?
    private var isUsingSystemAudio: Bool = false
    private var systemAudioPollingTask: Task<Void, Never>?

    public var keepAudioEngineAlive: Bool = false

    /// Captures the current live turn's raw PCM for direct Omni audio input.
    /// Call before `stopStreamingTranscription()` clears the active buffer.
    /// (Intel sends no raw audio to models; kept for upstream's composer.)
    public func currentLiveAudioSnapshot() -> LiveVoiceAudioSnapshot? {
        let samples = audioBuffer.snapshotRetained()
        guard !samples.isEmpty else { return nil }

        let sampleRate = Int(activeTapFormat?.sampleRate.rounded() ?? 16_000)
        return LiveVoiceAudioSnapshot(samples: samples, sampleRate: max(1, sampleRate))
    }

    public func currentLiveAudioWAVData() -> Data? {
        currentLiveAudioSnapshot()?.wavData()
    }

    /// Start streaming transcription
    public func startStreamingTranscription() async throws {
        if isRecording {
            print("[SpeechService] Already recording, skipping start")
            return
        }

        if let worker = transcriptionWorker {
            print("[SpeechService] Stopping previous worker before restart")
            _ = await worker.stop(flush: false)
            transcriptionWorker = nil
        }

        let inputSource = AudioInputManager.shared.selectedInputSource
        let selectedId = AudioInputManager.shared.selectedDeviceId

        var reuseEngine = false
        if let engine = audioEngine, engine.isRunning,
            inputSource == activeInputSource,
            selectedId == activeInputDeviceId,
            activeTapFormat != nil
        {
            print("[SpeechService] Reusing active audio engine for handoff")
            reuseEngine = true
        } else {
            await teardownAudioEngine()
        }

        if inputSource == .microphone {
            if !microphonePermissionGranted {
                let granted = await requestMicrophonePermission()
                if !granted {
                    throw SpeechError.microphonePermissionDenied
                }
            }
        } else {
            await SystemAudioCaptureManager.shared.checkPermission()
            if !SystemAudioCaptureManager.shared.hasPermission {
                throw SpeechError.transcriptionFailed(
                    "Screen recording permission required for system audio capture"
                )
            }
        }

        try await ensureModelLoaded()

        guard let recognizer else {
            throw SpeechError.modelNotLoaded
        }

        audioBuffer.clear()
        audioBuffer.setActive(true)
        currentTranscription = ""
        confirmedTranscription = ""
        liveTranscriptionJob = MediaActivityLogger.beginTranscription(
            model: loadedModelId ?? "unknown",
            audioSeconds: nil,
            audioBytes: nil,
            audioFormat: inputSource == .systemAudio ? "system_audio" : "microphone",
            mode: "live",
            remoteLabel: transcriptionRemoteLabel
        )
        audioLevel = 0.0
        isSpeechDetected = false
        isUsingSystemAudio = (inputSource == .systemAudio)

        let config = SpeechConfigurationStore.load()
        let recognition = AppleSpeechSettings(
            recognizer: recognizer,
            requiresOnDevice: recognitionRunsOnDevice,
            contextualStrings: contextualHints
        )

        print("[SpeechService] Starting transcription with:")
        print("[SpeechService]   - Language: \(loadedModelId ?? "?") (on device: \(recognitionRunsOnDevice))")
        print("[SpeechService]   - Sensitivity: \(config.sensitivity)")

        if inputSource == .microphone {
            var targetDeviceId: AudioDeviceID? = nil
            if let selectedId {
                targetDeviceId = AudioInputManager.shared.getAudioDeviceId(for: selectedId)
                if targetDeviceId == nil {
                    print("[SpeechService] WARNING: Could not find AudioDeviceID for UID: \(selectedId)")
                }
            }

            do {
                let tapFormat: AVAudioFormat
                if reuseEngine, let format = activeTapFormat {
                    tapFormat = format
                } else {
                    let (engine, format) = try await setupAudioEngine(
                        targetDeviceId: targetDeviceId,
                        buffer: audioBuffer
                    )
                    self.audioEngine = engine
                    self.activeTapFormat = format
                    self.activeInputDeviceId = selectedId
                    self.activeInputSource = inputSource
                    tapFormat = format
                }

                transcriptionWorker = TranscriptionWorker(
                    recognition: recognition,
                    audioBuffer: audioBuffer,
                    inputFormat: tapFormat,
                    sensitivity: config.sensitivity
                )

                isRecording = true
                recoveryAttempts = 0
                lastRecoveryTime = nil

                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self, self.isRecording else { return }
                    self.observeEngineConfiguration()
                    self.startEngineHealthMonitoring()
                }
                startAudioLevelMonitoring()
                startWorkerProcessing()

            } catch {
                await teardownAudioEngine()
                throw error
            }
        } else {
            do {
                if !reuseEngine {
                    try await SystemAudioCaptureManager.shared.startCapture()
                }

                guard
                    let systemAudioFormat = AVAudioFormat(
                        commonFormat: .pcmFormatFloat32,
                        sampleRate: 16000,
                        channels: 1,
                        interleaved: false
                    )
                else {
                    throw SpeechError.transcriptionFailed("Failed to create audio format for system audio")
                }

                self.activeTapFormat = systemAudioFormat
                self.activeInputDeviceId = selectedId
                self.activeInputSource = inputSource

                transcriptionWorker = TranscriptionWorker(
                    recognition: recognition,
                    audioBuffer: audioBuffer,
                    inputFormat: systemAudioFormat,
                    sensitivity: config.sensitivity
                )

                isRecording = true

                startSystemAudioPolling()
                startAudioLevelMonitoring()
                startWorkerProcessing()

            } catch {
                await teardownAudioEngine()
                throw error
            }
        }
    }

    /// Stop streaming transcription and get final result
    public func stopStreamingTranscription(force: Bool = false) async -> String {
        print(
            "[SpeechService] Stopping streaming transcription (force: \(force), keepAlive: \(keepAudioEngineAlive))"
        )

        // Intel: the worker finishes the segment in progress (Apple Speech
        // returns its final text once the audio ends) instead of upstream's
        // re-transcription of the leftover buffer.
        let worker = transcriptionWorker
        transcriptionWorker = nil
        let finalText = await worker?.stop(flush: true)
        audioBuffer.setActive(false)

        systemAudioPollingTask?.cancel()
        systemAudioPollingTask = nil

        if !keepAudioEngineAlive || force {
            print("[SpeechService] Tearing down audio engine")
            await teardownAudioEngine()
        } else {
            print("[SpeechService] Keeping audio engine alive for handoff")
        }

        isRecording = false
        isSpeechDetected = false
        _ = audioBuffer.getAndClear()
        let activity = liveTranscriptionJob
        liveTranscriptionJob = nil
        // Live capture runs in real time, so session wall-clock ≈ audio duration.
        let sessionSeconds = activity.map { Date().timeIntervalSince($0.started) }

        if let finalText, !finalText.isEmpty {
            if confirmedTranscription.isEmpty {
                confirmedTranscription = finalText
            } else {
                confirmedTranscription += " " + finalText
            }
            currentTranscription = ""
            activity?.finish(
                transcript: confirmedTranscription, language: loadedModelId, error: nil, audioSeconds: sessionSeconds)
            return finalText
        }

        let fullTranscript = [confirmedTranscription, currentTranscription]
            .filter { !$0.isEmpty }.joined(separator: " ")
        activity?.finish(transcript: fullTranscript, language: loadedModelId, error: nil, audioSeconds: sessionSeconds)
        return currentTranscription
    }

    // MARK: - Audio Engine Helpers

    private func teardownAudioEngine() async {
        activeInputDeviceId = nil
        activeInputSource = nil
        activeTapFormat = nil

        engineHealthTask?.cancel()
        engineHealthTask = nil

        if let observer = engineConfigObserver {
            NotificationCenter.default.removeObserver(observer)
            engineConfigObserver = nil
        }

        _ = await transcriptionWorker?.stop(flush: false)
        transcriptionWorker = nil

        systemAudioPollingTask?.cancel()
        systemAudioPollingTask = nil

        if isUsingSystemAudio {
            await SystemAudioCaptureManager.shared.stopCapture()
            isUsingSystemAudio = false
        }

        if let engine = audioEngine {
            audioEngine = nil

            await Task.detached(priority: .userInitiated) {
                if engine.isRunning {
                    engine.stop()
                }
                engine.inputNode.removeTap(onBus: 0)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }.value
        }
    }


    private func startSystemAudioPolling() {
        let bufferRef = audioBuffer
        systemAudioPollingTask = Task { @MainActor [weak self] in
            print("[SpeechService] Started system audio polling")
            while let _ = self, bufferRef.isActive {
                let samples = SystemAudioCaptureManager.shared.getAndClearSamples()
                if !samples.isEmpty {
                    bufferRef.append(samples)

                    let sum = samples.reduce(0) { $0 + $1 * $1 }
                    let rms = sqrt(sum / Float(samples.count))
                    bufferRef.setLevel(min(1.0, rms * 10))
                }

                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            print("[SpeechService] System audio polling stopped")
        }
    }

    private func setupAudioEngine(targetDeviceId: AudioDeviceID?, buffer: ThreadSafeAudioBuffer) async throws -> (
        AVAudioEngine, AVAudioFormat
    ) {
        return try await Task.detached(priority: .userInitiated) { () -> (AVAudioEngine, AVAudioFormat) in
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode

            if let deviceId = targetDeviceId {
                print("[SpeechService] Setting input device to AudioDeviceID: \(deviceId)")
                Self.setInputDevice(deviceId, for: inputNode)
            } else {
                print("[SpeechService] Using system default input device")
            }

            let hwFormat = inputNode.inputFormat(forBus: 0)
            print(
                "[SpeechService] Hardware input format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount) channels"
            )

            guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
                throw SpeechError.transcriptionFailed(
                    "Audio input device is not available. Please check your microphone settings."
                )
            }

            guard
                let tapFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: hwFormat.sampleRate,
                    channels: 1,
                    interleaved: false
                )
            else {
                throw SpeechError.transcriptionFailed("Failed to create audio format")
            }

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { tapBuffer, _ in
                guard buffer.isActive else { return }

                guard let floatData = tapBuffer.floatChannelData?[0] else { return }
                let frameCount = Int(tapBuffer.frameLength)
                guard frameCount > 0 else { return }

                var sum: Float = 0
                for i in 0 ..< frameCount {
                    let sample = floatData[i]
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(frameCount))
                buffer.setLevel(min(1.0, rms * 10))

                let samples = Array(UnsafeBufferPointer(start: floatData, count: frameCount))
                buffer.append(samples)
            }

            engine.prepare()

            var lastError: Error?
            for attempt in 1 ... 3 {
                do {
                    try engine.start()
                    print("[SpeechService] Audio engine started successfully on attempt \(attempt)")
                    lastError = nil
                    break
                } catch {
                    print("[SpeechService] Engine start attempt \(attempt) failed: \(error)")
                    lastError = error
                    try? await Task.sleep(nanoseconds: UInt64(attempt * 200_000_000))
                    engine.prepare()
                }
            }

            if let error = lastError {
                throw error
            }

            return (engine, tapFormat)
        }.value
    }

    private func startAudioLevelMonitoring() {
        let bufferRef = audioBuffer
        Task { @MainActor [weak self] in
            while let self = self, bufferRef.isActive {
                self.audioLevel = bufferRef.getLevel()
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            self?.audioLevel = 0
        }
    }

    private func observeEngineConfiguration() {
        engineConfigObserver.map { NotificationCenter.default.removeObserver($0) }
        guard let engine = audioEngine else { return }

        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let engine = self.audioEngine, !engine.isRunning else {
                    print("[SpeechService] Config change notification — engine still running, ignoring")
                    return
                }
                print("[SpeechService] Audio engine stopped after config change — attempting recovery")
                await self.recoverAudioEngine()
            }
        }
    }

    private func startEngineHealthMonitoring() {
        engineHealthTask?.cancel()
        engineHealthTask = Task { @MainActor [weak self] in
            while let self = self, self.isRecording {
                if let engine = self.audioEngine, !engine.isRunning {
                    print("[SpeechService] Engine stopped unexpectedly — attempting recovery")
                    await self.recoverAudioEngine()
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func recoverAudioEngine() async {
        guard isRecording else { return }

        if let lastTime = lastRecoveryTime, Date().timeIntervalSince(lastTime) < recoveryCooldown {
            print("[SpeechService] Recovery cooldown active, skipping")
            return
        }

        guard recoveryAttempts < maxRecoveryAttempts else {
            print("[SpeechService] Max recovery attempts (\(maxRecoveryAttempts)) reached")
            lastError = "Audio device changed. Please restart voice input."
            audioBuffer.setActive(false)
            _ = await transcriptionWorker?.stop(flush: false)
            transcriptionWorker = nil
            isRecording = false
            return
        }

        recoveryAttempts += 1
        lastRecoveryTime = Date()
        print("[SpeechService] Recovering audio engine (attempt \(recoveryAttempts)/\(maxRecoveryAttempts))...")

        audioBuffer.setActive(false)
        _ = await transcriptionWorker?.stop(flush: false)
        transcriptionWorker = nil

        if let engine = audioEngine {
            audioEngine = nil
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        activeTapFormat = nil

        isRecording = false

        try? await Task.sleep(nanoseconds: 500_000_000)

        do {
            try await startStreamingTranscription()
            print("[SpeechService] Audio engine recovered successfully")
        } catch {
            print("[SpeechService] Audio engine recovery failed: \(error)")
            lastError = "Audio device changed. Please restart voice input."
        }
    }

    private func startWorkerProcessing() {
        guard let worker = transcriptionWorker else { return }
        // `TranscriptionWorker` is a separate actor whose AsyncStream resumes on
        // the cooperative pool, so consume it on the main actor — otherwise these
        // @Published writes land off-main ("Updating ObservedObject from
        // background threads will cause undefined behavior").
        Task { @MainActor in
            print("[SpeechService] Starting to consume worker updates")
            for await update in await worker.start() {
                switch update {
                case .partial(let text):
                    self.currentTranscription = text
                case .final(let text):
                    if self.confirmedTranscription.isEmpty {
                        self.confirmedTranscription = text
                    } else {
                        self.confirmedTranscription += " " + text
                    }
                    self.currentTranscription = ""
                case .speechActivity(let detected):
                    self.isSpeechDetected = detected
                }
            }
            print("[SpeechService] Worker updates stream finished")
        }
    }

    /// Clear transcription state
    public func clearTranscription() {
        currentTranscription = ""
        confirmedTranscription = ""
        audioBuffer.clear()
    }

    // MARK: - Audio Device Helpers

    private nonisolated static func setInputDevice(_ deviceId: AudioDeviceID, for inputNode: AVAudioInputNode) {
        _ = inputNode.inputFormat(forBus: 0)

        guard let audioUnit = inputNode.audioUnit else {
            print("[SpeechService] Failed to get audioUnit from inputNode")
            return
        }

        var mutableDeviceId = deviceId
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceId,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            print("[SpeechService] Failed to set input device: \(status). Error code: \(status)")
        } else {
            print("[SpeechService] Successfully set input device to AudioDeviceID: \(deviceId)")
        }
    }

}

// MARK: - Transcription Worker (Intel: Apple Speech)

private enum TranscriptionUpdate: Sendable {
    case partial(String)
    case final(String)
    case speechActivity(Bool)
}

/// What the worker needs to start Apple Speech requests.
/// `@unchecked Sendable`: `SFSpeechRecognizer` is safe to share once
/// configured; the service never mutates it after `loadModel`.
struct AppleSpeechSettings: @unchecked Sendable {
    let recognizer: SFSpeechRecognizer
    let requiresOnDevice: Bool
    let contextualStrings: [String]
}

/// Upstream's worker cuts the stream into speech segments with Silero VAD
/// and transcribes each with Parakeet. Intel keeps the segmenting (so the
/// chat's pause/auto-send and VAD Mode behave the same) with a loudness
/// detector, and streams each segment into one Apple Speech request, whose
/// partial results feed the live preview.
private actor TranscriptionWorker {
    private let recognition: AppleSpeechSettings
    private let audioBuffer: ThreadSafeAudioBuffer
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<TranscriptionUpdate>.Continuation?
    private let inputFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let needsConversion: Bool
    private var converter: AVAudioConverter?

    private let speechThreshold: Float
    private let silenceThresholdSeconds: Double
    /// Apple's servers cap one request at about a minute; stay well under.
    private let maxSegmentDurationSeconds: Double = 30.0
    /// Audio kept from just before speech is detected, so the first
    /// syllable isn't clipped (0.5 s at 16 kHz).
    private let preRollSamples = 8_000

    private var segment: AppleSpeechSegment?
    private var idleSamples: [Float] = []
    private var isSpeaking = false
    private var lastSpeechTime = Date()
    private var segmentStartTime = Date()
    private var lastReportedSpeechActivity = false
    private var stopped = false

    init(
        recognition: AppleSpeechSettings,
        audioBuffer: ThreadSafeAudioBuffer,
        inputFormat: AVAudioFormat,
        sensitivity: VoiceSensitivity = .medium
    ) {
        self.recognition = recognition
        self.audioBuffer = audioBuffer
        self.inputFormat = inputFormat
        self.needsConversion = inputFormat.sampleRate != 16000
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        self.speechThreshold = sensitivity.energyThreshold
        self.silenceThresholdSeconds = sensitivity.silenceThresholdSeconds
    }

    func start() -> AsyncStream<TranscriptionUpdate> {
        let stream = AsyncStream<TranscriptionUpdate> { continuation in
            self.continuation = continuation
        }

        task = Task { [weak self] in
            await self?.runLoop()
        }

        return stream
    }

    /// Stop the worker. With `flush`, the segment in progress is finished
    /// (buffered audio appended, Apple Speech's final text awaited) and its
    /// text returned; without it, the segment is cancelled.
    func stop(flush: Bool) async -> String? {
        guard !stopped else { return nil }
        stopped = true
        let running = task
        task = nil
        running?.cancel()
        // Let a finalize that is already under way deliver its text first.
        await running?.value

        var text: String?
        if let segment {
            self.segment = nil
            if flush {
                let raw = audioBuffer.getAndClear()
                if !raw.isEmpty { segment.append(convertTo16kHz(raw), format: targetFormat) }
                let finished = await segment.finish(timeout: 2.5)
                text = finished.isEmpty ? nil : finished
            } else {
                segment.cancel()
            }
        }
        continuation?.finish()
        continuation = nil
        return text
    }

    private func runLoop() async {
        if needsConversion {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            if converter == nil {
                print("[TranscriptionWorker] Failed to create audio converter")
            }
        }

        while !stopped && audioBuffer.isActive && !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                break
            }

            guard !stopped, audioBuffer.isActive else { break }

            let samples = convertTo16kHz(audioBuffer.getAndClear())
            let speechDetected = !samples.isEmpty && Self.level(of: samples) > speechThreshold
            let now = Date()

            if speechDetected {
                if !isSpeaking {
                    isSpeaking = true
                    segmentStartTime = now
                    beginSegment(preRoll: Array(idleSamples.suffix(preRollSamples)))
                    idleSamples = []
                }
                lastSpeechTime = now
            }

            if isSpeaking {
                segment?.append(samples, format: targetFormat)
            } else if !samples.isEmpty {
                idleSamples.append(contentsOf: samples)
                if idleSamples.count > 16000 {
                    idleSamples.removeFirst(idleSamples.count - 16000)
                }
            }

            if speechDetected != lastReportedSpeechActivity {
                lastReportedSpeechActivity = speechDetected
                continuation?.yield(.speechActivity(speechDetected))
            }

            let silenceDuration = now.timeIntervalSince(lastSpeechTime)
            let segmentDuration = now.timeIntervalSince(segmentStartTime)
            let shouldFinalize =
                isSpeaking
                && (silenceDuration > silenceThresholdSeconds || segmentDuration > maxSegmentDurationSeconds)

            if shouldFinalize {
                isSpeaking = false
                let finishing = segment
                segment = nil
                if lastReportedSpeechActivity {
                    lastReportedSpeechActivity = false
                    continuation?.yield(.speechActivity(false))
                }
                if let finishing {
                    let text = await finishing.finish(timeout: 3)
                    if !text.isEmpty {
                        continuation?.yield(.final(text))
                    }
                }
            }
        }

        print("[TranscriptionWorker] Exiting run loop, buffer active: \(audioBuffer.isActive)")
    }

    private func beginSegment(preRoll: [Float]) {
        let continuation = self.continuation
        let segment = AppleSpeechSegment(settings: recognition) { text in
            continuation?.yield(.partial(text))
        }
        if !preRoll.isEmpty {
            segment.append(preRoll, format: targetFormat)
        }
        self.segment = segment
    }

    /// Scaled RMS on the audio meter's scale (`rms * 10`, clamped to 1).
    nonisolated static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return min(1, sqrt(sum / Float(samples.count)) * 10)
    }

    private func convertTo16kHz(_ samples: [Float]) -> [Float] {
        guard needsConversion else { return samples }
        guard !samples.isEmpty, let converter = converter else { return [] }

        let inputFrameCount = AVAudioFrameCount(samples.count)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount) else {
            return []
        }

        inputBuffer.frameLength = inputFrameCount
        if let channelData = inputBuffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { ptr in
                channelData.update(from: ptr.baseAddress!, count: samples.count)
            }
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(inputFrameCount) * ratio) + 100

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return []
        }

        var error: NSError?
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            print("[TranscriptionWorker] Conversion error: \(error)")
            return []
        }

        if let floatData = outputBuffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: floatData, count: Int(outputBuffer.frameLength)))
        }

        return []
    }
}

// MARK: - Apple Speech Segment (Intel)

/// One Apple Speech request for one stretch of speech: audio is appended as
/// it arrives, partial results go to `onPartial`, and `finish` ends the audio
/// and waits (bounded) for the final text. `finish` is idempotent, and a
/// segment that errors or times out resolves to its latest partial text.
final class AppleSpeechSegment: @unchecked Sendable {
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var latest = ""
    private var resolved: String?
    private var ending = false
    private var waiters: [CheckedContinuation<String, Never>] = []

    init(settings: AppleSpeechSettings, onPartial: @escaping @Sendable (String) -> Void) {
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = settings.requiresOnDevice
        request.addsPunctuation = true
        request.taskHint = .dictation
        if !settings.contextualStrings.isEmpty {
            request.contextualStrings = settings.contextualStrings
        }
        task = settings.recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    self.resolve(text)
                    return
                }
                // Once the segment is ending, a late partial must not
                // repaint the live preview after the final text landed.
                let forward: Bool = self.lock.withLock {
                    self.latest = text
                    return !self.ending
                }
                if forward { onPartial(text) }
            }
            if error != nil {
                self.resolve(nil)
            }
        }
    }

    func append(_ samples: [Float], format: AVAudioFormat) {
        guard !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        }
        request.append(buffer)
    }

    /// End the audio and wait up to `timeout` seconds for the final text.
    func finish(timeout: TimeInterval) async -> String {
        let alreadyEnding: Bool = lock.withLock {
            let was = ending
            ending = true
            return was
        }
        if !alreadyEnding { request.endAudio() }
        return await withCheckedContinuation { continuation in
            let immediate: String? = lock.withLock {
                if let resolved { return resolved }
                waiters.append(continuation)
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            } else {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.resolve(nil)
                }
            }
        }
    }

    func cancel() {
        lock.withLock { ending = true }
        task?.cancel()
        resolve(nil)
    }

    /// First resolution wins; `nil` falls back to the latest partial.
    private func resolve(_ text: String?) {
        let (value, pending): (String, [CheckedContinuation<String, Never>]) = lock.withLock {
            if resolved == nil {
                resolved = (text ?? latest).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let pending = waiters
            waiters = []
            return (resolved ?? "", pending)
        }
        for waiter in pending { waiter.resume(returning: value) }
    }

    /// Recognise a whole file (`SpeechService.transcribe(audioURL:)`).
    static func recognizeFile(request: SFSpeechURLRecognitionRequest, recognizer: SFSpeechRecognizer) async throws
        -> String
    {
        final class Once: @unchecked Sendable {
            let lock = NSLock()
            var done = false
            func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
        }
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if once.claim() { continuation.resume(returning: result.bestTranscription.formattedString) }
                } else if let error {
                    if once.claim() {
                        continuation.resume(throwing: SpeechError.transcriptionFailed(error.localizedDescription))
                    }
                }
            }
        }
    }
}

// MARK: - Thread-Safe Audio Buffer

private final class ThreadSafeAudioBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private var retainedSamples: [Float] = []
    private var _isActive: Bool = false
    private var _level: Float = 0.0
    private let maxRetainedSamples = 48_000 * 60 * 5
    private let lock = OSAllocatedUnfairLock()

    var isActive: Bool {
        lock.withLock { _isActive }
    }

    func setActive(_ active: Bool) {
        lock.withLock { _isActive = active }
    }

    func setLevel(_ level: Float) {
        lock.withLock { _level = level }
    }

    func getLevel() -> Float {
        lock.withLock { _level }
    }

    func append(_ newSamples: [Float]) {
        lock.withLock {
            if _isActive {
                samples.append(contentsOf: newSamples)
                retainedSamples.append(contentsOf: newSamples)
                if retainedSamples.count > maxRetainedSamples {
                    retainedSamples.removeFirst(retainedSamples.count - maxRetainedSamples)
                }
            }
        }
    }

    func getAndClear() -> [Float] {
        lock.withLock {
            let current = samples
            samples = []
            return current
        }
    }

    func snapshotRetained() -> [Float] {
        lock.withLock { retainedSamples }
    }

    func clear() {
        lock.withLock {
            samples = []
            retainedSamples = []
            _isActive = false
            _level = 0.0
        }
    }
}
