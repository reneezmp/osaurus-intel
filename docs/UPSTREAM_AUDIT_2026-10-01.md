# Upstream audit and port — 2026-10-01

**Range:** `b023f2c1e..fec69aa53` on `osaurus-ai/osaurus/main`, fetched
2026-10-01. **16 commits (no merges), 16 classified below.** Verdicts follow
the rule in [`UPSTREAM_AUDIT_2026-09-29.md`](UPSTREAM_AUDIT_2026-09-29.md#classification)
(Incompatible / Omit (not a feature) / Needs work / Needs work + decision,
plus Port / Covered / Split / Stage). The Port slices ship in the same change
(tests in `Tests/Chat/IntelUpstreamBatch1001Tests.swift` plus upstream's own
test files). The next review begins at `fec69aa53` (exclusive).

## Shipped on Intel (awaiting Rosy)

| Upstream | What Intel got |
|---|---|
| #2954 `87a9c5966` | `ProcessInputValidation` (upstream file): a NUL character in a process argument or environment string is refused with a normal tool error before launch. Before, Foundation raised an Objective-C exception and the app crashed. Hooked into `FolderToolHelpers.runProcessAsync` and `shell_run` (before its pipes and live-output registration), as upstream. |
| #2961 `bb846bc25` | Notes tools: the folder walk runs inside `tell application "Notes"`, fixing error −1708 ("doesn't understand the count message") in `notes_folders`, `notes_list` / `notes_search` without a folder or with a folder name, and `notes_create` with a folder. Intel's file was identical to upstream's before the fix; taken verbatim with the test. |
| #2963 `a64231c3e` | Chat tabs stay inside the chat column: the strip follows the sidebar's **live** on-screen width (`ChatWindowState.sidebarColumnWidth`, published by `ChatContentView`) instead of the persisted default, so it no longer lags a resize drag; and the `onDisappear` reset that zeroed the rail widths after a tab switch (tabs running under the open inspector) is gone. |
| #2960 `b6c96793c` | Code blocks: repeated taps on Copy no longer reset the checkmark early, the button shows a pointing hand, and a "Code copied to clipboard" toast confirms. The transcript renders at the table column's real width (`onContentWidthChanged` from `tile()`), so an always-visible scrollbar (mouse users) no longer shifts the layout after a copy. Brings upstream's earlier `lastFittedContentWidth` gate, which only refits the column when the width changes (a long-chat hang fix Intel lacked). |
| #2959 `8f7721c3b` | The stats row under replies (Worked for, TTFT, tok/s, tokens) moves into the reply's "…" menu: **Inspect response** becomes a submenu listing the values, then "Open request and response log". The row now appears only for the "thinking didn't close" warning. Intel: no model-load or cached-input values (Intel doesn't record them); the log entry opens the Insights tab as before (upstream focuses the response's own log; see #2926 below). |

## Classification

| # | Commit | Verdict | Intel note |
|---:|---|---|---|
| 1 | `74cf7ad1c` #2947 | **Stage** (`W-model-picker-2947`) | Chat model picker redesign (provider and model columns, reasoning controls), a Cloud model browser and a Credits card in the chat, with a new `AnchoredCardPresenter`. Feature-sized (+4.9k lines); plan below. |
| 2 | `87a9c5966` #2954 | **Port** | Shipped. |
| 3 | `e8a7bdb52` #2953 | **Incompatible** | MLX runtime pin. |
| 4 | `46c55f0ec` #2955 | Covered | Model-switch advisory UX. Intel never had the advisory, and since #2952 it only appears when leaving a local MLX model, which Intel can't run. |
| 5 | `f4e5c8183` #2956 | **Incompatible** | MLX runtime pin. |
| 6 | `4228b9b5f` | **Incompatible** | Upstream's own appcast (0.25.16). |
| 7 | `94fb98070` #2958 | **Needs work** | Osaurus Cloud starter favourites and the picker's options column. Prerequisites: favourite models (`FavoriteModelsStore`, upstream #1811, part of `W-providers-ux`) and #2947. Lands with `W-model-picker-2947`. |
| 8 | `8f7721c3b` #2959 | **Port** | Shipped. |
| 9 | `b3b9091c7` #2926 | **Port** (via #2964) | Insights snapshots computed off the main queue. Superseded upstream by #2964's store-backed service, which Intel ported on 2026-10-01 together with #1595 and #1350 ([`INSIGHTS_INTEL.md`](INSIGHTS_INTEL.md)). |
| 10 | `106580a0d` #2921 | Covered | Tool grants refreshed between turns and rechecked at dispatch. Intel composes the tool list on every send (no frozen session catalog: `SessionToolStateStore` is not compiled) and `ToolRegistry.runtimeCapabilityDenial` rechecks the live agent settings on every call, after any approval prompt. The `capabilities_load` re-load slice targets upstream's gateway; Intel's gateway authorises each load against the agent's allowlist. |
| 11 | `bb846bc25` #2961 | **Port** | Shipped. |
| 12 | `a64231c3e` #2963 | **Port** | Shipped. |
| 13 | `0af061408` #2962 | **Incompatible** | MLX runtime pin (post-answer cache). |
| 14 | `2e3179f8a` #2965 | **Needs work** | WhatsApp channel helper keeps final responses when it exits. Prerequisite: the WhatsApp channel (`W-channels`, upstream #2290). |
| 15 | `b6c96793c` #2960 | **Port** | Shipped. |
| 16 | `fec69aa53` | **Incompatible** | MLX runtime pin (GPU attention-mask perf). |

## Staged: `W-model-picker-2947` (#2947, then #2958)

Upstream redesigned the chat's model picker into a multi-column card
(providers | models | options), added a Cloud model browser dialog with
categories and a Credits card anchored in the chat, plus a typography token
(`smallBody`) used by the theme editor. Intel's picker is the older
dropdown (`ModelPickerView`) over Intel's own provider manager.

1. Port `FavoriteModelsStore` (#1811) — the picker and the Cloud browser
   both read it (`W-providers-ux` item).
2. `AnchoredCardPresenter` + `AnchoredCardResizeTransition` (generic,
   verbatim; Ventura check: single-value `onChange`, no `onGeometryChange`).
3. `ChatModelPickerCard` over Intel's picker items; `FloatingInputCard`
   wiring; remove the pill's trailing icons.
4. `CloudModelBrowserDialog` (Osaurus Cloud models from Intel's provider
   manager) and the Credits card.
5. #2958: starter favourites and the unified options column.
6. Theme token + editor, guide text, strings.

## `W-insights-sync` — shipped 2026-10-01

Upstream replaced Insights with a persisted activity log in #2964 a few hours
after this audit, so Intel ported that design instead of the plan staged
here. Stage A (redactor hardening, `4ffa176fb`) and stage B (store, UI,
chat rows, Inspect response) and stage C (per-feature emitters) are done;
details in [`INSIGHTS_INTEL.md`](INSIGHTS_INTEL.md).

Manual QA for the shipped slices:
[`ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`](ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md#upstream-batch-2026-10-01).
