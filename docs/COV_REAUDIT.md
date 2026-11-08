# Coverage re-audit (`W-cov-reaudit`)

Started 2026-11-07. The file classifiers (`classify_gap.py`,
`classify_gated.py`) only see upstream files Intel doesn't compile. A file
Intel compiles — its own copy, or an upstream file ported at some point — can
still miss later upstream commits to it, and nothing flags that. Two cases
were found by accident: #1522 (`ae34ca6ac`, the legacy-root merge marker,
2026-11-02) and #2232 (`7f39220f6`, headless runs follow the agent's default
model, 2026-11-06). This audit looks for the rest.

## Method

`scripts/upstream/cov_reaudit.py <ref>` walks every upstream commit from the
fork point (`d0782cbb4`, 2026-05-23) to the ref that touches OsaurusCore
sources, and keeps the ones **no doc under `docs/` mentions** (by short hash
or PR number). The audit docs are the commit ledger, so a mention means the
commit was examined. It drops commits that only touch tests/resources, or
only files whose feature group is Incompatible, Deferred or dev tooling
(`gap_features.py`).

For each remaining commit it scores **presence**: of the lines the commit
added that still exist in upstream at the ref (so later upstream rewrites
don't count), how many appear anywhere in Intel's OsaurusCore sources. A
"superseded" commit has no surviving added lines; upstream rewrote them later,
and the rewrite is a commit of its own. `--show <hash>` prints one commit's
files and its missing lines.

The table below gives every listed commit a verdict, and its hash mention
takes the commit off the list: the run ends with `UNTRIAGED 0` when every
commit has a verdict. Rerun it after each upstream batch.

Verdicts: **In** (present on Intel; presence ≥ 90% or checked), **I**
(incompatible: local MLX runtime, models, pins, containers), **NA** (needs a
part Intel doesn't have by design, e.g. upstream's SQLite chat store), **N**
(tests, CI, evals, comments, removals), a **backlog item** id (the commit
belongs to that item and is ported with it), **Gap:<area>** (missing on
Intel; port), **Check:<area>** (Intel has its own version; compare
behaviour before deciding).

## Results at `bce907045` (2026-11-07)

1,373 upstream commits touch OsaurusCore since the fork: 992 are mentioned in
the docs, 43 touch only tests/resources, 48 only incompatible/deferred files.
**290 were unexamined.** Verdicts: 141 I, 48 In, 9 N, 4 NA, 35 for backlog
items (`W-computer-use` 8, `W-skills-plugins-import` 8, `W-privacy-filter` 6,
`W-diagnostics-telemetry` 4, `W-declarative-config` 3, `W-ui-misc` 3,
`W-channels` 2, `W-subagents` 1), **6 Gap** and **47 Check**.

Also found while triaging:
- **Skill .zip import/export throws "unavailable on Intel"**
  (`IntelDataConformers.importSkillFromZip`). Upstream's `SkillImportPolicy`
  is listed under `W-skills-plugins-import`, so it is tracked there, but the
  user-facing gap (the Skills page offers .zip and then fails) was not
  written down.
- **Translations:** Intel's `Localizable.xcstrings` has 4,981 strings
  against upstream's 9,947; Korean and Russian cover 953 strings on Intel
  against 8,287 upstream, Traditional Chinese 790 against 7,546. Screens
  Intel shares with upstream may show English where upstream is translated.
  (Merge rule: `UPSTREAM_SYNC.md`, "`Localizable.xcstrings` merges".)
- **Skill folders:** Intel's `SkillStore` keeps a renamed skill's original
  folder (`directoryName`), where upstream moves it (#1321). Not a gap.

## Examined but absent (`--mentioned`)

Found in stage 2: a doc mention means a commit was examined, not ported. The
0.24.3 triage (`UPSTREAM_TRIAGE_0.24.3.md`) marked #2388 and #2392 PORT, and
neither reached Intel. `cov_reaudit.py --mentioned` scores the mentioned
commits and lists those whose code is mostly absent (presence < 50%) and
whose ledger lines record no skip/defer/omit/incompatible decision. At
`bce907045` that is **166 commits** (stage 3 triages them with the Check
groups). Re-checked ones are listed here as "re-checked `<hash>`" so the
tool drops them:

- re-checked `ccd310ed0` (#2388): ported in stage 2.
- re-checked `b9b8b7fc8` (#2392): ported in stage 2.

Stage 3 triage (2026-11-07) of the other 164: 15 are in after all
(the ledger records them covered or shipped in Intel's own form),
22 incompatible, 3 not applicable, 2 no behaviour, 44 belong to
backlog items, and **78 need a comparison** with Intel's own code, by
area. Most Check rows come from the 0.24.3 triage
(`UPSTREAM_TRIAGE_0.24.3.md`), whose PORT verdicts were a plan: that sync
ported selected commits, often by replacing whole files, so a PORT row with
its code absent is a candidate gap.

| Verdict | Commit | PR | Presence | Subject | Ledger |
|---|---|---|---|---|---|
| Check:agents | re-checked `3085b242a` | #2870 | 4/19 | Keep agent purpose metadata current across remote and voice consumers | UPSTREAM_AUDIT_2026-09-25 |
| Check:agents | re-checked `81d201c4a` | #1756 | 1/17 | Make built-in Default agent non-configurable; fix sub-agent toggle persistence | UPSTREAM_TRIAGE_0.24.3 |
| Check:agents | re-checked `cf01aa146` | #3121 | 3/13 | Avoid repeated @Published agents lookups in liveAgentSources | INTEL_MISSING_FEATURES_BACKLOG, UPSTREAM_AUDIT_2026-10-26 |
| Done (3c-1) | re-checked `2d238592c` | #1725 | 28/97 | Fix same-turn capability tool activation | Same-turn activation was already Intel's (`CloudChatEngine` adopts loaded tools on the next round); upstream's `validateDynamicToolSchema` now skips a malformed plugin/MCP schema with a diagnostic, at load and at every offer (`CapabilityLoadBuffer.validSpecs`). |
| W-seatbelt-sandbox | re-checked `554ace8e2` | #2157 | 28/150 | Redact secret tool arguments across agent surfaces | Redacts only `sandbox_secret_set`'s value; that tool is not compiled on Intel (`SandboxSecretTools.swift` excluded). Lands with the sandbox tools. |
| Done (3c-1) | re-checked `7ec54935b` | #2171 | 88/349 | Fix tracked tool completion and prompt cache stability | The Done banner reads Blocked from `complete`'s `outcome: blocked`. Its three todo rules are retired upstream (return nil); frozen tool specs belong to the per-chat prompt freeze Intel doesn't have (stage 5). |
| Done (3c-1) | re-checked `bc6146f1a` | #2344 | 0/3 | Fix #2327: a reasoning-only turn with tools offered was classified as a finished answer | Reasoning-only stop with tools offered gets one fresh retry (`IntelTerminalRecovery`, upstream `classifyTerminal` verbatim). |
| Done (3c-1) | re-checked `c05947f02` | #1681 | 16/81 | Fix #1680: surface (not silently truncate) multi-step tool tasks on a premature-EOS empty turn | Empty turn: re-asked twice, then a visible fallback (`emptyToolTaskFallback` after tool work). Chat runs; the API and plugin surfaces are stage 5. |
| Check:chat | re-checked `5bb946f7f` | #2144 | 92/249 | auto generate chat titles | SYNC_0.24.3_PLAN, UPSTREAM_SYNC, UPSTREAM_TRIAGE_0.24.3 |
| Check:chat | re-checked `bda1c895d` | #2170 | 9/19 | Add connectivity-driven offline mode for chat | UPSTREAM_TRIAGE_0.24.3 |
| Check:chat-import | re-checked `098cbd4ed` | #2650 | 13/29 | recognize claude's export index and point users at the batch zips | MEMORY_PLAN, UPSTREAM_TRIAGE_0.24.7 |
| I | re-checked `0129221a0` | #2538 | 24/79 | Warn when switching models mid-conversation | 3b: upstream now warns only when the previous model is an on-device MLX model (`isLocalChatModel`: only that drops an Osaurus-held prefix cache); Intel has none. |
| In | re-checked `13d04eb83` | #2365 | 2/9 | minor UI polish | 3b: the diff spinner fix is in (`NativeFileDiffView` matches upstream); Intel's agents sink runs `receive(on: RunLoop.main)`, after the list is set, so the per-agent theme never trails by one. |
| Done (3b-1) | re-checked `18bfc8563` | #1939 | 38/77 | added timestamps to user message cells | Done 2026-11-07 (3b-1): `.userMessage` carries `timestamp` and `responseTurnId`; the user header's "…" menu shows the time and Inspect response. With #1655 (`f67c3a3e1`, PORT in the 0.24.3 triage but never landed): the reply's "…" menu starts with its time. |
| In | re-checked `234e3bc20` | #3067 | 2/6 | make copy button copy only the response | 3b: Intel's copy button already leaves thinking out (`copyTurnContent`); the missing lines are the dispatch-envelope and image-only copy from other commits. |
| Done (3b-2) | re-checked `286c4a9a4` | #2020 | 0/2 | fixed find bar crash when scrolling to a match in a partially rendered message | Upstream's `NativeMarkdownView` (file sync): the child that owns an occurrence answers for it, and a negative index returns nil instead of trapping. Upstream `SearchOccurrenceIndexTests`. |
| Done (3b-1) | re-checked `3a17bc04d` | #2730 | 16/55 | Fix Orchestrator row selection and fit the chat window to small screens | Done 2026-11-07 (3b-1): the floor, the creation fit and the sidebar's `.subviews` mask were in; added the re-fit on display changes (`didChangeScreenParametersNotification`), the on-screen origin clamp at creation, and the full-screen and mouse-down guards. |
| I | re-checked `435426db4` | #1894 | 9/27 | Show live tool-call progress card during buffered tool generation | 3b: the tool-call progress hint is emitted only by the local MLX runtime, which buffers the whole envelope; cloud streams name the tool on its first delta. |
| Done (3b-1) | re-checked `4b96ae0ab` | #2074 | 82/215 | Fix singular and plural count labels | Done 2026-11-07 (3b-1): 17 files already had it; the rest applied where Intel shows the text (tool and thinking cards, Identity, memory, skills, plugins, external models, calendar/reminder probes). Strings Intel doesn't show were skipped. |
| Done (3b-2) | re-checked `8bd7106cc` | #2038 | 54/144 | make the chat window responsive down to narrow widths | The composer's toggle chips collapse to icons when the measured row is too narrow (`chipsCompact`); a chosen folder keeps its name. Intel's selector row has no meta cluster (credits sit in the button bar), and its empty state is its own, so `EmptyStateContent` doesn't apply. |
| Done (3b-2) | re-checked `a82aa1447` | #2381 | 12/56 | added full screen preview for generated images | Generated (markdown) images open full screen (`onImagePreviewImage` through the thread, table and cell); the "Generating image…" status shimmers. |
| Done (3b-1) | re-checked `d0b9502b8` | #2256 | 11/32 | Add optional shadow style for chat input | Done 2026-11-07 (3b-1): the theme's `inputStyle` (Gradient / Shadow) drives the composer border and shadow; Themes › Borders & Effects has the Input Box picker and the preview follows it. |
| Done (3b-2) | re-checked `dbfc3420a` | #1969 | 63/311 | fixed in-chat search bar focus, per occurrence navigation, and current match highlighting | Per-occurrence find: upstream `ChatFindMatcher` (off-main, debounced, spinner), `ChatFindBar` (refocus on Cmd+F; Up/Down on macOS 14+ only, `onKeyPress`), current-match highlight via the synced renderer, block offsets and scroll-to-line in `MessageTableRepresentable`. Also fixed Intel's `scrollToTurn`, which looked for upstream's `usermsg-` block ids (Intel's are `user-`). |
| Check:crashes | re-checked `161e6ca57` | #1699 | 2/21 | fix app hang watchdog stalls across folder, tool listing, permissions, and launch | SYNC_0.24.3_PLAN, UPSTREAM_SYNC, UPSTREAM_TRIAGE_0.24.3 |
| Check:crashes | re-checked `18367d94b` | #1754 | 8/30 | fixed main thread freezes | UPSTREAM_TRIAGE_0.24.3 |
| Check:crashes | re-checked `1fd695a68` | #1672 | 11/28 | fixed app hangs | UPSTREAM_TRIAGE_0.24.3 |
| Check:crashes | re-checked `4bfc9bb85` | #1920 | 17/52 | fixed sentry hangs & crashes | UPSTREAM_TRIAGE_0.24.3 |
| Check:crashes | re-checked `973c771fa` | #1948 | 18/44 | fixed main thread hangs | UPSTREAM_TRIAGE_0.24.3 |
| Check:crashes | re-checked `995376800` | #2307 | 60/186 | fixed main thread hangs | SYNC_0.24.3_PLAN, UPSTREAM_SYNC, UPSTREAM_TRIAGE_0.24.3 |
| Check:crashes | re-checked `ad5a2c5f9` | #1598 | 10/24 | fix app hang render path | UPSTREAM_TRIAGE_0.24.3 |
| Check:crashes | re-checked `cc1823517` | #2817 | 18/53 | fixed main thread hangs in the composer, markdown parsing and sidebar rows | CHAT_UX_INTEL, UPSTREAM_AUDIT_2026-09-25 |
| Check:crashes | re-checked `f6b9c984a` | #1781 | 13/29 | triage and fix sentry app hangs and crashes | UPSTREAM_TRIAGE_0.24.3 |
| Check:folders | re-checked `3034800ef` | #2765 | 87/194 | add recent folders to the + menu and agent working folder setting | UPSTREAM_AUDIT_2026-09-25 |
| Check:folders | re-checked `438b01222` | #2675 | 13/33 | apply project working folder by turning the agent sandbox off | UPSTREAM_AUDIT_2026-09-25 |
| Check:folders | re-checked `97498c331` | #2701 | 28/162 | Make the chat folder chip persist as the agent's working folder | UPSTREAM_AUDIT_2026-09-25 |
| Check:folders | re-checked `99ce8bd52` | #1900 | 2/10 | Fix folder file-write bugs: firmlinked-root rejection + new-file diff count | UPSTREAM_TRIAGE_0.24.3 |
| Check:i18n | re-checked `392954aa7` | #1437 | 47/144 | updated chinese translations | UPSTREAM_SYNC |
| Check:i18n | re-checked `50c2fb70e` | #1782 | 0/6 | Add Russian localization | UPSTREAM_TRIAGE_0.24.3 |
| Check:i18n | re-checked `54d650bad` | #1553 | 17/40 | updated chinese translations | UPSTREAM_SYNC |
| Check:i18n | re-checked `8a5606d0c` | #1633 | 0/38 | updated chinese translations | UPSTREAM_TRIAGE_0.24.3 |
| Check:mcp | re-checked `0901780cc` | #2805 | 38/89 | Preserve typed MCP image results in Chat and agent history | UPSTREAM_AUDIT_2026-09-25 |
| Check:memory | re-checked `79cc7dfe4` | #1834 | 20/113 | Clarify memory ingestion diagnostics | UPSTREAM_TRIAGE_0.24.3 |
| Check:mobile | re-checked `6673ecf0b` | #3070 | 1/20 | stop showing injected memory in user bubbles for chats continued from the phone | IDENTITY_MOBILE_INTEL, INTEL_MISSING_FEATURES_BACKLOG, UPSTREAM_AUDIT_2026-10-26 |
| Done (3b-3) | re-checked `1e62218a8` | #1973 | 0/2 | minor tweak in favorite models UI | Intel's SwiftUI `ModelPickerView` (agent editor, Settings, compaction): the favourites heart sits after the name; filled and always shown in the Favorites tab, where tapping removes. |
| Done (3b-3) | re-checked `2a58c2397` | #1467 | 93/223 | improved model picker view UX | Provider labels on rows that mix sources (All, Favorites, search); descriptions were already shown. Arrow-key tab switching doesn't apply: Intel's picker has no keyboard navigation (Ventura rule). |
| Done (3b-3) | re-checked `993c2b499` | #1889 | 0/8 | improved favorite models UI | Favorites tab pinned first (shown while a favourite is among the options), hearts on hover, filled hearts persistent (`FavoriteModelsStore`, shared with the chat picker). Intel keeps All as the default tab. |
| Check:onboarding | re-checked `1faccfa28` | #2487 | 3/16 | minor improvements in onboarding | UPSTREAM_TRIAGE_0.24.3 |
| Done (3c-1) | re-checked `0046b7b4a` | #2173 | 1/20 | inject current date and timezone into the latest user turn | `[Current Time]` (upstream's current, minute granularity) rides last on the latest user message for chat and HTTP agent runs; replaces Intel's Apple Apps-only clock. |
| Done (3c-2) | re-checked `31d9ec56c` | #2278 | 1/3 | Remove generative greetings | Generative greetings removed as upstream: the Conversation → Greetings section, the agent Empty State AI/Custom picker (the Greeting, Message and Action Bar fields stay), the empty-state path, the greeting fields of `ChatConfiguration` and `AgentSettings` (old agent keys survive as unknown fields), `greetingPoolCacheFile`, Intel's no-op stubs and the two test files. |
| Done (3c-2) | re-checked `4a9a23f0b` | #1430 | 15/111 | improved system prompts for better instructions following | Intel's composer now emits upstream's static sections (`IntelPromptDiscipline`: model family guidance, Grounding, Code style, Risk-aware actions, Agent loop; texts and `ModelFamilyGuidance.swift` at `bce907045`). Sandbox Plugin Creator skill removed, `PluginCreatorGate` synced, sentence-case folder headings. The sandbox ladder, Secret handling, Self-improvement and plugin recipe are sandbox-only; the manifest wording was rewritten again by #2309 (3c-3). |
| Done (3c-2) | re-checked `849bc4837` | #2862 | 0/5 | Stop quoting a settings shortcut that is not bound | Intel's guides already say Settings… (⌘,); the CLI plugin template still quoted Cmd+Shift+M and now says Settings… (⌘,) → Plugins. The other paths in the commit are upstream screens Intel doesn't have or has under its own names. |
| Done (3c-2) | re-checked `86ed14d91` | #3033 | 0/9 | Clarify judge polarity and ScreenContext rubric while preserving verdict gating | `CapabilityClaimsEvaluator` judge prompt: reason before verdict and the polarity rule. The ScreenContext eval runner is not on Intel. |
| I | re-checked `03de9e23b` | #2427 | 1/7 | Video attachments were silently dropped at send for bundles whose name lacks -vl | 3a: local bundle video capability (MLX). |
| Done (3a) | re-checked `0a8c50086` | #2415 | 5/11 | fix external providers stuck disconnected after an update relaunch | Intel had no recovery at all: discovery swallowed transport errors as "0 models". Now thrown, classified, and retried on the network's up edge. |
| In | re-checked `10e66ca5c` | #3042 | 14/88 | Compaction turns reasoning off in a form self-hosted servers read | 3a: Intel's compaction sends `disableThinking`, and non-strict hosts get `chat_template_kwargs.enable_thinking=false`. |
| Done (3a) | re-checked `31dd9f260` | #1954 | 15/68 | Fix ChatGPT/Codex test-button model count mismatch; add grok-4.5 to xAI catalog | Codex Test/discovery already use the live catalog; grok-4.5 (and grok-4.6) came with upstream's `XAIOAuthService`. |
| Done (3a) | re-checked `3877f5e99` | #2416 | 1/13 | fix openai codex models reporting a fallback context window | `OpenAICodexOAuthService.lastContextWindows` from the live catalog's `context_window`. |
| Done (3b-3) | re-checked `3dcd8f9b6` | #1991 | 204/470 | feat: catalog-driven reasoning controls + unified model options in the picker | Upstream's `ModelOptions.swift` (live `RemoteReasoningCapabilityCatalog`, audited per-version OpenAI / Mistral / DeepSeek-V4.1 profiles) and `ModelFamilyNames`; Codex catalog levels (`CodexModelMetadata`), the official OpenAI GPT-5.6 / GPT-6 contract and route-scoped Gemini levels fill the catalog from Intel's `ModelPickerItemCache`; the card uses catalog defaults and level descriptions. Intel stubs `DeclaredReasoningEffort` (local bundles). |
| In | re-checked `40031d8e1` | #1879 | 10/37 | fixed image attachments being blocked or silently dropped for remote provider model | 3a: remote models count as image-capable and Intel's Anthropic adapter sends image blocks. |
| In | re-checked `4137884fa` | #2562 | 111/459 | Recover media rejections and harden OpenAI Responses | 3a: media rejections are remembered (`IntelImageInputFallback`); keeping Responses-native output items across turns goes to stage 5 (ChatEngine audit). |
| In | re-checked `4569b76f7` | #1530 | 0/4 | Route OAuth requests through global proxy | 3a: Intel's OAuth services use `GlobalProxySettings` sessions. |
| NA | re-checked `563f91746` | #1968 | 7/28 | Fix Router 409 IDEMPOTENCY_CONFLICT on refunded agent-loop iterations | 3a: Intel sends no idempotency key on chat requests, so the 409 can't occur. |
| Done (3a) | re-checked `577a3eeec` | #2304 | 17/86 | honor context windows advertised by custom provider /models endpoints | The picker already had advertised windows; the chat budget now reads them (`IntelContextBudget.providerContextWindow`). |
| Check:stage5 | re-checked `5f12d260f` | #1961 | 265/665 | Remote provider hardening: crash/hang fixes, endpoint trust, Router spend safety, streaming perf | 3a: spread across upstream's `RemoteProviderService` (streaming producer, watchdog, trust gates); compared in stage 5's engine audit. |
| In | re-checked `7bdb440f4` | #1983 | 42/110 | fix: support Codex Responses Lite for GPT-5.6 models | 3a: `OpenAICodexOAuthService.usesResponsesLite` from the live catalog. |
| Done (3a) | re-checked `bce51e0f1` | #2464 | 1/18 | hardcode openai context windows as api never returns them | `ModelPickerItem.officialOpenAIContextWindow` for the official host. |
| Done (3c-1) | re-checked `c81491b4b` | #2235 | 49/240 | Fix four reported runtime and model metadata issues | Agent-loop part: Max Tool Attempts reaches the engine (it stopped at 12 with an error), upstream's tool-free step-limit wrap-up with `iterationCapWrapUpNotice`, blank and failed wrap-up text. 3a: MLX and Seatbelt parts are incompatible / `W-seatbelt-sandbox`. |
| Done (3a) | re-checked `f01e5d44a` | #2463 | 2/29 | fix xai oauth models reporting a stale catalog and fallback context window | The xAI OAuth catalog's documented windows (upstream `XAIOAuthService.contextWindows`). |
| In | re-checked `f52fc9a32` | #3068 | 1/11 | read nested metadata.context_length so DeepInfra context windows resolve | 3a: `RemoteProviderManager.advertisedContextLength` reads DeepInfra's `metadata.context_length`. |
| In | re-checked `f9478c0f1` | #2205 | 3/25 | fall back to lenient decode for nonstandard streaming chunks during tool calls | 3a: Intel parses stream frames with `JSONSerialization` (already lenient) and skips unparseable ones. |
| Check:server | re-checked `7664572c8` | #3207 | 0/7 | fix iphone rejecting images for remote provider models | IDENTITY_MOBILE_INTEL, INTEL_MISSING_FEATURES_BACKLOG, UPSTREAM_AUDIT_2026-10-26 |
| Check:settings | re-checked `04e763bf7` | #2859 | 23/163 | Decide Automation permission probes from the error code, not the localized text | UPSTREAM_AUDIT_2026-09-25 |
| Check:settings | re-checked `12c6de27b` | #2191 | 55/137 | fix factory reset hanging indefinitely and add reset progress ui | UPSTREAM_TRIAGE_0.24.3 |
| Check:settings | re-checked `af68b0641` | #2220 | 1/7 | Fix plugin layout at compact widths | UPSTREAM_TRIAGE_0.24.3 |
| Check:settings | re-checked `e06996e3e` | #2295 | 44/119 | surface specific keychain errors and recover from acl denied credential saves | SYNC_0.24.3_PLAN, UPSTREAM_SYNC, UPSTREAM_TRIAGE_0.24.3 |
| Check:storage | re-checked `311d90959` | #1600 | 370/958 | Make at-rest storage encryption opt-in (plaintext by default, FileVault-gated migration) | SYNC_0.24.3_PLAN, UPSTREAM_SYNC, UPSTREAM_TRIAGE_0.24.3 |
| Check:storage | re-checked `3172aae24` | #1830 | 17/98 | Persist user turns before chat streaming | UPSTREAM_TRIAGE_0.24.3 |
| Check:storage | re-checked `9ddb49b01` | #1615 | 51/107 | added additional migration hardening | SYNC_0.24.3_PLAN, UPSTREAM_SYNC, UPSTREAM_TRIAGE_0.24.3 |
| I | re-checked `092e81cf7` | #2395 | 11/146 | Constrain reasoning_effort to the bundle's declared set so Qwen3.8 cannot hard-fail the render | UPSTREAM_TRIAGE_0.24.3 |
| I | re-checked `0ef3d8335` | #2819 | 49/321 | Sandbox: attribute provisioning failures and stop the quit-time VM re-boot behind vmnet_in_use | UPSTREAM_AUDIT_2026-09-25 |
| I | re-checked `1d17e9e02` | #2194 | 5/33 | Fix settings prompt warmup cache invalidation | UPSTREAM_TRIAGE_0.24.3 |
| I | re-checked `2ab74c0fd` | #2836 | 38/545 | Fix SSD cache sizing and current-chat capacity notices | UPSTREAM_AUDIT_2026-09-25 |
| I | re-checked `3d680ba07` | #1806 | 33/145 | Onboarding model step: explicit resource costs, one pick per family, low-disk preflight | UPSTREAM_TRIAGE_0.24.3 |
| I | re-checked `3f73c480d` | #2231 | 8/73 | Make the model-selector dot reflect true model residency | UPSTREAM_TRIAGE_0.24.3 |
| I | re-checked `417da91f0` | #2783 | 27/156 | Notify when SSD cache reaches its quota and clear indexed cache safely | UPSTREAM_AUDIT_2026-09-25 |
| I | re-checked `4be798d87` | #1963 | 10/52 | Flush pending stream text before tool-call frames; repin vmlx (stall + prose-cut fixes) | UPSTREAM_TRIAGE_0.24.3 |
| I | re-checked `56b3eb502` | #2822 | 51/105 | Preserve reasoning choices on cold sends and delegated steps | UPSTREAM_AUDIT_2026-09-25 |
| I | re-checked `576e202c9` | #2868 | 44/245 | Add full DMG build with bundled Raptor 0.6 (light + full releases) | UPSTREAM_AUDIT_2026-09-25 |
| I | re-checked `6b6bd6e53` | #2444 | 5/26 | An audio-capable model could not be given audio | UPSTREAM_TRIAGE_0.24.3 |
| I | re-checked `7969bc0e1` | #2260 | 16/72 | Add DeepSeek V4 Flash 0731 app support | UPSTREAM_TRIAGE_0.24.3 |
| I | re-checked `86ddcdd31` | #2467 | 0/4 | keep cross-chat prefill reusable by stabilizing the injected time block | UPSTREAM_TRIAGE_0.24.3 |
| I | re-checked `98459196d` | #2537 | 10/66 | Preserve explicit reasoning on the first cold send | UPSTREAM_TRIAGE_0.24.3 |
| I | re-checked `a9d2a150c` | #2507 | 48/272 | Swap-pressure warning banner + designer emulation controls | SYNC_0.24.3_PLAN, UPSTREAM_SYNC, UPSTREAM_TRIAGE_0.24.3 |
| I | re-checked `b12a646eb` | #2293 | 0/4 | Fix DSV4 thinking default, duplicate pre-send warmups, and 1M context resolution | UPSTREAM_TRIAGE_0.24.3 |
| I | re-checked `b6863d77f` | #2253 | 6/27 | Stabilize execution modes, prompts, and cache warmup | UPSTREAM_TRIAGE_0.24.3 |
| I | re-checked `c654abc1e` | #1593 | 1/8 | Laguna-M.1 + VibeThinker-3B serving: fix Laguna chat garbage (missing-BOS) + drop rep-penalty special-case | UPSTREAM_TRIAGE_0.24.3 |
| Done (3c-1) | re-checked `cc0898026` | #2167 | 141/412 | Fix Gemma and Qwen post-tool completion | Re-checked 2026-11-08: its loop part is not MLX-only — reasoning-only recovery and the unfinished-todo step-limit message are on Intel now; the Gemma/Qwen runtime parts stay incompatible. |
| I | re-checked `ec38ab2a4` | #2310 | 25/177 | Clarify model memory estimates and fit guidance | UPSTREAM_TRIAGE_0.24.3 |
| I | re-checked `f3d776096` | #1793 | 16/40 | Generation params: wire seed into the sampler, accept string stop, native penalties, min_p | UPSTREAM_TRIAGE_0.24.3 |
| I | re-checked `f6b872371` | #2752 | 47/276 | Fix RAM admission measurement, capacity and token-budget contracts | UPSTREAM_AUDIT_2026-09-25 |
| In | re-checked `11aaf4954` | #2156 | 0/3 | Report MCP tool envelope failures | UPSTREAM_TRIAGE_0.24.3 |
| In | re-checked `210685eb9` | #2764 | 28/90 | fit the settings window to small screens | FEATURE_PARITY, UPSTREAM_AUDIT_2026-09-25 |
| In | re-checked `2365e126a` | #1811 | 60/179 | added favourite tab in the model selector | INTEL_MISSING_FEATURES_BACKLOG, MODEL_PICKER_INTEL, UPSTREAM_AUDIT_2026-10-01, U |
| In | re-checked `4f8ba2103` | #3151 | 0/9 | Refresh image progress on equal-length status updates | UPSTREAM_AUDIT_2026-10-26 |
| In | re-checked `541a1b559` | #2916 | 12/63 | show total response time in the assistant stats footer | UPSTREAM_AUDIT_2026-09-29, UPSTREAM_SYNC |
| In | re-checked `5f66b028a` | #3116 | 0/5 | fix agent working folder getting cleared when saving the agent editor | UPSTREAM_AUDIT_2026-10-26 |
| In | re-checked `612c48626` | #2912 | 29/103 | cap chat minimap height and make the expanded list scrollable | UPSTREAM_AUDIT_2026-09-29, UPSTREAM_SYNC |
| In | re-checked `6322c3705` | #2614 | 4/25 | keep the main window hidden on login item and cli launches | UPSTREAM_TRIAGE_0.24.7 |
| In | re-checked `888d8a55a` | #2671 | 19/71 | persist memory consolidator last run and catch up on launch | FEATURE_PARITY, UPSTREAM_AUDIT_2026-09-25 |
| In | re-checked `97f5cc190` | #2619 | 82/195 | fixed main thread hangs | UPSTREAM_TRIAGE_0.24.7 |
| In | re-checked `9af6f53dc` | #2658 | 0/2 | Reopened sessions: a window opened from a history row loads the stored transcript instead of erasing it on the next send | UPSTREAM_TRIAGE_0.24.7 |
| In | re-checked `b02aaad40` | #3011 | 4/13 | Pin PromptSection token estimation main thread hang fix | UPSTREAM_AUDIT_2026-10-07 |
| In | re-checked `c9e2d61a9` | #2900 | 7/46 | Preserve generation metrics across chat history reloads | UPSTREAM_AUDIT_2026-09-29 |
| In | re-checked `e53ae1106` | #2984 | 5/34 | Avoid storage-unlock scheduler waits and stale starts | UPSTREAM_AUDIT_2026-10-07 |
| In | re-checked `fb3d06a58` | #2889 | 2/16 | Preserve streamed tool names and align agent execution contracts | UPSTREAM_AUDIT_2026-09-29 |
| N | re-checked `6cf600fce` | #2778 | 23/58 | fixed xcode 27 build errors | UPSTREAM_AUDIT_2026-09-25 |
| N | re-checked `d264b231b` | #1639 | 0/3 | make plain-text answers the primary agent-loop exit | UPSTREAM_TRIAGE_0.24.3 |
| NA | re-checked `219640c82` | #2753 | 2/33 | Repair incomplete chat-history schemas so later turns persist | FEATURE_PARITY, UPSTREAM_AUDIT_2026-09-25 |
| NA | re-checked `96b05d20c` | #2566 | 0/6 | Hide local memory warnings for cloud models | SYNC_0.24.3_PLAN, UPSTREAM_SYNC, UPSTREAM_TRIAGE_0.24.3 |
| NA | re-checked `a2c020188` | #1481 | 3/22 | prevent switching chat windows from interrupting an in-flight chat | UPSTREAM_SYNC |
| W-agent-templates | re-checked `b4c9324b0` | #3172 | 1157/4280 | Add agent templates (file export/import) | INTEL_MISSING_FEATURES_BACKLOG, UPSTREAM_AUDIT_2026-10-26 |
| W-channels | re-checked `338425936` | #2775 | 271/1095 | Guide n8n setup so pairing codes only issue when they can work | INTEL_AGENT_SETTINGS_BACKLOG, UPSTREAM_AUDIT_2026-09-25 |
| W-channels | re-checked `94af9d41a` | #2762 | 106/361 | Add n8n pairing code for remote Secure Channel setup | INTEL_AGENT_SETTINGS_BACKLOG, UPSTREAM_AUDIT_2026-09-25 |
| W-channels | re-checked `a5cded095` | #3113 | 3/35 | accept slack messages posted through apps from allowlisted senders | UPSTREAM_AUDIT_2026-10-26 |
| W-channels | re-checked `a609acdb5` | #2748 | 360/2177 | Add first-party n8n agent channel with secret-verified webhook ingress | FEATURE_PARITY, INTEL_AGENT_SETTINGS_BACKLOG, UPSTREAM_AUDIT_2026-09-25 |
| W-channels | re-checked `e118cea31` | #2290 | 532/3241 | Add native WhatsApp agent channel (WhatsApp Web bridge) | UPSTREAM_AUDIT_2026-10-01 |
| W-computer-use | re-checked `246609942` | #2731 | 72/301 | Computer Use audit: telemetry funnel, readiness gate, verified done, loop evals | UPSTREAM_AUDIT_2026-09-25 |
| W-computer-use | re-checked `51ee70e3e` | #2797 | 121/247 | fix computer use failing with the privacy filter on and losing its step log | UPSTREAM_AUDIT_2026-09-25 |
| W-computer-use | re-checked `e6fb7a63d` | #3084 | 24/154 | Propagate screenshot scrubbing failures before cloud attachment | INTEL_MISSING_FEATURES_BACKLOG, UPSTREAM_AUDIT_2026-10-26 |
| W-declarative-config | re-checked `53c24678a` | #2750 | 68/303 | Make settings discoverable to the Orchestrator and Management search | UPSTREAM_AUDIT_2026-09-25 |
| W-declarative-config | re-checked `5e79d3304` | #2936 | 112/603 | Orchestrator audit remediation: truthful addendum, apply-first config, pool guard, default new-chat agent, compact spawn envelope | INTEL_MISSING_FEATURES_BACKLOG, ORCHESTRATOR_INTEL_PLAN, UPSTREAM_AUDIT_2026-09- |
| W-description-backfill | re-checked `c9021e91c` | #2869 | 19/49 | Generate missing agent descriptions from system prompts | FEATURE_PARITY, UPSTREAM_AUDIT_2026-09-25 |
| W-diagnostics-telemetry | re-checked `129e37729` | #1609 | 0/3 | fixed main thread hangs | UPSTREAM_TRIAGE_0.24.3 |
| W-diagnostics-telemetry | re-checked `3ba84c384` | #2081 | 1/10 | Fix management-window sheet-swap crash and wire Sentry release telemetry | SYNC_0.24.3_PLAN, UPSTREAM_SYNC, UPSTREAM_TRIAGE_0.24.3 |
| W-diagnostics-telemetry | re-checked `72c0f9e1f` | #1739 | 28/115 | Add model tool-use diagnostics | UPSTREAM_TRIAGE_0.24.3 |
| W-diagnostics-telemetry | re-checked `78b7ff8dd` | #2401 | 12/57 | Attribute silent restarts: exit markers + a launch-time verdict file | UPSTREAM_TRIAGE_0.24.3 |
| W-diagnostics-telemetry | re-checked `79b25d6b1` | #2284 | 5/74 | Improve activation telemetry: brain_source coverage, capability dimension, settings engagement | UPSTREAM_TRIAGE_0.24.3 |
| W-harness-runtimes | re-checked `0f7a4ed83` | #3180 | 83/710 | Harness runtimes in the model picker, config documents, and bundles | INTEL_MISSING_FEATURES_BACKLOG, UPSTREAM_AUDIT_2026-10-26 |
| W-harness-runtimes | re-checked `993c12f8e` | #3175 | 586/2592 | Add pluggable harness runtimes: Claude Code and Pi | INTEL_MISSING_FEATURES_BACKLOG, UPSTREAM_AUDIT_2026-10-26 |
| W-osaurus-bundles | re-checked `7ec27289f` | #3174 | 168/1030 | Add `osaurus import` for Osaurus bundles | INTEL_MISSING_FEATURES_BACKLOG, UPSTREAM_AUDIT_2026-10-26, UPSTREAM_SYNC |
| W-privacy-filter | re-checked `0d8ef8a2b` | #3152 | 0/6 | tie paired phone features to the phone's access key | IDENTITY_MOBILE_INTEL, INTEL_MISSING_FEATURES_BACKLOG, UPSTREAM_AUDIT_2026-10-26 |
| W-privacy-filter | re-checked `217c8c7d3` | #1545 | 0/4 | Route privacy model downloads through global proxy | UPSTREAM_SYNC |
| W-privacy-filter | re-checked `621912788` | #1449 | 1/35 | fixed fatal crashes | UPSTREAM_SYNC |
| W-privacy-filter | re-checked `bd0e196d5` | #1519 | 10/41 | [codex] Fix scrub-leaked localization fallback | UPSTREAM_SYNC |
| W-privacy-filter | re-checked `d9a1a0669` | #2474 | 345/792 | add bulk edit and on-device redaction tools for folder chats | UPSTREAM_TRIAGE_0.24.3 |
| W-seatbelt-sandbox | re-checked `02bcd1009` | #3094 | 0/1 | Seatbelt: cache isSupported check to prevent main-thread hangs (APPLE-MACOS-37V) | INTEL_MISSING_FEATURES_BACKLOG, UPSTREAM_AUDIT_2026-10-26 |
| W-seatbelt-sandbox | re-checked `d5b60ddf4` | #3105 | 0/1 | Use cached sandbox availability in effectiveAutonomousExec to fix main-thread hang | INTEL_MISSING_FEATURES_BACKLOG, UPSTREAM_AUDIT_2026-10-26 |
| W-skills-plugins-import | re-checked `40be05cb8` | #2737 | 14/30 | restore import claude plugin from github after tools and plugins refactor | UPSTREAM_AUDIT_2026-09-25 |
| W-skills-plugins-import | re-checked `c06428046` | #1477 | 60/316 | Harden skill archive imports | INTEL_MISSING_FEATURES_BACKLOG |
| W-skills-plugins-import | re-checked `e16fad2f3` | #1840 | 94/431 | Bound skill archive subprocesses | INTEL_MISSING_FEATURES_BACKLOG |
| W-subagents | re-checked `00486cc80` | #2688 | 6/24 | Honor admitted model overrides in delegated agent sessions | ORCHESTRATOR_INTEL_PLAN, UPSTREAM_AUDIT_2026-09-25 |
| W-subagents | re-checked `33d3c6812` | #2033 | 9/24 | Fix spawn_model target contract | ORCHESTRATOR_INTEL_PLAN |
| W-subagents | re-checked `3fb975f4e` | #1976 | 1/13 | spawn_agent: carry the target agent's own tool policy into the child run | ORCHESTRATOR_INTEL_PLAN |
| W-subagents | re-checked `9222379e3` | #2796 | 125/481 | Unify invoking-parent handoffs across local subagent kinds | UPSTREAM_AUDIT_2026-09-25 |
| W-subagents | re-checked `99a87c20f` | #2798 | 103/360 | Share parent handoff policy with images and compaction | UPSTREAM_AUDIT_2026-09-25 |
| W-subagents | re-checked `a48a58cf4` | #2707 | 0/26 | Let delegated agents write files in their own Working Folder | UPSTREAM_AUDIT_2026-09-25 |
| W-subagents | re-checked `fa706a5de` | #2790 | 3/15 | Explain warning-pressure delegation refusals and qualify RAM opt-out | UPSTREAM_AUDIT_2026-09-25 |
| W-workspaces-sharing | re-checked `16ec3a7a3` | #2811 | 159/613 | Embed the Workspaces explainer in the tab's empty state; drop the intro dialog | UPSTREAM_AUDIT_2026-09-25 |
| W-workspaces-sharing | re-checked `2ad1d93dc` | #2763 | 17/39 | disable add folder for shared agent chats | UPSTREAM_AUDIT_2026-09-25 |
| W-workspaces-sharing | re-checked `694efa53a` | #2915 | 9/113 | Bill the workspace pool by default for own shared agents; show pool chip on local tabs | UPSTREAM_AUDIT_2026-09-29, UPSTREAM_SYNC |
| W-workspaces-sharing | re-checked `940d86a31` | #2683 | 3548/9478 | Workspaces: shared agents, team-billed inference, single-plan trial billing | FEATURE_PARITY, INTEL_AGENT_SETTINGS_BACKLOG, ORCHESTRATOR_INTEL_PLAN, UPSTREAM_ |
| W-workspaces-sharing | re-checked `a4cb24b65` | #2692 | 738/1863 | Workspace agents as orchestration and dispatch targets | ORCHESTRATOR_INTEL_PLAN, UPSTREAM_AUDIT_2026-09-25 |
| W-workspaces-sharing | re-checked `d8e9cd60c` | #2687 | 22/136 | workspace improvements | UPSTREAM_AUDIT_2026-09-25 |
| W-workspaces-sharing | re-checked `fc48e4f0b` | #3111 | 1/9 | Chat sidebar: snapshot orphaned workspace pairings once per render | UPSTREAM_AUDIT_2026-10-26 |

### Feasibility rows the decline filter hid (found 2026-11-08)

Found in 3c-2. `--mentioned` drops a commit when a ledger line records a
skip or defer. `DEFER_FEASIBILITY_AUDIT_2026-09-08.md` supersedes every
DEFER in the 0.24.3 and 0.24.7 ledgers and marks many of those commits
**PORT NEXT** or **ROADMAP**, but the old DEFER lines still matched the
filter, so those commits were never scored. The tool now takes the
feasibility verdict as final for the commits it lists (`declined()` in
`cov_reaudit.py`); 32 came back mostly absent. The loop, capability and
prompt rows (11) form stage **3c-3**; the rest join their area's stage or
their backlog item.

Still open: the 0.24.3 SKIP verdicts that the feasibility audit did not
revisit (456 commits still count as declined). Some give reasons that no
longer hold, such as "Agent capabilities subsystem" or "Skills excluded",
now that Intel has both. Stage 6 re-reads them.

| Verdict | Commit | PR | Presence | Subject | Note |
|---|---|---|---|---|---|
| Check:agents | re-checked `ad0698d78` | #1608 | 82/196 | Stabilize the default configuration agent and fix disappearing custom agents | Default configuration agent and disappearing custom agents. |
| Check:capabilities | re-checked `06af55e7a` | #2336 | 24/60 | Bound capability group-load schemas + repin vmlx (Muse Glimmer runtime) | Group-load schema bounds (3c-3); the vMLX repin is incompatible. |
| Check:capabilities | re-checked `5d16b603f` | #2309 | 18/77 | Clarify capability IDs and recover grouped tool calls | Capability ids in the manifest, grouped tool-call recovery (3c-3). |
| Check:capabilities | re-checked `d89626227` | #2089 | 24/67 | Fix skill discovery metadata loss and MCP capability-load reliability seams | Skill discovery metadata and MCP capability-load seams (3c-3; `W-tools-tab-sync` holds the wording). |
| Check:chat | re-checked `7e109ade6` | #2668 | 0/1 | Chat: a run cancelled during its cold load must not roll back the retry that already owns the session | A cancelled cold-load run must not roll back the retry that owns the turn; check Intel's retry ownership. |
| Check:chat | re-checked `880752784` | #2661 | 3/31 | fix history dialog row actions and keep the dialog open under nested alerts | History dialog row actions and nested alerts (`CHAT_WINDOW_LAYOUT_INTEL.md` lists it as a source). |
| Check:crashes | re-checked `4daee7b36` | #2128 | 92/197 | fixed app hangs | App hangs #2128. |
| Check:crashes | re-checked `a9ae5fd9c` | #1901 | 80/176 | Free model memory on chat close, respond to memory pressure, and cap unbounded caches | Memory pressure and unbounded caches; the model-unload half is MLX. |
| Check:crashes | re-checked `b621603fb` | #2015 | 11/38 | Checkpoint: stop the gemma tool-loop, two crashes, and lying tok/s | Two crashes and tok/s reporting; the Gemma loop half is MLX. |
| Check:loop | re-checked `2b15a5078` | #1950 | 7/22 | Repin vmlx to 0d3444ca (gemma4 parser fix #128) + fix reasoning-toggle default display | Reasoning toggle default display; the vMLX repin is incompatible (3c-3). |
| Check:loop | re-checked `2ecf2b058` | #2250 | 466/937 | Make the Mac harness leaner and more reliable | Mac harness reliability (3c-3); the container and workspace parts go with their items. |
| Check:loop | re-checked `54aa52ada` | #2653 | 6/20 | Chat: queued steer ordering, stale notices across the steer boundary, empty wrap-up bubble | Queued steer ordering, notices across a steer, empty wrap-up bubble (3c-3). |
| Check:loop | re-checked `846ca9185` | #2101 | 2/17 | Preserve explicit Thinking mode across agent tool turns | Explicit Thinking mode kept across tool turns (3c-3). |
| Check:loop | re-checked `9b0331fd4` | #2105 | 5/72 | fix: honor reasoning toggle across agent tool loops | Reasoning toggle held across tool rounds (3c-3). |
| Check:loop | re-checked `e00a9d88d` | #2656 | 41/123 | Research completion: announce-only recovery names what the model can do; promised-work endings recovered; replayed retrieval failures escalate before stopping; window-close crash fixed | Announce-only recovery and promised-work endings (3c-3, with the stage-5 note on #2480). |
| Check:mobile | re-checked `67fba7464` | #1623 | 149/397 | harden remote agent security and reliability | Remote agent security and reliability. |
| Check:mobile | re-checked `d1b96a5e7` | #1658 | 40/176 | Harden Bonjour discovery (security, reliability, discoverability) | Bonjour discovery hardening; compare with Intel's discovered agents. |
| Check:mobile | re-checked `f7e683dfb` | #1636 | 29/158 | Fix and harden remote agent (Mode 2) runs | Remote agent (Mode 2) runs; compare with Intel's paired relay agents. |
| Check:prompt | re-checked `4be5a5776` | #1798 | 52/232 | Cut per-turn prompt cost: remote prompt caching + local KV prefix reuse + measured text trims | Remote prompt caching and prompt text trims; the local KV half is incompatible (3c-3). |
| Check:prompt | re-checked `61dad2f36` | #2051 | 19/85 | Reduce redundant agent prompt context | Redundant agent prompt context trimmed (3c-3; Intel's composer is its own). |
| Check:server | re-checked `34a64dc2d` | #2606 | 2/11 | fix /api/show for external models and report tool/thinking capabilities | `/api/show` for external models, with tool and thinking capabilities. |
| Check:settings | re-checked `64bc65808` | #2442 | 18/105 | Sampling Defaults were inert on almost every model, and nothing showed what actually ran | Sampling defaults applied and shown for remote models; the MLX half is incompatible. |
| W-channels | re-checked `44548e901` | #2202 | 487/1065 | Native channel presence, formatting, and reactions | Channel presence and reactions. |
| W-declarative-config | re-checked `8d7c3dd42` | #2485 | 1377/6646 | Default-agent declarative config + delegation orchestrator | The declarative configuration plane and orchestrator (`ORCHESTRATOR_INTEL_PLAN.md`). |
| W-declarative-config | re-checked `b285b946c` | #2628 | 5/72 | Watcher dispatch grounds itself; config apply says DONE | Watcher dispatch grounding and config apply; lands with the item. |
| W-declarative-config | re-checked `e03127e7b` | #2603 | 12/30 | Watcher/dispatch agents can actually reach their target folder | Watcher and dispatch agents reaching their folder. |
| W-diagnostics-telemetry | re-checked `1f052d17c` | #2563 | 45/185 | Show and cancel exact live inference work | Live inference work list and cancel. |
| W-subagents | re-checked `5856d3502` | #1769 | 4/14 | Standardize on "subagent" spelling (drop hyphenated "sub-agent") | "subagent" spelling; lands with the item. |
| W-subagents | re-checked `679ba7504` | #2498 | 88/219 | Orchestrator-first delegation: default-on spawn pool, same-turn spawn activation, and delegated artifact pass-through | Orchestrator-first delegation (`ORCHESTRATOR_INTEL_PLAN.md`). |
| W-subagents | re-checked `7aa8d7a30` | #2493 | 195/441 | Introduce the Orchestrator: dedicated settings tab, identity, and launch polish | Orchestrator settings tab and identity (`ORCHESTRATOR_INTEL_PLAN.md`). |
| W-subagents | re-checked `afa32e5c8` | #2165 | 268/576 | Unify runtime policy and bounded subagent delegation | Runtime policy and bounded delegation (`ORCHESTRATOR_INTEL_PLAN.md`). |
| W-subagents | re-checked `c853ca4ce` | #2533 | 104/253 | Spawn admission: price a child by its bounded request, not the retention cap | Spawn admission pricing (`ORCHESTRATOR_INTEL_PLAN.md`). |

## Plan (each stage a report and push)

1. **Stage 1 (this doc):** the tool and the triage.
2. **Stage 2, the six gaps (done 2026-11-07, five ported; #2306 moved to
   stage 5):** skill file path containment (#1275, security);
   DeepSeek thinking-mode `tool_choice` downgrade (#1940); window frame
   recovery (#2154); the cancelled-turn record and its "Interrupted" row
   (#2516, with upstream's `stop(preservesCancelledMarker:)` /
   `terminalStopReason`); the Data Visualizer skill loading `render_chart`
   (#2084); the Abilities context-impact readout (#2306, #2323).
3. **Stage 3, the Check rows of both tables (125), by area** (each a report
   and push): **3a** providers (21, done 2026-11-07); **3b** chat display
   and the model picker (22 with #1991), in three parts: **3b-1** composer
   and message actions (done 2026-11-07), **3b-2** the transcript (done
   2026-11-07; sync
   `NativeMarkdownView`, `MessageTableRepresentable` and the message cell
   with upstream as files: find per match, image preview, streaming
   scroll, durations, narrow chips), **3b-3** the pickers (done 2026-11-07;
   Favourites in the legacy picker, the live reasoning catalog); **3c**
   capabilities, the agent loop and prompts (14 with #2235's loop part), in
   three parts: **3c-1** the loop and capabilities (done 2026-11-08;
   upstream's terminal recovery in `CloudChatEngine`, the step limit and its
   wrap-up, the Blocked banner, schema checks, the time block; #1507, #2167,
   #2175 and #2192 re-checked with it), **3c-2** the prompt commits (done
   2026-11-08; generative greetings removed, #2278 and #1362; upstream's
   static discipline sections in Intel's composer, #1430 and #1317; the CLI
   plugin template's settings path, #2862; the judge polarity prompt,
   #3033), **3c-3** the loop, capability and prompt rows the decline filter
   hid (11; see "Feasibility rows the decline filter hid");
   **3d** knowledge (5); **3e** crashes and hangs (13); **3f** the rest
   (folders, storage, settings, agents, memory, voice, MCP, server, chat,
   chat import, onboarding, mobile, windows, flags, misc). Translations
   (Check:i18n) go to stage 4.
4. **Stage 4, translations:** bring upstream's translations for keys Intel
   shows.
5. **Stage 5, behaviour audit of the `COV-intel-own` files** (the item's
   original scope): commits since the fork are covered by stages 1–4; this
   compares behaviour Intel's replacements never had at all, starting with
   chat storage, the prompt composer (with the Abilities context-impact
   readout, #2306 / #2323, and upstream's per-chat freeze of the prompt and
   tool specs, #2171), `ChatEngine` and `RemoteProviderService`. From 3c-1:
   the engine's terminal recovery runs on chat only and skips upstream's
   announce-only and continuation-request cases (#2480); compare the rest
   of `AgentToolLoop.run` (truncated tool calls, repeated-retrieval and
   announce wrap-ups, the API and plugin surfaces). From 3c-2: Intel's
   composer puts the folder section and its own folder tool directive
   before the discipline sections (upstream: after Agent loop), never picks
   the compact variants (no context size class on Intel), and has no
   Capability Discovery section; upstream's Bulk edits section lands with
   `W-privacy-filter`.
6. **Stage 6, the declined verdicts:** re-read the 0.24.3 and 0.24.7 SKIP
   verdicts the feasibility audit did not revisit (456 commits at
   `bce907045` still count as declined) and drop the ones whose reason no
   longer holds on Intel ("subsystem excluded" for a subsystem Intel now
   has).

The 47 upstream commits past `bce907045` are a separate audit (carried
follow-up); rerun this tool with the new ref after it.

## Verdicts

| Verdict | Commit | PR | Presence | Subject | Note |
|---|---|---|---|---|---|
| Gap:agents | `8b0b59790` | #2323 | superseded | fix context impact ability count chip wrapping to two lines | Moved to stage 5: the readout (#2306) needs a prompt preview from Intel's own composer. |
| Gap:capabilities | `33dc9c0ee` | #2084 | 0/5 | Fix built-in Data Visualizer chart tool activation | Done 2026-11-07 (stage 2): `CapabilitiesTool.builtInSkillToolDependencies` loads `render_chart` with the built-in Data Visualizer skill. |
| Gap:chat | `c02c007cd` | #2516 | 5/10 | Render the recorded cancelled state instead of an invisible empty turn | Done 2026-11-07 (stage 2), with #2388 and #2392: `ChatTurn.terminalStopReason` (persisted), `stop(preservesCancelledMarker:)`, the trim keeps a stamped turn, and an empty cancelled turn renders "Interrupted". |
| Gap:providers | `3587ab0ad` | #1940 | 7/21 | Fix DeepSeek thinking-mode tool_choice HTTP 400 | Done 2026-11-07 (stage 2): `ChatEngine.sanitizedToolChoice` (also #3051: newer Claude generations) after the reasoning switch. |
| Gap:skills | `b32b368a7` | #1275 | 11/95 | [codex] Contain skill file paths | Done 2026-11-07 (stage 2): upstream's containment (`SkillStoreFileError`, contained read/write/remove) and recursive, symlink-skipping file listing in Intel's `SkillStore`. |
| Gap:windows | `84271e386` | #2154 | 2/14 | fix settings window opening offscreen with stale saved frame | Done 2026-11-07 (stage 2): `IntelWindowFrameRecovery` for chat windows (after the saved frame) and the reused Settings window. |
| Check:agents | `848f2c4c3` | #1837 | 54/160 | Add recoverable agent backup restore path | Recoverable agent backup restore (`AgentStore`); Intel keeps its own agent store. |
| Check:applescript | `0d4c8077d` | #2394 | 11/26 | Report an unusable AppleScript model assignment instead of swapping it | AppleScript agent reports an unusable model assignment instead of swapping it. |
| Done (3c-1) | `1a6bbd339` | #1679 | 1/3 | stop wasted iterations on repeated failing capabilities_load calls | An id matching nothing fails as not retryable in Intel's `capabilities`. |
| In | `9a593c5d3` | #2393 | 17/27 | Answer a bare capabilities call with the enabled list, not a rejection | Intel's `capabilities` answers a bare call with the paged enabled list and recovers id shapes (`recoveredIds`). |
| In | `f6384c3ce` | #2308 | 4/39 | Fix MCP capability indexing and custom agent scope | Intel's catalog is built live from the registry (no startup indexing race) and holds only loadable plugin/MCP tools, never the built-in configuration tools. |
| Done (3c-1) | `3c6941823` | #2175 | 24/35 | Stop completed agent runs from reopening on stale todos | Added 2026-11-08 (0.24.3 triage skipped it as "agent subsystem amputated", stale since the loop was ported). Upstream's reopening is retired (`prepareTrackedTaskContinuation` is never called); its live chat piece, `unfinishedTodoCapFallback` at the step limit for a todo written this run, is on Intel now. |
| In | `ca8bf2813` | #2192 | 33/78 | Fix stale Todo agent-loop completion and strengthen cache proof | Added 2026-11-08 (0.24.3 triage skipped it as "agent subsystem amputated", stale since the loop was ported). Its live part is on Intel: `complete` turns blocked only for a todo written this run (`AgentTodoRunScope`, upstream `AgentLoopTools`). The loop's recoverable-result rule is retired upstream; the cache proof is eval tooling. |
| Check:chat-errors | `f6657eb53` |  | 7/25 | Fix plugin tool-loop default iterations | `ChatErrorMessages` (system-resource exhaustion message) and plugin tool-loop default iterations; Intel has no `ChatErrorMessages`. |
| Done (3b-2) | `10dd0e915` | #1259 | 263/652 | chat improvements | `thinkingDuration` and `toolCallDurations` on Intel's `ChatTurn` (saved in the chat JSON), "Thought for 12s" / "Thought", and "· 1.2s" on tool rows. Friendly titles and the pending shimmer were already in; Intel's activity roll-up covers tool-group coalescing. |
| Done (3b-1) | `6d841a22b` | #1352 | 21/51 | save chart as image | Done 2026-11-07 (3b-1): upstream's `NativeChartView` (save as PNG, toast with Reveal in Finder; also #1283's no-replay entry animation flag). Intel keeps `chart.bar.xaxis` (the ascending symbol is macOS 14). |
| Done (3b-1) | `8b86266fb` | #1468 | 65/146 | cascading esc on chat view states | Done 2026-11-07 (3b-1): the Esc cascade (popover, themed alert via `ThemedAlertCenter.cancelActive`, voice overlay, clarify/secret prompt via `cancelByUser` with the question kept in the transcript, inline editor via `handlesEscapeLocally` / `cancelInlineEdit`, completion banner, then close); upstream's inline editor (hint, hover cursor, width re-measure) and clarify card (`EditableTextView`: Enter submits, Esc cancels); alert buttons carry Return/Esc shortcuts. |
| Done (3b-2) | `972e49b31` |  | 75/315 | chat polish with smoother streaming, stable tool call animations and scroll cache fixes (# | Chart and tool-group views survive cell recycling (coordinator caches, pruned per chat), charts animate once; the code block's streaming cursor and throttled highlight come with upstream's `NativeCodeBlockView`. |
| Done (3b-2) | `a69299136` | #1272 | 18/39 | fixed scroll to bottom lag & mid stream jumps during streaming | Leading-edge streaming height throttle (no more text growing below the viewport), the streaming row keeps its measured height, and no anchor capture around height notes. Intel keeps non-animated notes. |
| In | `ca2c1d202` | #2486 | 4/6 | fix leaked pacing timer on mid-stream processor dealloc | 3b: Intel's `StreamingDeltaProcessor` invalidates both timers in a plain `deinit` (`nonisolated(unsafe)` timers; `isolated deinit` needs a newer runtime). |
| Check:context | `78788ce18` | #1324 | 7/38 | fixed issue with context budget being out of sync | Context-budget preview sync; Intel has its own estimate refresh. |
| Check:context | `f6c5d13ae` |  | 1/7 | fix broken test | Context-budget preview refresh on agent change; Intel has its own `refreshContextEstimates`. |
| Check:crashes | `0336a4a2a` | #1359 | 32/63 | fixed fatal crashes & freezes | "fixed fatal crashes & freezes" #1359. |
| Check:crashes | `9150c0d68` | #1337 | 145/283 | fixed main thread freeze | "fixed main thread freeze" #1337. |
| Check:crashes | `a50e84448` | #1431 | 9/65 | fixed main thread hangs | Bonjour browser main-thread hang fix; Intel compiles its own `BonjourBrowser`. |
| Check:crashes | `efd4cd4e3` | #1353 | 60/98 | fixed app hangs across permissions, model browsing, audio and chat launch | App hangs across permissions, model browsing, audio, chat launch. |
| Check:file-tools | `53e657252` | #1311 | 191/296 | combined sandbox file operations into unified file operations | Unified file operations (#1311); container half is incompatible. |
| Check:flags | `2c04c6edd` | #1344 | 83/187 | updated feature flag logic and moved more features behind feature flags | Feature-flag logic (#1344). |
| Check:folders | `15543ac37` | #1313 | 348/413 | added stateful agent folder ops | Stateful agent folder operations (container half incompatible). |
| Check:folders | `270f3496e` | #1465 | 120/411 | Expose applied generation diagnostics | Applied generation diagnostics (MLX) plus `FolderContextService` ignore patterns. |
| Check:i18n | `3719bbee4` | #1380 | 15/83 | updated chinese translations | Translations; see the i18n group. |
| Check:i18n | `62397745f` | #1822 | 0/1 | Polish Russian localization | Translations; see the i18n group. |
| Check:i18n | `7f981963b` | #1491 | 8/16 | updated chinese translations | Translations; see the i18n group. |
| Check:i18n | `878984883` | #1373 | 5/10 | updated chinese translations | Translations; see the i18n group. |
| Check:i18n | `c19db3515` | #1466 | 8/83 | updated chinese translations | Translations; see the i18n group. |
| Check:i18n | `c5385fc15` | #1579 | 0/4 | updated chinese translations | Translations; see the i18n group. |
| Check:i18n | `d14a60a2c` | #1354 | 8/52 | updated chinese translations | Translations; see the i18n group. |
| Check:knowledge | `0c6563c66` | #2132 | 32/151 | auto categorize knowledge documents and soften the uncategorized warning | Knowledge documents: auto-categorized `inferredType`, softer uncategorized warning. |
| Check:knowledge | `2169524f6` | #2338 | 25/60 | pass full frontmatter through in read_knowledge output | `read_knowledge` passes full frontmatter. |
| Check:knowledge | `d85efbb74` | #2117 | 219/356 | knowledge base improvements | Knowledge base improvements #2117. |
| Check:knowledge | `dc13cff70` | #2383 | 95/316 | fix knowledge search timeouts and improve what gets indexed | Knowledge search timeouts, ignore rules and globs; Intel's knowledge stack is its own copy (`KnowledgeDatabase`, `KnowledgeView` differ by thousands of lines). |
| Check:knowledge | `e4aafec52` | #2067 | 1/3 | updated knowledge empty state copy | Knowledge empty-state copy. |
| Check:memory | `d870213bb` | #1613 | 4/8 | fixed issue with memory distill failure | Memory distillation collects visible text without streaming tool-hint sentinels; check Intel's distillation call. |
| Check:misc | `1342db202` | #1315 | 44/50 | minor UI improvements | Minor UI improvements #1315. |
| Check:misc | `1a4c25542` | #1297 | 24/42 | minor improvements | "minor improvements" #1297. |
| Done (3c-2) | `e2eec4a9e` | #1362 | 8/10 | disable generative greetings globally and moved to per agent configuration | Superseded: upstream removed generative greetings in #2278, ported in 3c-2. |
| Done (3c-2) | `76614779f` | #1317 | 31/48 | improve prompt for better guidance | Grounding, Code style and Risk-aware texts and the family blocks (LFM2, default obedience) come with #1430's port; `capabilities_search` was renamed later and Intel offers the `capabilities` gateway. Preflight companions are not on Intel (`COV-tool-discovery`). |
| In | `390eb33e2` | #1594 | 68/139 | anthropic compaction fix | 3a: Intel's `sanitizeToolSequence` pairs every call with a result, fills unanswered calls and demotes orphan results; a duplicate same-id result is demoted rather than merged. |
| Done (3a) | `76c1f6ae8` | #2108 | 21/76 | Fix truncated remote tool arguments | A round that ends on `finish_reason=length` with tool calls pending throws upstream's output-limit message; Anthropic's `max_tokens` stop now reaches the engine as `length`. |
| In | `b3472ce02` | #1428 | 20/26 | moved remote provider diagnostics to edit | 3a: the UI part is in (20/26); the missing lines are MLX disk-cache stats. |
| Check:server | `6948489e0` | #2399 | superseded | Reserve answer room on API requests so thinking cannot eat the whole max_tokens | Reserve answer room on API requests so thinking can't use all of `max_tokens`. |
| Check:server | `b51ef1ad8` | #1247 | 164/251 | added OpenAI compatible /v1/completions endpoint for FIM autocomplete | `/v1/completions` (FIM); upstream runs it on local MLX. |
| Check:voice | `6d25337b4` | #2321 | 55/106 | fix tts drift on long text with per sentence synthesis | TTS drift on long text (per-sentence synthesis). |
| Check:voice | `7b0babc73` | #2016 | 7/9 | Stop TTS from going silent after the output device changes | TTS goes silent after the output device changes. |
| Check:windows | `8d56219ee` | #2121 | 2/3 | fix settings window not opening on sequoia | Settings window not opening on Sequoia. |
| I | `004f479ff` | #1457 | 17/68 | fixed main thread disk hangs | MLX model discovery off the main thread. |
| I | `04465bb94` | #1292 | 4/11 | detect already downloaded local models in onboarding | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `07ab5fbcb` |  | superseded | Pin vMLX memory safety contract | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `09aa9a39d` |  | 32/75 | Guard Gemma4 required tool failures | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `0a67d44d0` |  | superseded | Repin vmlx (for real this time) and push the memory-safety level to the cache-store gate ( | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `0b8f7b99a` | #1397 | superseded | Pin vMLX Nemotron auto BF16 runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `0cf5749c1` |  | superseded | Pin vMLX Ultra mamba alias runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `0db031c0a` |  | superseded | Repin vmlx-swift b6eda04f — MLX Metal stream-map thread-safety (concurrent-GPU crash fix) | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `0e8247533` | #1817 | superseded | Repin vmlx-swift: strip orphan tool-call closer tags | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `0f674c39f` |  | superseded | Repin vmlx-swift to 65ba6986 (index-union MTP evidence, hybrid cache dedup, DSV3 dtype, ve | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `11167db8e` | #1453 | 6/109 | Keep local model discovery responsive | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `13947c787` | #1488 | 5/59 | Gemma 4 speed/cache + DiffusionGemma — consolidated (vMLX main 7d9a85fe) | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `144a9488a` | #1791 | superseded | Repin vmlx-swift: deterministic RMSNorm shift + Mistral VLM full-resolution images | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `149c17e57` |  | superseded | Repin vmlx: DFlash 2 at 56-62 tok/s in-app (ring fix + q4 drafter + verify dispatch) (#242 | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `156b6114c` | #2543 | superseded | Repin vMLX with Qwen 3.8 legacy-parser correction | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `1f507852f` | #2389 | superseded | Repin vmlx-swift to e77cdf59: fix Qwen3.6-27B image crash (vision quant dims) | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `2038cbd1e` |  | superseded | Repin vmlx: capture cache boundaries during prefill (fixes a family that could never popul | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `20d98c582` | #1378 | superseded | Pin Nemotron fallback macro runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `214ce0f75` |  | superseded | Repin vmlx a6472300: Gemma4 drifted tool-call envelope fix (stops leaked </tool_call/> mar | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `21b079b2f` | #2589 | superseded | Repin vmlx-swift to de0c26d3 (one canonical boundary record per tool-call cycle) | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `24af4289f` | #2134 | superseded | Pin LFM SSD prefix restore | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `26f880e11` | #1484 | 26/76 | hide embedding model from showing up for chat | Hide the local embedding model from the chat picker (MLX). |
| I | `28d028739` |  | 1/14 | Repin vmlx: DiffusionGemma prefill-progress + MLXLMCommon Swift 5 language-mode fix (#1499 | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `291db96fd` |  | superseded | Pin vMLX Gemma4 tool recovery | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `2bb390a94` | #2353 | superseded | Repin vmlx: stop generation on a verbatim output cycle | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `304166f98` | #2269 | superseded | Repin vMLX to the DSV4 encoder/cache hardening fixes | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `33527765c` |  | superseded | Harden Nemotron Ultra media and cache wiring | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `336e9311b` | #2491 | superseded | Repin vmlx: Ling 3.0 (BailingMoeV3/KDA) runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `3577e539d` | #2469 | superseded | Repin vmlx-swift to 1c17ce83 for the presence/frequency penalty fixes | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `357bc5dcf` | #2379 | superseded | Repin vmlx-swift to 294c11e9 so LFM2.5-VL can ship | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `36cf1da0e` | #2254 | 5/32 | Exclude warm-up calls from Insights | Local warm-up prefill calls excluded from Insights. |
| I | `3a11a687c` | #1619 | superseded | Repin vmlx-swift: L2 disk-cache orphan-row + solo seed-boundary fix | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `3db5cc20b` | #2445 | superseded | Repin vmlx to the merged VL feature-order fix | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `3f28d2a7d` | #1385 | superseded | Pin vMLX Nemotron graph evidence runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `41990541e` | #2532 | superseded | Repin vmlx-swift to aeb5e21c19: QSA crash fix + end-of-output hang fix | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `41c6f55ab` | #1348 | superseded | Pin Nemotron Ultra vMLX runtime contract | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `46029aa53` |  | superseded | Repin vmlx 466c0a10: Gemma4 bf16 global-attention fp32 upcast (fixes long-context <pad>) ( | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `465669aa5` | #1347 | superseded | Pin Gemma4 boolean schema vMLX runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `48c428dce` |  | superseded | Pin vMLX Ultra README boundary guard | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `48c659583` | #2553 | superseded | Repin vMLX for 90+ tok/s Ornith 35B decode | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `4ad6ef85b` | #2198 | superseded | Pin Nanbeige vMLX runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `4b88b1329` | #1427 | 29/121 | Add Gemma4 media capability diagnostics | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `4d10c76b8` | #2556 | superseded | Repin serialized MLX host reads for Qwen3.8 server crash | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `4f7dd1e84` | #1953 | 10/71 | Fix warm-up KV cache misses and sandbox tool-registration thrash | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `4fdfa4af9` | #1268 | 174/502 | Add post-1266 live family cache matrix harness | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `50d1aeac0` | #1341 | 32/65 | Pin Gemma4 nullable tool schema runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `518f6a60a` |  | 167/403 | Add Gemma cache defaults and prefill checkpoint | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `5372938f7` |  | 0/1 | Repin vmlx-swift → d35c0744: fix non-JANG Qwen3 tool-calling 'unsupported' regression (#16 | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `55f3dfcf8` | #2362 | superseded | Repin vmlx-swift to 3c354fb0: the repetition guard now reaches this app | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `599bb561f` |  | superseded | Repin vmlx: DFlash 2 drafter failures contained — AR fallback instead of a host crash (#24 | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `5cfb7c694` | #1489 | superseded | Re-pin vmlx-swift to main (357c81d4): DiffusionGemma router crash fix | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `63f8b59e6` | #1723 | superseded | Fix LFM2 tool-calling: repin vmlx native 'List of tools' format | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `65cdaf8f9` | #1301 | 19/131 | fixed missing stop button | Local MLX server runtime settings and companion streaming. |
| I | `65d0171d9` | #1310 | 33/78 | Consolidate Step 3.7 and LFM runtime proof | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `669419005` | #1490 | 50/188 | updated model lists | MLX model catalog. |
| I | `672a27b88` |  | superseded | Pin vMLX Nemotron Ultra release boundary | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `6e2c3c705` |  | 2/13 | DSV4 Flash integration: vmlx repin (fastpaths + weight-leak fix), warmup triple-prefill fi | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `6f7e7ca5b` | #2341 | superseded | Repin vmlx to the Muse Glimmer vision fix | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `6fcf1e0f3` | #1796 | superseded | Disconnect must not evict the BatchEngine (cold-load hangup crashed the server) | MLX BatchEngine eviction on disconnect. |
| I | `73086e7b2` | #1349 | superseded | Pin vMLX MiniMax parser runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `7840c3b9d` |  | 0/1 | Stop the engine at tool dispatch (kill zombie post-tool decode); repin vmlx de82613a (#259 | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `7c8139a02` |  | superseded | Re-pin vmlx-swift to main (53e7c208): Gemma de-scramble, slider KV, warm prefix reuse (#14 | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `7d6822732` | #2377 | superseded | Repin vmlx-swift to 11a43493 | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `7d6ee054c` | #1462 | 39/106 | Document Gemma checkpoint memory safety contract | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `7da425c53` | #2561 | 14/72 | Preserve the admitted allocator ceiling for native MTP | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `8112eb151` | #2573 | superseded | Advance the vmlx-swift pin to 1315fdcb (DeepseekV3 MoE f32 residual fix) | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `81375f161` | #1270 | 7/9 | feat(model-browser): add Newest / Oldest sort options | Local model browser sort. |
| I | `81c884be8` | #2557 | superseded | Repin cancellable speculative prefill runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `823508313` | #1421 | 39/118 | Pin vMLX LFM runtime hardening | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `837e2f1d4` | #2021 | superseded | Repin vmlx-swift: tool-call delimiter leak + batch prose cut | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `886d7b81f` | #1345 | 1/4 | Pin Nemotron Ultra vMLX runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `889a2708c` |  | superseded | Pin OsaurusCore to current vMLX main | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `89cc9be53` | #1930 | superseded | Repin vmlx-swift: default-on hybrid-SSM prefix cache reuse | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `8c490bf1b` |  | superseded | Pin OsaurusCore to current vMLX main | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `8ded9e417` |  | 0/1 | Add Step/LFM production model matrix | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `8ec2dcf84` | #1392 | superseded | Pin vMLX Ultra no-load speed gate | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `8efd41861` |  | superseded | Repin vmlx: refuse truncated model shards, and stop the post-answer stall on every warm tu | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `902bf4e6c` |  | superseded | Nemotron 3.5 Lightning: native MTP head + fix the fallback template eating its newlines (# | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `91c418f65` | #2570 | 4/26 | Fix embedding discovery in configured models directory | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `91f046ca6` | #2047 | superseded | Pin schema-1 JANG loader fix | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `93fcf2b43` |  | 2/25 | Honor DSV4's thinking default, recover desktop-subagent unavailability, accept context_win | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `94e6bcd3a` | #1454 | 2/7 | Make RAM pressure advisory for local model loads | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `95216c422` |  | 6/84 | Expose memory safety status in cache stats | VMLX memory-safety status in `/admin/cache-stats`. |
| I | `953913425` | #2438 | superseded | Repin vmlx to the auto disk-cache size (10f27d03) | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `95c55bed6` | #1405 | superseded | Pin vMLX runtime cache parser fixes | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `96cf188ff` | #1455 | 1/14 | Expose native MTP runtime status | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `989e86867` | #1340 | 94/218 | remove unused sandbox features | Removes container sandbox features. |
| I | `98da20529` | #2356 | superseded | Repin vmlx: fix the Muse tool-recipient header leak | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `9a9f91d2d` | #1443 | 11/33 | Fix MiMo JANG telemetry and N2 media preflight | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `9ad72084c` | #76 | superseded | Repin vmlx-swift → 14040d24: Gemma nested-object tool-call argument parse fix (#1592 | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `9bcde77d0` | #2382 | superseded | Repin vmlx-swift to a983c6fc so the reasoning ceiling reaches the app | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `9c38a3b67` | #1351 | superseded | Pin vMLX ZAYA CCA cache runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `a51e739cb` | #1381 | superseded | Pin vMLX Nemotron live proof runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `a614c1dbb` | #2342 | superseded | Repin vmlx to the Muse Glimmer centered-norm fold | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `aa7ab349b` | #2346 | superseded | Repin vmlx: parse GLM/DeepSeek tool calls that take no arguments | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `ae17c1481` | #2432 | superseded | Repin vmlx: adaptive depth re-arm + warmup-memo scope fix | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `aed4cd9fc` |  | superseded | Repin vmlx-swift to merged main (class-killer #116 + norm #117 + Theme 3) — fixes Metal co | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `aed6c870e` | #1355 | 557/974 | updated models details view, discover models from hugging face and LM studio | Local model details, Hugging Face / LM Studio discovery (MLX). |
| I | `b0d48c75d` | #1986 | 10/40 | Background work must never evict the model the user is using (+ vmlx repin) | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `b1cd2b368` | #1408 | superseded | Pin vMLX runtime proof harness | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `b8a3a2f50` | #1398 | superseded | Pin vMLX hybrid SSM cache fix | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `b9175979d` |  | superseded | Repin vmlx 36aebd42: strip tool-call markers when no tools offered (fixes chat-UI envelope | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `b965375f1` | #1331 | 0/1 | Fix Gemma4 chat image attachment routing | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `bb453a9f1` | #2586 | 0/7 | Mark internal utility generations as auxiliary cache intent (repin vmlx 86d23df8) | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `bbd5d5ceb` |  | superseded | Pin vMLX Nemotron Ultra loader hardening | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `bc23615e4` | #2122 | 1/5 | Attach SSD cache before publishing loaded models | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `bc84ce9f7` |  | 10/50 | Fix Gemma4 reasoning, VL recognition, and tool schema rendering | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `bd53530af` | #1429 | superseded | Pin vMLX Gemma4 RoPE and MoE fixes | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `c0d0bc02d` | #1343 | 0/1 | fixed minor issue with chat template | Gemma chat-template schema rendering (local MLX). |
| I | `c1d55f527` | #1319 | 6/27 | bug fixes | Sandbox container network reconcile (containers). |
| I | `c1ddce3ff` | #2386 | superseded | Repin vmlx-swift to cf3f16de | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `c6c47879a` | #2396 | superseded | Repin vmlx-swift: MTP sampled-engage overhaul + hybrid post-answer replay kill | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `c7b685893` | #2086 | superseded | Pin ZAYA cache fix and enable Nemotron Omni multimodal routing | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `c8e0b3126` |  | superseded | Pin vMLX Nemotron parser alias runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `ca79cc2af` |  | superseded | Pin vMLX Ultra mmap trace runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `cafd3348e` |  | superseded | Pin OsaurusCore to Nemotron JangPress status update | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `cfaf64053` | #1394 | superseded | Pin vMLX Nemotron decode conv runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `cfcc5b828` | #2361 | superseded | Repin vmlx-swift to 751a5779 | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `d61803a2e` |  | superseded | Repin vmlx-swift to c976fcbd — Ornith prefill counter advances (vmlx #105) | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `d94d9d55c` | #1994 | 9/68 | Refuse background model loads inside the actor, not before it | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `dad7dfdfb` | #2405 | 1/12 | fall back to the chat model when follow up generation hits a residency refusal | Local model residency refusal fallback. |
| I | `dae15a924` | #1403 | superseded | Pin vMLX hybrid SSM cache fix | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `df3a7e1f7` | #1338 | superseded | Pin Gemma4 tool parser vMLX runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `dfd7c43af` | #2340 | superseded | Fix the Muse Glimmer vision path: placeholders never rendered or matched | MLX vision model path (Muse Glimmer). |
| I | `e2a73c316` | #1622 | superseded | Repin vmlx-swift -> 643fde27: Kanana-2-30B-A3B (deepseek_v3) support | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `e51c804cf` | #2093 | superseded | Pin Bonsai hybrid cache replay and disk quota fixes | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `e5474d0a6` |  | 15/49 | Gemma 4 audio + GGUF-class speed: repin vMLX 1ab081eb, fix TurboQuant KV regression, decod | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `e6bbcc345` | #1329 | 0/3 | Add Gemma 4 12B unified vMLX runtime pin | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `e83547bf3` |  | 2/6 | fail image jobs on recovered mlx gpu errors instead of crashing and repin vmlx-swift (#258 | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `e9f48f066` |  | superseded | Prove LFM2.5-2.6B (JANG_6M + MXFP8) live and repin vMLX to the short-conv cache fixes (#22 | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `eaa03589a` | #2276 | superseded | Repin vMLX to the disk-store offset guard | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `ec5c21e39` | #2504 | superseded | Repin vmlx-swift to 447a6a2b: Qwen 3.8 Flash Next native runtime | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `ec7eab2b1` | #1330 | 1/8 | fixed onboarding issues | Onboarding local model selection (MLX). |
| I | `ed3aa6bd9` |  | superseded | Repin vMLX 839d9f55: live prefill streaming + tool-name canonicalization + monotonic prefi | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `edcc7ec52` | #1401 | superseded | Pin vMLX streamed parser fix | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `f40c687e1` | #2262 | 0/7 | Pin vMLX DSV4 warmup replay fix | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `f4ce297b5` | #1492 | 21/63 | fixed missing prefill UI | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `f57a15d44` | #1686 | 6/18 | Repin vmlx-swift: fix Mistral3/Pixtral VLM model-load crash | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `f6f6d8749` |  | superseded | Pin OsaurusCore to vMLX JPREG proof docs | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `fbca33861` | #2270 | superseded | Repin vMLX to the boundary-digest diagnostic | Local MLX runtime, model or pin; no Intel local runtime. |
| I | `fdc5d210f` | #1425 | superseded | Pin vMLX MiMo routed JANG fix | Local MLX runtime, model or pin; no Intel local runtime. |
| In | `1cae8487c` | #2064 | 18/18 | Fix AppleScript query completion outcomes | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `1cb70f1a6` | #2351 | 11/11 | Accept a string `contents` on mac_query instead of rejecting it | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `1ff28234b` | #1285 | 39/39 | fix MCP OAuth discovery for servers that publish path scoped PRM | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `21123c9ad` | #1418 | 9/9 | fixed main thread hangs | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `22ebfcad9` | #1279 | 127/127 | [codex] Harden PPTX ingress metadata | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `25d0175d1` | #2151 | 146/146 | Fix TextEdit AppleScript state and completion handling | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `2ea0189d1` | #1423 | 11/11 | fixed memory that never produced new episodes on long-running installs | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `326ae2d3b` | #2314 | 53/58 | fix diff card header alignment | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `36db4ce62` | #1239 | 20/20 | added inline paste button to paste the copied content in chat textfield | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `3b401a791` | #2065 | 39/39 | Recover observed Bonsai chart argument drift | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `40dfc5687` | #1237 | 124/132 | added no timeout option for remote providers | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `46c074861` | #2150 | 6/11 | fix streaming error on deepseek and other openai compatible providers | Intel's `CloudChatEngine` already skips unparseable SSE frames ("Skipped unparseable SSE frame"). |
| In | `4b57749cd` | #1277 | 151/152 | [codex] Preview XLSX workbooks through file_read | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `55d361ff9` | #2375 | 1/1 | open schema ahead chat history databases instead of refusing them | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `564186a80` | #1234 | 3/3 | fixed HF import not surfacing models in the models page | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `5dbc8c6c6` | #1509 | 12/12 | fixed app hangs | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `5e8d8c080` | #1306 | 105/105 | Bound raw file_read previews | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `5f068b471` | #1287 | 9/9 | set imported theme as current theme | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `60c949d46` | #1470 | 17/18 | updated chinese translations | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `62b989f9a` | #1498 | 5/5 | fixed hang main thread hangs | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `69b1c266a` | #1907 | 13/13 | qwen3.5 agent-loop nudge + JANGTQ_K unblock + ZAYA tool-arg parser repin | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `69c12c096` | #2334 | 14/14 | AppleScript subagent: tell the caller the repair that actually works | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `7d7c85162` | #1334 | 84/87 | added guards to prevent sentry from flagging false hangings | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `81a7fd696` | #1278 | 1/1 | [codex] Harden generated XLSX cell output | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `845f95ae9` | #1326 | 224/225 | voice transcription improvements | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `8891f49c8` | #1302 | 108/108 | [codex] Validate relay public URL before showing connected | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `8934ef2ba` | #2352 | 15/15 | Route a lone mac_query string to `question` when that field is absent | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `8ce02ccc6` | #1286 | 3/3 | [codex] Restore Swift format gate | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `90fa5b6a0` | #1369 | 516/516 | Add CSV table workflow previews and export | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `950005976` | #1474 | 241/245 | Add storage location standards audit | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `9a6b47886` | #1294 | 96/104 | [codex] Add ChatGPT auth diagnostics | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `aaf758091` | #1473 | 28/28 | fixed app hangs | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `acba41ab3` | #1510 | superseded | fixed main thread hang from non-converging layout loop in management window | Later replaced upstream by `AppKitOwnedWindowHostingController`, which Intel has. |
| In | `af3d41e25` | #1243 | 3/3 | fix: preserve exposeToNetwork setting across launches | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `b7948ab75` | #1557 | 665/665 | Add Business Document Studio service | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `cf321e94a` | #1273 | 29/29 | [codex] Bound document parser adapter bridge | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `d3c873e7c` | #1332 | 10/10 | [codex] Reject workbook targets in file_write | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `d5b0f313d` |  | 13/13 | Agent loop: bound the truncated-read continuation steer (2 per file), keep the partial-rea | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `dba9236cd` | #1956 | 50/51 | added get_current_time built-in tool | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `dcdaad11d` | #2370 | 21/21 | Give host-folder artifact sharing the basename fallback it documents | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `dd1425f58` | #1389 | 324/333 | updated remote provider cards for improved UX | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `e98a1ffcd` | #1947 | 49/49 | Update Simplified Chinese and Traditional Chinese translations | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `e9e105d02` | #1832 | 26/26 | fixed subagent feed hang | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `f0725e244` | #1368 | 414/414 | Add workbook workflow validation and export service | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `f0e5cc314` | #1321 | 0/12 | fixed skill renaming | Intel's `SkillStore` keeps the original folder name (`directoryName`) on rename, so a rename never orphans the folder. |
| In | `f385681f8` | #1246 | 65/67 | allow custom base URL for built in remote providers | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `f44fe022b` | #1267 | 15/15 | Fix zero free space on external model volumes | Most of its surviving code is in Intel (presence ≥ 90%). |
| In | `fb5359427` | #2406 | 3/3 | added close button to router account sheet | Most of its surviving code is in Intel (presence ≥ 90%). |
| Done (3c-1) | `1877babba` | #1507 | 15/41 | Fix test-core CI failure by skipping TCC status probes under tests | Re-checked 2026-11-08: not only CI — it brought the empty-turn recovery (`emptyTurnNotice`, `emptyTurnFallback`), now in Intel's engine. |
| N | `3d47a9d74` | #1500 | 4/6 | Restore Swift-format parity on current main | swift-format parity. |
| N | `858eb6c2a` | #1464 | 182/256 | added frontier evals and improved harness stability | Frontier evals. |
| N | `c12a01bb2` | #1438 | 422/772 | harness hardening with tools and evals | Eval harness hardening. |
| N | `c13d363a1` | #1851 | superseded | Persist user turns before chat streaming | Comment and tests only. |
| N | `cc232be83` | #1289 | superseded | removed unused configurations | Removes unused configuration; nothing to port. |
| N | `e6f3d3ba5` | #1527 | 5/105 | Add system prompt injection proof trace | System-prompt injection proof trace for the MLX runtime harness. |
| N | `f4bb1c2cd` | #1339 | 0/1 | remove old migrations and deprecated code | Removes old migrations. |
| N | `fefd7a5bc` | #1433 | 547/1207 | harness improvements | Eval harness. |
| NA | `3d212f797` | #1749 | 4/26 | fix continuing and exporting conversations after the encryption update | Upstream's encrypted SQLite chat store recovery. |
| NA | `6fb655d81` | #1742 | 4/34 | Recover chat continuation from transcript fallback | Transcript recovery for upstream's encrypted SQLite chat store; Intel stores chats as JSON. |
| NA | `a041e512e` | #1755 | 8/26 | Fix chat history loss from non-idempotent schema migrations | Upstream's SQLite chat history migrations; Intel stores chats as JSON. |
| NA | `df3a1023d` | #2565 | 0/1 | Restore type tags on Responses Lite namespace tools | Responses Lite namespace tools; Intel's Responses path has no namespace tools. |
| W-channels | `50bf441ee` | #1650 | superseded | disable broken tools | Discord tool registration switched off. |
| W-channels | `d6216d23b` | #2208 | 15/117 | fix app freeze when saving channel tokens in   keychain | Discord token save off the main thread. |
| W-computer-use | `0a9df67c8` | #2316 | 2/19 | route skylight input through SLEventPostToPSN on macOS 26.4+ to prevent crashes | Belongs to that backlog item. |
| W-computer-use | `405ab5aeb` | #1627 | 141/330 | Harden Computer Use privacy, autonomy gate, and consent UX | Computer Use privacy, autonomy gate, consent. |
| W-computer-use | `69726a371` |  | 0/1 | Computer Use: open apps foreground so the window is visible and the model doesn't misrepor | Belongs to that backlog item. |
| W-computer-use | `71c63d0f4` |  | 0/1 | Computer Use AX bounding + AccessibilityBoundedElement test fix + vmlx repin (SpecDec tail | Computer Use AX bounding (plus an MLX pin). |
| W-computer-use | `890b7eaef` | #1618 | 1/44 | improved screen context distiller | Belongs to that backlog item. |
| W-computer-use | `c5b84db75` | #1634 | 9/60 | Fix Computer Use main-thread hangs | Belongs to that backlog item. |
| W-computer-use | `c8abb1eec` | #1602 | 1/41 | fixed crash with computer use | Belongs to that backlog item. |
| W-computer-use | `c9bc8d06a` | #1643 | 195/837 | Add Computer Use diagnostics | Belongs to that backlog item. |
| W-declarative-config | `18c75a287` | #1290 | 43/139 | harden default agent configuration, added mcp | Default agent configuration hardening. |
| W-declarative-config | `7aa6a9334` | #2372 | 4/9 | Stop agent plugin reads from depending on the Plugins UI being opened | Agent plugin reads independent of the Plugins UI. |
| W-declarative-config | `f2da317ed` | #1271 | 1007/1535 | Default Agent is now Onboarding Agent | Default agent becomes the onboarding agent. |
| W-diagnostics-telemetry | `073378037` | #1320 | 83/230 | opt in telemetry | Opt-in telemetry. |
| W-diagnostics-telemetry | `52dce0a7b` | #1445 | 1/22 | add first time chat shown and used telemetry events | First-chat telemetry events. |
| W-diagnostics-telemetry | `661c76169` | #1829 | 74/338 | Add support diagnostics bundle scaffold | Belongs to that backlog item. |
| W-diagnostics-telemetry | `f54d9c7f4` | #1360 | 33/118 | expanded telemetry scope and added telemetry doc | Feature telemetry events. |
| W-privacy-filter | `0f25e6cc4` | #1252 | 18/46 | added whats new privacy filter | What's New for the privacy filter. |
| W-privacy-filter | `1f1ba003a` |  | 1/12 | Fix sweep: MiniMax-M2.7 JANGTQ crash + Mistral chat + hunyuan_v1_dense + Rampart PII (repi | Rampart PII part; the rest is MLX model fixes. |
| W-privacy-filter | `40c21f121` | #1244 | 1142/4119 | added privacy filter | The privacy filter itself. |
| W-privacy-filter | `59baf8b11` | #1764 | 69/275 | added Rampart as a lightweight on-device PII detection model | Rampart on-device PII model. |
| W-privacy-filter | `602304107` | #1946 | 6/25 | Fix Privacy Filter false "URLs were not scrubbed" send block | Belongs to that backlog item. |
| W-privacy-filter | `e503384fa` | #1641 | 209/623 | Privacy filter: opt-in on-device model, no-regex rule builder, settings polish | Belongs to that backlog item. |
| W-skills-plugins-import | `0ed6a6a2f` | #1327 | 413/802 | added claude plugins catalog | Claude plugins catalog. |
| W-skills-plugins-import | `14be4e831` | #1744 | superseded | Add skill policy diagnostics | Skill policy diagnostics; files later removed upstream. |
| W-skills-plugins-import | `5e3e4aba9` | #1439 | 23/35 | import third party skills | Third-party skill import. |
| W-skills-plugins-import | `bdd3f9b7b` | #1245 | 35/90 | improved skills page in settings | Skills page in Settings. |
| W-skills-plugins-import | `c06428046` | #1477 | 40/316 | Harden skill archive imports | Skill .zip import (`SkillImportPolicy`); Intel's zip import throws "unavailable". |
| W-skills-plugins-import | `c11747a30` | #1250 | 2798/3262 | moved claude plugins to plugins section | Claude plugins moved to the Plugins section. |
| W-skills-plugins-import | `d05d028b1` | #1647 | 94/356 | Add plugin marketplace trust preview | Belongs to that backlog item. |
| W-skills-plugins-import | `e16fad2f3` | #1840 | 94/431 | Bound skill archive subprocesses | Bounded skill archive subprocesses. |
| W-subagents | `f25d89acb` | #2062 | 0/3 | Fix spawned agent tool execution scope | Belongs to that backlog item. |
| W-ui-misc | `0764a7a72` | #1291 | superseded | fixed remote providers failing to authenticate after keychain migration | Keychain migration (`KeychainDataProtection`), classified with `W-ui-misc`. |
| W-ui-misc | `269b8ebf8` | #1288 | 28/78 | migrate legacy keychain to data protection keychain | Legacy keychain to data-protection keychain migration. |
| W-ui-misc | `d9c1dfbc5` | #1296 | 58/76 | crash fix: reverted breaking change, added failsafe check | Crash fix with failsafe check. |
