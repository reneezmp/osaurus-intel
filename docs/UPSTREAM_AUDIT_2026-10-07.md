# Upstream audit and port — 2026-10-07

**Range:** `4064a6fde..66ea7ebc4` on `osaurus-ai/osaurus/main`, fetched
2026-10-07. **40 commits (no merges), 40 classified below.** Verdicts follow
the rule in [`UPSTREAM_SYNC.md`](UPSTREAM_SYNC.md#verdict-rule-doesnt-apply-is-not-a-verdict--2026-09-29):
Incompatible only for Apple Silicon (MLX/Metal local inference) or
upstream-only artifacts; "Intel doesn't have X yet" is **Needs work** with X
named on the backlog; a policy question is **Needs work + decision**. Being
hard to port never takes a commit off the list. The next review begins at
`66ea7ebc4` (exclusive).

Two commits were already ported while finishing `W-chat-ux` and the model
picker: #3017 (`5cae5ad23`, except its lone-tab styling, ported here with
#2995) and the post-#2978 streaming processor.

## Classification

| # | Commit | Verdict | Intel note |
|---:|---|---|---|
| 1 | `1118c8ea5` #2973 | **Incompatible** | Fits a *resident* (local MLX) delegation context to available memory; native subagents' local residency. |
| 2 | `4b69a9c1c` #2976 | **Port** | PDF table cell identity and glyph/bounds pairing in `PDFAdapter` / `PDFTableDetector` (both on Intel). |
| 3 | `dae94983e` #2978 | Covered | Removes upstream's stream-repetition heuristic and forced retry. Intel never had the heuristic, and its `StreamingDeltaProcessor` is already upstream's post-#2978 file (ported 2026-10-06); the rest is an MLX pin. |
| 4 | `fa47416a8` #2979 | **Needs work** (`W-privacy-filter`) | International regex presets, checksum validators and the region picker. Portable (no MLX), but Intel has no Privacy Filter yet; this lands with that workstream's regex half. |
| 5 | `cce2803d4` #2977 | **Port** | `NSButton(title:target:action:)` in `NativeAssistantActionsView` hung the main thread (Sentry). |
| 6 | `20e297122` #2982 | **Split:** Port (polling cuts) + **Needs work + decision** (announcements feed) | Router control-plane polling cuts apply to Intel's account service. The announcements feed (`AnnouncementsService`, dialog, deep links) is portable, but upstream's announcements may advertise Apple-Silicon-only features: decide whether Intel shows them (filtered or not). The removed Product Hunt campaign never existed on Intel. Workspaces sync throttling waits for `W-workspaces-identity-mobile`. |
| 7 | `83b9166e3` #2983 | **Port** | PDF reading order for flattened forms (`PDFReadingOrder`), page headers in text fallback, `file_read` pages. |
| 8 | `3b0730d0d` | **Incompatible** | Upstream's own appcast (0.25.17). |
| 9 | `e53ae1106` #2984 | Covered | Hardens the scheduler's "start once storage unlocks" observer. Intel starts `NextRunScheduler` directly at launch and has no storage-unlock deferral, so the race can't happen. |
| 10 | `0a50e1371` #2986 | **Incompatible** | MLX runtime pin. |
| 11 | `2dea0aeb6` #2972 | **Incompatible** | MLX runtime pin (M5 Max rotary). |
| 12 | `fcb332320` #2990 | **Split:** Port (robustness + catalog) + **Needs work** (elicitation, `W-mcp-providers`) | Intel has the MCP provider manager, OAuth and templates: hint-driven approvals, plain-language errors, 401 → sign-in, connect coalescing, progress-token timeouts and the new connectors port. MCP elicitation (form/URL prompts) needs its prompt service and view. |
| 13 | `98b1fec16` #2991 | **Incompatible** | MLX runtime pin. |
| 14 | `8cc221e7e` #2994 | **Incompatible** | MLX runtime pin. |
| 15 | `cb31510b2` #2996 | **Incompatible** | Local image-generation producers (MLX). |
| 16 | `1d1714de1` #2995 | **Port** | Safari-style tab track, with #3017's quiet lone tab (`W-chat-tabs` follow-up). |
| 17 | `b248e21b5` #2998 | **Port** | Agent avatars rendered at exact pixel size (crisp). |
| 18 | `3cb2ab085` #2997 | **Incompatible** | Qwen-Image 2.1 local generation/editing (MLX). |
| 19 | `8af73f9f0` #2999 | **Split:** Covered + Port | Intel's `CloudChatEngine.completeChat` already streams Codex one-shots, so compaction, titles and follow-ups work on ChatGPT models. Port upstream's `/compact` messages (already running / streaming / nothing to compact). |
| 20 | `4a33301b1` #3000 | **Incompatible** | MLX runtime pin. |
| 21 | `25416b0b7` #3001 | **Incompatible** | MLX runtime pin. |
| 22 | `bade79a86` | **Incompatible** | Upstream's own appcast (0.25.18). |
| 23 | `2fe5cc3f0` #3002 | **Incompatible** | MLX runtime pin. |
| 24 | `3b6ea83be` #3004 | **Incompatible** | MLX runtime pin. |
| 25 | `4659188a5` #2980 | **Needs work** (`W-workspaces-identity-mobile`) | Paired phone manages agents and chats over a secure channel. Intel has no phone pairing or secure channel yet. |
| 26 | `c20888999` #3005 | **Incompatible** | MLX runtime pin. |
| 27 | `1cc8d44dc` #3007 | **Port** | `DispatchRequest.reattachSession`: schedules group by key but always start a fresh chat. Intel's reattach lookup is a stub today, so behaviour is already fresh; the flag keeps it so if reattach lands. |
| 28 | `5a9abe0f3` #3008 | **Needs work** (`W-channels`) | Queue channel messages arriving mid-turn. |
| 29 | `802ba386c` #3006 | **Incompatible** | Native MTP controls (MLX). |
| 30 | `5ecc914f2` #3010 | **Needs work** (`W-channels`) | Steer channel messages into the running turn (`steerTask`, `remoteSteers`); needs channels and remote steering. |
| 31 | `44069eeab` #2922 | **Split:** Port + **Needs work** (`W-tools-misc`) | Chat table applies snapshots incrementally (Intel still used `animatingDifferences: false`, i.e. `reloadData`) and `StringCleaning` speedups. Intel's `StringCleaning` predates upstream's leaked tool-call JSON / Harmony label cleanup, which comes with it. The Seatbelt NUL check waits for the Seatbelt host-shell sandbox. |
| 32 | `5cae5ad23` #3017 | **Ported** (2026-10-06) | Model picker stage D; the lone-tab part ships with #2995 here. |
| 33 | `fb3adda14` | **Incompatible** | Upstream's own appcast (0.25.19). |
| 34 | `4d506c990` #3003 | **Port** | Tab layout persisted off the main thread (Sentry hang). |
| 35 | `b02aaad40` #3011 | Covered | Precomputes `PromptSection` token estimates. Intel's `PromptManifest` is an empty stub, so no section estimate runs during rendering. |
| 36 | `12f67c83c` #3018 | **Split:** Port + **Needs work** (`W-workspaces-identity-mobile`) | Retry a busy server port for a few seconds (Intel's AppDelegate starts the server once and only logs failure, so relaunching while the old copy quits left no local API). The pairing-code reason text waits for phone pairing. |
| 37 | `7aa5fcb2c` #3019 | **Incompatible** | K2-Horizon runtime and bundle-declared native reasoning modes (local bundles). |
| 38 | `ad71b7a7f` #3020 | **Incompatible** | Native MTP option for the phone's picker (MLX). |
| 39 | `dad736b7c` #3022 | **Incompatible** | MLX runtime pin. |
| 40 | `66ea7ebc4` #3028 | **Incompatible** | Local grammar-constrained JSON Schema output (MLX `JSONSchemaGrammar`). |

**Totals:** Port 7 · Split (with a Port part) 5 · Covered 3 · Needs work 4 ·
Incompatible 20 · already ported 1.

## Shipped on Intel (awaiting Rosy)

| Upstream | What Intel got |
|---|---|
| #2977 `cce2803d4` | The reply footer's "files changed" button is created with `NSButton(frame:)`; `NSButton(title:target:action:)` hung the main thread. |
| #3003 `4d506c990` | Tab layout is saved off the main thread (a busy cfprefsd hung the app). **Intel difference:** the quit path (`stopAllSessions`) saves synchronously, so the record can't be lost at exit. |
| #3007 `1cc8d44dc` | `DispatchRequest.reattachSession`; schedules pass `false`, so every run is a fresh chat even once reattach exists on Intel. |
| #2999 `8af73f9f0` (part) | `/compact` explains itself: already running, wait for the reply, or nothing to compact yet. |
| #3018 `12f67c83c` (part) | The local API server retries a busy port six times, a second apart, at launch (an Osaurus still quitting held it, and Intel ran with no API). **Intel:** a failed bind now shuts down its event loop group (Intel's server makes one per start). |
| #2922 `44069eeab` (part) | The chat table applies snapshots incrementally (`animatingDifferences: true`, no row animation) and does its follow-up work after `apply`, not inside AppKit's update (which recursed). Upstream's `MessageTableSnapshotApplyTests` pass on Intel. Upstream's current `StringCleaning` (faster `stripLeakedActionJSON`, plus the leaked-JSON, Harmony channel-label and Gemini metadata cleaners Intel's older copy lacked): finished assistant replies render cleaned, cached `visibleContent`; the live stream stays raw, as upstream. |
| #2998 `b248e21b5` | Agent avatars render through `AvatarBitmapRenderer` at the exact pixel size for the display scale (crisp, cached), in the chat headers, avatar view and theme editor. Intel's agent pill already uses `AgentAvatarView`, so upstream's pill hunk isn't needed. **Also:** upstream's `MemoryPressureResponder`, which Intel lacked entirely, frees the chat image, LaTeX, symbol and avatar caches on memory pressure (upstream's model-unloading tier has nothing to unload on Intel). |
| #2995 `1d1714de1` + #3017 (rest) | Chat tabs restyled as upstream's Safari-style track; a lone tab reads as the window title. Upstream's current `ChatTabStripView` with Intel's existing adaptations ([`CHAT_TABS_INTEL.md`](CHAT_TABS_INTEL.md)). |

## Found while porting

- **Shipped:** upstream's server hardening from #2239 (marked "port next"
  in `DEFER_FEASIBILITY_AUDIT_2026-09-08.md` but never done): one
  process-wide event loop group (`Networking/SharedEventLoopGroups.swift`,
  verbatim) instead of a group per start, a `ChildChannelRegistry` so
  `stop` drains and force-closes connections (8 s, or 1 s at quit), and
  `ConnectionLimitHandler` capping concurrent connections at 512. Intel's
  server restarts on Settings changes and retries a busy port at launch, so
  per-start groups were a real thread/descriptor leak (APPLE-MACOS-19T). The
  quit path now passes `gracefully: false` like upstream.
