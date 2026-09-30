# Upstream audit and port — 2026-09-30

**Range:** `3dad2dad4..b023f2c1e` on `osaurus-ai/osaurus/main`, fetched
2026-09-30. **13 commits (no merges), 13 classified below.** Verdicts follow
the rule in [`UPSTREAM_AUDIT_2026-09-29.md`](UPSTREAM_AUDIT_2026-09-29.md#classification)
(Incompatible / Omit (not a feature) / Needs work / Needs work + decision,
plus Port / Covered / Split / Stage). The small Port slices ship in the same
change (tests in `Tests/Chat/IntelUpstreamBatch0930Tests.swift`); #2950 is a
staged port of its own. The next review begins at `b023f2c1e` (exclusive).

## Shipped on Intel (awaiting Rosy)

| Upstream | What Intel got |
|---|---|
| #2937 `d1d65ec32` | Claude Code subprocess pipes are drained after the in-flight chunk is delivered, so the last output of a run is no longer lost when the process exits mid-delivery. Upstream patch applied unchanged (Intel's runner only differs in `ClaudeCodeConfiguration.subprocessEnvironment()`); upstream `ClaudeCodePipePumpTests` added. |
| #2939 `b8bd4a406` | `OptionalDoubleField` buffers decimal input until Return, focus loss or Save, and restores the bound value on invalid input. **Latent on Intel:** the only decimal fields live in the local-inference Server sections Intel hides (like the #2893 integer slice). Ported so future decimal fields behave; the Save/Reset committer is included but no Intel form needs it yet. |
| #2936 `5e79d3304` (slices) | Four slices mapped onto Intel's own Orchestrator (see the split below): **relaxed setting search** — `find_setting` retries without intent words ("turn off memory" finds Enable Memory) and reports `relaxed_query`; **empty delegation list** — Settings → Orchestrator offers **Add all agents** when no custom agent is allowed yet, `orchestrator_targets` says the list is empty and how to fix it, and settings search finds it; **plans that empty the list** are flagged as high-risk on the review sheet; **new chats open on the Orchestrator** unless `new_chat_agent` is set (browsing a custom agent's chat no longer re-targets the next new window). |

## Classification

| # | Commit | Verdict | Intel note |
|---:|---|---|---|
| 1 | `a99f7360b` #2932 | **Incompatible** | MLX runtime pin (GLM / JANGH local models, Apple Silicon only). |
| 2 | `e8eb360da` #2933 | **Incompatible** | Diagnostics for symlinked local MLX bundles. `ExternalModelLocator` compiles on Intel but nothing shows it (`ExternalModelsSettingsView` is never instantiated); Intel has no local runtime to run what it finds. |
| 3 | `33d827545` #2934 | **Incompatible** | MLX runtime pin. |
| 4 | `cc7c47145` #2935 | **Needs work** | Phone runs survive a dropped connection and can be rejoined or stopped by run id (`DetachedPhoneRuns`, HTTP routes). Prerequisite: the mobile relay (B1, `W-workspaces-identity-mobile`). |
| 5 | `d1d65ec32` #2937 | **Port** | Shipped. |
| 6 | `5e79d3304` #2936 | **Split** | See below. |
| 7 | `b8bd4a406` #2939 | **Port** (latent) | Shipped. |
| 8 | `1d5c4c7a7` #2940 | **Incompatible** | Stops the MLX model detail page forcing a manifest refresh on `.localModelsChanged`. Intel's model detail has no manifest polling. |
| 9 | `220e8ef5a` | **Incompatible** | Upstream's own appcast (0.25.15). |
| 10 | `61127dc20` #2938 | **Incompatible** | MLX preparation errors (`GenerationEventMapper`, excluded) and runtime pin. |
| 11 | `47fcad49f` #2949 | **Incompatible** | `ChunkedFileDownloader` lane invalidation; used only by `ModelDownloadService` (MLX downloads). |
| 12 | `64b0d6a4b` #2950 | **Stage** (`W-settings-ux-2950`) | Settings redesign; plan below. |
| 13 | `b023f2c1e` #2952 | **Covered** | Limits the model-switch advisory to leaving a local MLX model. Intel never had the advisory (`ModelSwitchContinuityWarning` is not in the Intel tree), and with only remote models the fixed version would never show. |

### #2936 split

| Slice | Verdict | Intel note |
|---|---|---|
| Relaxed `osaurus_help find` fallback | **Port** | Shipped in Intel's `orchestrator_config` `find_setting`. |
| Empty spawn pool in status + Settings "Add all agents" + search entry | **Port** | Shipped against Intel's delegation allowlist (`orchestrator_targets`, Orchestrator settings). |
| Pool-emptying applies flagged HIGH RISK | **Port** | Shipped on Intel's configuration review sheet. |
| New chats open on the Orchestrator (`new_chat_agent`) | **Port** | Shipped as `DefaultAgentConfiguration.newChatAgentId` (reviewed through `orchestrator_config`, like every other Orchestrator setting). |
| Truthful addendum (no `spawn_agent` / `file_read` named when absent) | **Covered** | Intel's Orchestrator prompt is already rendered from the admitted roster, always offers `orchestrator_delegate`, and names folder tools only when a folder is mounted and tools are on. |
| Orchestrator folder surface narrowed to `file_read` / `file_search` (no `file_copy`, `file_undo`, `redact_file` …) | **Needs work** | Upstream's Orchestrator hands folder work to workers. Intel's delegates are tool-free, so Intel's Orchestrator does the folder work itself; narrowing it now would remove working features. Lands with `W-subagents`. |
| Spawn result compaction, background-spawn Stop, `continue` as `invalid_args`, same-turn spawn staging for every bound session | **Needs work** | Native subagents (`W-subagents`). |
| "Configured same-model local ceiling" refresh | **Incompatible** | Local-model concurrency. |
| Evals, `HARNESS_COMPATIBILITY.md`, eval JSON cases | **Incompatible** | Upstream-only artifacts (eval harness not compiled on Intel). |

## #2950 — Settings redesign (staged port, `W-settings-ux-2950`)

Intel's Settings are an older layout: General (`ConfigurationView`) still
holds Chat, Work, Voice (Advanced), Notifications and the command-line tool
on one page, and the Intel groups differ from upstream's (Intel has no
Conversation, Images, Mobile, Privacy, Workspaces or Channels tabs). Every
touched Intel file diverges heavily (ConfigurationView ~2k lines,
ProvidersView ~1.5k, ToolsManagerView ~1.6k, ThemesView ~1.6k), so this is a
hand-port, not a copy. Nothing in it needs Apple Silicon.

| Piece | Verdict | Intel note |
|---|---|---|
| `SettingsKit` grouped-form kit (`SettingsGroup`, `SettingsRow`, `SettingsPickerRow`, `SettingsLinkRow`, `SettingsAdvancedDisclosure`, `SettingsDestructiveZone`, `SettingsPage`) + `SettingsPrimitives`/`ManagerHeader` restyle | **Port** | Ventura: replace the two two-value `onChange` calls and the `.pickerStyle(.segmented)` (banned by `IntelVenturaControlGuardTests`) with `ThemedSegmentedPicker`. |
| General split: General / **Conversation** (upstream `ChatSettingsView`) / Advanced → Data & Storage; `storage` deep link → General | **Port** | Intel's Chat, Work and Notifications sections move to their upstream homes; Intel's Storage tab content folds into Advanced → Data & Storage. Settings search anchors must follow (`SettingsSearchIndex`, 379 lines changed upstream). |
| Command-line tool card → Developer Tools → Server → Overview | **Port** | Intel already has the card on General. |
| Tab renames: Tools → **Tools & MCP**, sub-tabs Services / All Tools / Plugins (old deep links kept) | **Port** | Intel's tab titles change with it. Chat → Conversation arrives with the split. Osaurus Connect → Mobile and Media → Images: **Needs work** (Intel has neither tab; B1, `W-media-generation`). |
| Tools & MCP → Services: configured MCP services + browsable **MCP directory** (`MCPProviderDirectoryView`) | **Port** | Intel has `MCPProviderTemplate`. |
| "Auto-Allow All Tool Calls" master switch (`ToolAutoAllowToggle`, upstream #2241) | **Needs work + decision** | Intel never had it: a blanket auto-approval of every tool call conflicts with Intel's per-call approval (for example `delete_knowledge`, `db_execute`). Renée decides whether Intel gets it and whether per-call tools stay exempt. |
| Slash command editor sheet (moved from the settings section) | **Port** | Intel's Commands tab still uses the inline section. |
| Voice: separate **Chat Voice** tab, `TranscriptionSettingsTab` (renamed + regrouped), `VoiceSharedComponents`, restyled TTS/VAD tabs | **Port** | Re-apply on top of the Intel Voice port (Apple Speech, system voices, Recognition tab instead of Models) — see [`VOICE_INTEL.md`](VOICE_INTEL.md). |
| Providers and remote provider sheet restyle | **Port** | With the kit. |
| Themes restyle | **Port** | With the kit; keep Intel's Ventura theme fixes. |
| Privacy Filter view, Image Generation view, Agent Channels views, Osaurus Connect / iMessage views | **Needs work** | Intel lacks the features (`W-privacy-filter`, `W-media-generation`, `W-channels`, B1). |
| Guide markdown, docs, translations | **Port** | Only for the pieces Intel ships. |

**Suggested order:** (1) kit + header restyle; (2) General/Conversation split
and search anchors; (3) Tools & MCP rename, Services and MCP directory;
(4) Voice tabs; (5) Providers, Themes, Commands sheet, CLI card move.
Each step gets its own Rosy checklist section (Ventura rendering first).

## Needs-work backlog from this batch

| Prerequisite | Unblocks |
|---|---|
| Mobile relay (B1) | #2935; #2950's Mobile tab rename |
| Native subagents (`W-subagents`) | #2936 spawn slices and the narrowed Orchestrator folder surface |
| Decision on "Auto-Allow All Tool Calls" | #2950's `ToolAutoAllowToggle` |
