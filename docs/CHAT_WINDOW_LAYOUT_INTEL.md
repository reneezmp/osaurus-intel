# Chat window layout on Intel (chat tabs stage 2, #2907 part C)

Renée's decision, 2026-10-01: follow upstream's chat-window layout, adapting
only what Intel or Ventura forces. Builds on chat tabs stage 1
([`CHAT_TABS_INTEL.md`](CHAT_TABS_INTEL.md)).

Upstream sources: #2630 (`ae942a150`, the sidebar half), #2661, #2662,
#2664, #2727 (agent rows: badges, new-agent highlight), #2907 part C
(`74e83c6c5`: right-hand inspector with History, Projects as folders of
chats), #2910 (strip clear of the inspector), and the full-screen header.

## Target layout (upstream)

- **Left rail, "navigator":** Agents | Projects lenses. Agents lists the
  local agents. Each row shows the agent's live activity, an unread badge
  and a hover "+" for a new chat; picking an agent shows its tabs. Projects
  lists projects as folders of chats. The toolbar's agent pill goes away.
- **Toolbar:** sidebar toggle, tab strip, then the inspector toggle and Pin
  Window.
- **Right rail, "inspector":** File Changes | History. History lists the past
  chats of the tab's agent, with search, filters, New Chat and Import. It
  replaces the old chats sidebar. File Changes needs per-chat file history
  (`W-file-history`, #2907 part A), not ported yet, so Intel shows the
  History pane alone until then.
- When the window is too narrow for both rails, the left one steps aside.

## Steps

| Step | Content | Status |
|---|---|---|
| 1–3 | Shipped together 2026-10-01 (a chats list in both rails in between made no sense): window state and toolbar (inspector toggle + Pin Window, step-aside, #2910 strip inset); inspector rail with History; navigator with Agents and Projects; agent pill and Settings gear gone from the toolbar; follow-upstream fixes to stage 1 (⌘N opens a tab, `startNewChat(with:)` always a tab) | Shipped |
| 4 | Projects lens and upstream's project page (`ProjectDetailView` + `ProjectInspectorPanel`) in place of Intel's `ProjectPageView` | Planned |
| 5 | Background, scheduled and watcher runs as tabs; Stop from the navigator for detached runs | Planned |
| 6 | Layout tour (`ChatLayoutTour`, #2664), Help menu entry, full-screen themed header | Planned |

## Intel adaptations (filled in per step)

- No workspace/teammate agents, relay agents or LAN-discovered agent rows:
  Intel has no workspaces, and its chat window never wired the Bonjour or
  relay lists (`discoveredAgents` stays empty). Their sections are left out.
- File Changes pane: absent until `W-file-history`.
- History pane, Default agent: lists every chat (Intel's
  `ChatSessionsManager.sessions(for:)`), not only Default-tagged ones.
  Intel saves chats with no agent under a random agent id, so upstream's
  rule would hide them.
- Content search in History: a scan of the in-memory transcripts
  (`ChatHistoryList.sessionIds(withContentContaining:)`), not upstream's
  SQLite query; Intel keeps saved chats in memory.
- Import in History: straight to the picker; upstream's first-time guide
  sheet (`ImportGuideSheet`) is not ported (`W-chat-ux`).
- Plugins filter: Intel's `PluginManager.plugins` is empty, so the filter
  also lists plugin ids the chats reference.
- Agent rows: no subagent "helper mirror" roll-up (no subagents on Intel);
  the live step comes from dispatched runs (`BackgroundTaskManager.liveTask`,
  added).
- Agent order: Intel's `AgentManager` gained upstream's
  `reorder(orderedIds:)` and display sort (ordered agents first, the rest
  alphabetically). Before this Intel sorted custom agents by creation
  date, so the first launch shows unordered agents alphabetically.
- `ColumnResizeHandle`: AppKit cursor push/pop instead of
  `.pointerStyle(.columnResize)` (macOS 15).
- `HeaderActionButton`: upstream's active state and badge, without the
  Liquid Glass circle (macOS 26).
- `/agent` slash command: posts `chatToolbarOpenAgentPicker`, which nothing
  observes since the pill left the toolbar. Same as upstream.
- No layout tour anchors until step 6.

## Files (steps 1–3)

- From upstream, adapted: `Views/Chat/ChatSessionSidebar.swift` (navigator
  plus `ChatHistoryList`, workspace/shared/network rows removed),
  `Views/Chat/ChatHistoryPane.swift`, `Views/Chat/ChatInspectorPanel.swift`,
  `Views/Management/SharedSidebarComponents.swift` (Intel's multi-select
  row background kept), `Managers/Chat/SessionActivityMonitor.swift`
  (verbatim), `Managers/Chat/NewAgentHighlightStore.swift` (no roster or
  remote observation), `Utils/Localization.swift` (verbatim, `LCached`).
- Intel files changed: `ChatContentView.swift` (three columns, step-aside,
  publishes rail geometry), `ChatWindowState.swift` (inspector state,
  `toggleSidebar`, Pin Window), `ChatWindowManager.swift` (toolbar,
  `session(forSessionId:)`, `setWindowPinned`), `ChatView.swift`
  (`ChatSession` reports activity), `IntelManagerConformers.swift`
  (agent order), `BackgroundTaskManager.swift` (`liveTask`,
  `activeTaskSessions`), `AppDelegate.swift` + `ManagementStateManager` +
  `AgentsView` (New Agent deep link), `ChatTabStripView.swift` re-synced to
  upstream (trailing inset back, accessory gone).
- Removed: `Views/Chat/ChatSidebarSection.swift` (dead since M10.5).
- Tests: upstream `ChatWindowStateInspectorTests` (minus File Changes deep
  links and Project Settings), `NewAgentHighlightStoreTests`,
  `SessionActivityMonitorTests`, `ChatSessionSidebarFilterTests`; Intel
  `IntelChatWindowLayoutTests`.
