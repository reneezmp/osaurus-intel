# Chat tabs on Intel (`W-chat-tabs`)

Browser-style tabs in the chat window, ported 2026-10-01 from upstream #2630
(`ae942a150`) and its follow-ups: #2721 tab right-click menu, #2740
remembered tabs, #2781 Ask AI opens a tab, #2802 stable strip on resize,
#2911 per-tab scroll memory. Stage 2 (the chat-window layout: navigator,
inspector, tour) is [`CHAT_WINDOW_LAYOUT_INTEL.md`](CHAT_WINDOW_LAYOUT_INTEL.md);
since it shipped the agent pill lives in the navigator, as upstream.

## What the user gets

- A tab strip in the toolbar. Each tab is one
  conversation, with the agent's avatar, the title and a ×. A spinning
  ring on the avatar means the agent is replying; a steady orange ring
  means it is waiting for an answer to a question. A folder glyph on a tab
  means the chat belongs to a project; clicking it opens the project page.
- **Tabs belong to agents.** The strip shows only the active agent's tabs.
  Picking another agent in the navigator shows that agent's tabs: the one waiting
  for input first, else the most recently used. When the agent has none,
  a blank active tab is reused, otherwise a new tab opens. A blank tab
  left behind by switching agents is dropped; whatever was typed in it
  comes back with that agent's next New Chat.
- **New Chat** (History pane, "+" in the strip, menu bar Ask AI) reuses a
  blank tab, otherwise opens a new tab. ⌘N and ⌘T always open a new tab
  (⌘N stays in the current project).
  The conversation you were in keeps its tab, and a reply keeps streaming
  there.
- Sidebar rows: click opens the chat in the current tab (or focuses the tab
  already showing it); right-click has **Open in New Tab** and **Open in New
  Window**. Rename, pin, archive and delete reach every open tab of that chat.
- Tab right-click menu: Stop (while running), Open in New Window, Rename,
  Pin, Move to Project, Export, Archive, Delete, Close Tab. Drag a tab to
  reorder. Too many tabs fold into a "N ▾" menu.
- Shortcuts (window key equivalents, `ChatTabShortcut`): ⌘N new tab in the
  current project (overrides File ▸ New Window while the chat shows), ⌘T new tab, ⇧⌘T
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
- Toolbar (`IntelChatToolbarDelegate`): `[sidebar, tabs, trailing]`, as
  upstream. The tabs item is flexible (a min/max width range, upstream
  #2802). The strip insets past the open sidebar and the open inspector
  (#2910), measured from AppKit by `WindowEdgeReader`.
- Tab right-clicks use an AppKit event monitor (`TabRightClickCatcher`),
  because the toolbar claims right-clicks for its own menu.

## Intel differences from upstream (keep on re-sync)

Since Renée's 2026-10-01 rule (follow upstream; adapt only what Intel
forces), the stage-1 divergences on ⌘N, `startNewChat(with:)` and the tab
activity ring were reverted to upstream's behaviour.

| Upstream | Intel | Why |
|---|---|---|
| Project new chat via `switchAgent` (can land on an existing chat and stamp the project on it) | `startNewChat(with:)` | Bug fix: never re-files an existing conversation into a project |
| `IntelLastChatStore` (pre-tabs Intel) | Read once by `legacyLastChatRecord`, then removed | Migration from the 2026-09-25 analogue |

Toolbar changes, as upstream: the centred agent pill moved into the
navigator, its back-to-project chip became the folder glyph on project
tabs, the "+ New chat" button gave way to the strip's "+", and the
Settings gear became the navigator's footer row. The trailing slot holds
the inspector toggle and Pin Window.

## Files

- New: `Managers/Chat/ChatTabLayoutStore.swift` (upstream, verbatim),
  `Models/Chat/ThreadScrollPositionStore.swift` (upstream, verbatim),
  `Managers/Chat/DetachedChatRunRegistry.swift` (Intel),
  `Views/Chat/ChatTabStripView.swift` (upstream; Intel edits marked
  "Intel:": no tour anchor yet, no workspace identity, single-value
  `onChange`, no registry task to cancel on Delete).
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

## Stage 2

Tracked in [`CHAT_WINDOW_LAYOUT_INTEL.md`](CHAT_WINDOW_LAYOUT_INTEL.md).

Manual QA: [`ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`](ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md#chat-tabs-w-chat-tabs).
