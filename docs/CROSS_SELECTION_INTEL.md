# Cross-block chat selection on Intel

Upstream #2247 (`5212ffbc6`) and #2899 (`f90c8dcb3`), ported 2026-10-01
(part of `W-chat-ux`; Renée's order: after per-chat file history).

## What the user gets

- Drag across a reply: the highlight continues from one paragraph,
  heading, code block or table cell into the next, ChatGPT-style. Before,
  every block was its own text view and its own table row, so a drag
  stopped at the block where it started.
- The drag auto-scrolls near the top and bottom of the chat.
- ⌘C, right-click ▸ Copy and Edit ▸ Copy copy the whole selection (blocks
  joined with newlines), even after its first rows scrolled out of view.
- The cursor is an I-beam over chat text and a pointing hand over links.
- Double- and triple-click still select a word or paragraph natively.

## How it works (upstream, unchanged)

- `Views/Chat/ChatCrossSelection.swift` owns the drag: a single-click
  mouse-down in a participating text view starts a local event-tracking
  loop; each tick computes one range per block view between the anchor and
  the pointer (reading order in the table's flipped document) and rebuilds
  the copy string.
- Participating views (`CrossSelectableTextView`): `SelectableNSTextView`
  (markdown blocks), `CodeNSTextView` (code blocks, diff cards) and
  `CellTextView` (table cells). Each paints its slice at the top of
  `draw(_:)`, because these views run with `drawsBackground = false` and
  AppKit's own selection pass never shows.
- `ChatView`'s key monitor serves ⌘C; the views' `copy(_:)` /
  `validateUserInterfaceItem` serve the menus (#2899).
- `Color(hex:)` in `Theme.swift` now reads 8-digit hex as RGBA (web-style),
  as upstream. Intel's `CustomTheme.swift` already had this half of the fix;
  no Intel code passes 8-digit hex to `Color(hex:)` today.

## Intel differences

- `ChatCrossSelection.dragForTesting(from:down:to:)` (Intel test seam,
  end of the file): one drag tick without the tracking loop. A test
  process has no running event loop, so `beginDrag`'s
  `window.nextEvent` waits forever (found 2026-10-01: a test that posted
  synthetic drag/up events hung).
- Everything else is upstream's code; the four Intel files carry exactly
  upstream's additions.

## Tests

`Tests/Chat/IntelCrossSelectionTests.swift`: a drag from one block into
the next selects both slices and joins them, Copy stays enabled, another
window can't copy it, `clear()` drops every slice; 8-digit hex is RGBA.
The tests never write the system pasteboard (see
[`TEST_STORAGE_SAFETY.md`](TEST_STORAGE_SAFETY.md) rule 10).

Manual QA: [`ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`](ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md#cross-block-chat-selection).
