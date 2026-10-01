# Insights activity log on Intel (`W-insights-sync`)

Upstream rebuilt Insights into a persisted, tamper-evident activity log in
#2964 (`3176b8b5a`, merged 2026-10-01, after the
[2026-10-01 audit](UPSTREAM_AUDIT_2026-10-01.md) range). It absorbs #2926
(snapshots off the main queue), #1595 (`logs` not `@Published`) and #1350
(Inspect response focuses its own log). Renée chose this item first on
2026-10-01; per [follow upstream by default](UPSTREAM_SYNC.md), Intel ports
the current upstream design rather than the older staged plan. Upstream's
reviewer specification (`docs/ACTIVITY_LOG.md` on upstream, not copied) is the
reference for the chain, export and verification formats; Intel doesn't
change them.

Work is in stages:

| Stage | Commit | What |
|---|---|---|
| A | `4ffa176fb` | Redactor hardening (upstream's table verbatim). |
| B | `d7272257f` | Store, service, Insights UI, settings, chat-engine attribution, Inspect response, Credits links. |
| C | this change | Per-feature emitters (below). |

## What the user gets (stage B)

- **Insights keeps its history.** Rows survive relaunch, in an encrypted
  database at `~/.osaurus/activity/activity.sqlite`.
  An `activity.head` sidecar records the last `seq:hash`.
- **Tamper-evident chain.** Each row hashes the previous one. "…" ›
  **Verify Integrity** walks the chain and reports gaps, edits or a truncated
  tail. Clear, prune, verify, export and settings changes are themselves
  `system` rows.
- **Export** (header button): JSONL with chain fields, CSV, or a Markdown
  report. Choose the current filter or everything, with or without message
  content. Each export comes with a manifest.
- **New layout (upstream's IA):**
  - Glance strip: Events, Left this Mac, Failed, Privacy-filtered. The last
    three are one-tap filters.
  - A local/cloud bar and a destinations disclosure.
  - Search, time range and a Filter popover, with removable filter tokens.
  - Scope tabs: All, Models, Web, Tools, Channels, API, Audio & Media,
    System.
  - Day-grouped rows. At 1040 pt or wider, a row opens in a side inspector;
    narrower, it opens as a page. Up, down and Escape navigate.
- **Detail pane:**
  - Overview: a facts grid, a one-sentence summary, and collapsible "Where it
    went", "Who drove this", "Generation settings" and "Integrity" groups.
  - Prompt: the parsed messages and tools.
  - Raw: the request and response, with a sub-toggle between Server (wire
    bytes) and Local.
- **Settings › General › Advanced › Data & Storage › Activity Log:**
  - Keep Activity History: 7, 30 (default), 90 or 365 days, or forever.
  - Store Prompts and Responses: off keeps metadata only for new rows.
  - Review Activity in Insights.
- **Chat rows** now carry the assistant turn, agent, chat, provider endpoint
  (`direct` / `remoteInference`), destination label and host, data classes,
  and the **wire bytes** (exact request body sent, raw response stream,
  1 MiB cap each).
  - A provider **HTTP error** is now logged; before, it returned without a
    row.
  - Inline base64 images are replaced by `[redacted N-char image]` in the
    logged request (upstream `redactInlineImagePayloads`).
- **Inspect response › Open request and response log** opens that reply's
  own row (`focus(turnId:)`). A reply older than retention, or from before
  this change, gets upstream's "Insights Unavailable" alert.
- **Credits › Activity** rows link to their Insights row when one exists,
  matched by request id or turn (upstream `openInsightsReference`).

## Intel differences (keep on re-sync)

| Upstream | Intel | Why |
|---|---|---|
| `ActivityLogStore.open` via `OsaurusStorageOpener` + `StorageMutationGate`, `PersistenceHealth` / `StorageRecoveryService` on failure | Storage key + `EncryptedSQLiteOpener` (FileHistoryDatabase pattern) after `StorageMigrationCoordinator.blockingAwaitReady()`; no recovery-service hooks | Intel's storage stack; always encrypted |
| `StorageDatabaseCatalog` "activity log" | `StorageMigrator.databaseTargets` "activity log" | Intel's rekey / export list |
| Privacy › Activity Log section in `PrivacyOverviewTab` | `Views/Settings/ActivityLogSettingsSection.swift` (body verbatim) on Data & Storage; search entries keep upstream ids (`privacy.activityLog.*`) in tab `.settings`, section Advanced | Intel has no Privacy tab |
| Detail-pane text "Privacy › Activity Log › Store Prompts and Responses…" | "Data & Storage › Activity Log › …" (two strings) | Same |
| `ChatEngine` + `RemoteProviderService` feed `WireTransportProbe` through the task-local | `CloudChatEngine` owns a probe per stream: first-round `httpBody`, then every SSE line / Codex byte chunk / error body | Intel builds its own requests; `RemoteProviderService` isn't compiled |
| `request.turnId ?? currentAssistantTurnId` | `currentAssistantTurnId` (ChatView binds it around `streamChat`); agent and chat from the task-locals, captured before the stream task | Intel's request type has no `turnId` |
| `onKeyPress` / `focusEffectDisabled` list navigation | `InsightsKeyMonitor` (window-scoped local key monitor, ignored while a text field edits) | macOS 14 APIs |
| Two-value `onChange` (3) | Single-value | macOS 13 |
| `.toggleStyle(.checkbox)`, `.borderedProminent` in the export sheet | `ThemedCheckboxToggleStyle`, `ThemedBorderedButtonStyle`; the sheet also gets `.intelControlRendering` | Ventura control sweep (UPSTREAM_SYNC) |
| `MCPActivityLogger` scrubs `sandbox_secret_set` via `SecretArgumentScrubber` | Arguments pass through unchanged (still `redactCredentials`) | No sandbox secrets on Intel |
| `SearchActivityLogger` records `structuredFormat` | Line dropped | Intel's `SearchReadability` predates #2656 |
| `ChannelActivityLogger` | Excluded in `Package.swift` | Lands with `W-channels` |
| `ToolRegistry.agentChannelToolNames` | Same set in Intel's `ToolRegistry` (`IntelStubConformers.swift`) | `ToolCallLog` redaction keys off it |
| Guide `guide-insights.md` and cross-links | Not shipped | Intel ships only the Knowledge guide; lands with the Help menu item |

`AgentManager.agentDisplayName(for:)` and
`RemoteProviderManager.providerDisplayName(for:)` (lock-protected name
caches, upstream verbatim) live on Intel's managers in
`IntelManagerConformers.swift` / `IntelStubConformers.swift`.

## Stage C: what each source logs (shipped 2026-10-01)

| Source | Row | Intel call site |
|---|---|---|
| Web search (tools, Try it, provider test) | `web_search`, one per operation: query, providers tried, hits, destination host | `SearchProviderManager.runSearch` / `runHostedFirstSearch` / `testProvider` (upstream wrapping, `runCascade` split) |
| Page fetch | `url_extract`, destination = the page's host | `SearchReadability.extract` → `fetchAndExtract` (Intel keeps its older fetch body) |
| Hosted contents (Osaurus Router) | `url_extract` via the Router | `SearchProviderManager.hostedExtract` |
| MCP tool call | `mcp_tool_call`, remote host or local stdio | `MCPProviderManager.executeTool` (+ `reconnectAndRetry` split, upstream) |
| Router control plane (credits, account, workspaces…) | `router_control`, plain-language purpose; hosted search/contents excluded | `OsaurusRouterAPIClient.perform` |
| Cloud TTS | `speech_synthesis`, remote, text + voice + audio seconds | `TTSService.startRemotePlayback` (upstream) |
| macOS system voice | `speech_synthesis`, local, `AVSpeechSynthesizer` | `TTSService.startSystemPlayback` / `systemUtteranceEnded` / `stop` (Intel's stand-in for upstream's PocketTTS row) |
| Dictation / file transcription | `audio_transcription`, live or file | `SpeechService` (Apple Speech) |
| Titles, memory distillation, compaction, transcript cleanup, agent descriptions | `/internal/<purpose>` inference rows (compaction → `compaction` category, source Chat UI); others source System, **no turn** | `ChatEngine.completeChat` now logs every call; callers bind `ChatEngine.$activityPurpose` |
| Delegated helper steps | source Agent, the dispatching turn | `IntelOrchestratorDelegationRuntime`, `IntelDelegationProbe` bind `ChatEngine.$activitySource` |
| Local API `/chat/completions` (DeepSeek proxy) | inference row, **remote** to `api.deepseek.com`, streamed and non-streamed | `HTTPHandler.logProxiedChat` (SSE responses log when the stream ends) |

Intel-specific decisions:

- **Apple Speech can leave the Mac.** Without an on-device model for the
  language, `SFSpeechRecognizer` sends audio to Apple. Those rows are
  `remote` with destination "Apple Speech" (`TranscriptionJob.remoteLabel`,
  an Intel addition to `MediaActivityLogger`). Upstream's local-model rows
  are always `local`.
- **One-shots carry no turn id.** This matches upstream's `CoreModelService`
  (source System). A title request made during a reply would otherwise be
  the newest row for that turn, and Inspect response would open it instead
  of the reply.
- `completeChat` via Codex goes through `streamChat`, which uses the same
  purpose / source rules.
- `HTTPHandler.handlerWritesOwnActivityRow` / `embeddingActivityDetails`
  are ported for parity. Intel serves no media or embedding endpoints, so
  nothing binds the double-write guard. `mediaActivityDetails` is not ported
  (no `MediaGenerationBackend`).

Not applicable on Intel: channel deliveries (`W-channels`), local
embeddings (`MetalSafeEmbedder` excluded), local image generation, P2P
inbound and plugin host rows (`PluginHostAPI` excluded). Intel's own plugin
inference (`IntelPluginExecution`) logs as an ordinary
`/chat/completions` row through `completeChat`.

## Tests

- Upstream, verbatim:
  - `Tests/Insights/ActivityExportTests.swift`
  - `ActivityLogSettingsTests.swift`
  - `ActivityLogStoreTests.swift`
  - `InsightsAddressAbbreviationTests.swift`
  - `InsightsConnectionActivityTests.swift`
  - `InsightsP2PSourceTests.swift`
  - `InsightsScopeTests.swift`
  - `InsightsWireBodyRoundTripTests.swift`
  - `Tests/Chat/InsightsImageRedactionTests.swift` (Intel's engine is also
    named `ChatEngine`)
- Upstream `Tests/Insights/ActivityEmitterTests.swift`, adapted: no channel
  cases, and only the embedding half of the HTTP media-details check. Intel's
  `SearchReadability.Extraction` has no structured-page fields.
- Intel, `Tests/Insights/IntelInsightsTests.swift`, with the engine run
  against an in-process fixture:
  - The row's turn, agent, chat, connection, host, path and wire bytes.
  - The HTTP error row.
  - Image redaction in the logged body.
  - Storage enrollment and paths.
  - Name caches.
  - Settings search ids.
  - Stage C: the title one-shot (System, no turn, tokens, wire bytes), the
    compaction category, a delegated Agent row, a failed one-shot, the
    DeepSeek proxy row, and Apple Speech remote vs on-device rows.
- Updated:
  - `StorageMigratorTargetFilterTests`: "activity log".
  - `SettingsSearchIndexTests`: the new section's source.
  - `ConfigurationView.advancedAnchorIds`: the three ids.
- The shared store opens under `OsaurusPaths.root()`, so the test gate's
  `OSAURUS_TEST_ROOT` keeps it off the live data directory.
- Rendering was checked offscreen in light and dark (2026-10-01). The list,
  glance strip, destinations bar, scope tabs, day groups, failure dot and
  detail pane all draw.
  - The offscreen pass can't show AppKit `Menu` labels (the header "…").
    That is the `Menu` pattern Rosy already accepted.
  - The render harness must wait with `Task.sleep`, not
    `RunLoop.main.run`. Blocking the main actor stops the service's
    detached reload from delivering rows, and the list renders empty.

## i18n

- 179 keys were merged from upstream's catalog. Upstream shipped them
  without German or Chinese, so Intel filled both: German with informal
  "du", Chinese with 聊天, 智能体 and 你. "Insights" is 「Einblicke」 / 「洞察」,
  as elsewhere in the catalog.
- Stage C added 7 strings: Router purposes and "OpenAI-compatible TTS".
  "Account" and "Workspaces" come from upstream's catalog; the rest Intel
  translated.
- The missing-key count rises from 126 to **149**: upstream's 26 sentences
  built with interpolation inside `L("…\(x)…")`, which no catalog entry can
  match (the same gap exists upstream), minus 3 keys now covered.

## Upstream audit `fec69aa53..4064a6fde`

| Commit | Verdict |
|---|---|
| `2f953db29` #2969 | **Incompatible** (MLX runtime pin) |
| `3176b8b5a` #2964 | **Port**: stages B and C shipped |
| `4064a6fde` #2971 | **Incompatible** (MLX runtime pin) |

The next audit starts after `4064a6fde`.

Manual QA:
[`ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`](ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md#insights-activity-log-w-insights-sync).
