---
title: Getting Started with Osaurus
summary: What this Osaurus build is, its requirements, and how to find your way around.
order: 10
---

# Getting Started with Osaurus

Osaurus is a macOS AI app: agents, memory, tools, and identity that live on your Mac. This is the Intel build of Osaurus, for Intel (x86_64) Macs. Your chats, memory, agents, and settings stay on your Mac; the model itself runs in the cloud — Osaurus Cloud, a provider you connect, or Claude Code — because local models need Apple Silicon. See the "What runs on this Intel Mac" topic for the full list of differences.

## Requirements

- An Intel Mac running macOS 13 Ventura or newer.
- A brain for your agents: Osaurus Cloud (hosted models with a welcome credit), an API key or sign-in for a cloud provider, or a signed-in Claude Code CLI.

## Finding your way around

- Chat window: global hotkey (default ⌘;), the Dock icon, or the menu bar icon.
- Settings… (⌘,) opens the Management window. Its sidebar groups: **General** (General, Conversation, Voice, Themes, Credits, Identity, Permissions), **Models** (Cloud Models), **Agents** (Orchestrator, Agents), **Capabilities** (Web Search, Knowledge, Memory, Tools & MCP, Skills, Commands, Plugins), **Automation** (Schedules, Watchers), **Developer Tools** (Server, Insights). Local Models and Sandbox are listed under "Not Available on This Mac". Type a setting name in the sidebar search to jump to it.

## First steps

1. On first launch, onboarding helps you create your first agent and give it a brain (Osaurus Cloud, a provider, Claude Code, or a custom endpoint).
2. Open chat and talk to the built-in Orchestrator — it explains Osaurus, finds settings for you, applies a small set of configuration changes after you approve them, and can hand bounded tasks to the custom agents you allow.
3. Create custom agents (Settings → Agents) for real work: coding, research, files, the web — each with its own prompt, model, tools, memory, and theme.

## Where data lives

Everything is stored locally under `~/.osaurus/` (chats, memory, agents, config), encrypted at rest. API keys live in the macOS Keychain. Prompts go to the model provider you chose for that chat; nothing else leaves your Mac unless you enable it (for example web search or network exposure of the local server).
