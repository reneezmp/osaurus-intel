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
| #2976 `4b69a9c1c` | PDF tables keep cell identity and pair glyphs with their bounds (upstream's current `PDFAdapter` / `PDFTableDetector`, with their tests). |
| #2983 `83b9166e3` | Flattened PDF forms read in visual order (`PDFReadingOrder`: a label and its value share a line), `--- Page N of M ---` markers in the text, a hidden-content security finding, and `file_read` `pages: "3"` / `"3-5"` with `pages`, `pages_with_text`, `pages_layout_ordered`, `pages_requested` and the provenance note. **Intel:** Intel's `file_read` is older than upstream's (no `format`/`source` on every read, no `tail_lines`/`max_chars`), so the PDF path was hand-applied: `file_read` now reads PDFs through `PDFAdapter` like upstream, keeping Intel's OCR fallback for scanned PDFs. Upstream's file_read PDF tests run as `IntelFileReadPDFPagesTests` (Intel's gutter has a space after the bar). Upstream's `FileSearchDocumentsTests` came along (its flattened-form test passes: a form row is one search hit), minus three skipped-files-note tests for a `file_search` feature Intel never got. Not ported: the in-app guide line (no guide on Intel, `W-ui-misc`). |
| #2982 `20e297122` (part) | Router polling cuts in the account service: returning to Osaurus no longer fetches the balance (a signed request plus a synchronous keychain query on Intel) unless a Stripe top-up is pending, and then at most 10 times; `refreshBalance(ifOlderThan:)` with one shared in-flight request; billed summaries bump a debounced `usageRevision` that only an open Credits tab or usage center refetches on, instead of fetching `/credits/usage` per summary. Insights no longer logs `/announcements` or `/health`. Upstream's `OsaurusRouterAccountServiceTests` pass. **Intel:** the identity gate is still the keychain query (`existsCached()` memo is upstream #1523, not on Intel); there is no composer credits chip to use `ifOlderThan`; Intel never forwards Router summary frames yet (`W-router-billing`), so `usageRevision` waits on that. Workspaces sync throttling waits for `W-workspaces-identity-mobile`. |
| #2990 `fcb332320` | MCP connectors: hint-driven default approvals (read-only tools run without asking unless open-world; possibly destructive tools ask every call and the Tools menu hides Auto), plain-language connector errors with a Details toggle, tool pills with read-only/destructive icons, 401 on a tool call marks the provider as needing sign-in (Sign In offered for `.none` providers that publish OAuth), concurrent connects coalesced, progress tokens extend the tool-call idle timeout (10 min cap) and show after the running tool's title, `structuredContent` used when a result has no text, OAuth spec alignment (RFC 9728 path-inserted well-known, RFC 9207 `iss` check, issuer-bound client ids, Client ID Metadata Document, scope step-up), MCP swift-sdk 0.12.1, and upstream's full connector catalog (Dropbox, Dropbox Dash, Gusto, QuickBooks, Microsoft 365, Harvey, …) with category chips. **Elicitation shipped too** (not left for `W-mcp-providers`): servers can ask for a form or open a URL mid-call. Upstream's `MCPRobustnessTests`, `MCPElicitationTests`, `MCPSpecAlignmentTests`, template and OAuth tests pass. **Intel:** (1) Intel's MCP OAuth was an older fork; this takes upstream's current `MCPOAuthService` / `Discovery` / `Registration` and the new `MCPOAuthHTTPTransport`, which also brings two older upstream commits Intel never had: #1276 (OAuth metadata and token traffic never follows redirects; discovered URLs may not point a public server at local or private addresses) and #1284 (HubSpot's confidential-client sign-in: Client ID + Secret form, fixed loopback port, secret in the keychain). Intel's HubSpot template asked for a private-app token, which HubSpot's MCP server rejects. (2) `MCPProviderKeychain` keeps Intel's fork-private keychain service and gains only the client-secret slot. (3) Elicitation prompts unless the run's caller is not at this Mac (local HTTP API or P2P); upstream's headless/external/unattended flags don't exist on Intel. (4) The elicitation panel's `safeAreaRegions` is macOS 13.3+ only. (5) The progress text goes after the row title (Intel's tool row has no shimmer label). (6) `MCPServerManager` is deleted as upstream (Intel never compiled it); upstream's `ExternalMCPToolPolicy` is not ported (see below). (7) Intel's `MCPProviderTool` stays text-only for media. (8) `docs/oauth/mcp-client-metadata.json` is upstream's published document; Intel uses the same hosted client id. Not ported: the in-app guide text (`W-ui-misc`), the template probe script. |
| #2982 `20e297122` (announcements) | Decided 2026-10-07: Intel shows upstream's Router announcements, marked as upstream's with a warning banner, an opt-out, `https` links only and no `app_version` ([`ROUTER_ANNOUNCEMENTS_INTEL.md`](ROUTER_ANNOUNCEMENTS_INTEL.md)). |

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
- **Gap in the 2026-09-29 #91 (#2791) slice:** upstream's unified
  `file_read` has `tail_lines`, `max_chars`, XLSX preview caps, directory
  reads and `format`/`source` metadata on every read, and `file_search`
  reports skipped files (`ContentSearchSkipTally`). Intel's slice left these
  out without listing them. Now on the backlog under `W-tools-misc` (file
  tool parity).
- **Router billing summaries never reach Intel's account service.** Known
  since 2026-09-02 ("Router billing ledger is dead code",
  `SYNC_0.24.3_PLAN.md`) and blocked on observing the frame shape; upstream's
  `OsaurusRouterSummaryEvent` decoder (already on Intel) defines it, so it is
  now a plain port: `W-router-billing` on the backlog.
- **`existsCached()` identity memo (upstream #1523, 2026-06-16) is not on
  Intel.** `OsaurusRouterAccountService` and other hot paths still call the
  synchronous keychain `OsaurusIdentity.exists()`. #2982 removed the
  per-activation call; the memo itself goes with
  `W-workspaces-identity-mobile`.
- **Upstream's external-caller deny model is not on Intel.** Upstream's
  `ExternalMCPToolPolicy` (stdio `osaurus mcp` and `/mcp/*`) relies on
  `ToolRegistry.externallyDeniedToolNames`,
  `ChatExecutionContext.isExternalSurface` / `isUnattendedDispatch` /
  `denyUnapprovedToolPrompts`, none of which Intel has; Intel's approval gate
  always prompts on this Mac. Checked 2026-10-07: not a live exposure.
  Intel's `POST /mcp` (`MCPBridge`) serves only three demo tools (`echo`,
  `get_time`, `os_info`) and none of the registry's tools, and there is no
  stdio `osaurus mcp` server. The policy is needed when Intel starts
  exposing real tools over MCP: `W-server-api`.
- **Tests could write the real keychain.** The documented test gate never
  set `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, which is what makes the
  keychain wrappers no-ops under tests. Added to the gate in
  `TEST_STORAGE_SAFETY.md`.
- **i18n baseline 154** (was 146): the 8 new entries are literals inside
  upstream's new test files (URLs and fixture labels the checker scans), not
  UI strings.
