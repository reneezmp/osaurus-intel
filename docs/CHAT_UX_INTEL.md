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

## Compaction marker, dialog and model picker

- **Marker:** after a compaction, a thin divider ("Older messages
  summarized — ~Nk tokens reclaimed") sits below the last summarized
  message. Click it to read the summary the model now sees in place of
  the messages above; the tooltip names the model. It disappears on its own
  when an edit, regeneration or deletion retires the summary.
  - Files: `Views/Chat/NativeCompactionMarkerView.swift` (upstream; Intel
    builds its sized symbols itself and fades with a plain alpha animation,
    since Intel's `SymbolImageCache` has no sized variants and no
    `ExpandFade`).
  - `ContentBlockKind.compactionMarker` + `ContentBlock.compactionMarker`
    (id `compaction-<summary id>`), inserted at display time by
    `ChatSession.insertCompactionMarkerIfNeeded`, never cached.
  - The cell, kind tag and height estimate are upstream's.
- **Compaction model:** Settings › Conversation › Advanced › **Compaction
  Model** (search id `settings.chat.compactionModel`). Unset means the
  chat's current model, as upstream.
  - Stored in `chat.json` as `compactionModelProvider` /
    `compactionModelName`, the upstream keys.
  - `IntelContextCompaction.configuredModelIdentifier`,
    `effectiveModelIdentifier`, `usesChatModelFallback` and
    `saveConfiguredModel` are upstream's `ContextCompactionService` helpers.
  - The context popover's helper names the model the next run uses
    (upstream copy).
- **Progress state:** `ChatSession.compactionState`
  (`ContextCompactionUIState` with phases preparing → summarizing →
  applying, upstream types) replaces Intel's old `isCompacting` flag, which
  is now derived from it. `reset()` and loading another chat cancel a run
  in flight (upstream).
- **Dialog:** `Views/Chat/CompactionDialogView.swift` (upstream) opens only
  when no model is known: no compaction model and no chat model. Choosing
  one saves it as the compaction model and runs, with progress, the result
  and Retry in the dialog.
- **Intel differences:**
  - Never automatic (decision recorded in `UPSTREAM_SYNC.md`, #136): no
    pre-send trigger, so the dialog never shows for an auto run and
    `hasPendingSendAfterCompaction` is always false.
  - Outcomes outside the dialog stay toasts; upstream shows them as popover
    rows.
  - Copy drops the Privacy Filter (Intel has none) and "runs automatically
    near the limit". The Settings description names Intel's three triggers.
- Deleting a summarized response now adds upstream's warning line ("part of
  a conversation summary…"), which Intel had left out until compaction
  existed.
- Tests: `IntelContextCompactionTests` (model resolution, setting
  round-trip, phase order, the marker's place and its retirement, the
  no-model dialog, token formatting).

## Activity roll-up and expanding thinking while it streams

- **Roll-up:** a run of two or more thinking / tool steps (an agent loop
  across several assistant turns included) collapses into one **Worked**
  row with up to three step circles (green done, red failed, accent
  running, "+N" beyond that). While a step is live the title shimmers
  "Working". Expanded, it shows the steps, each still expandable, plus
  **Expand All / Collapse All**.
  - Settings › Conversation › Appearance › **Group Thinking & Tool
    Activity**, on by default (upstream). `UserDefaults`
    `chatActivityRollupEnabled`, memoized in
    `ContentBlock.ActivityRollupSetting`; flipping it posts
    `activityRollupSettingChanged` and open chats regroup at once.
  - Files: `Views/Chat/NativeActivityGroupView.swift` and
    `Views/Chat/ShimmerLabel.swift` (verbatim).
  - `ContentBlockKind.activityGroup`, `rollupActivityBlocks`,
    `activityStepCount`, `enclosingActivityGroupId` and `rendersToggleId`
    are upstream's, in `IntelDataConformers.swift`. The table finds the row
    to re-measure with `rendersToggleId`, and treats a roll-up holding
    streaming thinking as the streaming row.
  - `BlockMemoizer.blocks(from:)` applies the roll-up on top of
    `unrolledBlocks(from:)` (upstream's `generateBlocks`); tests that check
    raw grouping use `unrolledBlocks`.
- **Stats only under the reply's last turn** (upstream): Intel used to give
  every intermediate tool-calling turn its own speed/TTFT row, which also
  split loops into separate runs.
- **Expand Thinking While Streaming:** Settings › Conversation › Advanced,
  off by default (upstream key `chatExpandThinkingWhileStreamingEnabled`).
  While the reply is still only reasoning, its thinking block (and the
  roll-up around it) stays open, then folds once the answer or a tool call
  starts. A manual collapse mid-stream sticks.
  - A finished reply that is only reasoning opens its thinking once
    (upstream `seedAutoExpandedReasoningBlocks`).
- **Intel differences:**
  - The finished title is "Worked", never "Worked for 12s": Intel records
    no per-step durations (upstream's thinking `duration` and
    `ToolCallItem.duration`). The reply's own "Worked for" stats chip still
    shows the total.
  - Step glyphs come from `ToolCategory` (no subagent registry).
  - Intel's thinking id is `thinking-<turn>` (upstream `think-<turn>-<n>`),
    via `ContentBlock.thinkingBlockId(turnId:)`.
  - Sized symbols and a plain alpha fade replace upstream's
    `SymbolImageCache` sizes and `ExpandFade`.
- Tests: `IntelActivityRollupTests` in `IntelChatUXTests.swift` (grouping
  rules, loops with one stats row, the switch and its default, streaming
  expansion, reasoning-only seeding).

## Smooth streaming

- Replies type out at a steady ~180 tok/s however bursty the provider's
  SSE delivery is; a burst that arrived at once still finishes within about
  a second. Settings › Conversation › Appearance › **Smooth Streaming**, on
  by default (upstream key `chatSmoothStreamingEnabled`).
- `Utils/StreamingDeltaProcessor.swift` is now upstream's file (it was
  excluded; Intel had a pass-through that appended each delta and rebuilt
  the transcript per delta). UI syncs are throttled by reply length
  (16 → 100 ms), which also bounds main-thread work on long replies.
- `finalize()` is async and waits for the paced tail, so a tool card or
  the end of the run only lands after the text before it has typed out.
- **Intel differences:**
  - Plain `deinit` instead of upstream's `isolated deinit` (needs a newer
    runtime than macOS 13); the timers and waiters it releases are
    `nonisolated(unsafe)`.
  - `finalize(immediately: true)` when the run was stopped, so Stop
    doesn't keep typing the buffered tail.
- Tests: upstream `Tests/Chat/StreamingDeltaProcessorTests.swift` plus an
  Intel case for the immediate drain.

## Not applicable on Intel

- `Views/Chat/ChatPersistenceNotice.swift` watches the unsaved-session set of
  upstream's SQLite chat writer (`ChatSessionStore.retryUnsaved`). Intel
  stores chats as JSON and never compiled that writer.
- `Views/Chat/RecentFoldersPanel.swift` has no callers on upstream/main
  (dead code there). Intel's folder menu already lists recent folders from
  `RecentFoldersStore`.

## Still to port (resumed 2026-10-06)

Renée asked to release after this batch. The remaining items are large, so
they wait for the next session, in this suggested order:

1. ~~Compaction marker, dialog and compaction-model picker~~ **done
   2026-10-06** (section above).
2. ~~Activity roll-up and expanding thinking while it streams~~ **done
   2026-10-06**.
3. ~~Smooth streaming~~ **done 2026-10-06**.
4. Screenshot attach (`ScreenshotCaptureService`, a shared-artifact turn).
5. Chat import guide (`ImportGuideSheet`, `ImportHistoryPromptGate`).
6. Markdown document view (`MarkdownBlockParsing`, `MarkdownDocumentView`).
7. Activity / dispatch rows (`DispatchEnvelope`, `AgentDispatchTarget`,
   `NativeDispatchBadgeRow`).
8. Context attribution (`ContextAttribution`).
9. `AgentDetailChrome` and `BuiltInAgentGuard`.
10. Slash-command registry parity.

After that comes the model picker (`W-model-picker-2947`).
