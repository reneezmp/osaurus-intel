---
title: Settings Overview
summary: Where the settings live in this build, which ones the assistant can change for you, and which names are different controls.
order: 120
---

# Settings Overview

Settings… (⌘,) opens the Management window. Type a name in the sidebar search to jump to a control. The built-in assistant uses the same catalog through `osaurus_help` `{action: find}`: it quotes a breadcrumb instead of inventing a path.

Ask the assistant to change declarative settings in chat (`osaurus_config`); every change shows a plan in a **Review configuration changes** window first, and nothing is applied until you approve it (see the Declarative Configuration topic).

## Management sidebar

General (General, Conversation, Voice, Themes, Credits, Identity, Permissions), Models (Cloud Models), Agents (Orchestrator, Agents), Capabilities (Web Search, Knowledge, Memory, Tools & MCP, Skills, Commands, Plugins), Automation (Schedules, Watchers), Developer Tools (Server, Insights). Local Models and Sandbox are listed under "Not Available on This Mac".

## What the assistant can change in chat

- The Orchestrator itself: display name, model, temperature, max output tokens, persona.
- Memory: enabled, token budget, retention days.
- Agents: create and update custom agents, their capability toggles, which agent new chats open with (`new_chat_agent`), and which built-in Apple apps an agent may use (`capabilities.apple_apps`). The Orchestrator never calls the Apple app tools itself; ask it to "give Planner access to Calendar" and it patches that custom agent.
- Tools: global enablement and permission policies.
- Delegation: which custom agents the Orchestrator may delegate to (`delegation.spawnable_agents`).
- Also: MCP servers, plugins, cloud providers (a provider key goes through a secure sheet, never chat), web-search providers, slash commands, knowledge collections, schedules and watchers.

## What lives only in the Settings UI

- **Server**: Server URL, Access Keys, API endpoints and **Expose to Network** (off by default; the assistant never turns it on, because it opens this Mac to the local network). Port and exposure changes restart the server.
- **Orchestrator**: System Prompt (identity), Generation (model, temperature, **Max Output Tokens**, inherited from General until overridden), **Delegation** (turn it on, choose the allowed custom agents, **Add all agents**), and **Declarative Configuration** (a reviewed JSON plan sheet). Which cloud models the Orchestrator may delegate to, its permission modes and child limits are Settings-only.
- **Conversation**: Smooth Streaming, Group Thinking & Tool Activity, Check Spelling While Typing, Automatically Name Chats, Suggest Follow-Up Questions, Clipboard Monitoring, Collapse Long Pastes, Keep Mac Awake, and under Advanced the Top P Override and Max Tool Attempts. Long chats compact automatically near the context limit, and on demand with **Compact conversation** in the chat's context budget popover or the `/compact` command.
- **General**: Global Hotkey, Start at Login, Hide Dock Icon, Beta Updates, Core Model (the model used for background jobs such as chat titles and memory distillation), Notifications (toasts), and under Advanced the Max Concurrent Tasks, **Data & Storage** (encryption key and backup, **Keep File History** and its size limit, **Keep Activity History**). **Factory Reset…** sits at the very bottom.
- **Themes**: the gallery, the editor and import/export. **Small body** under Text & Fonts sets the font size of compact controls.
- **Permissions**: macOS permission grants (Accessibility, Automation, …). Tool Auto / Ask / Deny policies and **Auto-Allow All Tool Calls** live under Tools & MCP → All Tools.
- **Tools & MCP**: **Services** (connected MCP services, **Add Service**, the **Directory**), **All Tools**, and **Plugins**.
- **Browser Use**: saved browser sessions (open, close, reset); the per-agent switch is under Agents → Abilities (see the Browser Use and Mac Automation topic).
- Identity (master address, recovery phrase), Credits, and Insights are their own tabs.
- Secrets of any kind (API keys, tokens) are always entered in native secure fields, never in chat.

## Common names that are different controls

| You might say | Actual control | Path |
|---|---|---|
| Memory budget / token budget (memories) | Memory Budget | Settings… (⌘,) → Memory |
| Max tokens (reply length) | Max Output Tokens | Settings… (⌘,) → Orchestrator → Generation |
| Orchestrator folder / file access | The chat's Folder chip (a working folder belongs to the chat) | The chat window's input bar |
| Ask before delegating / who it can delegate to | Delegation | Settings… (⌘,) → Orchestrator → Delegation |
| Audit log / activity history | Insights (dashboard) and Keep Activity History (policy) | Settings… (⌘,) → Insights; Settings… (⌘,) → General → Advanced |
| Undo agent file changes / how long to keep them | Keep File History | Settings… (⌘,) → General → Advanced → Data & Storage |
| Tool permissions | Could be All Tools, the chat's folder tools or macOS Permissions: ask `find` | |
| Calendar / Reminders / Contacts / Notes / Mail / Messages / Maps / Music / Shortcuts access for an agent | The agent's Apple app group | Settings… (⌘,) → Agents → the custom agent → Abilities (declarative: `agents[].capabilities.apple_apps`) |
| Calendar / Contacts / Automation grant for the whole app | macOS permission | Settings… (⌘,) → Permissions |
| Run Osaurus in the background / hide it | Hide Dock Icon, Start at Login | Settings… (⌘,) → General |

## Agent descriptions

Each custom agent has an optional **Brief description** under Settings → Agents → the agent. It is a one-line summary of what the agent does and when to delegate to it, shown wherever the Orchestrator lists targets. It is routing metadata only: it never grants tools or permissions.

## Where settings are stored

Config JSON lives under `~/.osaurus/config/`. Secrets live in the macOS Keychain.
