//
//  TTSService.swift
//  osaurus
//
//  Text-to-speech for Intel. Same surface as upstream's `TTSService`
//  (speaker button, auto-speak, the `speak` tool, settings preview), with
//  two engines:
//
//    * `.system` — the macOS system voices through `AVSpeechSynthesizer`,
//      on this Mac and ready without a download. Replaces upstream's
//      FluidAudio PocketTTS engine (CoreML, Apple Silicon only).
//    * `.openAICompatible` — upstream's `/v1/audio/speech` client, streamed
//      into upstream's `TTSAudioPipeline`, unchanged.
//
//  See docs/VOICE_INTEL.md.
//

import AVFoundation
import Combine
import Foundation
import NaturalLanguage
import OSLog

/// TTS diagnostics. A synthesis failure used to be a bare `print`, which meant a user whose
/// audio silently died had nothing to send us and nothing to read.
enum TTSLogger {
    static let service = Logger(subsystem: "ai.osaurus", category: "tts.service")
}

/// Errors mapped onto tool error envelopes by the `speak` tool.
public enum TTSPlaybackError: Error {
    case modelNotReady
}

/// Model-readiness state. Intel's engines have nothing to download, so this
/// stays `.ready`; the type is kept for upstream's settings and agent views.
public enum TTSModelState: Equatable {
    case notReady
    /// `fraction` is in [0, 1]. `nil` means indeterminate (e.g. compile phase).
    case downloading(fraction: Double?)
    case ready
    case failed(String)
}

/// Owns the AVAudioEngine + player node and serializes every call to them on a
/// private queue. Engine construction and `start()` make synchronous XPC
/// round-trips to coreaudiod that stalled the main thread for seconds in
/// production, so none of this may run on the main actor.
/// `@unchecked Sendable`: all mutable state is confined to `queue`.
final class TTSAudioPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.osaurus.tts.audio", qos: .userInitiated)
    private let sourceFormat: AVAudioFormat

    // Lazy so constructing the pipeline stays cheap; the audio stack is only
    // realized on first playback, on `queue`.
    private lazy var engine = AVAudioEngine()
    private lazy var playerNode = AVAudioPlayerNode()
    private var configured = false
    private var needsRebuild = false
    private var changeObserver: NSObjectProtocol?

    /// Invoked (on an arbitrary thread) when the engine reports its graph was
    /// torn down by an output-route change. The owner rebuilds the graph on
    /// the new device and resumes playback (or ends it if the rebuild fails).
    var onConfigurationChange: (@Sendable () -> Void)?

    init(format: AVAudioFormat) {
        self.sourceFormat = format
    }

    /// Configure the engine graph if needed, start the engine, and start the
    /// player node. Runs on the pipeline queue; the caller awaits without
    /// blocking its thread.
    func prepareAndPlay() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.configureIfNeededLocked()
                    self.playerNode.play()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Schedule a PCM frame. `completion` fires exactly once — when the buffer
    /// finishes playing, or immediately if the buffer could not be built — so
    /// the owner's pending-buffer accounting stays balanced.
    func schedule(samples: [Float], completion: @escaping @Sendable () -> Void) {
        queue.async {
            guard let buffer = self.makeBufferLocked(from: samples) else {
                completion()
                return
            }
            self.playerNode.scheduleBuffer(buffer) { completion() }
        }
    }

    /// Stop and reset the player node (drops any scheduled buffers). The
    /// engine itself keeps running so the next playback start is cheap.
    func stopPlayer() {
        queue.async {
            guard self.configured else { return }
            self.playerNode.stop()
            self.playerNode.reset()
        }
    }

    private func configureIfNeededLocked() throws {
        // Do NOT trust `isRunning` alone.
        //
        // When the output device changes — AirPods connecting, the user switching to the
        // built-in speakers, the default device changing — AVAudioEngine tears its graph
        // down and posts `.AVAudioEngineConfigurationChange`, but it keeps reporting
        // `isRunning == true`. Returning early on that would leave the player node wired to
        // a device that no longer exists: buffers are still consumed, their completion
        // handlers still fire, the Stop control still flips back on its own — and not a
        // single sample is audible, with no error anywhere. That is exactly what a silent
        // TTS looks like from the outside.
        //
        // `needsRebuild` is set by the configuration-change observer, so the next
        // playback re-establishes the graph instead of politely doing nothing.
        if needsRebuild {
            if engine.isRunning { engine.stop() }
            configured = false
            needsRebuild = false
        }

        if configured, engine.isRunning { return }
        if !configured {
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: sourceFormat)
            configured = true
            // Registered against the engine we just built, and only once.
            observeEngineConfigurationChangesLocked()
        }
        if !engine.isRunning {
            try engine.start()
        }
    }

    /// The notification arrives on an arbitrary thread; flag flips hop onto
    /// `queue`, and the owner is told so it can end playback on its own actor.
    private func observeEngineConfigurationChangesLocked() {
        guard changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.needsRebuild = true }
            self.onConfigurationChange?()
        }
    }

    private func makeBufferLocked(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let ptr = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                ptr.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }
}

/// Singleton that owns the speech engines and the playback lifecycle.
@MainActor
public final class TTSService: NSObject, ObservableObject {
    public static let shared = TTSService()

    // MARK: - Published state

    /// ID of the message currently being spoken. `nil` when idle.
    @Published public private(set) var playingMessageId: UUID? {
        didSet {
            if oldValue != playingMessageId {
                // Clear the tool-call binding when playback ends so
                // the row's spinner stops alongside the audio.
                if playingMessageId == nil { activeSpeakCallId = nil }
                NotificationCenter.default.post(name: .ttsPlaybackStateChanged, object: nil)
            }
        }
    }

    /// Always `.ready` on Intel (no model download).
    @Published public private(set) var modelState: TTSModelState = .ready

    /// Tool-call id driving the current playback (`nil` for the manual
    /// speaker button or when idle). The inline tool card watches this
    /// to swap its check for a spinner while audio is still playing.
    @Published public private(set) var activeSpeakCallId: String? {
        didSet {
            if oldValue != activeSpeakCallId {
                NotificationCenter.default.post(name: .ttsPlaybackStateChanged, object: nil)
            }
        }
    }

    /// Most recent remote-synthesis failure, shown in the TTS settings tab.
    /// Cleared when a later playback starts.
    @Published public private(set) var lastRemoteError: String?

    // MARK: - Private state

    private var playbackTask: Task<Void, Never>?

    /// System-voice engine. Kept for the app's lifetime: an
    /// `AVSpeechSynthesizer` stops speaking when it is released.
    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance the current system playback is waiting on. Delegate
    /// callbacks for any other utterance (a stopped one) are ignored.
    private var currentUtterance: AVSpeechUtterance?
    /// Intel: the Insights row for the system-voice utterance in flight
    /// (upstream logs its local PocketTTS synthesis the same way).
    private var systemSpeechActivity: MediaActivityLogger.SpeechJob?

    /// All AVAudioEngine work lives here, serialized on the pipeline's own
    /// queue, because engine construction and `start()` block on coreaudiod
    /// XPC. This class keeps only the published UI state and the
    /// pending-buffer accounting on the main actor.
    private let pipeline = TTSAudioPipeline(
        format: AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!
    )
    private var pendingBufferCount = 0
    private var streamFinished = false

    /// Bumped whenever the buffer accounting is reset (stop, route-change
    /// rebuild). Completion handlers from buffers scheduled under an older
    /// generation — including ones wired to a disconnected output device,
    /// whose callbacks may fire late or not at all — are ignored so they
    /// can't corrupt the count for the rebuilt node.
    private var bufferGeneration = 0

    private override init() {
        super.init()
        synthesizer.delegate = self
        pipeline.onConfigurationChange = {
            Task { @MainActor in
                TTSService.shared.handleRouteChange()
            }
        }
    }

    // MARK: - Public API

    /// Both Intel engines can speak right away: the system voices ship with
    /// macOS, and the remote engine reports connection failures at playback
    /// time via `lastRemoteError`.
    public var isModelReady: Bool { true }

    /// Toggle speech for a given message. Tapping the currently-playing
    /// message stops playback; tapping a different message switches to it.
    public func toggleSpeak(text: String, messageId: UUID, voiceOverride: String? = nil) {
        if playingMessageId == messageId {
            stop()
            return
        }

        let plain = MarkdownStripper.plainText(from: text)
        guard !plain.isEmpty else { return }

        stop()
        playingMessageId = messageId
        startPlayback(text: plain, messageId: messageId, voiceOverride: voiceOverride)
    }

    /// Fire-and-forget playback for the `speak` tool. Sets
    /// `activeSpeakCallId` so the row spinner runs until audio drains
    public func startToolPlayback(text: String, messageId: UUID, callId: String, voiceOverride: String? = nil) throws {
        let plain = MarkdownStripper.plainText(from: text)
        guard !plain.isEmpty else { return }

        stop()
        playingMessageId = messageId
        activeSpeakCallId = callId
        startPlayback(text: plain, messageId: messageId, voiceOverride: voiceOverride)
    }

    /// Stop any in-flight synthesis and clear playback state.
    public func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        streamFinished = true
        pendingBufferCount = 0
        bufferGeneration += 1
        pipeline.stopPlayer()
        if currentUtterance != nil {
            currentUtterance = nil
            synthesizer.stopSpeaking(at: .immediate)
            systemSpeechActivity?.finish(audioSeconds: nil, error: nil, cancelled: true)
            systemSpeechActivity = nil
        }
        playingMessageId = nil
    }

    /// Upstream downloads PocketTTS here. Intel has nothing to load.
    public func ensureModelLoaded() {}

    /// Upstream probes the PocketTTS cache here. Intel is always ready.
    public func refreshModelState() {}

    /// The output device changed mid-utterance (e.g. a Bluetooth speaker
    /// disconnected). The engine graph is dead, but the synthesis stream is
    /// still producing frames — so rebuild the engine on the new default
    /// device and keep playing instead of stopping. Buffers already scheduled
    /// on the old device are lost (a sub-second gap), and their late/missing
    /// completions are excluded from accounting via `bufferGeneration`.
    /// (Remote engine only: `AVSpeechSynthesizer` follows the device itself.)
    private func handleRouteChange() {
        guard playingMessageId != nil, currentUtterance == nil else { return }
        bufferGeneration += 1
        pendingBufferCount = 0
        Task { [weak self] in
            do {
                // `needsRebuild` was already flagged on the pipeline queue
                // ahead of this call, so this re-establishes the graph.
                try await self?.pipeline.prepareAndPlay()
            } catch {
                // Couldn't rebuild on the new device: end playback honestly
                // rather than leaving a Stop control over silence.
                self?.stop()
            }
        }
    }

    // MARK: - Playback

    private func startPlayback(text: String, messageId: UUID, voiceOverride: String? = nil) {
        let config = TTSConfigurationStore.load()
        switch config.provider {
        case .system:
            startSystemPlayback(text: text, voiceOverride: voiceOverride, config: config)
        case .openAICompatible:
            startRemotePlayback(
                text: text, messageId: messageId, voiceOverride: voiceOverride, config: config)
        }
    }

    private func startSystemPlayback(text: String, voiceOverride: String?, config: TTSConfiguration) {
        let trimmedOverride = voiceOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requested = (trimmedOverride?.isEmpty == false ? trimmedOverride! : config.voice)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SystemVoiceCatalog.voice(for: requested, text: text)
        utterance.rate = SystemVoiceCatalog.utteranceRate(multiplier: config.rate)
        currentUtterance = utterance
        // Activity log: local synthesis, one row per utterance (Intel's
        // stand-in for upstream's PocketTTS row).
        systemSpeechActivity = MediaActivityLogger.beginSpeech(
            text: text,
            model: "AVSpeechSynthesizer",
            voice: utterance.voice?.identifier ?? requested,
            provider: "macOS system voice",
            endpoint: nil,
            trigger: activeSpeakCallId != nil ? .speakTool : .readAloud
        )
        synthesizer.speak(utterance)
    }

    /// Delegate hop: end playback when the utterance we're waiting on ends.
    fileprivate func systemUtteranceEnded(_ utterance: ObjectIdentifier) {
        guard let current = currentUtterance, ObjectIdentifier(current) == utterance else { return }
        currentUtterance = nil
        systemSpeechActivity?.finish(audioSeconds: nil, error: nil)
        systemSpeechActivity = nil
        playingMessageId = nil
    }

    private func startRemotePlayback(
        text: String, messageId: UUID, voiceOverride: String?, config: TTSConfiguration
    ) {
        streamFinished = false
        pendingBufferCount = 0
        lastRemoteError = nil

        let trimmedOverride = voiceOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = (trimmedOverride?.isEmpty == false ? trimmedOverride! : config.remoteVoice)
        // Activity log: the text is about to leave this Mac for the TTS
        // provider. One Cloud row per utterance with the destination host.
        let activity = MediaActivityLogger.beginSpeech(
            text: text,
            model: config.remoteModel,
            voice: voice,
            provider: EgressInfo.host(from: config.remoteEndpoint) ?? L("OpenAI-compatible TTS"),
            endpoint: OpenAICompatibleTTSClient.resolvedEndpoint(config.remoteEndpoint),
            trigger: activeSpeakCallId != nil ? .speakTool : .readAloud
        )

        playbackTask = Task { [weak self] in
            // Keychain read is blocking XPC; a detached task keeps it off the
            // main actor (a plain `Task {}` here would inherit it).
            let apiKey = await Task.detached(priority: .userInitiated) {
                TTSRemoteAPIKeyStore.loadSync()
            }.value
            guard !Task.isCancelled else {
                activity.finish(audioSeconds: nil, error: nil, cancelled: true)
                return
            }
            let client = OpenAICompatibleTTSClient(
                endpoint: config.remoteEndpoint,
                model: config.remoteModel,
                voice: voice,
                speed: config.remoteSpeed,
                apiKey: apiKey
            )
            do {
                try await self?.pipeline.prepareAndPlay()
            } catch {
                self?.lastRemoteError = error.localizedDescription
                self?.playingMessageId = nil
                activity.finish(audioSeconds: nil, error: error.localizedDescription)
                return
            }
            guard !Task.isCancelled else {
                activity.finish(audioSeconds: nil, error: nil, cancelled: true)
                return
            }
            var sampleCount = 0
            do {
                let stream = try client.synthesizeStreaming(text: text)
                for try await samples in stream {
                    if Task.isCancelled { break }
                    sampleCount += samples.count
                    self?.schedule(samples: samples)
                }
                self?.markStreamFinished(for: messageId)
                activity.finish(audioSeconds: Double(sampleCount) / 24_000.0, error: nil, cancelled: Task.isCancelled)
            } catch is CancellationError {
                // stop() already cleared state
                activity.finish(audioSeconds: Double(sampleCount) / 24_000.0, error: nil, cancelled: true)
            } catch {
                activity.finish(audioSeconds: Double(sampleCount) / 24_000.0, error: error.localizedDescription)
                self?.handleRemoteStreamError(error, for: messageId)
            }
        }
    }

    private func handleRemoteStreamError(_ error: Error, for messageId: UUID) {
        TTSLogger.service.error(
            "Remote TTS synthesis failed: \(error.localizedDescription, privacy: .public)")
        lastRemoteError = error.localizedDescription
        if playingMessageId == messageId {
            stop()
        }
    }

    private func schedule(samples: [Float]) {
        // Incremented before handing off; the pipeline guarantees the
        // completion fires exactly once even when the buffer can't be built.
        pendingBufferCount += 1
        let generation = bufferGeneration
        pipeline.schedule(samples: samples) { [weak self] in
            Task { @MainActor [weak self] in
                self?.bufferDidFinish(generation: generation)
            }
        }
    }

    private func bufferDidFinish(generation: Int) {
        guard generation == bufferGeneration else { return }
        pendingBufferCount = max(0, pendingBufferCount - 1)
        if streamFinished, pendingBufferCount == 0 {
            playingMessageId = nil
            pipeline.stopPlayer()
        }
    }

    private func markStreamFinished(for messageId: UUID) {
        guard playingMessageId == messageId else { return }
        streamFinished = true
        if pendingBufferCount == 0 {
            playingMessageId = nil
            pipeline.stopPlayer()
        }
    }
}

extension TTSService: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in TTSService.shared.systemUtteranceEnded(id) }
    }

    nonisolated public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in TTSService.shared.systemUtteranceEnded(id) }
    }
}

/// Intel: the macOS system voices, for the TTS settings tab, the per-agent
/// voice picker and playback. Stands in for upstream's PocketTTS catalog.
public enum SystemVoiceCatalog {
    public struct Entry: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let language: String
        public let quality: String
    }

    /// Installed voices, the Mac's language first, then by language and name.
    public static func availableVoices() -> [Entry] {
        let preferred = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(preferred.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .map { voice in
                Entry(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    quality: qualityLabel(voice.quality)
                )
            }
            .sorted { lhs, rhs in
                let lRank = rank(lhs.language, preferred: preferred, prefix: prefix)
                let rRank = rank(rhs.language, preferred: preferred, prefix: prefix)
                if lRank != rRank { return lRank < rRank }
                if lhs.language != rhs.language { return lhs.language < rhs.language }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Menu label: "Samantha — English (United States)", plus quality.
    public static func displayName(for identifier: String) -> String {
        guard let voice = AVSpeechSynthesisVoice(identifier: identifier) else { return identifier }
        return label(name: voice.name, language: voice.language, quality: qualityLabel(voice.quality))
    }

    public static func label(for entry: Entry) -> String {
        label(name: entry.name, language: entry.language, quality: entry.quality)
    }

    /// The voice to use: a stored identifier when it is still installed,
    /// otherwise a voice for the text's language (the automatic setting),
    /// otherwise the system default (`nil`).
    public static func voice(for identifier: String, text: String) -> AVSpeechSynthesisVoice? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: trimmed) {
            return voice
        }
        if let language = dominantLanguage(of: text) {
            return AVSpeechSynthesisVoice(language: language)
        }
        return nil
    }

    /// BCP-47 language of `text` when it is confidently recognised.
    nonisolated public static func dominantLanguage(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(1_000)))
        guard let language = recognizer.dominantLanguage,
            let confidence = recognizer.languageHypotheses(withMaximum: 1)[language],
            confidence >= 0.5
        else { return nil }
        return language.rawValue
    }

    /// Map a 0.5×–2× multiplier onto `AVSpeechUtterance`'s rate scale,
    /// where the default rate is the midpoint.
    nonisolated public static func utteranceRate(multiplier: Double) -> Float {
        let clamped = min(2.0, max(0.5, multiplier))
        let base = Double(AVSpeechUtteranceDefaultSpeechRate)
        let rate: Double
        if clamped >= 1 {
            rate = base + (Double(AVSpeechUtteranceMaximumSpeechRate) - base) * (clamped - 1)
        } else {
            rate = base - (base - Double(AVSpeechUtteranceMinimumSpeechRate)) * (1 - clamped) * 2
        }
        return Float(rate)
    }

    private static func rank(_ language: String, preferred: String, prefix: String) -> Int {
        if language == preferred { return 0 }
        if language.hasPrefix(prefix) { return 1 }
        return 2
    }

    private static func label(name: String, language: String, quality: String) -> String {
        let languageName = Locale.current.localizedString(forIdentifier: language) ?? language
        let base = "\(name) — \(languageName)"
        return quality.isEmpty ? base : "\(base) (\(quality))"
    }

    private static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .enhanced: return L("Enhanced")
        case .premium: return L("Premium")
        default: return ""
        }
    }
}

/// Splits text into utterance-sized chunks for PocketTTS.
///
/// Intel: kept from upstream for parity (and its tests); Intel's engines
/// take whole replies, so nothing on Intel calls it yet.
///
/// PocketTTS carries a continuous decoder state for the length of a single
/// `synthesizeStreaming` call, and that state drifts audibly on long runs.
/// Synthesizing one chunk per call resets the decoder between chunks, which
/// keeps a long paste from degrading into slurred, slowed speech. Chunks are
/// built from sentence boundaries and packed up to `maxChars` so we reset
/// often enough to stay ahead of the drift without chopping prosody every few
/// words. FluidAudio still splits each chunk to its own token budget
/// internally; this only controls where the decoder state resets.
///
/// Newlines are handled deliberately: hard-wrapped prose (a paste whose lines
/// break every ~80 chars) must NOT split at each wrap, or the voice resets
/// mid-sentence. Only a blank line — a real paragraph break — is treated as a
/// boundary; single newlines inside a paragraph are folded to spaces so
/// sentence detection sees the reflowed text.
enum TTSTextChunker {
    /// Roughly a few seconds of speech per chunk — comfortably under the
    /// window where PocketTTS starts to drift, while long enough that sentence
    /// prosody is preserved.
    static let maxChars = 240

    static func split(_ text: String, maxChars: Int = TTSTextChunker.maxChars) -> [String] {
        var chunks: [String] = []
        var current = ""

        func flush() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            current = ""
        }

        for paragraph in paragraphs(in: text) {
            for sentence in sentences(in: paragraph) {
                if current.isEmpty {
                    current = sentence
                } else if current.count + 1 + sentence.count <= maxChars {
                    current += " " + sentence
                } else {
                    flush()
                    current = sentence
                }
                // A single sentence longer than the budget becomes its own
                // chunk; FluidAudio's internal chunker still splits it to fit.
                if current.count >= maxChars { flush() }
            }
            // A paragraph break is a natural reset point; never pack sentences
            // from two paragraphs into one chunk.
            flush()
        }
        return chunks
    }

    /// Split text into paragraphs on blank lines, folding the soft newlines
    /// inside each paragraph into spaces so wrapped prose reads as one flow.
    private static func paragraphs(in text: String) -> [String] {
        var result: [String] = []
        var lines: [String] = []
        func closeParagraph() {
            if !lines.isEmpty {
                result.append(lines.joined(separator: " "))
                lines = []
            }
        }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                closeParagraph()  // blank line = paragraph boundary
            } else {
                lines.append(line)
            }
        }
        closeParagraph()
        return result
    }

    /// Break a single paragraph into sentence-ish spans on `.`, `!`, and `?`,
    /// keeping the terminating punctuation with its sentence.
    private static func sentences(in paragraph: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in paragraph {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { result.append(piece) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }
}

extension Notification.Name {
    /// Posted when the user taps a speaker button but the TTS model isn't ready.
    /// The app should surface the TTS settings tab so they can download the model.
    /// (Intel's engines are always ready; the agent editor still posts it
    /// to open the Voice settings.)
    public static let openTTSSettingsRequested = Notification.Name("osaurus.openTTSSettingsRequested")

    /// Posted whenever `TTSService.playingMessageId` changes.
    /// AppKit views that can't observe `@Published` use this to refresh their speaker button icon.
    public static let ttsPlaybackStateChanged = Notification.Name("osaurus.ttsPlaybackStateChanged")
}
