---
title: Agents
summary: Create custom agents with their own prompt, model, tools, memory, folder, and theme.
order: 40
---

# Agents

Agents are the core of Osaurus. Each agent has its own system prompt, default model, tool grants, memory, and look. The built-in agent — the Orchestrator — explains and configures Osaurus and can hand bounded tasks to your custom agents; custom agents do the hands-on work (see The Orchestrator topic).

## Creating and managing agents

- Settings… (⌘,) → Agents → create, edit, duplicate, or delete agents. Onboarding creates your first one.
- Switch agents from the agent menu in the chat window; each agent can have its own chat tabs.
- A new agent can start from a specialty (Assistant, Writer, Researcher, Coder, Productivity), which fills in the system prompt and a routing description.

## An agent's settings

An agent's page has five groups:

- **General** — Configure (name, description, instructions, default model, temperature, max tokens) and Appearance (avatar, greeting, quick actions, theme).
- **Abilities** — Overview (what the agent may do), Tools (which tools it can use, Auto or Manual selection).
- **Connections** — Network (Bonjour discovery on your local network); Remote Connections and Channels belong to features not in this build.
- **Automation** — the agent's schedules and watchers.
- **Memory** — the agent's memory and its private Database.

## Per-agent abilities (Abilities → Overview)

- Tools and Memory.
- Off by default, opt in per agent: Web Search, Charts, the Speak tool (voice output), Memory Recall (`search_memory`), Self-scheduling, Database (a private, encrypted SQLite database with `db_*` tools), and Knowledge collections.
- Autonomous Execution, Subagents, and Sandbox are shown as unavailable on this Mac. Claude Code agents can work in the chat's selected folder instead.

## Working folder

The folder chip in the chat input gives the current chat access to one folder: file read/write/edit/search, shell, undo/history, and git tools in a repository. Picking a folder (or letting the agent open the picker with `prompt_working_folder`) also remembers it on the agent, so new chats, schedules, and watchers start there. See the Chat topic for the file formats the folder tools handle.

## The Orchestrator vs custom agents

- The Orchestrator answers questions about Osaurus, finds settings, applies its bounded configuration after you approve it, and delegates single tasks to allowed agents. It has no knowledge collections or private database of its own.
- For hands-on work (files, code, research, the web) use a custom agent directly, or let the Orchestrator delegate to one.
- Custom agents get the full tool surface, gated by their ability switches and tool permissions.

## Storage

Custom agents are stored as JSON under `~/.osaurus/agents/`. The Orchestrator's own settings (name, instructions, model, temperature, max tokens, delegation) live in Settings → Orchestrator.
