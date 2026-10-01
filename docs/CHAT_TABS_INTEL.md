# Chat tabs on Intel (`W-chat-tabs`)

Browser-style tabs in the chat window, ported 2026-10-01 from upstream #2630
(`ae942a150`) and its follow-ups: #2721 tab right-click menu, #2740
remembered tabs, #2781 Ask AI opens a tab, #2802 stable strip on resize,
#2911 per-tab scroll memory. Stage 1 of 2; stage 2 is listed under
[Not ported yet](#not-ported-yet-stage-2).

## What the user gets

- A tab strip in the toolbar, after the agent pill. Each tab is one
  conversation, with the agent's avatar, the title and a ×. A spinning
  ring on the avatar means the agent is replying; a steady orange ring
  means it is waiting for an answer to a question. A folder glyph on a tab
  means the chat belongs to a project; clicking it opens the project page.
- **Tabs belong to agents.** The strip shows only the active agent's tabs.
  Picking another agent in the pill shows that agent's tabs: the one waiting
  for input first, else the most recently used. When the agent has none,
  a blank active tab is reused, otherwise a new tab opens. A blank tab
  left behind by switching agents is dropped; whatever was typed in it
  comes back with that agent's next New Chat.
- **New Chat** (sidebar, "+" in the strip, menu bar Ask AI, ⌘N with the
  Conversation setting on) reuses a blank tab, otherwise opens a new tab.
  The conversation you were in keeps its tab, and a reply keeps streaming
  there.
- Sidebar rows: click opens the chat in the current tab (or focuses the tab
  already showing it); right-click has **Open in New Tab** and **Open in New
  Window**. Rename, pin, archive and delete reach every open tab of that chat.
- Tab right-click menu: Stop (while running), Open in New Window, Rename,
  Pin, Move to Project, Export, Archive, Delete, Close Tab. Drag a tab to
  reorder. Too many tabs fold into a "N ▾" menu.
- Shortcuts (window key equivalents, `ChatTabShortcut`): ⌘T new tab, ⇧⌘T
  reopen the last closed tab, ⌃Tab / ⌃⇧Tab and ⇧⌘] / ⇧⌘[ next / previous
  tab. ⌘W closes the active tab; closing an agent's last conversation
  leaves a blank chat, and only a lone blank tab closes the window. None of
  them act on the project page.
- **Remembered tabs.** Closing a window or quitting records its saved
  conversations (`ChatTabLayoutStore`, key `chatTabLayout.v1`). The next
  window opened brings them back. A plain open (dock, hotkey, New Window)
  lands on the chat that was showing. A window opened for something
  specific (Ask AI, a given agent, a given chat) keeps that in front, with
  the remembered tabs behind it. Blank tabs are never remembered.
- **Scroll memory.** Each tab returns to where you were reading. A tab that
  was following the bottom keeps following.

## How it works

- `ChatWindowState` (Intel section of `Managers/Chat/ChatWindowState.swift`)
  holds `tabs: [ChatTab]` and `activeTabId`. `session` is `@Published
  private(set)` and always the active tab's. The window root
  (`IntelChatWindowRootView` in `ChatWindowManager.swift`) rebuilds `ChatView`
  with `.id(ObjectIdentifier(session))`, so every per-chat `@State` resets on
  a switch, as in upstream.
- `ChatTabScope` has only `.local(agentId)`. Upstream also has `.workspace`
  for teammates' shared agents, which Intel does not have.
- **Hibernation:** past 5 hydrated tabs (`warmTabLimit`), the least recently
  used idle saved tabs swap to a metadata-only stand-in. Intel keeps every
  saved chat in `ChatSessionsManager`'s memory, so waking is a synchronous
  copy (upstream reads the disk asynchronously and shows a loading state).
  Running, clarify-paused, queued-send and blank tabs never hibernate.
- **Closing a tab or window that is still replying:**
  `DetachedChatRunRegistry` holds the session until the run ends. The run
  needs nothing else: `ChatSession.send` keeps the session alive and saves
  when it finishes. Reopening that chat (sidebar, ⇧⌘T, Open in New Tab)
  attaches the same live instance, so the reply keeps rendering and no
  stale copy races its saves. This is Intel's stand-in for upstream's
  `BackgroundTaskManager.adoptSession` / `liveTask(forSessionId:)`. Intel's
  `BackgroundTaskManager` only runs dispatched work (schedules, watchers).
- **One owner per saved chat** (upstream 979d53b40):
  `ChatWindowManager.revealOpenSession` checks every tab of every window and
  focuses the owning tab.
- Toolbar (`IntelChatToolbarDelegate`): `[sidebar, tabs, action]`. The tabs
  item is flexible (a min/max width range, upstream #2802) and hosts
  `IntelToolbarTabsView` = agent pill + `ChatTabStripView`
  (`leadingAccessory`). The strip insets past the open sidebar
  (`chatSidebarWidth`, clamped 260–460), measured from AppKit by
  `WindowEdgeReader`.
- Tab right-clicks use an AppKit event monitor (`TabRightClickCatcher`),
  because the toolbar claims right-clicks for its own menu.

## Intel differences from upstream (keep on re-sync)

| Upstream | Intel | Why |
|---|---|---|
| Agent pill moved into an agents sidebar; chat history in a right-hand inspector | Agent pill stays in the toolbar, ahead of the strip; Intel's chats sidebar unchanged | Stage 2 (layout redesign) not ported |
| Window takes ⌘N for a new tab | ⌘N stays with the File menu (Settings › Conversation chooses New Chat or New Window) | Keeps Intel's setting meaningful; with it on, ⌘N already opens a tab via New Chat |
| `startNewChat(with:)` always opens a tab | Reuses a blank active tab | Same as `switchAgent`; no stray blank tabs |
| Project new chat via `switchAgent` (can land on an existing chat and stamp the project on it) | `startNewChat(with:)` | Never re-files an existing conversation |
| Activity ring from `SessionActivityMonitor` | `ChatTabActivity.of(session)` | Intel has no monitor; detached runs have no tab |
| Background / scheduled runs attach as tabs | Not attached | Stage 2 |
| Full-screen themed header | None | Intel had none before tabs either |
| `IntelLastChatStore` (pre-tabs Intel) | Read once by `legacyLastChatRecord`, then removed | Migration from the 2026-09-25 analogue |

Toolbar changes: the centred agent pill and its back-to-project chip are
gone. The chip's job moved to the folder glyph on project tabs (upstream
did the same). The trailing "+ New chat" button is gone: the strip's "+"
replaces it (upstream #2630), so the trailing slot always shows the
Settings gear.

## Files

- New: `Managers/Chat/ChatTabLayoutStore.swift` (upstream, verbatim),
  `Models/Chat/ThreadScrollPositionStore.swift` (upstream, verbatim),
  `Managers/Chat/DetachedChatRunRegistry.swift` (Intel),
  `Views/Chat/ChatTabStripView.swift` (upstream, adapted: leading accessory,
  no inspector inset, no tour anchor, no workspace identity, single-value
  `onChange`).
- Changed: Intel sections of `ChatWindowState.swift` and
  `ChatWindowManager.swift`; `ChatContentView.swift` (sidebar wiring);
  `ChatSessionSidebar.swift` (Open in New Tab; `DontAskAgainToggle` made
  internal as upstream); `ProjectNamePromptSheet.swift` (`placeholder`,
  #2721); `MessageTableRepresentable.swift`, `ScrollAnchorManager.swift`,
  `MessageThreadView.swift`, `ChatView.swift` (#2911, merged into Intel's
  own scroll fixes; see below); `AppDelegate.swift` (Ask AI, task banner).
- #2911 merge: Intel's `handlePostSnapshotScroll` and `reportMeasuredHeight`
  keep their Intel structure (`isNewTurn`, `noteRowHeightsChanged`), with
  upstream's restore step, restore hold and pin-settle follow added.
  Re-sync these by hand, not by taking upstream's functions.

## Tests

`Tests/Chat/IntelChatTabsTests.swift` covers scope, agent switching, close,
move, cycle, New Chat, dedupe, cross-window ownership, deletion, sidebar
sync, detached runs, ⇧⌘T, hibernation, layout store, snapshot, restore
(both modes), the legacy migration, the shared scroll store and shortcuts.
These are upstream's `ChatWindowStateScopedTabsTests` and
`ChatTabLayoutPersistenceTests` cases that don't depend on the
background-task registry, plus the Intel-only ones.

Rendering check: `ImageRenderer` cannot draw `TabRightClickCatcher` (an
`NSViewRepresentable`), so it shows a yellow placeholder over every chip.
Remove the overlay in a throwaway copy to look at the chips.

## Not ported yet (stage 2)

- Agents sidebar and history in an inspector rail (#2630 sidebar half,
  #2661, #2662), the layout tour (#2664 / `ChatLayoutTour`), and #2910
  (strip clear of the inspector rail). These change the chat window's
  layout.
- Background, scheduled and watcher runs as tabs (`attachBackgroundTab`,
  `attachRetainedTab`), and a sidebar Stop for detached runs.
- Full-screen themed header.

Manual QA: [`ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`](ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md#chat-tabs-w-chat-tabs).
