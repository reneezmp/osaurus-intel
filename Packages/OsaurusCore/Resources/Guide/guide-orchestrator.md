---
title: The Orchestrator
summary: The built-in agent — what it can configure, how delegation works, and its limits on this Mac.
order: 45
---

# The Orchestrator

The Orchestrator is the built-in agent new chats open with. It explains Osaurus, finds settings, applies a small set of configuration changes after you approve them, and hands bounded tasks to the custom agents you allow.

## What it can do

- **Answer questions about Osaurus** from this guide (`osaurus_help`: `topics`, `read`, `find`). `find` searches the same catalog as the Settings search and returns the exact path to quote.
- **Read what is configured** with `osaurus_inspect`: `status` for a snapshot (including whether delegation is ready), then `list` or `describe` with a scope such as agents, providers, plugins, schedules or the delegation section. It only reads, and it never shows API keys or other secrets.
- **Configure Osaurus** with `osaurus_config`: one YAML document (`schema`, `export`, `plan`, `apply`) covering memory, itself (`default_agent`), custom agents, tools, MCP servers, plugins, cloud providers, search providers, schedules, watchers, commands, which agent new chats open with (`new_chat_agent`), and `delegation.spawnable_agents` (the custom agents it may delegate to). Every apply is shown as a plan in a **Review configuration changes** window and applied only after you approve it (the Declarative Configuration topic has the details); it never admits a cloud model, enables Expose to Network, or takes an API key in text (a provider key goes through a secure sheet). Use `osaurus_help` `find` to locate any setting it cannot change.
- **Delegate to an agent** with `spawn_agent` when you have allowed an agent and admitted its cloud model: the agent runs as its own chat with its own tools, within the budgets in Settings → Orchestrator, and returns a short result and a session id. You approve each run (Ask by default), and it uses your cloud account. Creating an agent does not make it delegable; you add it to the allowed list (or approve a `delegation.spawnable_agents` change).
- **Delegate a quick text task** with `orchestrator_delegate` (used when `spawn_agent` is not available): one fresh, standalone, tool-free, single-turn task for an allowed custom agent, bounded by input, output, token, and time limits, cancellable, and returned as text in the chat. It never creates a child chat, file, background task, or nested delegation.
- **Check targets** with `orchestrator_targets`: the live list of agents it may delegate to, with the reason any allowed agent is not currently available.

## Other tools and limits

Its configuration and delegation tools belong to it alone. It can also use the general tools a chat offers it — the folder tools when the chat has a working folder, and whatever is enabled for it in the Tools settings — but it has no knowledge collections or private database. For longer hands-on work, a custom agent set up for the job is the better fit. It doesn't change settings outside `osaurus_config`: it finds them and tells you the exact path.

## Delegation targets

Settings → Orchestrator → Delegation: turn delegation on and choose which custom agents it may use. An agent is a target only when it is allowed and its exact model is admitted and available; `orchestrator_targets` reports any mismatch.

## Its settings

Settings → Orchestrator: Identity (name and instructions), Generation (model, temperature, max output tokens — inherited from General until overridden), Delegation, and Declarative Configuration (a reviewed JSON plan sheet for the Orchestrator's own settings, delegation and new-chat agent).
