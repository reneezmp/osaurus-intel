---
title: What runs on this Intel Mac
summary: Which Osaurus features this Intel build has, which it doesn't, and what to use instead.
order: 12
---

# What runs on this Intel Mac

This build of Osaurus is for Intel Macs. Most of Osaurus works the same; the features below need Apple Silicon or haven't been brought to Intel yet. When someone asks for one of them, say plainly that this Mac's Osaurus doesn't have it and offer the alternative.

## Not available (needs Apple Silicon)

- **Local models** (MLX downloads, on-device inference, speculative decoding, the Local Models tab). Use Osaurus Cloud, a cloud provider, or Claude Code instead.
- **Sandbox** (the Linux container for running code). Agents with a working folder run shell commands on the Mac itself, with approval.
- **Local image and video generation.** Cloud images and video work (Osaurus Cloud or Venice); see the Images and Video topic.

## Not in this build yet

- **Agent Channels** (Slack, Discord, Telegram, WhatsApp, iMessage, webhooks).
- **Workspaces and shared agents**, peer devices, and pairing a phone or another Mac.
- **Computer Use and Browser Use.**
- **Subagents** (`spawn_agent`). The Orchestrator can delegate one bounded, tool-free task at a time to an allowed custom agent instead (see The Orchestrator topic).
- **Agent templates, harness runtimes, and `osaurus import` bundles.**
- **Full declarative configuration.** The Orchestrator's `orchestrator_config` covers only its own settings, delegation, and which agent new chats open with.
- **Skill import from GitHub, Claude plugin import**, and skill zip import/export. Skills can be created, edited, and imported from a file.
- **The Privacy Filter**, usage analytics, and crash reporting (this build sends neither).
- **Osaurus as an MCP server for other apps.** The local server's `/mcp` endpoint only offers test tools.
- **Most of the local HTTP API.** The server answers `/health`, `/models`, `/chat/completions` (forwarded to DeepSeek with your DeepSeek key), and `/mcp`; see the Server and API topic.

## What works the same

Chat with folder tools and file history, the Orchestrator, custom agents, memory, knowledge collections, web search, MCP connectors, skills, slash commands, native plugins built for Intel, schedules, watchers, the agent database and self-scheduling, voice (Apple Speech and macOS voices), cloud images and video, themes, credits, identity, Insights, Shortcuts and Siri.
