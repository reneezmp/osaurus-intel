---
title: Troubleshooting and Support
summary: Quick fixes, diagnostics, and where to get help.
order: 180
---

# Troubleshooting and Support

## Quick checks

- No reply or an error in chat: open the provider's card under Settings → Cloud Models for the exact message, re-check its key or sign-in, and check your Credits balance if the model is on Osaurus Cloud.
- Asked for a feature this Mac doesn't have: see "What runs on this Intel Mac".
- Tools not being used: make sure the agent's tools are on (Abilities → Overview → Tools) and the tool is enabled under Abilities → Tools, and use a model with good tool calling.
- New skill, plugin, or MCP tools not appearing mid-chat: start a new chat.
- Memory isn't learning: distillation is off by default per agent and needs a Core Model (Settings → Memory → Diagnostics).
- Port already in use: change the server port in Settings → Server; pick one above 1024.
- Permission prompts (Microphone, Speech Recognition, Accessibility, Screen Recording, Full Disk Access): grant them in macOS System Settings → Privacy & Security, then retry.
- A data store won't open: Settings → General → Advanced → Data & Storage → Stores needing attention → Retry or Reset (Reset quarantines the file, never deletes it).

## Diagnostics

- Settings → Insights: the activity log of model requests, web searches, URL fetches, MCP calls, Router calls, inbound API requests, and plugin calls, with Local/Cloud badges, filters, Verify, and Export. Open a row's Overview for the plain-language summary and any error.
- Settings → Memory → Diagnostics for the memory store.
- CLI: `osaurus status`.

## Getting help

- Ask the Orchestrator — it can read this guide and find any setting.
- This Intel build is maintained separately from the main Osaurus app: report problems with it to its maintainer rather than to the main Osaurus project.
