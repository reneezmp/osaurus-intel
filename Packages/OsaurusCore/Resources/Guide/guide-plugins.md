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
- A plugin's tools ask before they run, like other tools that act for you; choose **Always Allow** on the approval card (or set the tool's permission in the Tools tab) to stop asking.
- If a plugin can't load, the Plugins tab says why (for example, it needs a newer Osaurus or macOS).
- A plugin that crashed Osaurus while loading is set aside on the next launch instead of crashing it again. Its card offers **Retry** and **Uninstall**; updating the plugin (or Osaurus) gives it one fresh try.
- Plugins with instructions get a tab on each agent's page (Settings… → Agents → *agent*), where you can rewrite those instructions for that agent.
- Plugin calls appear in Settings → Insights under the **Tools** scope.
- When a plugin talks to a model (a chat bot, for example), the conversation is saved as a chat with the plugin's badge in the sidebar; a plugin that names its conversation keeps adding to one chat.
- Plugins can't reach your Mac itself or your local network (localhost, 192.168.x.x and similar addresses are refused), make at most 60 web requests a minute per agent, and can only read files Osaurus saved as artifacts.

## Built into Osaurus

Web search and the Apple app tools (Calendar, Reminders, Contacts, Notes, Mail, Messages, Maps, Music, Shortcuts) are part of Osaurus itself, not plugins. Turn Apple app tools on per custom agent under Settings… (⌘,) → Agents → *agent* → Abilities → Tools, where each app is a group in the tool picker; they are off by default.

## Not in this build

Claude plugin import (skills, commands, and MCP servers bundled from a GitHub repo) and the out-of-process plugin host.

## Troubleshooting

- "Failed to load plugin" or "Plugin quarantined": the card shows the error; **Retry** reloads it.
- New plugin tools not offered mid-chat: start a new chat.
