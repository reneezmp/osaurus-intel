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
- **Subagents** (`spawn_agent`). The Orchestrator can delegate one bounded, tool-free task at a time to an allowed custom agent instead (see The Orchestrator topic).
- **Runtimes in config documents and `osaurus import` bundles.** Agent runtimes themselves are here (Settings → Agents → Runtimes); the declarative `harness_runtimes` / `runtime` keys and bundle items are not yet. Agent templates are here (Agents → Templates) except the first-run setup wizard and the template share-to-store flows.
- **Some declarative configuration sections.** The Orchestrator's `osaurus_config` (and the loopback-only `/admin/config/*` routes, whose apply always waits for your approval in the app) covers memory, the Orchestrator and custom agents (including which runtime an agent runs on), harness runtimes, tools, MCP servers, plugins, cloud providers, search providers, schedules, watchers, commands and its delegation list. Channels, local models, agent skills, knowledge switches and sandbox network keys are not available on this build. Agent templates work through `template`, `overrides` and `save_as`.
- **Skill import from GitHub, Claude plugin import**, and skill zip import/export. Skills can be created, edited, and imported from a file.
- **The Privacy Filter**, usage analytics, and crash reporting (this build sends neither).
- **Osaurus as an MCP server for other apps.** The local server's `/mcp` endpoint only offers test tools.
- **Most of the local HTTP API.** The server answers `/health`, `/models`, `/chat/completions` (forwarded to DeepSeek with your DeepSeek key), and `/mcp`; see the Server and API topic.

## What works the same

Chat with folder tools and file history, the Orchestrator, custom agents, memory, knowledge collections, web search, MCP connectors, skills, slash commands, native plugins built for Intel, schedules, watchers, the agent database and self-scheduling, voice (Apple Speech and macOS voices), cloud images and video, Mac Automation with AppleScript (on the chat's cloud model), Browser Use (on macOS 13 all agents share one browser profile), Computer Use with its opt-in screen context, themes, credits, identity, Insights, Shortcuts and Siri.
