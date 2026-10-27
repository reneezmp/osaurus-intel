---
title: Cloud Models and Providers
summary: Osaurus Cloud, connecting OpenAI, Anthropic, Gemini, xAI, OpenRouter, DeepSeek and others, Claude Code, and custom endpoints.
order: 30
---

# Cloud Models and Providers

On this Intel Mac every model runs in the cloud. Your context, memory, and agents stay on your Mac whichever provider serves the model; only the request for that turn goes to the provider.

## Osaurus Cloud

Osaurus Cloud is the managed Osaurus Router: hosted models billed from your Credits, with a one-time welcome credit for new installs. It is tied to your Osaurus identity; balance, usage, and top-ups are under Settings → Credits. Hosted models appear in the model picker under Osaurus Cloud and in the Cloud model browser.

## Adding a provider

- Settings… (⌘,) → Cloud Models → **Add Provider** → choose a provider → follow its connect screen → Save.
- Providers include OpenAI, Anthropic, Google (Gemini), xAI (Grok), OpenRouter, DeepSeek, Mistral, Fireworks AI, MiniMax, Venice AI, Azure OpenAI, Ollama, and a custom OpenAI-compatible endpoint.
- Sign-in instead of a key: ChatGPT Plus/Pro (OpenAI Codex), OpenRouter (mints a key in your browser), and Grok (SuperGrok or X Premium+).
- Keys and tokens are stored in the macOS Keychain and never pass through chat text. Non-secret settings are in `~/.osaurus/providers/remote.json`.

## Claude Code

If the Claude Code CLI is installed and signed in, Osaurus can use it as a model: Settings → Cloud Models → Claude Code. Its models appear in the picker as Claude Code (Sonnet / Opus / Haiku). Credentials stay with the CLI.

## Local servers as providers

- Ollama: add a custom provider at `http://localhost:11434/v1` (no key needed on localhost).
- LM Studio: `http://localhost:1234/v1` (start its server first).

## Using remote models

- The chat model picker groups each provider's models under the provider name; star favourites to keep them in the shortlist.
- Models with options (reasoning effort, thinking on/off) show an options column when selected.
- Each connected provider's card shows its connection state and model count; open it to edit, re-enter a key, or see the exact error.
