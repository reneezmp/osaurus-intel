---
title: Voice — Dictation and Text-to-Speech
summary: Chat voice input, Transcription Mode, wake word, and spoken replies with Apple Speech and macOS voices.
order: 130
---

# Voice

Voice input uses Apple Speech and spoken replies use the macOS system voices, so voice works without downloading any model.

## Setup and recognition

- Settings… (⌘,) → Voice. Tabs: **Setup**, **Chat Voice**, **Transcription**, **Text-to-Speech**, **Wake Word**, and **Recognition**.
- Setup: grant Microphone and Speech Recognition access, set the detection sensitivity, and test with the mic button.
- Recognition: choose the language. Recognition stays on this Mac by default; a language without on-device support shows as not ready unless you allow Apple's servers for it.
- Audio Input can also capture System Audio (needs Screen Recording permission; excludes Osaurus's own output).

## In chat

Turn on **Enable Voice Input** under Voice → Chat Voice, then tap the mic button. Stop behaviour (pause duration before auto-send, confirmation delay) and **Clean Up Transcription** live under Voice → Transcription. Cleanup uses the Core Model, a cloud model, and is off by default.

## Wake word

Off by default. Enable it under Voice → Wake Word to listen for a phrase and open that agent's chat with what follows.

## Dictation anywhere

Voice → Transcription → **Enable Transcription Mode** turns on system-wide dictation into any app via a global hotkey (needs Accessibility permission). An overlay shows Listening / Done; Esc cancels.

## Text-to-speech

- Voice → Text-to-Speech: enable, pick a voice (any macOS voice installed on this Mac, in any language), and Preview.
- Alternative under Advanced: an OpenAI-compatible TTS server (`/v1/audio/speech`) — endpoint, model, voice, speed, optional API key (Keychain).
- In chat, a speaker button appears on assistant replies when text-to-speech is on; agents can auto-speak, have their own voice, and be granted the Speak tool in Abilities.
- Dictation sessions and spoken replies are recorded in Settings → Insights (**Audio & Media** scope).
