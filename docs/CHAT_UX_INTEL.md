# Chat UX batch on Intel (`W-chat-ux`)

The remaining `W-chat-ux` items from
[`INTEL_MISSING_FEATURES_BACKLOG.md`](INTEL_MISSING_FEATURES_BACKLOG.md),
ported from `upstream/main` in Renée's order (Insights → `W-chat-ux` → model
picker, 2026-10-01). Cross-block selection shipped earlier
([`CROSS_SELECTION_INTEL.md`](CROSS_SELECTION_INTEL.md)). Each slice notes
what Intel adapted; everything else is upstream verbatim.

## Composer: input history, "@" files, IME field

- **Input history:** ↑ on the composer's first line recalls this chat's
  earlier messages, newest first. ↓ on the last line walks back toward the
  draft you had. Consecutive duplicates collapse, sending resets the
  position, and switching chats drops it.
  - Files: `Models/Chat/ChatInputHistory.swift` (upstream).
  - `FloatingInputCard`: `inputHistoryProvider` / `inputHistoryKey`,
    `handleInputArrowUp/Down`.
  - `ChatContentView` passes `ChatInputHistory.entries(from: session.turns)`
    and the session id.
- **"@" file menu:** typing `@` lists the chat's work folder (home when
  none). Folders come first, dotfiles appear once a `.` is typed, and the
  list caps at 50 rows.
  - `@/…` and `@~/…` browse absolute and home paths.
  - ↑/↓/Return pick a row. A folder drills in; a file inserts its path and
    a space. Escape removes only the `@` token.
  - A folder macOS denied (TCC) offers **Grant Access** through an open
    panel.
  - The listing runs off the main actor.
  - Files: `Models/Chat/AtFileMenu.swift`, `Views/Chat/AtFileMenuPopup.swift`
    (Intel: single-value `onChange`).
  - The composer's commit, arrow and escape handlers are upstream's
    `handleInputCommit` / `handleInputArrowUp` / `handlePopupEscape`. The
    popup also suppresses window-closing Escape
    (`SlashCommandRegistry.isPopupVisible`).
- **IME-aware fields:** `Views/Common/IMEAwareTextField.swift` (upstream).
  `SearchField` now uses it, so the placeholder hides while a CJK
  composition is in progress (upstream's `SearchField`, verbatim).
- Tests: upstream `Tests/Chat/ChatInputHistoryTests.swift`. Intel
  `Tests/Chat/IntelChatUXTests.swift` covers the "@" resolver and lister;
  upstream ships no test for them.

## Follow-up suggestions

- After a clean reply, up to four next questions appear as tappable rows
  under it. Tapping one sends it. The rows clear on the next send, on stop
  or error, and on a chat switch or new chat. They aren't persisted.
- **On by default** (upstream, backlog decision 3f): Settings › Conversation
  › Behavior › **Suggest Follow-Up Questions**.
  `ChatConfiguration.generateFollowUpSuggestions` is stored in `chat.json`.
- Files, from upstream: `Views/Chat/FollowUpSuggestionsBar.swift`
  (verbatim) and `Services/Chat/FollowUpSuggestionService.swift` (prompt,
  parsing and limits verbatim).
- **Intel differences:**
  - Generation runs as one `ChatEngine.completeChat` on the Core Model,
    else the chat's model: the chat-title resolution. Upstream uses
    `CoreModelService`, which Intel doesn't compile.
  - The 30 s timeout is a task-group race.
  - Insights logs the request as `/internal/follow_up_suggestions`
    (source System).
  - No per-agent follow-up model (upstream `AgentFollowUpConfig`), so the
    Settings description leaves out upstream's "each agent can tailor…"
    sentence. `generateSuggestions(modelOverride:)` is kept for when the
    agent setting lands.
- Wiring (upstream shape):
  - `ChatSession.followUpSuggestions` / `followUpTurnId`,
    `maybeGenerateFollowUps()` (from `completeRunCleanup`),
    `clearFollowUpSuggestions()`, `sendFollowUp(_:)`.
  - A display-time `ContentBlockKind.followUpSuggestions` is inserted by
    `insertFollowUpSuggestionsIfNeeded`. The memoizer never caches it, and
    its id is `followups-<turn>`.
  - `NativeMessageCellView.configureAsFollowUpSuggestions` hosts the bar,
    with the height estimate and the entrance animation played once per
    chat (`shownFollowUpBlockIds`).
- Tests in `IntelChatUXTests`: parsing, the setting default and copy, the
  generation path through a fixture engine (with its Insights row), and no
  request without an answer.

## Not applicable on Intel

- `Views/Chat/ChatPersistenceNotice.swift` watches the unsaved-session set of
  upstream's SQLite chat writer (`ChatSessionStore.retryUnsaved`). Intel
  stores chats as JSON and never compiled that writer.
- `Views/Chat/RecentFoldersPanel.swift` has no callers on upstream/main
  (dead code there). Intel's folder menu already lists recent folders from
  `RecentFoldersStore`.

## Still to port (paused 2026-10-01 for Renée's weekly usage budget)

Renée asked to release after this batch. The remaining items are large, so
they wait for the next session, in this suggested order:

1. Compaction marker in the transcript (`NativeCompactionMarkerView`,
   `CompactionDialogView`) and the compaction-model picker (the four
   Conversation switches from the #2950 port).
2. Group thinking and tool activity roll-up (`NativeActivityGroupView`,
   `ShimmerLabel`), plus expanding thinking while it streams.
3. Smooth streaming.
4. Screenshot attach (`ScreenshotCaptureService`, a shared-artifact turn).
5. Chat import guide (`ImportGuideSheet`, `ImportHistoryPromptGate`).
6. Markdown document view (`MarkdownBlockParsing`, `MarkdownDocumentView`).
7. Activity / dispatch rows (`DispatchEnvelope`, `AgentDispatchTarget`,
   `NativeDispatchBadgeRow`).
8. Context attribution (`ContextAttribution`).
9. `AgentDetailChrome` and `BuiltInAgentGuard`.
10. Slash-command registry parity.

After that comes the model picker (`W-model-picker-2947`).
