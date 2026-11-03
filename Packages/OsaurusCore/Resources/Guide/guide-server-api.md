---
title: Server and API
summary: The local HTTP server on this Intel Mac — what it serves, access keys, and the command-line tool.
order: 110
---

# Server and API

Osaurus runs a local HTTP server that other apps on this Mac can use. On this Intel Mac it answers with your cloud models; there are no local models to serve.

## What it serves

- Base URL: `http://127.0.0.1:1337` (the `/v1` and `/api` prefixes are accepted too). It listens only on this Mac unless you turn on **Expose to Network** (below).
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
- `POST /memory/ingest` — load past conversation turns into an agent's memory (`agent_id`, `conversation_id`, `turns: [{user, assistant}]`). The reply says whether an episode was distilled; agents with memory distillation off keep only the transcript. Not for the Orchestrator.
- `GET /sessions` (filters: `q`, `agent_id`, `archived`, `pinned`, `project_id`, `limit`…), `GET` / `PATCH` / `DELETE /sessions/{id}`, `POST /sessions/{id}/truncate`, `GET /projects` — your chat history: list and search it, read a chat, rename, pin, archive or delete it, or cut it back to an earlier turn. Owner-only.
- `GET /models/picker`, `POST` / `PUT /models/options`, `PUT /models/favorites` — the composer's model picker: the models in its tabs, a model's Model Options (Thinking and the like), and hearting a model. Owner-only.
- `GET /credits/balance` — your Osaurus credit balance, for a usage dashboard or menu bar app. Needs your access key, or "Allow local API access without a key" in Credits.
- `POST /images/generations` — an image from an Osaurus Cloud or Venice image model. Name it with `target` (`/models/picker` lists each image model's target, options and starting price) and add `"allow_remote_media_spend": true`, since it spends credits or Venice money. `"stream": true` answers as events; `POST /images/cancel` with the event's `job_id` stops it.
- `POST /videos/quote`, then `POST /videos/generations` with the `quote_token` and `"allow_remote_media_spend": true` — a video from an Osaurus Cloud or Venice video model. Check it at `GET /videos/jobs/{id}` and download it from `GET /videos/jobs/{id}/content` once it's done.
- `GET /admin/cache-stats` — server diagnostics, including where Osaurus keeps its data (`storage_locations`). The on-device model caches it reports upstream are always empty here, as is `GET /admin/generation-settings`.
- `POST /completions` answers that raw completions need Apple silicon, and so do on-device image models (`/images/edits`, `/images/upscale`, a bare `model` name).

Not in this build yet: runs from your phone. Shortcuts and Siri run agents inside the app.

## Expose to Network

Settings → Server → Settings → Connection → **Expose to Network** lets phones, iPads and other computers on your network reach the server at your Mac's network address (the Server tab shows it). While it's on, every caller needs an access key, including apps on this Mac; Osaurus's own Shortcuts actions keep working. Turning on **Local Network Discovery** for an agent also turns this on. Updating to this version turned the switch off once if it was saved on, because earlier Intel builds never honoured it.

## Pair your iPhone

Settings → **Mobile** pairs the Osaurus iPhone app with this Mac. Turn on **Expose to Network** first (the page offers it), keep the iPhone on the same network, then **Generate Pairing Code** and type the 6-digit code into the app. One iPhone per Mac: pairing a new one unpairs the old one, and **Unpair** under **Paired iPhone** cuts it off at once. **Keep Mac Awake for Paired iPhone** stops idle sleep only while a phone is paired. Once paired, the iPhone reaches your agents, chats, approvals and models through an end-to-end encrypted channel; only sizes of those requests appear in Insights. A reply keeps going if the app goes to the background, and the iPhone picks it up where it left off when you come back, or stops it with its Stop button. On a voice call, the agent answers in a few spoken sentences. The iPhone can carry on any chat from this Mac: its messages and replies are added to that chat, and a chat started on the iPhone shows in History with an iPhone badge. While the iPhone is replying in a chat, a message you send to it on the Mac waits until the iPhone's reply is in. With **Continue Phone Chats on This Mac** on, the chat you used on the iPhone opens in front when you come back to the Mac. Images the iPhone asks for with a cloud image model keep generating if the app goes to the background, are never generated (or billed) twice for one request, and land in the chat they were asked from. Reaching the Mac away from home comes with the next step of this port.

## Access keys

Settings → Server → Access Keys: **Generate Key** creates an `osk-v1` key for callers when network exposure is on. The full key is shown once; Revoke takes effect immediately. Agent-scoped keys come from the agent's row in Settings → Identity.

Models from the Osaurus Router spend your credits, so another app on this Mac can only use them over the API with your access key (`Authorization: Bearer <key>`), or once you turn on **Allow local API access without a key** in Credits. Chats in the app aren't affected.

## Use with Codex CLI

Server → Overview → **Use with Codex CLI** sets up OpenAI's Codex CLI to use this Mac as its model provider. Pick one of the models shared in Server → Models, then **Copy** the two files, or write them with the Add to `~/.codex` button, and run `codex --profile osaurus`. Only an `osaurus` section of Codex's `config.toml` is touched, plus its own `osaurus.config.toml`. Osaurus Router models also need **Allow local API access without a key** in Credits, or an access key while Expose to Network is on.

## Command-line tool

Settings → Server → Command Line Tool installs the `osaurus` CLI (`osaurus status`, `osaurus serve`, `osaurus ui`, `osaurus version`).
