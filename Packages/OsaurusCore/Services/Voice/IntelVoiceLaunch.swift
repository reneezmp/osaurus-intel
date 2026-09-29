//
//  IntelVoiceLaunch.swift
//  osaurus
//
//  Intel: the voice launch hooks upstream keeps in its `AppDelegate`
//  (speech auto-load, VAD Mode, Transcription Mode, voice notifications,
//  quit teardown). Intel's AppDelegate is a trimmed rewrite, so they live
//  here and `AppDelegate` calls `IntelVoiceLaunch.start()` /
//  `IntelVoiceLaunch.shutdown()`. See docs/VOICE_INTEL.md.
//
//  VAD Mode follows upstream's rule: it listens only while no chat window is
//  open. A chat window becoming key pauses it (the chat's microphone must
//  not compete with it); closing the last chat window resumes it.
//

import AVFoundation
import AppKit
import Foundation
import os
import Speech

@MainActor
enum IntelVoiceLaunch {
    private static let log = Logger(subsystem: "ai.osaurus", category: "voice.launch")
    private static var observers: [NSObjectProtocol] = []
    private static var started = false

    /// Called once from `applicationDidFinishLaunching`.
    static func start(openVoiceSettings: @escaping @MainActor (_ subTab: String?) -> Void) {
        guard !started, !RuntimeEnvironment.isUnderTests else { return }
        started = true

        // Prepare Apple Speech for the chosen language when access was
        // already granted (never prompts at launch).
        Task { @MainActor in
            await SpeechModelManager.shared.refreshDiskStateInBackground()
            await SpeechService.shared.autoLoadIfNeeded()
            startVADIfConfigured()
        }

        TranscriptionModeService.shared.initialize()

        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: .vadAgentDetected, object: nil, queue: .main) { note in
                guard let detection = note.object as? VADDetectionResult else { return }
                Task { @MainActor in handleAgentDetected(detection) }
            })
        observers.append(
            center.addObserver(forName: .openTTSSettingsRequested, object: nil, queue: .main) { _ in
                Task { @MainActor in openVoiceSettings(VoiceTab.textToSpeech.rawValue) }
            })
        observers.append(
            center.addObserver(forName: NSNotification.Name("ShowVoiceSettings"), object: nil, queue: .main) {
                _ in
                Task { @MainActor in openVoiceSettings(nil) }
            })
        observers.append(
            center.addObserver(forName: .chatViewClosed, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    // Only once the last chat window is gone.
                    guard !ChatWindowManager.shared.hasVisibleWindows else { return }
                    await VADService.shared.resumeAfterChat()
                }
            })
    }

    /// Upstream's `initializeVADService`: start VAD at launch when it's on,
    /// has agents, and the microphone is already allowed — and, on Intel,
    /// when no chat window is open (it starts later, when the last closes).
    private static func startVADIfConfigured() {
        let config = VADConfigurationStore.load()
        guard config.vadModeEnabled,
            !config.enabledAgentIds.isEmpty || !config.customWakePhrase.isEmpty
        else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            log.info("VAD auto-start skipped — microphone not authorized yet")
            return
        }
        guard SpeechService.shared.isModelLoaded else {
            log.info("VAD auto-start skipped — speech recognition not ready")
            return
        }
        guard !ChatWindowManager.shared.hasVisibleWindows else {
            log.info("VAD waits — a chat window is open")
            return
        }
        Task { @MainActor in
            do {
                try await VADService.shared.start()
            } catch {
                log.error("VAD start failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Upstream's `handleVADAgentDetected`: focus or open the agent's chat,
    /// hand the microphone over, and start voice input when configured.
    private static func handleAgentDetected(_ detection: VADDetectionResult) {
        let manager = ChatWindowManager.shared
        let targetWindowId: UUID
        if let existing = manager.findWindows(byAgentId: detection.agentId).first {
            manager.showWindow(id: existing.id)
            targetWindowId = existing.id
        } else {
            targetWindowId = manager.createWindow(agentId: detection.agentId)
        }
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor in
            await VADService.shared.pause()
            if VADConfigurationStore.load().autoStartVoiceInput {
                try? await Task.sleep(nanoseconds: 200_000_000)
                NotificationCenter.default.post(name: .startVoiceInputInChat, object: targetWindowId)
            }
            NotificationCenter.default.post(name: .chatOverlayActivated, object: nil)
        }
    }

    /// Upstream's quit-path audio teardown: nothing keeps the microphone or
    /// playback running through the quit window.
    static func shutdown() async {
        TTSService.shared.stop()
        await VADService.shared.stop()
        if SpeechService.shared.isRecording {
            _ = await SpeechService.shared.stopStreamingTranscription(force: true)
        }
        SpeechService.shared.unloadModel()
    }
}
