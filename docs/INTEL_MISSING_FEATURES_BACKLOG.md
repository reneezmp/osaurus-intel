# Intel missing-features backlog (full sweep, 2026-09-29)

**Why this exists.** Renée: the Intel fork ports everything it can, even when
it takes work; features must not be dropped on "this doesn't apply" grounds
(verdict rule in [`UPSTREAM_SYNC.md`](UPSTREAM_SYNC.md)). This sweep re-checks
**every** upstream feature Intel does not have, not just recent commits.

**Method.** `scripts/upstream/classify_gap.py` lists every upstream
`OsaurusCore` source file (at `3dad2dad4`) that Intel does not compile —
**770 files**: 622 never copied, 148 present but excluded — and assigns each
to a feature. **All 770 are assigned** (the script exits non-zero if any file
is unassigned). Each feature was then checked against Intel's compiled code
(its own conformers and replacements), the parity ledger and the audits.
The per-file list is in
[`INTEL_MISSING_FEATURES_APPENDIX.md`](INTEL_MISSING_FEATURES_APPENDIX.md).

| Bucket | Features | Files | Upstream lines |
|---|---:|---:|---:|
| **Incompatible** (hardware or upstream-only) | 3 | 121 | ~58.9k |
| **Covered** by Intel's own implementation | 1 group | 92 | ~63.3k |
| **Needs work** | 30 | 545 | ~218k |
| **Not a user feature** (developer tooling) | 1 | 12 | ~7.1k |

Most of the "needs work" volume is Channels (~52k) and Workspaces/identity/
mobile (~25k), which wait on backends B3 and B1/B2/B7.

## 1. Incompatible — the only true "can't"

| Id | What | Why it cannot run on Intel | What would change that |
|---|---|---|---|
| `INC-mlx` | Local model inference: MLX/vMLX runtime, model downloads, residency, MTP, disk cache, local vision, local image generation, Apple Foundation Models, local-model UI | MLX requires Apple Silicon (Metal); Apple Foundation Models require Apple Intelligence (Apple Silicon). | A different local runtime for Intel (for example llama.cpp on CPU/AMD GPU). That is a **new product project, not a port** — Renée's decision; nothing here is portable as written. |
| `INC-containers` | The Linux VM sandbox (Apple Containerization), sandbox plugins, egress proxy, `/workspace` tools | Apple's Containerization framework runs only on Apple Silicon. | A different VM backend (Lima/QEMU) would be a new project. **Not the same as the host shell sandbox**, which is portable (see `W-tools-misc`: Seatbelt). |
| `INC-upstream-only` | Product Hunt campaign dialogs; mock drivers used by upstream tests | Marketing for upstream's launch; test doubles for code Intel does not run. | Nothing to port. |

## 2. Covered — Intel has its own implementation

92 files (listed in the appendix under `COV-intel-own`) are replaced by Intel
code: the chat engine (`CloudChatEngine`), the prompt composer and chat tool
loop (Intel conformers + `ChatView`), chat turns/blocks/storage (Intel JSON
history), providers and remote APIs, memory (Intel memory services and
console), agent manager/store, Claude Code, compaction, chat titles, the
abilities overview, Credits usage centre, the local API server core, plugin
host basics, themes sharing, and settings. **Covered means equivalent
behaviour exists**, not that every upstream refinement is present; later
upstream fixes to these areas are still classified commit by commit.

## 3. Needs work — the backlog

Size: **S** < 1.5k lines, **M** 1.5–6k, **L** 6–16k, **XL** > 16k (upstream
lines; Intel adaptation can be smaller or larger). "Was" records how the
feature had been labelled before this sweep.

### 3a. Wrongly dropped or silently missing (fix first)

| Id | Feature | Size | Was | Intel path |
|---|---|---|---|---|
| `W-gated-sweep` | **Triage done 2026-10-10** (`UPSTREAM_SYNC.md`, "Gated files sweep"). `scripts/upstream/classify_gated.py` lists every wholly `#if !OSAURUS_INTEL` file, every `AppleSiliconOnlyTab` placeholder and every upstream App-target file Intel lacks, and fails on any unassigned one (87 entries, all assigned). Wrong placeholders fixed: `AgentReorderSheet`, `MarkdownImageView` (plus the blank full-screen image preview), `ToolSecretsSheet` (with `W-plugin-reliability`). Newly found gaps were filed under `W-app-intents`, `W-chat-ux` (inline terminal), `W-ui-misc` (theme sharing), `W-agent-detail-redesign` (Next Run panel) and `W-declarative-config` (Default-agent addendum). 18 files upstream deleted in redesigns (onboarding, notch, toasts, agent DB tabs) are leftovers: remove each with its replacement feature. | — | Run `classify_gated.py` with `classify_gap.py` on every audit. |
| `W-router-billing` | **Shipped 2026-10-08.** Router billing summary frames in chat: `CloudChatEngine` decodes the `{"osaurus": {…}}` frame (Router endpoints only), calls `noteRouterSummary` (live balance decrement, debounced `usageRevision`) and passes the charge to the chat as a `StreamingBillingHint`; `ChatView` stamps `routerBilling` on the turn (saved with the chat), records a `RouterBillingLedger` row per charge and finalizes its outcome at run cleanup; billed turns are never trimmed and a billed turn with no reply shows upstream's "You were charged …" notice with Retry; a connected stream that ends without a summary reconciles the balance. Not ported: `billed_to` workspace routing (`W-workspaces-identity-mobile`), the composer's per-chat spend chip (`W-model-picker-2947` credits chip). | S (0.5k) | Open since 2026-09-02 as "Router billing ledger is dead code" ([`SYNC_0.24.3_PLAN.md`](SYNC_0.24.3_PLAN.md)). | Done; see `UPSTREAM_AUDIT_2026-10-07.md`. |
| `W-agent-loop-tools` | **Core shipped 2026-09-29** (`todo`, `complete`, `clarify`, `get_current_time`, the clarify prompt card, unescaped slashes in tool JSON); ~~output caps/compression, schema validation, `ToolWirePropertyOrder`~~ **shipped 2026-10-10** (the registry boundary: preflight, 120 s timeout, result normalization; `UPSTREAM_SYNC.md`, "Tool execution boundary"), ~~repetition detector~~ (retired upstream, #2978); ~~run-progress monitor~~ **shipped 2026-10-10** (slow / stalled chip); remaining: grounded claim checks, vision tool results. Originally: `todo`, `complete`, `clarify` agent-loop tools; `get_current_time`; tool output caps/compression; argument schema validation; run-progress (stall) monitor; stream repetition detector; grounded claim checks; `ToolWirePropertyOrder`; images from tool results to vision models | M (5.3k) | **Silently absent.** `ChatView` has the `complete`/`clarify` intercepts, but the tools are not registered (`AgentLoopTools.swift` excluded; `ClarifyTool` is a stub). | Port on top of Intel's chat loop. Lets agents keep a todo list, ask a clarifying question with options, and finish cleanly. **Upstream #3033:** judge polarity and ScreenContext rubric for grounded claim checks (Intel's `CapabilityClaimsEvaluator` is an older, unwired copy). |
| `W-voice` | Voice input (dictation), live voice, text-to-speech | M (4.7k) | "Apple-Silicon-only" (Voice tab disabled) — true only of the **FluidAudio** engine. | **Shipped 2026-09-29** ([`VOICE_INTEL.md`](VOICE_INTEL.md)): Apple Speech for the chat mic, Transcription Mode and VAD Mode; macOS system voices + the upstream OpenAI-compatible server for speech; `speak` tool behind a per-agent switch. Only `LiveVoiceAudioInputRegistry` (MLX omni audio) stays out — reclassified `INC-mlx`. |
| `W-self-scheduling` | **Shipped 2026-09-29** (tools, switch, presets, agent notifications; schedule run-history view remains). Agent schedules its own next run (`schedule_next_run`, `cancel_next_run`, `notify`) and schedule run history | S (1.0k) | "Intentionally out of Intel scope" — not a valid reason under the rule. | The scheduler already runs on Intel; the per-agent Self-scheduling toggle is the consent. |
| `W-methods` | Methods (saved procedures) | — | ~~Silently absent~~ **Re-checked 2026-09-29: retired upstream.** Upstream removed method creation (`MethodTools.swift`) in April 2026 (#893, "Deprecate Work Mode"); `upstream/main` only lets `capabilities_load` find methods saved by older upstream builds. Intel never had methods, so an Intel port would be an empty database nothing can fill. | Nothing to port on its own. If `W-tool-discovery` is ported, its search simply returns no method hits. Revisit only if upstream brings method creation back. |
| `W-tool-discovery` | Automatic tool discovery (semantic search over tools/skills, `capabilities_search`/`capabilities_load`, session tool state) | M (4.9k) | Silently absent: Intel "Auto" mode sends every tool. | **Shipped 2026-09-30** ([`TOOL_DISCOVERY_INTEL.md`](TOOL_DISCOVERY_INTEL.md)): Auto mode loads plugin/MCP tools and skills on demand through the `capabilities` gateway; in-memory BM25 + local static embeddings; engine adopts loads mid-run. Also fixed: skills never reached the model (lookup stubs, no `/` entries). Remaining upstream index/search files classified `COV-tool-discovery`. |
| `W-description-backfill` | Background fill of missing agent descriptions | S (0.2k) | Omitted (automatic paid calls). | **Shipped 2026-09-29** as an opt-in switch, off by default (Settings › Chat › Agent Descriptions), including #2897 stale-prompt handling and #2898 purposes in agent lists. |
| `W-doc-editing` | In-place .docx/.xlsx/.pptx/.pdf editing, PDF form filling, `.pptx` writing, CSV/TSV emitters, business-document and CSV workflows, `file_copy` | L (6.6k) | #2907 part B staged. | **Core shipped 2026-09-29**: `file_edit` `operations` + Word/PowerPoint text matching, `dry_run`, `file_read` `mode: "structure"`, PowerPoint writing, `file_copy`. Remaining: business-document studio and CSV table workflow services; batch `edits` / argument normalisation / `ToolWirePropertyOrder` (with `W-agent-loop-tools`). |
| `W-chat-export` | Export chats (Markdown, PDF, zip with attachments; optional timestamps, deltas and token usage) | S (0.7k) | Removed in 1.0.34. | **Shipped 2026-09-29** — right-click a chat (or its "…" menu) › Export…. |

### 3b. Chat and everyday UX

| Id | Feature | Size | Notes |
|---|---|---|---|
| `W-chat-tabs` | Browser-style chat tabs, per-tab scroll, live-session registry | M (1.8k) | **Stage 1 shipped 2026-10-01** ([`CHAT_TABS_INTEL.md`](CHAT_TABS_INTEL.md)): tab strip with the agent pill, per-agent tabs, right-click menu, shortcuts, remembered tabs, hibernation, per-tab scroll (#2911), running tabs held by `DetachedChatRunRegistry`. Stage 2 approved 2026-10-01 (follow upstream; [`CHAT_WINDOW_LAYOUT_INTEL.md`](CHAT_WINDOW_LAYOUT_INTEL.md)): all six steps shipped the same day (navigator with Agents/Projects, History inspector, toolbar, #2910, upstream project page, runs as tabs, layout tour, #2664 window size, full-screen header). File Changes pane shipped with `W-file-history` (2026-10-01). Remaining: retained finished runs across relaunch, upstream's full Help menu. ~~Follow-up: Safari-style tab track (#2995) + quiet lone tab (#3017)~~ shipped 2026-10-07. |
| `W-chat-ux` | ~~Cross-block text selection (#2247, #2899)~~ **shipped 2026-10-01** ([`CROSS_SELECTION_INTEL.md`](CROSS_SELECTION_INTEL.md)); ~~`@file` mentions, input history (↑), IME-aware fields, follow-up suggestions (on by default like upstream — decision 3f)~~ **shipped 2026-10-01** ([`CHAT_UX_INTEL.md`](CHAT_UX_INTEL.md), which lists what remains); ~~smooth streaming~~ **shipped 2026-10-06**, ~~group thinking & tool activity (roll-up), expand thinking while streaming~~ **shipped 2026-10-06**, ~~compaction-model picker, compaction marker in the transcript~~ **shipped 2026-10-06**, ~~activity/dispatch rows~~ **shipped 2026-10-06** for self-scheduled and watcher runs (channel and delegated kinds wait for `W-channels` / `W-subagents`), recent-folders panel, ~~chat import guide~~ **shipped 2026-10-06** (post-onboarding prompt waits for onboarding, `W-ui-misc`), IME-aware text field (CJK input), ~~Markdown document view~~ **shipped 2026-10-06**, ~~screenshot attach~~ **shipped 2026-10-06**, slash-command registry parity (context attribution → `N-dev-tooling`; `AgentDetailChrome` → `W-agent-detail-redesign`; `BuiltInAgentGuard` shipped 2026-10-06), ~~inline terminal for `shell_run`~~ **shipped 2026-10-10** (`TerminalDisplayView` / `TerminalSnapshot`) | M (7.1k) | Mostly independent small items. Follow-up suggestions follow upstream (on by default, switch in Settings). |
| `W-tool-catalog-ui` | Friendly tool names (`ToolDisplayName`), tool catalog rows, availability badges, advanced diagnostics | M (2.3k) | **Shipped 2026-09-30** with Settings redesign step 3 ([`SETTINGS_REDESIGN_INTEL.md`](SETTINGS_REDESIGN_INTEL.md#step-3--tools--mcp-and-the-tool-catalog-2026-09-30)): All Tools catalog, Auto-Allow, advanced diagnostics, friendly names in chat rows. Remaining: `AgentCapabilityReadiness` (agent readiness panel) and `ToolExecutionSurface` (run location on the approval card). |
| `W-model-picker-2947` | **Shipped 2026-10-06** ([`MODEL_PICKER_INTEL.md`](MODEL_PICKER_INTEL.md)): column picker, options column, Cloud browser, starter favourites, #3017 popups and context card. Remaining: composer credits chip + wallet card. Original scope: | Upstream #2947 (2026-09-30) chat model picker redesign (provider / model / options columns), Cloud model browser, Credits card in the chat, `AnchoredCardPresenter`; then #2958 starter favourites | L (5.5k) | Staged in [`UPSTREAM_AUDIT_2026-10-01.md`](UPSTREAM_AUDIT_2026-10-01.md#staged-w-model-picker-2947-2947-then-2958). Needs favourite models (#1811) first. |
| `W-insights-sync` | Insights catch-up: request log turn/request ids and wire bodies, hardened secret redactor, `logs` off `@Published` (#1595), focus API so Inspect response opens its own log (#1350), off-main snapshots (#2926) | S (0.6k) | Staged in [`UPSTREAM_AUDIT_2026-10-01.md`](UPSTREAM_AUDIT_2026-10-01.md#staged-w-insights-sync-2926-and-its-prerequisites). Redactor first. |
| `W-file-history` | Per-chat file change history with revert, history/inspector panes | L (8.0k) | #2907 part A. **Stage 1 shipped 2026-10-01** ([`FILE_HISTORY_INTEL.md`](FILE_HISTORY_INTEL.md)): journal + content-addressed object store, rows in a new encrypted `FileHistoryDatabase`, capture in `ToolRegistry.execute` for `file_write`/`file_edit`/`file_copy`/`shell_run`, File Changes inspector pane (Timeline/Files, revert/rollback/Revert All with conflicts and Undo), `file_undo` + `file_operation_history`, History-row badge, transcript links, retention setting; `FileOperationLog` removed. **Stage 2 shipped the same day**: inline diff cards (`NativeFileDiffView`, `.fileDiff` block, live streaming preview, #1683) and text `dry_run` for `file_write`/`file_edit`. Not yet tested on Rosy. |
| `W-ui-misc` | Chat layout tour, onboarding design system (then wire the ported `ImportHistoryPromptGate` prompt after onboarding), theme library management (~~built-in Dark/Light as appearance modes, #1931~~ shipped 2026-10-10 with `W-app-menus`; remaining: the System card, sources/validation, #1776 deferred theme loading off the launch path; theme sharing to themes.osaurus.ai and import by id, `ShareThemeSheet` / `ImportThemeByIdSheet` / `ThemeShareService`, identity-signed), system accent colour (#2115), in-app guide, keep-awake during agent runs, keychain helpers, shared UI components | M (3.2k) | Small pieces; keep-awake during long runs is useful on laptops. |
| `W-app-menus` | **Shipped 2026-10-10** (see `UPSTREAM_SYNC.md`, "App menu bar"): upstream's menu bar, entry point (SIGPIPE ignored) and #1931 theme model. Intel keeps its About panel and leaves Discord / Report an Issue out of Help. Original scope: Upstream's main menu bar (`App/osaurus/osaurusApp.swift`): File › New Window with Agent, Schedules and Watchers submenus (New / Manage), Agents submenu, Voice Detection toggle (⇧⌘V); View › Theme submenu (System / Light / Dark, installed themes, Manage Themes…); Window › Models / Tools / Server; Help › Osaurus Help, Documentation, Discord, Report an Issue, Keyboard Shortcuts, Acknowledgements. Intel's App target is a trimmed entry point (About, New Window/Chat, Toggle Sidebar, Next Agent, Zoom, Settings, Chat Layout Tour). | S (0.4k) | Found by the 2026-10-09 audit (#3052, #3054 fix hangs in these menus). The managers exist on Intel (`ScheduleManager`, `WatcherManager`, `ThemeManager`). When ported, use upstream's post-#3052 shape: no `@ObservedObject` on the App struct, state in `VADToggleMenuItem` / `ThemeMenuItems`, `LCached` for submenu labels. Intel's zoom items already follow it (`ZoomMenuItems`). |
| `W-providers-ux` | Provider catalog, connectivity centre, credential prompt sheet, replay diagnostics, wire probe, Fireworks, Codex CLI integration, favourite models | M (3.2k) | Codex CLI mirrors the existing Claude Code integration. |
| `W-media-generation` | Cloud image/video generation (Venice, Osaurus Cloud), `video` tool, OpenAI image API on the server | M (2.9k) | Cloud-based: runs on Intel. Local image generation stays in `INC-mlx`. |
| `W-settings-ux-2950` | Upstream #2950 (2026-09-30) Settings UX/IA cleanup: grouped-form `SettingsKit`, General/Conversation split with Advanced → Data & Storage, renamed tabs (Tools & MCP: Services / All Tools / Plugins), MCP service directory, a separate Chat Voice tab and regrouped Transcription tab, slash-command editor sheet, command-line tool card moved to Developer Tools → Server | L (6.0k changed; Intel files diverge heavily) | **Audited 2026-09-30** ([`UPSTREAM_AUDIT_2026-09-30.md`](UPSTREAM_AUDIT_2026-09-30.md#2950--settings-redesign-staged-port-w-settings-ux-2950)): hand-port in five steps (kit → General/Conversation split → Tools & MCP → Voice → Providers/Themes/Commands/CLI). **All five steps shipped 2026-09-30** (kit + header, General/Conversation split, Tools & MCP with the tool catalog and Auto-Allow, Voice tabs, real slash-command editor); the Services health/probe hub waits for `W-mcp-providers`; manual [`SETTINGS_REDESIGN_INTEL.md`](SETTINGS_REDESIGN_INTEL.md). Ventura: two two-value `onChange` and one segmented picker in the kit. "Auto-Allow All Tool Calls" (`ToolAutoAllowToggle`, upstream #2241) needs Renée's decision. Mobile / Images / Privacy / Channels views wait for their features. |

### 3c. Capabilities

| Id | Feature | Size | Notes |
|---|---|---|---|
| `W-knowledge-write` | Knowledge writing/curation (agents add and edit notes with preview, diff, write log), folder watcher, git sync, link resolver | M (4.6k) | **Part 1 shipped 2026-09-30** ([`KNOWLEDGE_WRITE_INTEL.md`](KNOWLEDGE_WRITE_INTEL.md)): `write_knowledge` / `edit_knowledge` / `delete_knowledge` with a diff on the approval card, write log + History tab with revert, folder watcher. **Part 2 shipped the same day:** stale-document tickets (grant-gated; upstream's leftover curator check dropped), git Sync for repo folders (clone stays hidden as upstream), clickable knowledge paths in chat, inferred document types (index schema v3). Remaining upstream file: none user-facing (proposal service not ported: Intel never had proposals). |
| `W-skills-plugins-import` | Skill import policy/update tool, GitHub skill import, Claude marketplace and plugin installer, out-of-process plugin host | L (10.3k) | Intel has skills (local store) and in-process dylib plugins. |
| `W-plugin-reliability` | **Stage 1 shipped 2026-10-10** (`UPSTREAM_SYNC.md`, "Plugin secrets and load checks"): plugin config and keys live in `ToolSecretsKeychain` per agent with upstream's resolution policy (#2061 `resolvedSecret` / `hasResolvedSecret`, #3057 memo); `config_get/set/delete` follow upstream (agent-scoped, anonymous calls refused, 1 MiB cap); tool calls get `_secrets` and `_context` like upstream's `ExternalTool`; the old plaintext `Tools/.intel-plugin-config.json` migrates into the Keychain once; upstream's `ToolSecretsSheet` replaces the "Apple Silicon only" stub; ABI table and manifest identity / tool-id checks at load; deleting an agent sweeps its plugin keys. **Stage 2 (open):** Intel's plugin host is M9's slim `IntelPluginExecution` (+ the `#else` half of `PluginManager`), not upstream's `ExternalPlugin` + `PluginHostAPI` (both compiled out). Missing against upstream: per-agent config delivery at load / on agent add (`deliverInitialConfig`), upstream's per-agent `PluginConfigView` (stubbed), routes, web mounts and the tunnel (#2061 route timeout and mount matching apply there), task events, `embed`, `list_models`, `http_request` SSRF and rate limits, a scoped `file_read` (Intel's reads any path), plugin DB size caps, the crash-loop guard, compatibility enforcement, and the repository installer (`OsaurusRepository`: install integrity, TOFU key pinning; Intel uses its own SHA-checked `reneezmp/osaurus-intel-plugins` index). | L (est. 6k) | **Reassessed 2026-10-10.** The 2026-10-09 entry was wrong to say tool calls merged Default-agent secrets: `ExternalPlugin` is `#if !OSAURUS_INTEL`. Value today is modest: the Intel registry has five x86_64 plugins (fetch, hello, memo, time, the retired search), and upstream's catalog is arm64-only. Do the host hardening (`file_read`, `http_request`) before anything widens the plugin catalog. |
| `W-app-intents` | **Shipped 2026-10-10** (`UPSTREAM_SYNC.md`, "Shortcuts and Siri"): upstream's Ask Osaurus and Run Osaurus Agent intents, `AgentEntity` and the App Shortcuts. Intel's `OsaurusLocalClient` dispatches in process instead of calling `/agents/{id}/run` / `dispatch`, which Intel's server lacks (`W-server-api`). Original scope: Shortcuts and Siri, removed in sync row 41. | S (0.6k) | Found 2026-10-10 (`W-gated-sweep`). |
| `W-keychain-layer` | Upstream's current Keychain layer: `Keychain.swift` (typed read / write outcomes), `SecretSaveOutcome`, `SecretAvailability`, `OsaurusKeychainServices`, `AgentSecretsKeychain` and the rest of `ToolSecretsKeychain` (legacy `{pluginId}.{key}` read-through migration, typed save outcomes). ~1k lines across 7 files. | S (1k) | Found 2026-10-10 while porting `W-plugin-reliability`: only the resolution functions were taken. Security-sensitive: port with the keychain test gate (`OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS`, the in-memory test store) and never against the real Keychain. |
| `W-mcp-providers` | MCP provider probe and health, child-spawn limiter, capture-capability policy, OAuth HTTP transport extras | S (1.2k) | Intel has remote MCP providers; these are hardening/diagnostics. **Shipped 2026-10-08 with #3038:** the child-spawn limiter and upstream's current stdio host transport (login-shell PATH, `~` expansion). |
| `W-server-api` | Server-side pieces: live request registry, which models the API lists, evidence reports, owner auth, local network helpers, **`/v1/embeddings`** (Intel ships a local embedder for memory; the #2768 fix lands with it); **external-caller tool policy** (upstream `ExternalMCPToolPolicy`, `externallyDeniedToolNames`, external-surface / unattended / headless-deny task locals; found 2026-10-07 porting #2990) | S (1.0k+) | Check each upstream route against Intel's `HTTPHandler`. |
| `W-storage-health` | Persistence health check, storage recovery service, FileVault status, storage-location standards, safe config writes | S (1.0k) | Intel has its own encrypted storage and key rotation; these are health/recovery surfaces on top. |
| `W-tools-misc` | `render_chart`, `search_memory`, `share_artifact` tool parity, redaction tools, **Seatbelt host-shell sandbox** (`sandbox-exec`, plus #2922's NUL-byte check); ~~file tool parity with upstream #2791~~ **shipped 2026-10-09** (upstream's current `file_read` / `file_search` / `FileTreeTool` / `FolderToolHelpers`, see `UPSTREAM_SYNC.md`) | M (4.1k) | Seatbelt works on Intel; it is not the VM sandbox. The file tool gaps (left out of the 2026-09-29 #91 slice, found 2026-10-07) shipped 2026-10-09. **Upstream #2922:** Seatbelt NUL-byte argument check comes with the Seatbelt port. |
| `W-declarative-config` | Declarative configuration: YAML export/import, planner/applier, approval modal, secret refs, provider presets; the Default agent's settings-tool addendum (`DefaultAgentSystemPromptBuilder`, #2268) | L (11.3k) | Intel has its own Orchestrator configuration tool (`find_setting`, plan approval); export/import to a file is missing. |
| `W-privacy-filter` | Privacy filter: regex/entity rules, redaction pipeline, review sheet, streaming un-scrub, custom rules | L (11.6k) | **Split:** the ML detector (`PrivacyFilterKit`) imports MLX → incompatible; Rampart detector needs a check. Rules, pipeline and review UI are portable. **Upstream #2979 (2026-10-02):** international regex presets, checksum validators and the region picker land with the regex half. |

### 3d. Agents acting on the Mac

| Id | Feature | Size | Notes |
|---|---|---|---|
| `W-applescript-agent` | AppleScript agent loop, `applescript` tool, `mac_query`, app dictionary knowledge | M (5.1k) | Builds on the AppleScript executor already ported for Apple apps. |
| `W-browser-use` | Browser Use (agent drives a WebKit browser) | M (4.8k) | **Ventura:** per-agent profiles use `WKWebsiteDataStore(forIdentifier:)` (macOS 14+); needs a macOS 13 fallback (shared or non-persistent store) — isolation trade-off for Renée. |
| `W-computer-use` | Computer Use (screen, accessibility, input) | L (15.1k) | **Ventura:** screenshots use `SCScreenshotManager` (macOS 14+); fall back to `CGWindowListCreateImage` on 13. Cloud vision model with consent. |
| `W-subagents` | Native subagents (spawn, batch admission, report back, subagent feed and settings) | L (15.3k) | Dependency-blocked in the ledger (request-scoped budgets). Image/video subagent kinds follow `W-media-generation`. Also carries upstream #2936's spawn slices (result compaction, background-spawn Stop, `continue` as `invalid_args`, same-turn staging) and narrowing the Orchestrator's folder tools to `file_read`/`file_search` once workers can do folder work (2026-09-30 audit). |

### 3e. Backend-dependent

| Id | Feature | Size | Prerequisite |
|---|---|---|---|
| `W-agent-detail-redesign` | Upstream's agent detail redesign (#1656 unify local/remote detail, #2052 Database workspace navigation, #2072 detail navigation + Tools tab restyle): `AgentDetailChrome` header bar, agent switcher popover, grouped two-level tab strip, shared section cards and metadata rows; the Next Run panel above the detail tabs (`NextRunPanelView`, found 2026-10-10) | M | Found 2026-10-06 while finishing `W-chat-ux`: never audited, Intel's agent page predates it. Audit the three commits first, then port onto Intel's `AgentsView`. |
| `W-channels` | Slack, Telegram, Discord, WhatsApp, iMessage, n8n, custom JSON channels and the channel runtime | XL (51.9k) | B3 transport, credential isolation, reply assignment, safety gates. **Upstream #3008 / #3010 (2026-10-05):** queue channel messages that arrive mid-turn, then steer them into the running turn (`steerTask`, `remoteSteers`). **Upstream #3034:** channel code blocks neutralize inner fences (`AgentChannelMessageFormatter`). |
| `W-workspaces-identity-mobile` | Workspaces and shared agents, ~~the `existsCached()` identity memo~~ (shipped 2026-10-09), Osaurus ID, pairing/secure channel, relay, Bonjour browsing, phone app, peer inference sharing, invites | XL (24.6k) | B1/B2 identity, pairing and relay; B7 billing; the secp256k1 crash vector (#131) first. **Upstream #2980, #2982, #3018 (2026-10):** the paired phone manages agents and chats over the secure channel; workspaces sync throttling (lazy `/workspaces/sync`, roster throttle); the pairing-code reason for a busy port. **Upstream #3044 (2026-10-08):** phone secure-channel and pairing hardening, phone image generation. |

### 3f. Decisions (Renée, 2026-09-29)

| Topic | Decision |
|---|---|
| Chat titles, follow-up suggestions | **Follow upstream:** both on by default (Settings switches to turn off), even though Intel runs them on the chat's paid cloud model. Titles already behave this way; follow-ups ship on by default with `W-chat-ux`. (Agent description backfill stays opt-in, off by default — a separate decision.) |
| Crash reporting and telemetry (`W-diagnostics-telemetry`) | **Not ported for now.** Upstream sends analytics to Aptabase and crashes to Sentry with **upstream's own keys** from its build config; an Intel build would either send nothing or send to the upstream team. Worth revisiting only if Renée sets up her own Sentry/Aptabase projects (for example to receive testers' crash reports). The local pieces — support diagnostics bundle, termination forensics, console log file — are still on the backlog. |
| "Auto-Allow All Tool Calls" (upstream #2241, `ToolAutoAllowToggle`, 2026-09-30) | **Port exactly like upstream:** off by default, and upstream's behaviour for every tool (no Intel-only exemption for per-call tools such as `delete_knowledge`). Ships with the Tools & MCP step of the Settings redesign, after `W-tool-catalog-ui`. |
| Local model inference (`INC-mlx`) | Not now. A future Intel local runtime would be closer to Renée's [Rosy-Bit](https://github.com/reneezmp/Rosy-Bit) app than to a port. |

## 4. Not a user feature

`N-dev-tooling` (12 files): upstream's eval harness (agent-loop, memory,
reasoning, subagent evaluators, `ContextAttribution` cost breakdown) and
prompt experiments. Runnable on Intel with
cloud models if the fork wants its own eval suite; no user-facing effect.

## 5. Earlier "Omit" verdicts re-checked

| Audit row | Result |
|---|---|
| 2026-09-25 #65 `6e67eec21` embeddings | Needs work, with `/v1/embeddings` (`W-server-api`). |
| 2026-09-25 #107 `97a390380` tool-stream cancellation | Native-runtime change is incompatible; **open task**: audit `CloudChatEngine` cancellation of streamed tool calls. |
| 2026-09-25 #127 `289a52272`, #163 `2fecfc883` | Native runtime only (incompatible); no cloud-engine counterpart found. |
| 2026-09-25 #103, #128 telemetry | Decision (`W-diagnostics-telemetry`). |
| 2026-09-25 MLX pins, local runtime, appcasts (~70 rows) | Confirmed incompatible (`INC-mlx`) or upstream-only. |
| 2026-09-29 corrected rows | See that audit. |

## 6. Suggested order

1. **Wrongly dropped, small:** `W-agent-loop-tools` (core shipped),
   `W-self-scheduling` (shipped), `W-description-backfill` (opt-in),
   `W-chat-export` (shipped), `file_copy` (shipped). (`W-methods` turned
   out to be retired upstream.)
2. **Medium, high value:** `W-doc-editing`, `W-voice`, `W-tool-discovery`,
   `W-knowledge-write`, `W-chat-tabs` + cross-block selection,
   `W-tool-catalog-ui`, `W-media-generation`.
   Also small: `W-storage-health`, `W-mcp-providers`, `W-server-api`
   (`/v1/embeddings`), `W-ui-misc`, `W-providers-ux`.
3. **Large:** `W-file-history`, `W-applescript-agent`, `W-browser-use`,
   `W-computer-use`, `W-privacy-filter`, `W-declarative-config`,
   `W-skills-plugins-import`, `W-subagents`.
4. **Backend projects:** `W-channels` (B3), `W-workspaces-identity-mobile`
   (B1/B2/B7).
5. **Last (Renée, 2026-10-10):** `W-report-issue`. An Intel "Report an
   Issue…" item in the Help menu that opens a new issue on the fork
   (`reneezmp/osaurus-intel`). Upstream's item points at
   `osaurus-ai/osaurus/issues/new` and was left out on 2026-10-10
   (`W-app-menus`). **Before coding:** Renée turns on Issues for the fork on
   GitHub (it was off on 2026-10-10). Then add the menu item where upstream
   has it (`App/osaurus/osaurusApp.swift`, after Documentation), with an
   Intel URL. An issue template that asks for the Intel build number and
   macOS version would help. Update the Intel-owned files table in
   `UPSTREAM_SYNC.md`.

Update this doc (and re-run the script) whenever a feature ships or upstream
adds files; an UNASSIGNED file is an unclassified feature. Also run
`scripts/upstream/classify_gated.py`: `classify_gap.py` cannot see files Intel
compiles but switches off (`#if !OSAURUS_INTEL`), `AppleSiliconOnlyTab`
placeholders, or the App target (`W-gated-sweep`, 2026-10-10). Both scripts
share the feature table in `scripts/upstream/gap_features.py`.
