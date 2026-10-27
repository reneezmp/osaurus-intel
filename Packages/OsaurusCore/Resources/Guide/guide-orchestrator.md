---
title: The Orchestrator
summary: The built-in agent — what it can configure, how delegation works, and its limits on this Mac.
order: 45
---

# The Orchestrator

The Orchestrator is the built-in agent new chats open with. It explains Osaurus, finds settings, applies a small set of configuration changes after you approve them, and hands bounded tasks to the custom agents you allow.

## What it can do

- **Answer questions about Osaurus** from this guide (`osaurus_help`: `topics`, `read`, `find`). `find` searches the same catalog as the Settings search and returns the exact path to quote.
- **Configure itself** with `orchestrator_config`: only the Orchestrator's own settings (`default_agent`), delegation, and which agent new chats open with (`new_chat_agent`). Every change is shown as an exact before-and-after plan and applied only after you approve it. Its `find_setting` operation also locates any setting.
- **Delegate** with `orchestrator_delegate`: one fresh, standalone, tool-free, single-turn task for an allowed custom agent, bounded by input, output, token, and time limits, cancellable, and returned as text in the chat. It never creates a child chat, file, background task, or nested delegation.
- **Check targets** with `orchestrator_targets`: the live list of agents it may delegate to, with the reason any allowed agent is not currently available.

## Other tools and limits

Its configuration and delegation tools belong to it alone. It can also use the general tools a chat offers it — the folder tools when the chat has a working folder, and whatever is enabled for it in the Tools settings — but it has no knowledge collections or private database. For longer hands-on work, a custom agent set up for the job is the better fit. It doesn't change settings outside `orchestrator_config`: it finds them and tells you the exact path.

## Delegation targets

Settings → Orchestrator → Delegation: turn delegation on and choose which custom agents it may use. An agent is a target only when it is allowed and its exact model is admitted and available; `orchestrator_targets` reports any mismatch.

## Its settings

Settings → Orchestrator: Identity (name and instructions), Generation (model, temperature, max output tokens — inherited from General until overridden), Delegation, and Declarative Configuration (the reviewed JSON plan flow `orchestrator_config` uses).
