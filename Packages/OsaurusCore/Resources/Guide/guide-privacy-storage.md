---
title: Privacy, Storage, and Encryption
summary: What leaves your Mac, where data lives, encryption, backups, and secrets.
order: 170
---

# Privacy, Storage, and Encryption

Chats, memory, agents, and settings all live under `~/.osaurus/` on your Mac.

## What leaves your Mac

- Each chat turn goes to the model provider serving it (Osaurus Cloud, a provider you connected, or Claude Code's service). Memory distillation and transcript cleanup use the Core Model, also a cloud model, and only when you turn them on.
- Web search and URL fetches go to the search provider; MCP tools go to their servers.
- This build sends no usage analytics and no crash reports, and has no Privacy Filter.
- To see exactly what left, open Settings → Insights: every model request, web search, URL fetch, MCP call and Router call is logged with a Local/Cloud badge, destination, and bytes. Retention and whether prompt/response bodies are stored: Settings → General → Advanced → Data & Storage → Activity Log. See the Insights topic.

## Storage layout

`~/.osaurus/chat-history/history.sqlite` (chats), `memory/memory.sqlite`, `agents/<uuid>/db.sqlite`, `activity/activity.sqlite` (the Insights log), `knowledge/`, `skills/`, `themes/`, `config/*.json`, and attachments as content-addressed blobs.

## Encryption

Every Osaurus database is encrypted at rest with SQLCipher, using a storage key kept in this Mac's Keychain. Settings → General → Advanced → Data & Storage can rotate the key. Losing the key means losing the data, so keep a backup.

## Backup and recovery

- Data & Storage → **Export plaintext backup** copies databases, attachments, and config to a folder you choose, decrypted. Do this before a macOS reinstall or moving to another Mac.
- **Stores needing attention** lists stores that failed to open, with Retry / Reset; Reset quarantines the file under `~/.osaurus/quarantine/` — nothing is deleted.
- Data & Storage → **File History** sets how long chat file-change snapshots are kept.

## Secrets

API keys and tokens are stored in the macOS Keychain, never in JSON config, and never pass through chat text.
