---
title: Server and API
summary: The local HTTP server on this Intel Mac — what it serves, access keys, and the command-line tool.
order: 110
---

# Server and API

Osaurus runs a small local HTTP server. On this Intel Mac it is a developer surface, not the full API of the Apple Silicon app: there is no local model to serve, and most upstream routes aren't in this build.

## What it serves

- Base URL: `http://127.0.0.1:1337` (the `/v1` prefix is accepted too). Port and network exposure are set in Settings → Server.
- `GET /health` — server status.
- `GET /models` — the hosted DeepSeek models the proxy below accepts.
- `POST /chat/completions` — forwarded to DeepSeek's API, and only when Osaurus was started with a `DEEPSEEK_API_KEY` environment variable. It doesn't use your providers, agents, tools, or memory.
- `POST /mcp` — an MCP endpoint with test tools only; Osaurus doesn't expose its own tools to other apps on this Mac.

Not in this build: chat with any configured model, `/responses`, Anthropic- and Ollama-style routes, embeddings, audio, `/agents/*` runs, tasks, and `/mcp/tools` / `/mcp/call`. The Server tab's endpoint list still shows some of these; they answer with an error. Shortcuts and Siri run agents inside the app instead.

## Access keys

Settings → Server → Access Keys: **Generate Key** creates an `osk-v1` key for callers when network exposure is on. The full key is shown once; Revoke takes effect immediately. Agent-scoped keys come from the agent's row in Settings → Identity.

## Command-line tool

Settings → Server → Command Line Tool installs the `osaurus` CLI (`osaurus status`, `osaurus serve`, `osaurus ui`, `osaurus version`).
