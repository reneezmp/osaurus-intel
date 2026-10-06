# Context budget indicator on Intel

Renée's request, 2026-10-01: match upstream's context budget icon and
popover, which had drifted far from Intel's. Upstream's current design is
the ring chip + "wallet-style" popover (reworked through #1512 and #2947).

## What the user gets

- A small **ring** in the composer's button bar, left of Send/Stop
  (Intel's old "~33k / 128k tokens" text chip sat at the right of the
  selector row). The ring fills with the share of the usable budget, turns
  **amber** at 85% of it and **red** when the part compaction can't trim
  no longer fits. Hover previews the popover; a click pins it.
- The **popover** (upstream layout):
  - a header with "Context Budget", a status pill (N% used / Near limit /
    Over limit), "~N tokens used", "N remaining of M usable" and where the
    window comes from;
  - a usable-budget bar;
  - a composition bar (share of used context);
  - **Sources**: system prompt sections roll up behind one "System Prompt"
    row (click to expand), with Memory and Tools as their own rows;
  - **Messages**: conversation, input, output;
  - **Compaction**: "Compact conversation" when an older part of the chat
    can be summarized, or progress while it runs;
  - a link to the Context Length setting.

## How it works

- `Services/Chat/IntelContextBudget.swift`: upstream's assessment rules
  (`AgentLoopBudget.assess`): usable budget = window × 85%; near limit at
  ≥ 85% of that; over limit when everything except conversation/output
  history, plus the response reservation (the agent's max tokens, capped
  at a quarter of the budget, default 4096), exceeds it. Also
  `ContextBudgetUtilization` / `computeContextBudgetUtilization`
  (upstream, verbatim).
- `FloatingInputCard`: `ContextBudgetSnapshot` (one pass per render, as
  upstream), `contextBudgetRing`, and upstream's `FloatingContextChip`,
  `ContextBreakdownPopover`, `BudgetGroup` and `PopoverCardModifier`.
- `ChatSession.canCompactConversation` (an older span exists,
  `IntelContextCompaction.compactionCutIndex`) drives the popover's button.

## Intel differences

| Upstream | Intel | Why |
|---|---|---|
| Window from `AgentLoopBudget.resolveContextWindowResolutionSync` (bundle / provider metadata / user cap) | Model catalog (`ModelInfo`), else Settings › Conversation › Context Length (`.userSetting`, labelled "Your context limit"), the same resolution Intel's compaction suggestion uses | `AgentLoopBudget` isn't compiled; most cloud models aren't in Intel's catalog |
| Over limit blocks Send (except under a user cap) | Never blocks; the red ring is advisory | Intel's window is usually the Settings value, which upstream also never lets block a send |
| Disk Cache section (on-SSD prompt cache) | Not shown | MLX-only |
| Compaction rows for completed / failed runs | Running and "Compact conversation" only | Intel reports results as toasts (or in the dialog when it is open). The helper text is upstream's since 2026-10-06: it names the Compaction Model, else the current chat model ([`CHAT_UX_INTEL.md`](CHAT_UX_INTEL.md)) |
| "Open Context Window Cap" (Server › Cache) | "Open Context Length" (Settings › Conversation › Advanced) | Intel's equivalent setting |
| Right-click "Compact Conversation" on the old Intel chip | Removed (upstream has none); compaction is in the popover, the slash command and the "getting long" notice | Follow upstream |
| `onChange(old, new)` | Single-value `onChange` | macOS 13 |

## Tests

`Tests/Chat/IntelContextBudgetTests.swift`: usable budget and near-limit
ratio, only the non-compactable part can overflow, reservation cap,
utilization never invents a limit, window source (catalog vs setting).
Rendering checked offscreen 2026-10-01 in light and dark: ring states
(normal / amber / red) and the popover sections.

Manual QA: [`ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`](ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md#context-budget-indicator).
