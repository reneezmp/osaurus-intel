---
title: Server and API
summary: The local HTTP server on this Intel Mac — what it serves, access keys, and the command-line tool.
order: 110
---

# Server and API

Osaurus runs a local HTTP server that other apps on this Mac can use. On this Intel Mac it answers with your cloud models; there are no local models to serve.

## What it serves

- Base URL: `http://127.0.0.1:1337` (the `/v1` and `/api` prefixes are accepted too). It only listens on this Mac for now.
- `GET /health` — server status.
- `GET /models` (and Ollama's `GET /api/tags`) — the models you switched on in Server → **Models**. Remote models start hidden; turn on the ones apps should see.
- `POST /chat/completions` — OpenAI-style chat with any model you can chat with in the app, streamed or not. If the model wants to use a tool, the call is returned to the caller to run.
- `POST /responses` — the OpenAI Responses API, including `previous_response_id`.
- `POST /messages` — Anthropic-style messages (needs a provider that reports token counts).
- `POST /api/chat` and `POST /api/generate` — Ollama-style chat for apps that speak Ollama.
- `POST /embeddings` (and `/api/embed`) — vectors from the on-device `potion-base-8M` model.
- `POST /audio/transcriptions` — speech to text with Apple Speech.
- `GET /mcp/tools`, `POST /mcp/call` — Osaurus's tools for other apps (see the MCP topic).
- `GET /agents`, `GET /agents/{id}` — your agents, with their models and memory counts.
- `POST /agents`, `PATCH` / `DELETE /agents/{id}`, `PUT /agents/{id}/model` and the `/agents/{id}/tools` routes — create, edit and delete agents and set their tools. Only this Mac's owner can make these changes: a caller on this Mac, or the owner's own key.
- `POST /agents/{id}/dispatch` — start a background task for an agent; poll it at `GET /tasks/{id}` and stop it with `DELETE /tasks/{id}`. A task started from another device can't use tools set to Ask (nobody there can approve them); set those to Auto if it needs them.
- `POST /agents/{id}/run` (or `/agents/default/run` for the Orchestrator) — run an agent on this Mac and stream its answer, OpenAI-style. The agent uses its own model, prompt, memory and tools; `osaurus_agent_tool` chunks show each tool as it starts and finishes. Tools set to Ask are refused in runs (nobody is there to approve them); set them to Auto if the agent needs them.
- `GET /approvals`, `/config/approvals`, `/secrets/prompts`, `/computer-use/prompts` — the approval cards a run from your paired phone is waiting on, answered with `POST` to the same path plus the card's id. Owner-only. Empty in this build, since phone runs aren't here yet.
- `POST /completions` answers that raw completions need Apple silicon.

Not in this build yet: chat sessions, images and video, and runs from your phone. Shortcuts and Siri run agents inside the app.

## Access keys

Settings → Server → Access Keys: **Generate Key** creates an `osk-v1` key for callers when network exposure is on. The full key is shown once; Revoke takes effect immediately. Agent-scoped keys come from the agent's row in Settings → Identity.

## Command-line tool

Settings → Server → Command Line Tool installs the `osaurus` CLI (`osaurus status`, `osaurus serve`, `osaurus ui`, `osaurus version`).
