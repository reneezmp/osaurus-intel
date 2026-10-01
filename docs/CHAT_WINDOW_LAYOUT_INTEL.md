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
  replaces the old chats sidebar. File Changes (per-chat file history,
  `W-file-history`, #2907 part A) shipped 2026-10-01; see
  [`FILE_HISTORY_INTEL.md`](FILE_HISTORY_INTEL.md).
- When the window is too narrow for both rails, the left one steps aside.

## Steps

| Step | Content | Status |
|---|---|---|
| 1–3 | Shipped together 2026-10-01 (a chats list in both rails in between made no sense): window state and toolbar (inspector toggle + Pin Window, step-aside, #2910 strip inset); inspector rail with History; navigator with Agents and Projects; agent pill and Settings gear gone from the toolbar; follow-upstream fixes to stage 1 (⌘N opens a tab, `startNewChat(with:)` always a tab) | Shipped |
| 4 | Upstream's project page: `ProjectDetailView` (the project's chats in the content area) + `ProjectInspectorPanel` (Project Settings in the right rail, same toolbar toggle) in place of Intel's `ProjectPageView` | Shipped 2026-10-01 |
| 5 | Background, scheduled and watcher runs as tabs of their agent; Stop from the navigator for detached runs; "view task" focuses the run's tab | Shipped 2026-10-01 |
| 6 | Layout tour (`ChatLayoutTour`) with its Help menu entry, #2664 window size, full-screen themed header | Shipped 2026-10-01 |

## Intel adaptations (filled in per step)

- No workspace/teammate agents, relay agents or LAN-discovered agent rows:
  Intel has no workspaces, and its chat window never wired the Bonjour or
  relay lists (`discoveredAgents` stays empty). Their sections are left out.
- File Changes pane: shipped with `W-file-history` (2026-10-01,
  [`FILE_HISTORY_INTEL.md`](FILE_HISTORY_INTEL.md)); `ChatInspectorPanel`
  is now identical to upstream's.
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

## Step 4 notes (project page)

- `ProjectDetailView.swift` and `ProjectInspectorPanel.swift` are upstream's
  files. Intel edits: the project's chats come from
  `ChatSessionsManager.sessions(forProject:)` (the store is keyed by id), and
  single-value `onChange`.
- Both are mounted with `.id(project.id)`: switching projects rebuilds them
  with fresh state. This keeps Intel's fix for instructions written to the
  wrong project (`3fc23c3eb`), even though upstream's panel also flushes on
  switch.
- Intel's `ProjectPageView.swift` (one full-width page: instructions,
  members, knowledge, folder) is removed. Its jobs now live in the page
  (chats, Add Chats, rename, delete) and the rail (instructions with
  auto-save, knowledge, working folder, shared memory, default agent).
- `chatWindow.showProjectInspector` (UserDefaults, default on) remembers
  whether Project Settings is open, as upstream.

## Step 5 notes (runs as tabs)

- A dispatched run that registers (schedule, watcher, API; anything with
  `showToast`) appears as a background tab of its agent in the frontmost
  window, without taking focus (`BackgroundTaskManager.taskRegistered` →
  `ChatWindowManager.surfaceRegisteredTask` →
  `ChatWindowState.attachBackgroundTab`). A window that opens later picks
  up every registered run (`tasksForTabs`).
- Closing a running run's tab only unlinks the view; closing a finished
  run's tab dismisses the task (`finalizeTask`), as upstream.
- "View" from the menu-bar card or a notification (`openTaskWindow`) now
  focuses the run's tab, or attaches it to the frontmost window, instead of
  opening a new window (upstream `revealTask`).
- Opening a running chat from History attaches its live session
  (`liveTask(forSessionId:)`), so the reply keeps streaming in view.
- Intel difference: upstream keeps finished runs in the registry (and
  across relaunch, as retained tabs) until their tab closes. Intel's
  registry still auto-finalizes a finished run after 15 seconds; its tab
  stays and simply becomes an ordinary saved chat. Retained runs across
  relaunch are not ported (Intel never persisted the registry).

## Step 6 notes (tour, window size, full screen)

- `Views/Tour/ChatLayoutTour.swift` is upstream's file. It offers its
  three-stop coachmark tour once per user (`chatLayoutTourCompleted`) when a
  chat window becomes key, and waits while any alert, sheet or modal is up.
  Intel edit: single-value `onChange` with a remembered step. (Until File
  Changes shipped the third stop said "Past chats" only; it now uses
  upstream's "Past chats and file changes" copy.) Anchors: the navigator's
  lens bar, the tab strip, the inspector toggle.
- Help ▸ **Chat Layout Tour** replays it. Intel adds this one item after the
  system Help item; upstream's full Help menu (docs, Discord, report an
  issue) is not part of this port.
- Upstream's onboarding hand-off (`holdAutoStart` / `releaseAutoStart`
  around first-run dialogs) has no Intel counterpart: Intel has no
  onboarding window flow. The tour's own wait for open dialogs covers it.
- New chat windows open at the visible size of the screen under the
  pointer, cascade 25pt per extra window, and share the `ChatWindow` frame
  autosave slot written by the first window (#2664). Before this Intel
  opened every window at 900×650, centred.
- Full screen: the NSToolbar is detached on entering full screen and
  restored on exit; the root view shows `ChatFullScreenHeaderView` (sidebar
  toggle, tab strip, inspector/pin row) on the theme background, as upstream.
  `ThemedAlertCenter.hasAnyActiveAlert` added for the tour.

