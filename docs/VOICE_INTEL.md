# Voice on Intel

Status: **shipped 2026-09-29**, awaiting Rosy (checklist:
[`ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`](ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md#voice)).
Backlog id: `W-voice` in [`INTEL_MISSING_FEATURES_BACKLOG.md`](INTEL_MISSING_FEATURES_BACKLOG.md).

Upstream's voice features run on FluidAudio (Parakeet speech recognition,
Silero voice detection and PocketTTS speech, all CoreML on Apple Silicon).
That made Voice look "Apple-Silicon-only", but only the **engines** are. Intel
keeps upstream's whole voice feature set and UI and swaps the engines for
macOS ones:

| Upstream (FluidAudio) | Intel |
|---|---|
| Parakeet TDT speech recognition | Apple Speech (`SFSpeechRecognizer`), one request per stretch of speech |
| Silero VAD (speech detection) | Loudness detector on the same audio (`VoiceSensitivity.energyThreshold`) |
| Parakeet model downloads (Models tab) | Recognition tab: Speech Recognition access, language, Apple-servers opt-in |
| PocketTTS (on-device TTS, English only) | macOS system voices (`AVSpeechSynthesizer`), any installed language |
| OpenAI-compatible TTS server | Same (upstream client and audio pipeline, unchanged) |
| Transcript cleanup on the local core model | Same prompt and guards on Intel's remote Core Model — **off by default** |

Everything else is upstream code: chat microphone and voice overlay, Transcription
Mode (global dictation hotkey, paste into any app), VAD Mode (wake word opens
the agent's chat), audio device and system-audio input, the speaker button,
auto-speak, the per-agent voice, and the `speak` tool.

## Where things live

- `Managers/SpeechService.swift` — upstream's capture layer (input devices,
  ScreenCaptureKit system audio, engine recovery, level meter) plus the Intel
  `TranscriptionWorker` (segmenting + Apple Speech) and `AppleSpeechSegment`
  (one recognition request; `finish` is idempotent and time-bounded).
- `Managers/Model/SpeechModelManager.swift` — Intel: languages instead of
  models. "Downloaded" means *usable*: access granted and the language runs on
  this Mac (or Apple's servers are allowed). The upstream-shaped surface
  (`selectedModel`, `downloadedModelsCount`) is what the chat mic, Transcription
  Mode and VAD Mode check.
- `Managers/TTSService.swift` — Intel engines; `SystemVoiceCatalog`.
- `Services/Voice/TranscriptionCleanupService.swift` — Intel generator via
  `ChatEngine` and the Core Model (same resolution as other Intel one-shot calls).
- `Services/Voice/IntelVoiceLaunch.swift` — the launch hooks upstream keeps in
  its AppDelegate (Intel's AppDelegate is a trimmed rewrite).
- `Views/Voice/*` — upstream views; Intel edits are marked `Intel:`.
- Settings files: `~/.osaurus*/voice/{speech,tts,vad,transcription}.json`.
  The TTS server API key is in the Keychain (`ai.osaurus.tts.remote`).

## Privacy rules (decisions)

- **Recognition stays on this Mac by default.** A language without on-device
  support shows as not ready until the user turns on *Use Apple's servers when
  needed* (Recognition tab, off by default). With it on, the setup screen says
  speech is sent to Apple.
- **VAD Mode never uses Apple's servers.** An always-on microphone may only
  run with on-device recognition; `VADService.start` refuses otherwise
  (`VADError.needsOnDeviceRecognition`), and the VAD tab lists it as a setup
  requirement.
- **Transcript cleanup is opt-in** (`postProcessTranscription` defaults to
  `false` on Intel; upstream defaults to `true`). On Intel it is a paid call
  that sends every transcript to the Core Model's provider; the setting's text
  says so. An upstream `speech.json` with an explicit `true` is kept.
- The speech-recognition prompt is never raised at launch:
  `autoLoadIfNeeded` only prepares Apple Speech when access was already
  granted. The first prompt comes from the Voice tab or the first mic use.
- `NSSpeechRecognitionUsageDescription` is in `App/osaurus/Info.plist` and the
  project's build settings. **Without it macOS terminates the app** the moment
  it asks for Speech Recognition access — keep it in any new target.

## VAD Mode and chat windows

Upstream pauses VAD whenever the chat is shown and resumes when it closes;
the chat microphone takes over the running audio engine after a wake word.
Intel follows the same rule, adapted to Intel's persistent chat windows:

- A chat window becoming key pauses VAD (`ChatWindowManager.windowDidBecomeKey`).
- Closing the last chat window resumes it (`.chatViewClosed` →
  `IntelVoiceLaunch`).
- At launch VAD only starts when no chat window is open.
- `FloatingInputCard` never adopts VAD's wake-word recording as chat input
  (it would otherwise auto-send what VAD heard).

So VAD Mode is a "no chat open" feature on Intel, as upstream's is a "chat
overlay closed" feature.

## `speak` tool

Registered with the agent-loop tools but granted by the agent's **Speak Tool**
switch (Agents → Abilities → Output, custom agents only, off by default;
upstream `AgentSettings.speakEnabled`). It bypasses the Tools-tab allowlist in
the composer and in `runtimeCapabilityDenial`, like other ability switches.
`CloudChatEngine` now binds `ChatExecutionContext.currentToolCallId` around each
tool call and `ChatView` binds `currentAssistantTurnId` around the stream, so
`speak` ties its playback to the reply and the tool row's spinner.

## Known gaps / Rosy checks

- **On-device recognition on Intel Macs is unverified.** The dev host is
  Apple Silicon, where `supportsOnDeviceRecognition` reflects the host, not an
  Intel Mac. Rosy must record which languages report "On this Mac". If none
  do, voice still works with the Apple-servers opt-in, and VAD Mode stays off.
- Recognition quality and latency differ from Parakeet; the loudness detector
  is cruder than Silero in noise (the Sensitivity setting picks the threshold).
- Upstream's direct-audio path for local omni models
  (`LiveVoiceAudioInputRegistry`, MLX pre-encoding) stays excluded: Intel
  sends models text.
- Not covered by automated tests: microphone capture, recognition, playback,
  the hotkey paste, VAD wake words (all hardware/TCC). Tests cover settings,
  language matching, voice helpers, cleanup, the Speak Tool gate and the tab.
