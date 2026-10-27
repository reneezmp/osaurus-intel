# Upstream audit and port — 2026-10-26

**Range:** `24f4c416a..fc75a1e06` on `osaurus-ai/osaurus/main`, fetched
2026-10-26. **102 commits (no merges), 102 classified below.** Verdicts follow
the rule in
[`UPSTREAM_SYNC.md`](UPSTREAM_SYNC.md#verdict-rule-doesnt-apply-is-not-a-verdict--2026-09-29):
Incompatible only for Apple Silicon (MLX/Metal local inference) or
upstream-only artifacts; "Intel doesn't have X yet" is **Needs work** with X
named on the backlog. Deferred means a feature Renée deferred until someone
asks (`W-channels`, `W-workspaces-sharing`). The next review begins at
`fc75a1e06` (exclusive). `classify_gap.py` exits 0 and `classify_gated.py`
reports nothing unassigned at this point.

**Method.** Each commit's touched `OsaurusCore` files were checked against
Intel's `Package.swift` (compiled, excluded, absent, or `#if !OSAURUS_INTEL`),
and its diff to compiled files was test-applied to Intel's tree. Commits whose
title suggested a fix were read against Intel's own code before a verdict:
#3060 (theme library), #3130 (window pre-layout) and #3143 (context
overflow) were each first guessed wrong and corrected by reading Intel's code.

## Classification

| # | Commit | Verdict | Intel note |
|---:|---|---|---|
| 1 | `a40ab57ff` #3065 | **Port** | `AppleURLOpener`: the Apple-app `*_open_*` tools open URLs with the completion-handler `NSWorkspace` call instead of a synchronous one on the main actor (Sentry hang). All four tools and the test are on Intel; applies cleanly. |
| 2 | `b56d9892d` #3060 | **Needs work (`W-ui-misc`, theme library)** | Themes tab: validation and duplicate fingerprinting move off the main thread. Both come from `ThemeLibraryManagementService`, which Intel doesn't have yet (theme library management, `W-ui-misc`), so the hang can't happen here; the fix lands with the library. |
| 3 | `c0dc38588` #3058 | **Deferred (`W-channels`)** | WhatsApp config loading off the main thread; WhatsApp is part of the deferred channels. |
| 4 | `234e3bc20` #3067 | **Port** | The reply's copy button copies only the response, not the thinking (`copyTurnContent`; Intel's older body lacks the image-only and dispatch-envelope branches, hand-apply the thinking removal). |
| 5 | `5601f0cfa` #3053 | **Port** | Menu titles use `LCached` (on Intel since #2757) instead of `L` (Sentry hang). Hand-apply to Intel's menus. |
| 6 | `f52fc9a32` #3068 | **Port** | DeepInfra reports the context window under `metadata.context_length`. Intel's discovery is its own (`IntelStubConformers`, reads `max_model_len` / `context_length` / `max_context_length`): add the nested key, and upstream's `context_window` which Intel also lacks. |
| 7 | `96da338ac` #3069 | Incompatible | `/api/show` for external models resolved through the installed-MLX-model matcher (`INC-mlx`). |
| 8 | `6673ecf0b` #3070 | **Needs work (`W-identity-mobile`)** | Injected memory hidden in user bubbles for chats continued from the phone (`MobileConnect`, `InjectedContextSpans`). |
| 9 | `e5b42c836` #3066 | **Split:** Port (folder) + Incompatible (sandbox) | `file_write` loses the 30,000-character `content` cap (schema, wording) and gains `source_path` (render a document from a text file in the folder); schema rejections become non-retryable. Intel never had the 64 KiB stream abort. The `sandbox_write_file` chunking is `INC-containers`. |
| 10 | `6baa09383` #3063 | Incompatible | vMLX pin (background cache writes, bundled tokenizer); `MLXBatchAdapter` / `ModelRuntime`. |
| 11 | `826427670` #3073 | **Split:** Port + Incompatible (sandbox) | Workbook edits keep cell formatting and formulas (`XLSXPreservation`, `XLSXEditor`, `XLSXEmitter`, `FileWriteDocumentRouting`, all on Intel). The sandbox tool hunk is `INC-containers`. |
| 12 | `9792706be` #3074 | **Port** | PDF body-text edits no longer advise regenerating the PDF with `file_write`. Applies cleanly. |
| 13 | `648becefc` #3075 | Incompatible | vMLX pin (MiniCPM-V, DSpark warmup). |
| 14 | `a1544ee71` | Incompatible | Upstream appcast 0.25.21. |
| 15 | `7fa529787` #3078 | Incompatible | `CoreMLLoadSentinel` guards Core ML speech/TTS model loads (Parakeet, PocketTTS). Intel's voice uses Apple Speech and system voices; there is no Core ML load to crash. |
| 16 | `0f982c10b` #3079 | **Port** | Three Sentry crashes: plugin ABI slots must point into a loaded image (`dladdr`; Intel's loader is `IntelPluginExecution`, adapt there), the settings window's constraint loop (`AppKitOwnedWindowHostingController`; adapt to Intel's window code), the clipboard poller race (`IsolatedPasteboard`, `ClipboardService` on Intel). |
| 17 | `bd5b5b1a5` #3080 | **Port** | Chat table coalesces per-child height notes and stops grapheme-walking block equality (`MessageTableRepresentable`; `ContentBlock` is Intel's own, adapt the equality change). |
| 18 | `333fed176` #3082 | Incompatible | vMLX: Liquid tools, LFM runtime. |
| 19 | `077c17a06` #3083 | **Port** | Pinned-memory text matches ranked by relevance before salience (`MemoryDatabase`, on Intel). |
| 20 | `e6fb7a63d` #3084 | **Needs work (`W-computer-use`)** | Screenshot scrubbing failures stop cloud attachment (`ComputerUse`). |
| 21 | `13c16fbba` #3085 | Incompatible | MLX model and subagent admission weights. |
| 22 | `b441a4a1f` #3087 | Incompatible | vMLX pin; the `IsolatedPasteboardTests` hunk comes with #16's port. |
| 23 | `68619074d` | Incompatible | Upstream appcast 0.25.22. |
| 24 | `382011839` #3095 | Incompatible | Local image workflow parameters (`ImageGenerationService`, MLX). |
| 25 | `972cc657e` #3096 | Incompatible | SeedVR2 local upscaling and job cancellation (MLX). |
| 26 | `3425dcf55` #3098 | Incompatible | Native (local) image batches in the API, tools and galleries. |
| 27 | `5e905991b` #3106 | **Needs work (`W-identity-mobile`)** | Short spoken replies on a paired phone's voice-call turns. |
| 28 | `5f66b028a` #3116 | Covered | Intel's `saveAgent` already passes `workingFolderBookmark` / `workingFolderPath` through from the stored agent, so saving the editor never cleared the folder. |
| 29 | `fc7ef8184` #3115 | **Port** | Gemini reasoning-effort control (`GeminiReasoningContract`, picker item). Intel ships native Gemini presets on its own provider service; adapt the request mapping there. |
| 30 | `a5cded095` #3113 | **Deferred (`W-channels`)** | Slack: messages posted through apps by allowlisted senders. |
| 31 | `e82893b00` #3114 | Incompatible | Nemotron Super-VL local runtime and local vision evidence. |
| 32 | `657220cd8` #3118 | Incompatible | Image bundles kept out of the language-model download path (local models). |
| 33 | `2f777b30c` #3119 | Incompatible | vMLX pin and declared reasoning modes for local bundles (`DeclaredReasoningEffort` is local-model only). |
| 34 | `f4a877ff8` #3104 | **Split:** Incompatible (local) + Needs work (`W-media-generation`) | Local image/video workflow controls are MLX. The shared parts (`MediaGenerationCoordinator`, `video` tool, the grounded-write check accepting a completed `image`/`video` result) come with `W-media-generation`. |
| 35 | `e614fc0ac` | Incompatible | Upstream appcast 0.25.23. |
| 36 | `1e5bfab23` #3125 | Incompatible | Allosaurus local runtime, residency settings, SSD cache. |
| 37 | `7f392f329` #3129 | Incompatible | vMLX pin (48 GB adaptive MTP). |
| 38 | `c0c4ca744` #3132 | Incompatible | Qwen hybrid local memory estimates and residency. |
| 39 | `24e5121b1` #3133 | **Port** | Model picker: a search that filters out the selected row no longer leaves an empty model column (`ChatModelPickerCard` resets its scroll identity; on Intel). |
| 40 | `658cb49e1` #3135 | **Needs work (`W-identity-mobile` + `W-privacy-filter`)** | Phone runs own their Mac chat, spoken-number PII detection, a phone call setting the privacy filter. The sidebar/tab hunks only render phone-owned chats. |
| 41 | `7cf530e13` #3140 | Incompatible | Ornith local runtime and vMLX pin. |
| 42 | `4b32bf653` #3141 | **Port** | `gpt-6.1-sol` in the ChatGPT (Codex OAuth) model list; Intel has `OpenAICodexOAuthService`. |
| 43 | `b3ba3d150` #3142 | Incompatible | vMLX pin. |
| 44 | `1e2e75849` #3143 | Covered | Estimated context overflow no longer refuses a turn. Intel never gated sends on `hardOverflow` and `IntelContextBudgetManager`'s `overBudget` is only reported, never used to refuse; `AgentToolLoop` is upstream's native loop. |
| 45 | `78232d434` #3145 | Incompatible | FLUX 3 Image Klein local image generation. |
| 46 | `783b408e9` #3146 | **Deferred (`W-channels`)** | Slack confirm sheet placement. |
| 47 | `ea120774f` | Incompatible | Upstream appcast 0.25.24. |
| 48 | `2a6eaf5bd` #3147 | Incompatible | vMLX pin. |
| 49 | `055f071ec` #3149 | Incompatible | Native image composer paste/regeneration (local image models). |
| 50 | `4f8ba2103` #3151 | Covered | `ChatTurn.contentRevision` for `BlockMemoizer`; Intel has neither (its own turn and no memoizer keyed on content length). |
| 51 | `0d8ef8a2b` #3152 | **Needs work (`W-identity-mobile`)** | Paired-phone features tied to the phone's access key. |
| 52 | `a48f4dd00` #3150 | Incompatible | Adaptive drafter loading (MTP settings). |
| 53 | `fdfa925ca` #3154 | Incompatible | SSD cache quotas (local KV cache). |
| 54 | `7ccdcf08b` #3155 | Incompatible | vMLX pin. |
| 55 | `bc313d630` #3156 | Incompatible | Retired cold-weight tier setting (local runtime); Intel never had it. |
| 56 | `4119d56f7` #3157 | **Port** | The RAM gauge uses the reclaimable-capacity definition (Activity-Monitor-like). Intel's status panel shows `SystemMonitorService`'s gauge. |
| 57 | `ed369ca69` #3158 | Incompatible | vMLX pin. |
| 58 | `6be767ea8` #3162 | Incompatible | vMLX pin. |
| 59 | `9ebaeaf31` #3161 | Incompatible | Flint local runtime. |
| 60 | `c6f1f3476` #3165 | Incompatible | vMLX pin. |
| 61 | `bf9d5816c` #3166 | Incompatible | Declared native reasoning Off/On for local bundles. |
| 62 | `6d5cd1ef6` #3167 | Incompatible | Declared reasoning tiers across local bundle metadata. |
| 63 | `4c8d5e996` #3168 | Incompatible | vMLX pin. |
| 64 | `46d0507ef` | Incompatible | Upstream appcast 0.25.25. |
| 65 | `a69fe812a` #3171 | **Split:** Port + Needs work (`W-computer-use`, `W-browser-use`, `W-ui-misc`) | Port: dark-theme selected tab pill (`AnimatedTabSelector`), the Add Provider glyph, the What's New and Agents/Plugins path wording. The Computer Use / Browser Use settings strings and the guide text land with those workstreams. |
| 66 | `b4c9324b0` #3172 | **Needs work (new `W-agent-templates`, after `W-declarative-config`)** | Agent templates: one agent's configuration as a signed `.osaurustemplate`, export/import, built-in Cloud/Local/Sub Agent templates, a setup wizard and checker, Orchestrator hints. Built on upstream's declarative config (`ConfigApplier` / `ConfigExporter` / `ConfigPlanner`), which Intel lacks. |
| 67 | `426f14db5` #3173 | **Port** | The chat tab strip moves the window like the title bar it covers (`ChatTabStripView`, on Intel). |
| 68 | `7ec27289f` #3174 | **Needs work (new `W-osaurus-bundles`, after `W-declarative-config`)** | `osaurus import`: installer bundles of agents, skills and MCP servers (`osaurus-bundle.json`, import queue, `PendingImportProcessor`, `/admin/import`, CLI). Also a per-agent skill allow-list and exact per-agent tool lists in `config export`. |
| 69 | `f47c0d00a` #3169 | **Port** | `ChatModelPickerProvider` sort without MainActor isolation. Applies cleanly. |
| 70 | `5b0084ee1` #3160 | **Deferred (`W-channels`)** | Channel connection configs cached off the main thread. |
| 71 | `76bccf5ba` #3159 | **Port** | Custom avatar URL resolved with `isDirectory: false` (`Agent`, on Intel). |
| 72 | `10c7bcb6d` #3148 | Incompatible | MTP layout advisory refresh (local models); Intel's composer has no MTP advisory. |
| 73 | `091d5554f` #3144 | **Port** | `ConfigurationView` static labels use `LCached` (Sentry hang). |
| 74 | `d68a8711f` #3131 | **Port** | Terminal display views drop synchronous `ensureLayout` calls. Applies cleanly. |
| 75 | `12cc6f321` #3130 | **Port** | Window creation no longer runs a synchronous pre-layout pass (main-thread hang). Intel doesn't compile `WindowManager`, but its Settings window (`AppDelegate.showManagementWindow`) did the same `layoutSubtreeIfNeeded()` before `setContentSize`; removed there. |
| 76 | `cf01aa146` #3121 | **Needs work (`W-subagents`)** | `liveAgentSources` caching for subagent spawn descriptors. |
| 77 | `5980d6051` #3120 | Incompatible | Hugging Face model list formatters (local model browser). |
| 78 | `0ab37a06a` #3112 | **Port** | Transcript context token totals memoized across renders (`ChatView`; Intel's own `ChatTurn` needs the cache adapted). |
| 79 | `fc48e4f0b` #3111 | **Deferred (`W-workspaces-sharing`)** | Chat sidebar workspace-pairing snapshot. |
| 80 | `d5b60ddf4` #3105 | **Needs work (`W-seatbelt-sandbox`)** | Cached sandbox availability in `effectiveAutonomousExec` (Intel's agent manager has no autonomous exec yet). |
| 81 | `02bcd1009` #3094 | **Needs work (`W-seatbelt-sandbox`)** | Seatbelt `isSupported` cached. |
| 82 | `eb951e190` #3092 | **Port** | Composer stops querying `AVCaptureDevice` synchronously on appear (`FloatingInputCard`; hand-apply). |
| 83 | `92e1e9b67` #2946 | **Port** | Link clicks no longer hang the UI. Applies cleanly. |
| 84 | `83d42ca29` #2925 | **Port** | OAuth token deletion from the keychain moves off the main thread. Applies cleanly. |
| 85 | `b8e2a3da2` #2866 | Incompatible | External (local) models settings counts. |
| 86 | `993c12f8e` #3175 | **Needs work (new `W-harness-runtimes`)** | Pluggable harness runtimes: Claude Code and Pi as per-agent runtimes, user-added runtimes in Settings › Agent Runtimes, agent tokens for the Osaurus MCP tools and API. Supersedes Intel's own Claude Code integration (`IntelClaudeCodeService`, `COV-intel-own`); follow upstream. |
| 87 | `0f7a4ed83` #3180 | **Needs work (`W-harness-runtimes`, `W-declarative-config`, `W-osaurus-bundles`)** | Harness runtimes in the model picker, config documents and bundles. |
| 88 | `bc08a546e` #3178 | **Needs work (`W-server-api`)** | Opt-in local access key for sensitive routes (`/sessions`, `/agents`, `/mcp/*`, `/admin/config/*`), browser-origin refusal, CLI `--access-key`; bundle-settable. Portable; Intel's server and auth section are its own. |
| 89 | `820e38d90` #3181 | Incompatible | Upstream CI workflow timeout. |
| 90 | `1f100d854` | Incompatible | Upstream appcast 0.25.26. |
| 91 | `c5fabeea4` #3182 | Incompatible | System One decision routing for local D3 bundles. |
| 92 | `2f2e1158b` #3185 | **Split:** Port + Incompatible | Port: the composer's attachment picker opens as a sheet on the chat window and can't open twice. The rest consumes local runtime diagnostics. |
| 93 | `d3eff2055` #3189 | Incompatible | Handled Metal interactivity failures reported to Sentry (local runtime; Intel has no crash reporting service). |
| 94 | `0c378f201` #3192 | Incompatible | vMLX pin. |
| 95 | `564ee2314` #3195 | **Port** | SQLCipher connections released after setup failures (`EncryptedSQLiteOpener`, on Intel). Applies cleanly. |
| 96 | `af61ba0ac` #3194 | Incompatible | vMLX pin. |
| 97 | `2a657f9b3` #3200 | **Port** | A restored chat keeps its model when provider models arrive later. Intel's `refreshPickerItems` prefers the agent's model over the restored one, so the bug exists here; adapt the `restoredWindowModelSelection` intent. |
| 98 | `c1fce01f7` #3202 | Covered | Initial `ChatHistoryDatabase` open failures surfaced to storage recovery; Intel's chat history is its own JSON store. |
| 99 | `7664572c8` #3207 | **Needs work (`W-identity-mobile`)** | iPhone images for remote provider models. |
| 100 | `06b89a1da` #3208 | **Deferred (`W-channels`)** | Queued channel messages kept when the post-turn drain is denied. |
| 101 | `f0a400095` #3193 | **Port** | Long MCP calls report progress past 120 s and poll without loop nudges (Intel has upstream's MCP provider tools since #2990). |
| 102 | `fc75a1e06` #3203 | **Split:** Covered + Port (slices) | The typed Responses engine, HTTP protocol adapters, plugin inference and evals are upstream's `ChatEngine` stack (`COV-intel-own`: Intel's `CloudChatEngine`). Port slices on Intel files: `GroundedFileSideEffectCheck` (no false file-write retries after read-only answers, with tests), `ChatToolChoicePolicy`, `StreamingDeltaProcessor`, `RemoteImagePayloadPolicy`, `WireTransportProbe`, running tool cards refreshing (`NativeToolCallGroupView` / `NativeBlockViews`), Anthropic terminal usage. |

**Totals:** Port 25 · Split 6 · Needs work 15 · Deferred 6 · Covered 4 ·
Incompatible 46 (31 are vMLX/local-runtime pins or local image/video work, 7
are upstream appcasts and CI).

## Shipped on Intel (awaiting Rosy)

Commits `506d9f096`, `bbac9fee2`, `8309877c7`, `5efa099cd` on
`claude/suspicious-curie-a86099`, merged to `intel-fork`. Package gate:
3,238 tests in 401 suites pass with 6 known issues (4 earlier, 2 marked here),
`--no-parallel`, fresh `OSAURUS_TEST_ROOT`, `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`;
no live `~/.osaurus` writes in the test window and the identity item's `mdat`
unchanged.

| Upstream | What Intel got |
|---|---|
| #3065 | The Apple-app `*_open_*` tools no longer freeze the app while Calendar, Contacts, Maps or Reminders launches. |
| #3067 | The copy button under a reply copies the reply only, not the thinking. |
| #3053, #3144 | Menu titles and the General settings labels use `LCached` (Sentry hangs). |
| #3068 | Custom providers' context windows also come from gateway `context_window` and DeepInfra's nested `metadata.context_length`. Intel's discovery is its own (`RemoteProviderManager.advertisedContextLength`, tests from upstream's cases). |
| #3066 | `file_write` has no content length cap any more, and `source_path` renders a document (or writes text) from a text file already in the folder, with `file_read`'s confinement and secret gates. Schema rejections are no longer advertised as retryable (`IntelToolRegistryBoundary`). |
| #3073 | Workbooks keep formatting and formulas through model edits, and `file_write` refuses to regenerate a formatted `.xlsx`, pointing at `file_edit` operations. |
| #3074 | PDF body-text edits don't advise regenerating the PDF. |
| #3079 | Three Sentry crashes: the clipboard poller reads through its own `IsolatedPasteboard` (1QM); the Settings window is hosted AppKit-owned, fed the per-screen floor (1ZM); `IntelPluginLoader` rejects ABI tables whose slots don't point at code (337). |
| #3083 | Pinned-memory matches are ranked by relevance before salience. **With it:** upstream's OR-prefix FTS recall (#1815), see below. |
| #3130 | The Settings window is created without the synchronous pre-layout pass. |
| #3133, #3169 | The model picker's list no longer goes blank after a search below the selected row; the provider sort is off the main actor. |
| #3141 | `gpt-6.1-sol` in the ChatGPT list. |
| #3157 | The RAM gauge uses upstream's reclaimable-capacity arithmetic (kept locally; upstream's helper lives in a local-model file). |
| #3159 | Avatar paths built with `isDirectory: false`. **With it:** `AvatarExistenceCache` from #2757, which Intel's earlier #2757 port left out. |
| #3171 (part) | Dark-theme tab pill and the Add Provider glyph. |
| #3173 | The chat tab strip drags the window like the title bar. |
| #3185 (part) | The composer's attachment picker opens as a sheet on its chat window, and only once. |
| #3092, #3131, #2946, #2925, #3195 | Composer, terminal, link and OAuth-delete main-thread fixes; SQLCipher connections released after setup failures. |
| #3112 | The context readout's transcript token totals are memoized (keyed on transcript and turn revisions). |
| #3193 | Long MCP calls report progress past 120 s and poll without loop nudges. |
| #3200 | A restored chat keeps its model when provider models load later. **With it:** upstream's manual-pick precedence, which Intel's picker refresh also lacked (`ChatSession.modelAfterDiscovery`). |
| #3203 (part) | The grounded file-write check no longer flags read-only answers, and its notice states the fact instead of instructing a write. |

Tests: every port brought upstream's tests where they run on Intel; Intel
equivalents were written where upstream's exercise code Intel doesn't compile
(`IntelModelDiscoveryContextLengthTests`, `IntelModelSelectionAfterDiscoveryTests`,
`IntelTranscriptTokenTotalsCacheTests`, the ABI cases against
`IntelPluginLoader`, `ManagementWindowFloorTests` on Intel's factory). The
upstream assertions left out, each noted in its file: `AgentToolLoop`'s
stop-on-rejected rule and upstream's loop-driver tests (Intel's loop is its
own); the manifest/v1 cases of `PluginLoaderAbiValidationTests` (upstream's
manifest model); the deeplink replacement controller (Intel reuses the
Settings window). One assertion is a known issue: an unshown test window
collapses to 1x1 when the run loop turns, so the re-clamped `contentMinSize`
can't be observed in SwiftPM (the forwarding into the controller is asserted).

## Not yet shipped (Port verdicts still open)

- **#3080 `bd5b5b1a5`, chat table height-note batching.** Intel's
  `MessageTableRepresentable` has diverged from upstream (no find bar, its own
  anchor code), so a 3-way merge drags in unrelated upstream code. Needs a hand
  port of the batching (`heightNoteBatchDepth`, `pendingHeightNoteIds`,
  `rowIndexByBlockId`) and a long-transcript UI check.
- **#3115 `fc7ef8184`, Gemini reasoning effort.** `GeminiReasoningContract`
  ports as is; the picker capability and request mapping must go into Intel's
  own provider path (`IntelGeminiAdapter`, Intel's picker cache).
- **#3203 `fc75a1e06`, remaining Intel-file slices.** `ChatToolChoicePolicy`,
  `StreamingDeltaProcessor`, `RemoteImagePayloadPolicy`, `WireTransportProbe`,
  running tool cards refreshing (`NativeToolCallGroupView`,
  `NativeBlockViews`), Anthropic terminal usage. Each needs checking against
  Intel's `CloudChatEngine`, which owns the request side.

## Found while porting

- **Upstream's OR-prefix FTS memory recall (#1815, 2026-07-17) was missing.**
  It came inside the knowledge-collections commit, triaged SKIP in
  `UPSTREAM_TRIAGE_0.24.3.md`. Intel's `ftsMatchQuery` AND-joined the words,
  so a natural-language recall query almost never matched a pinned fact.
  Ported with this audit. Same lesson as the 2026-09-28 symlink fix: grep
  SKIP commits for fixes to files Intel compiles.
- **Intel's `MemoryDatabase` is otherwise behind upstream:** no forward-version
  refusal (`databaseFromNewerVersion`, from #1323 / #1635) and an older schema
  than upstream's v10. On the dev Mac, Intel and the installed upstream app
  share `~/.osaurus/memory/memory.sqlite`, so an Intel launch there could open
  a newer-schema database without refusing. Not ported here; recorded on the
  backlog (`W-memory-db-sync`). **Done 2026-10-27**, see `UPSTREAM_SYNC.md`
  "Memory database at upstream's schema".
- **Intel's Settings window floor was `min(900, …)`,** below the SwiftUI
  root's own 940-point minimum and older than the per-screen clamp (#2761).
  It now follows the controller-mirrored floor, as upstream.
- **`#2757` was half-ported:** `LCached` came over, `AvatarExistenceCache`
  didn't. It's in now (with #3159).
- **Audit tooling:** a regex that reads `Package.swift`'s `exclude:` blocks
  stops at the first `]`, and a comment in the test target's list contains one.
  Read every quoted `.swift` path instead. (`classify_gap.py` only reads the
  production list, which has no such comment.)

## Product impact (FEATURE_PARITY vocabulary)

### Working and tested
The 23 shipped Port commits and the Port parts of #3066, #3073, #3171, #3185
and #3203 above. Automated tests only; Rosy is pending (checklist section
"Upstream audit 2026-10-26").

### Partial
- Hosted Gemini models: no reasoning-effort control yet (#3115).
- Chat transcript performance on long, tool-heavy chats: #3080 batching open.

### Dependency-blocked / Absent (new backlog rows)
- `W-harness-runtimes` (#3175, #3180): Claude Code and Pi as per-agent
  runtimes; supersedes Intel's own Claude Code integration.
- `W-agent-templates` (#3172), `W-osaurus-bundles` (#3174, #3180, #3178's
  bundle settings): both need `W-declarative-config` first.
- `W-server-api` gains the opt-in local access key (#3178).
- Existing rows gain upstream work: `W-identity-mobile` (#3070, #3106, #3135,
  #3152, #3207), `W-privacy-filter` (#3135), `W-media-generation` (#3104's
  shared parts), `W-computer-use` (#3084), `W-subagents` (#3121),
  `W-seatbelt-sandbox` (#3094, #3105), `W-ui-misc` (#3060 with the theme
  library; #3171's guide text).

### Intentionally omitted
None. Deferred, not omitted: `W-channels` (#3058, #3113, #3146, #3160, #3208)
and `W-workspaces-sharing` (#3111), until someone asks.
