# Upstream audit and port — 2026-09-29

**Range:** `a4daf94c4..3dad2dad4` on `osaurus-ai/osaurus/main`, fetched
2026-09-29. **33 commits (no merges), 33 classified below.** Verdicts use the
vocabulary of [`UPSTREAM_AUDIT_2026-09-25.md`](UPSTREAM_AUDIT_2026-09-25.md)
(Port / Stage / Covered / Split / Omit). Unlike that audit, this one also
**ships** the Port slices, in the same change (tests in
`Tests/Folder/IntelUpstreamBatch0929Tests.swift`). The next review begins at
`3dad2dad4` (exclusive).

## Shipped on Intel (awaiting Rosy)

| Upstream | What Intel got |
|---|---|
| #2894 `79f978e16` | `FolderToolHelpers.contentLines`: CRLF is one line and a final newline adds none, so `file_read` / `file_search` / `file_write` line numbers match an editor. Before, `components(separatedBy: .newlines)` counted CRLF twice. |
| #2893 `0ee595278` (slice) | `OptionalIntFieldEditing.reconcile`: typing "1" on the way to "15" in a clamped (5…100) settings field no longer snaps to "5"; leaving the field canonicalizes it. On Intel the only visible clamped fields (Server › Advanced HTTP body limits) start at 1, so this is mostly latent; it protects future fields. The context-cap, follow-up and search-anchor slices do not apply (see below). |
| #2909 `fcda29d39` | Block-based scroll anchor: when a run ends while you are scrolled up, rows inserted above no longer push you to older content. The anchor is saved before `blockIds` changes and resolves by block id. |
| #2914 `0c27f14c1` (text slice) | `FileEditMatcher` (upstream file, unchanged): exact → whitespace-normalised → blank-line-tolerant → unicode-punctuation cascade that copies unchanged lines from the file, keeps line endings/BOM, maps indentation, and refuses ambiguous relaxed matches. `file_edit` gains `replace_all`, reports `match_strategy` / `replacements` / `matched_lines` with a warning quoting the file text, and a not-found diagnosis (line-number prefixes pasted from `file_read`, closest line). |
| #2918 `0a114acdb` | `prompt_working_folder`: a custom agent in an attended, folder-less chat can open the folder picker (with its reason as the panel message); on a pick the chat ends the run and continues with `send("")` so the file tools appear. Intel differences are in the file header of `Folder/PromptWorkingFolderTool.swift`: offered by `ChatSession.canPromptForWorkingFolder`, session passed via `ChatExecutionContext.currentChatSessionBox` only for that run, the pick is **per chat only** (Intel's agent default folder stays an explicit choice), no sandbox step, never for the Orchestrator. The database tools' no-folder message now names it first. |
| #2916 `541a1b559` (adapted) | "Worked for 12.3s" leads the assistant stats row: from the user's message to the reply's last assistant turn's `completedAt` (tool steps and approval waits included). Derived from existing persisted fields (`createdAt`/`completedAt`), so old chats show it too; no new storage. |
| #2912 `612c48626` (simplified) | Collapsed minimap packs ticks to fit 280 pt; past about 130 messages each tick stands for a group (lit when the current message is in it). Intel already had the scrollable expanded list (Renée, 2026-06-13) and keeps it; the tick-to-row morph is preserved whenever every message has its own tick. Upstream's two-value `onChange`/scroll-centring is not ported (Ventura). |

## Classification

**Verdict rule (Renée, 2026-09-29):** "Omit" is not allowed for "Intel lacks
the prerequisite". Every commit is one of:

- **Incompatible** — needs Apple Silicon hardware (MLX/Metal local
  inference) or is an upstream-only artifact (their appcast, their tests of
  code Intel cannot run).
- **Omit (not a feature)** — compiles, but carries nothing for Intel users
  (upstream marketing). Rare; say why.
- **Needs work** — portable once a named prerequisite lands; the
  prerequisite goes on the backlog.
- **Needs work + decision** — portable, but conflicts with a standing Intel
  policy (for example, no automatic paid calls) until Renée decides.

| # | Commit | Verdict | Intel note |
|---:|---|---|---|
| 1 | `76eda8b78` #2888 | **Incompatible** | Update polling for MLX local models. MLX runs only on Apple Silicon (Metal); Intel has no local model runtime to update. |
| 2 | `c97f5e701` #2882 | **Incompatible** | Retires the MLX Raptor v0.5 model and rewrites upstream's own What's New copy. (Intel's What's New screen still carries upstream 0.17.7 notes and never matches an Intel version; writing Intel's own release notes is a separate, possible task.) |
| 3 | `0802d9692` #2890 | Split | MLX generation-defaults slice: **incompatible**. Child output-budget admission slice: **needs work**, lands with native subagents (staged; Intel has bounded delegation today). |
| 4 | `fb3d06a58` #2889 | Covered | Intel's `CloudChatEngine` already ignores empty streamed tool names (`!n.isEmpty`) and tells the model when no tools are offered. Evals/tests are upstream-only. |
| 5 | `3388439f7` #2892 | **Needs work + decision** | Background description backfill. Upstream runs it on a free local core model; Intel has none, so it would be paid cloud calls. Portable as an **opt-in** ("fill missing descriptions in the background with model X"), off by default. |
| 6 | `74f80f721` #2895 | **Incompatible** | Test-only change to the MLX model manager's tests. |
| 7 | `0ee595278` #2893 | Split → **Port** | Integer field shipped. Context cap: Intel's `ChatConfiguration` has no `contextLengthCap`. Follow-up parsing: Intel has no follow-up suggestions. Search anchors: Intel's settings index is its own. |
| 8 | `79f978e16` #2894 | **Port** | Shipped. |
| 9 | `d1f1bdfbd` | **Incompatible** | Upstream's own release feed (arm64 builds, their signing key). Intel publishes its own appcast. |
| 10 | `be3617236` #2896 | **Incompatible** | MLX runtime pin (Apple Silicon only). |
| 11 | `a7d2f37e7` #2897 | **Needs work + decision** | Backfill follow-up; lands with #5. |
| 12 | `610aa089a` #2898 | **Needs work + decision** | Shows backfilled purposes in pickers; lands with #5. |
| 13 | `d8d24271b` #2875 | Stage | iOS app integration (mobile relay, phone chats). Needs the mobile/relay backend (B1). |
| 14 | `f90c8dcb3` #2899 | **Needs work** | Fix for cross-block drag selection. Prerequisite: port that feature first (upstream #2247 `5212ffbc6`, `ChatCrossSelection.swift`, ~320 lines), never ported to Intel. |
| 15 | `3479aedc8` #2901 | **Needs work + decision** | Backfill follow-up; lands with #5. |
| 16 | `c9e2d61a9` #2900 | Covered | Upstream's SQLite history dropped generation metrics; Intel's history already encodes TTFT, tok/s and token counts. |
| 17 | `12a02a9f7` #2902 | **Needs work** | Export timing for restored chats. Prerequisite: Intel chat export, removed in 1.0.34 because its files are excluded; Renée wants it back (`MEMORY_PLAN.md` §3b). |
| 18 | `4b7dd0f1a` #2905 | Omit (not a feature) | Upstream's Product Hunt launch dialogs asking users to vote for their product. Compiles on Intel; there is nothing for Intel users. |
| 19 | `a53e1b45e` #2906 | Omit (not a feature) | Fix to the Product Hunt dialogs (#18). |
| 20 | `9e3bde41f` | **Incompatible** | Upstream's own release feed (see #9). |
| 21 | `74e83c6c5` #2907 | **Stage** | Three features; see the plan below. |
| 22 | `fcda29d39` #2909 | **Port** | Shipped (hand-ported; Intel's scroll files diverge). |
| 23 | `1faed06fb` #2910 | **Needs work** | Tab strip vs inspector rail. Prerequisite: browser-style chat tabs (upstream #2630 `ae942a150`, already ROADMAP-feasible in `DEFER_FEASIBILITY_AUDIT_2026-09-08.md`), not yet ported. |
| 24 | `612c48626` #2912 | **Port** (simplified) | Shipped. |
| 25 | `1eb0faddf` #2911 | **Needs work** | Per-tab scroll memory; lands with chat tabs (#23). |
| 26 | `e1ff79b51` #2913 | Split | Local-model update card: **incompatible**. Osaurus Connect (phone pairing) card: **needs work**, lands with B1. |
| 27 | `0c27f14c1` #2914 | Split → **Port** | Text slice shipped. Document slice (DOCX/PPTX/PDF editing, AcroForm filling) needs #2907's editors; `ToolWirePropertyOrder` (xAI constrained decoding) and `edits`/`operations` argument normalisation belong with the fuller `file_edit` (batch `edits`, `dry_run`) — staged with #2907 part B. |
| 28 | `541a1b559` #2916 | **Port** (adapted) | Shipped. |
| 29 | `694efa53a` #2915 | Stage | Workspace pool billing (B7). |
| 30 | `0a114acdb` #2918 | **Port** | Shipped. |
| 31 | `764124dce` #2917 | **Incompatible** | MLX gathered-matmul runtime (Apple Silicon only). |
| 32 | `0cd7d294f` #2931 | Stage | Phone "worked-for" span over the mobile protocol (B1). |
| 33 | `3dad2dad4` #2930 | Stage | Phone chat handoff and quick actions (B1). |

## Needs-work backlog from this batch

| Prerequisite | Unblocks |
|---|---|
| Cross-block chat selection (upstream #2247) | #2899 |
| Browser-style chat tabs (upstream #2630) | #2910, #2911 (and #2907 part C's tab strip) |
| Intel chat export (MEMORY_PLAN §3b) | #2902 |
| Opt-in background description generation (decision: paid model, off by default) | #2892, #2897, #2901, #2898 |
| Native subagents (staged) | #2890 admission slice |
| Mobile pairing / relay (B1) | #2875, #2913 Connect card, #2930, #2931 |
| Workspaces billing (B7) | #2915 |
| #2907 A/B/C (plan below) | #2914 document slice |

## Staged plan for #2907 (and the #2914 document slice)

`74e83c6c5` is three independent features. Each is feature-sized (the whole
commit is +19.8k/−7.5k lines), so each should be its own release with its own
Rosy checklist, like the Apple apps.

**A. Per-chat file change history.** Every mutating tool call is journaled as
a change set with exact before/after content in a content-addressed store
(`Services/FileHistory/*`, ~3.3k lines), shown in a File Changes inspector
pane (Timeline | Files, per-file and Revert All with preview and conflicts)
and via `file_undo`; retention under Privacy › Storage. Intel today has
`FileOperationLog` undo (binary-safe since #91). Intel work: port the journal
and object store onto Intel storage (encrypted storage root, test-storage
safety), capture from Intel's folder tools and `shell_run`, a Ventura-safe
pane, migration of the existing undo log. Largest part.

**B. In-place document editing.** `file_edit` `operations` for
.docx/.xlsx/.pptx/.pdf (validate-then-swap), `file_read` `mode: "structure"`
listing addressable paragraphs/cells/slides/pages, plus the #2914 hardening
(tolerant run/paragraph matching, AcroForm `fill_form`, argument
normalisation, batch `edits`/`dry_run`, `ToolWirePropertyOrder`). Brings the
OOXML package/DOM and ZIP writer that #91 skipped, so it also unlocks
`.pptx` writing (`PPTXEmitter`). Natural follow-on to rich folder formats.

**C. Chat window information architecture.** Left navigator (Agents |
Projects), right inspector (File Changes | History), projects as folders of
chats. Intel's chat window has diverged (no tabs, Ventura-themed controls);
treat as a design decision, not a port. Depends on A for the File Changes pane.

Suggested order: B (smallest, extends shipped #91), then A, then decide C.

## Rosy checklist

"Upstream batch 2026-09-29" in
[`ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`](ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md).
