---
title: Plugins
summary: Native plugins built for Intel Macs, their keys and permissions, and the Apple app tools built into Osaurus.
order: 70
---

# Plugins

Plugins add new tools to Osaurus. This Intel build loads native plugins compiled for Intel (x86_64) Macs from the Intel plugin repository; plugins that exist only for Apple Silicon show "Apple Silicon required".

## Native plugins

- Settings… (⌘,) → Plugins: browse the repository, Install, update, and Uninstall.
- A plugin may need your approval before it loads, macOS permissions (**Grant** opens the right System Settings pane), or API keys: **Configure** stores them in the Keychain, per agent, never through chat.
- A plugin's page shows its tools, capabilities, HTTP routes, README, and changelog. **Open Web App** opens a plugin's web UI with the agent id it needs.
- Plugin calls appear in Settings → Insights under the **Tools** scope.

## Built into Osaurus

Web search and the Apple app tools (Calendar, Reminders, Contacts, Notes, Mail, Messages, Maps, Music, Shortcuts) are part of Osaurus itself, not plugins. Turn Apple app tools on per custom agent under Settings… (⌘,) → Agents → *agent* → Abilities → Tools, where each app is a group in the tool picker; they are off by default.

## Not in this build

Claude plugin import (skills, commands, and MCP servers bundled from a GitHub repo) and the out-of-process plugin host.

## Troubleshooting

- "Failed to load plugin": the card shows the error; **Retry** reloads it.
- New plugin tools not offered mid-chat: start a new chat.
