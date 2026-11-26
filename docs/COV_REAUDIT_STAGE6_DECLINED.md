# Stage 6: declined verdicts re-read (2026-11-26)

Read-only audit by a Sonnet subagent. **Caveat:** about 130 Covered verdicts rest on symbol presence and the W-item docs, not a per-commit code check; treat them as likely, not proven. Port and Needs-work rows were checked against Intel code.

# W-cov-reaudit stage 6: the declined verdicts re-read (2026-11-26)

Read-only audit at `bce907045` (upstream) against Intel `intel-fork` HEAD `8e850997a`. Scope: the 456 commits that `scripts/upstream/cov_reaudit.py --mentioned` still counts as declined (242 of them have their verdict in `UPSTREAM_TRIAGE_0.24.3.md` / `0.24.7.md`, 214 in later audit docs; the declined filter matches any doc, not only the two ledgers). Commits that already have a row in `COV_REAUDIT.md` were excluded by the tool. Method: per-commit symbol and line presence on Intel (`cov_reaudit.py` presence plus a defined-symbol check against all Intel sources), then `git grep` on Intel, `Package.swift` excludes, the W-item docs, and the Intel-own conformers (`Models/Chat/IntelConformers/*`) for every non-runtime code commit.

## Summary

| Verdict | Count |
|---|---|
| Covered | 133 |
| Port | 12 |
| Needs work (named W-item) | 13 |
| Still declined | 298 |
| Total | 456 |

The stale reasons were mostly "Agent / Skills / Plugin / Sandbox / Voice / Computer Use amputated". Most of those subsystems are now on Intel and the commits were reached by later W-items without their hash being recorded (a `Covered` row below cites where). Genuine gaps are few and small: 12 Port rows (one M, the rest S) and 3 larger W-items that remain open.

## Commits whose verdict changed

Ordered by user impact: Port, then Needs work, then Covered.

| sha | PR | title | new verdict | Intel note (file:line, size) |
|---|---|---|---|---|
| `85d531362` | #2355 | added a delete all data option to agent settings | Port | M. Intel `AgentManager.delete(id:)` (Models/Chat/IntelConformers/IntelManagerConformers.swift:628-680) leaves the agent's chat sessions, pinned facts, episodes and vector index on disk; upstream wipes them and adds the Delete all data card (Views/Agent/AgentsView.swift general tab). Privacy and disk-leak fix. |
| `605f862a3` | #2647 | Tool flow: no replay of transient knowledge replies, paging signals survive compression, manual | Port | S. Intel `AgentsView.duplicateAgent` (Views/Agent/AgentsView.swift:417) drops toolSelectionMode, manualToolNames, toolsEnabled, memoryEnabled, plugin instructions: a duplicated manual agent runs Auto with every tool. Items 1,2,7,8 of the commit are already in (KnowledgeTools.swift:196, WebSearchTools.swift:553). |
| `9d7d0712d` | #2625 | Web pipeline: retrieval rides with discovery; hallucinated fetch calls get steered | Port | S. No steering for fetch names imported from other harnesses (`web_fetch`, `fetch_url`, `read_webpage`: grep finds none), and Intel's Research skill text (Models/Agent/Skill.swift:133) still tells the model to `capabilities_load` `search_and_extract`. Add the retryable envelope in the tool boundary (Tools/IntelToolRegistryBoundary.swift / IntelToolScopeGate) and expose `search_and_extract` with `web_search`. |
| `1b8ae239d` | #2632 | Agent loop: knowledge-tool dedupe, dynamic same-name run advisory, repeat visibility | Port | S. `AgentTaskState.dynamicToolClassifier` (Services/Chat/AgentTaskState.swift:396) is never set on Intel, so the 4-call same-name advisory for MCP/plugin tools is dormant. Wire a registry snapshot in CloudChatEngine, IntelHTTPAgentRun, IntelPluginInference and the subagent runner. The "x N" export marker is in (ChatSessionExporter.swift:99). |
| `64f54a670` | #2505 | Delete the persisted global Disable Tools switch; tool availability is agent-scoped | Port | S. Persisted global `ChatConfiguration.disableTools` (Models/Chat/ChatConfiguration.swift:93) still decoded and read by Intel `effectiveToolsDisabled` (IntelManagerConformers.swift:1002); a stale chat.json bit strips tools from every surface with no UI to explain it. Delete it as upstream did. |
| `661eaeaca` | #1676 | Surface host-side remote-agent (p2p) activity | Port | S. Host notification when a peer/phone calls an agent (`PeerCallNotifier`, Managers/PeerCallNotifier.swift upstream, absent on Intel). The `.p2p` Insights source is already in (Managers/InsightsService.swift:1003). Hook `/agents/{id}/run` for Secure Channel callers (W-identity-mobile). |
| `389a816e0` | #1880 | fixed plugin search matching unrelated plugins | Port | S. Plugin search fuzzy-matches descriptions (Views/Plugin/PluginsView.swift:610-615), so unrelated plugins match; upstream restricts to id/name/keywords and derives chip counts from matches. |
| `063ac5fd6` | #1949 | added an option to update all plugins in one go instead of individual update | Port | S. No "Update all" for outdated plugins (Views/Plugin/PluginsView.swift has no batch update; upstream adds `updateAllPlugins` and a banner). |
| `dc6a9013c` | #2837 | fix model picker hover and favorite heart on bottom rows | Port | S. Intel's picker table (Views/Model/ModelPickerTableRepresentable.swift:119, `HoverTrackingTableView`) has no mouse-moved monitor, so rows below the first list extent do not hover or show the favourite heart when the popover grows; plus heart alignment. |
| `7ff316c3f` | #3212 | Report cached prompt tokens in the streamed chat usage chunk | Port | S. Streaming usage chunk drops cached_tokens: writeUsageChunk (Networking/IntelHTTPInference.swift:413) has no cached-token parameter although IntelOpenAIWire.swift:63 (cachedPromptTokens) exists; callers HTTPHandler.swift:1915 and IntelHTTPAgentRun.swift:671. Remote provider cache hits never reach streaming API clients. |
| `d5aea7fdf` | #1838 | Decouple startup completion from plugin loading | Port | S. Plugins load before the server binds (AppDelegate.swift:363 `loadAll()` at launch); upstream defers `loadAll` and repository refresh to the first successful server start so a crashing plugin cannot delay `/health`. |
| `94921b451` | #1775 | minor UI tweaks | Port | S (cosmetic). Create-agent sheet and provider chips wrap labels (Views/Agent/AgentsView.swift:6910 sheet width, Views/Settings/ProvidersView.swift chip grid). |
| `36e31641a` | #1763 | Make screen context a per-agent Computer Use option | Needs work | W-computer-use (screen, accessibility, input; `ComputerUse/Feed` and `Loop` exist for the AppleScript gate but no `computer_use` kind or screen context). Largest remaining declined feature. |
| `f5e2ff97f` | #1610 | Add opt-in frozen screen context for chat (Computer Use) | Needs work | W-computer-use (screen, accessibility, input; `ComputerUse/Feed` and `Loop` exist for the AppleScript gate but no `computer_use` kind or screen context). Largest remaining declined feature. |
| `ccbd92526` | #1578 | New Feature: Computer Use Subagent | Needs work | W-computer-use (screen, accessibility, input; `ComputerUse/Feed` and `Loop` exist for the AppleScript gate but no `computer_use` kind or screen context). Largest remaining declined feature. |
| `0daa73033` | #2529 | Enable sandboxing by default with hardened runtime | Needs work | W-seatbelt-sandbox stages 3-5 (tools, per-agent AutonomousExecConfig, plugins/background processes, UI/config; docs/W_SEATBELT_SANDBOX_PLAN.md). The Seatbelt executor and host SandboxManager are in (Services/Sandbox/Seatbelt/SeatbeltExecutor.swift, IntelSandboxManager.swift); the sandbox tools are not wired yet. VM-only parts (apk installs, CoW rootfs) stay Incompatible. |
| `f43406050` | #2313 | Fix remaining sandbox reachability gaps | Needs work | W-seatbelt-sandbox stages 3-5 (tools, per-agent AutonomousExecConfig, plugins/background processes, UI/config; docs/W_SEATBELT_SANDBOX_PLAN.md). The Seatbelt executor and host SandboxManager are in (Services/Sandbox/Seatbelt/SeatbeltExecutor.swift, IntelSandboxManager.swift); the sandbox tools are not wired yet. VM-only parts (apk installs, CoW rootfs) stay Incompatible. |
| `ee2fcecc8` | #2311 | Fix sandbox plugin activation and dependency installs | Needs work | W-seatbelt-sandbox stages 3-5 (tools, per-agent AutonomousExecConfig, plugins/background processes, UI/config; docs/W_SEATBELT_SANDBOX_PLAN.md). The Seatbelt executor and host SandboxManager are in (Services/Sandbox/Seatbelt/SeatbeltExecutor.swift, IntelSandboxManager.swift); the sandbox tools are not wired yet. VM-only parts (apk installs, CoW rootfs) stay Incompatible. |
| `2a280aaad` | #2080 | Add combined-mode file_copy bridge for binary files between workspace and sandbox | Needs work | W-seatbelt-sandbox stages 3-5 (tools, per-agent AutonomousExecConfig, plugins/background processes, UI/config; docs/W_SEATBELT_SANDBOX_PLAN.md). The Seatbelt executor and host SandboxManager are in (Services/Sandbox/Seatbelt/SeatbeltExecutor.swift, IntelSandboxManager.swift); the sandbox tools are not wired yet. VM-only parts (apk installs, CoW rootfs) stay Incompatible. |
| `907b19d7e` | #1839 | Cap sandbox plugin tool expansion | Needs work | W-seatbelt-sandbox stages 3-5 (tools, per-agent AutonomousExecConfig, plugins/background processes, UI/config; docs/W_SEATBELT_SANDBOX_PLAN.md). The Seatbelt executor and host SandboxManager are in (Services/Sandbox/Seatbelt/SeatbeltExecutor.swift, IntelSandboxManager.swift); the sandbox tools are not wired yet. VM-only parts (apk installs, CoW rootfs) stay Incompatible. |
| `8a145f36c` | #1597 | decouple sandbox tools from the agent Tools toggle and compact sandbox prompt sections | Needs work | W-seatbelt-sandbox stages 3-5 (tools, per-agent AutonomousExecConfig, plugins/background processes, UI/config; docs/W_SEATBELT_SANDBOX_PLAN.md). The Seatbelt executor and host SandboxManager are in (Services/Sandbox/Seatbelt/SeatbeltExecutor.swift, IntelSandboxManager.swift); the sandbox tools are not wired yet. VM-only parts (apk installs, CoW rootfs) stay Incompatible. |
| `fa47416a8` | #2979 | International privacy filter presets with region picker | Needs work | W-privacy-filter (regex presets, region picker, PII extraction flow); deferred item, Rampart/regex half is portable. |
| `437ca4257` | #2793 | improved PII extraction flow | Needs work | W-privacy-filter (regex presets, region picker, PII extraction flow); deferred item, Rampart/regex half is portable. |
| `8f80b11bd` | #1753 | Coalesce subagent image progress in place; show step/ETA + elapsed | Needs work | W-media-generation remainder: image / video subagent kinds not started (docs/W_SUBAGENTS_PLAN.md, Stage 6 outcome). |
| `a29fe877e` | #1682 | Native image generation/editing + agent delegation (spawn / local_delegate) | Needs work | W-media-generation remainder: image / video subagent kinds not started (docs/W_SUBAGENTS_PLAN.md, Stage 6 outcome). |
| `bce907045` | #3216 | DeepSeek-V4.1 alignment: dSpark solo lease, full effort ladder, model_type detection, cached-to | Covered | UPSTREAM_AUDIT_2026-10-27 (11 commits; DeepSeek-V4.1 local parts Incompatible, router/memory parts ported) |
| `20887a4aa` | #3217 | Unify installed model inventory and correct capacity estimates | Covered | UPSTREAM_AUDIT_2026-10-27 #9: VolumeAvailableCapacityCache + volumeFreeBytes ported (SystemMonitorService); inventory/capacity parts are MLX |
| `80cf45032` | #3210 | Fix memory recall and delayed tool output | Covered | UPSTREAM_AUDIT_2026-10-27 #2: MemoryDistillateScreen, FTS function-word drop, delegated_conversations ported |
| `fc75a1e06` | #3203 | Use typed Responses and isolate helper reports from user memory | Covered | UPSTREAM_AUDIT_2026-10-26 (102 commits audited: typed Responses and helper-report isolation split into Port/Incompatible rows there) |
| `2f2e1158b` | #3185 | Keep chat pickers attached and consume nonfatal runtime diagnostics | Covered | UPSTREAM_AUDIT_2026-10-26 (#3173, #3185 picker attach shipped) |
| `bc08a546e` | #3178 | Add opt-in local access key for sensitive routes, settable by bundle import | Covered | W-server-api complete 2026-11-02 (SERVER_API_INTEL.md) |
| `a69fe812a` | #3171 | Fix stale agent paths, Browser Use title, dark tab pill and provider glyph | Covered | W-ui-misc closed 2026-10-27 |
| `658cb49e1` | #3135 | make phone runs own their mac chat, catch spoken pii and let a phone call set the privacy filte | Covered | UPSTREAM_AUDIT_2026-10-26 #40: phone-owned chat ported (stage 3b); spoken-number PII waits for W-privacy-filter |
| `f4a877ff8` | #3104 | Integrate native workflow media controls, video and memory admission | Covered | W-media-generation closed 2026-10-28 (Tools/VideoTool.swift, Tools/IntelImageTool.swift, MEDIA_GENERATION_INTEL.md) |
| `077c17a06` | #3083 | Rank pinned memory text matches by relevance before salience | Covered | W-memory-db-sync done 2026-10-27; storage merge marker (COV 2026-11-02) |
| `bd5b5b1a5` | #3080 | Chat table: coalesce per-child height notes and stop grapheme-walking block equality | Covered | App-hang ports (LCached, AvatarExistenceCache Agent.swift:1053, theme fingerprint off main) per UPSTREAM_AUDIT_2026-10-26 / UPSTREAM_SYNC |
| `826427670` | #3073 | Workbooks: keep formatting and formulas through model edits | Covered | FEATURE_PARITY / UPSTREAM_AUDIT_2026-10-26: PDF reading, file_write cap, workbooks, shell PATH, pasted-image reason shipped |
| `e5b42c836` | #3066 | file_write: remove the 30,000-character content cap and the 64 KiB streamed tool-call abort | Covered | FEATURE_PARITY / UPSTREAM_AUDIT_2026-10-26: PDF reading, file_write cap, workbooks, shell PATH, pasted-image reason shipped |
| `b56d9892d` | #3060 | fix themes tab hang by moving duplicate fingerprinting off main thread | Covered | App-hang ports (LCached, AvatarExistenceCache Agent.swift:1053, theme fingerprint off main) per UPSTREAM_AUDIT_2026-10-26 / UPSTREAM_SYNC |
| `24f4c416a` | #3056 | give shell_run the login shell PATH so version-manager toolchains resolve | Covered | FEATURE_PARITY / UPSTREAM_AUDIT_2026-10-26: PDF reading, file_write cap, workbooks, shell PATH, pasted-image reason shipped |
| `ec654e8c5` | #3057 | fixed plugins tab freezing on scroll | Covered | App-hang ports (LCached, AvatarExistenceCache Agent.swift:1053, theme fingerprint off main) per UPSTREAM_AUDIT_2026-10-26 / UPSTREAM_SYNC |
| `19271bb14` | #3040 | Say why images are unavailable instead of dropping a pasted image (#3021) | Covered | FEATURE_PARITY / UPSTREAM_AUDIT_2026-10-26: PDF reading, file_write cap, workbooks, shell PATH, pasted-image reason shipped |
| `5ecc914f2` | #3010 | steer channel messages into the running turn instead of waiting for the next one | Covered | W-background-runs-sync stages 1-3 (BackgroundTaskManager fresh chat per run, eviction); channel-only parts stay deferred |
| `1cc8d44dc` | #3007 | start a fresh chat for every scheduled run | Covered | W-background-runs-sync stages 1-3 (BackgroundTaskManager fresh chat per run, eviction); channel-only parts stay deferred |
| `fcb332320` | #2990 | MCP robustness, elicitation, and regulated-industry connectors | Covered | W-server-api complete 2026-11-02 (SERVER_API_INTEL.md) |
| `83b9166e3` | #2983 | PDF reading-order extraction for flattened forms (file_read pages, page markers) | Covered | FEATURE_PARITY / UPSTREAM_AUDIT_2026-10-26: PDF reading, file_write cap, workbooks, shell PATH, pasted-image reason shipped |
| `dae94983e` | #2978 | Preserve requested repeated text without an automatic retry | Covered | W-agent-loop-tools complete 2026-10-10 (AgentTaskState wired) |
| `4b69a9c1c` | #2976 | Preserve native PDF glyph and table cell identity | Covered | FEATURE_PARITY / UPSTREAM_AUDIT_2026-10-26: PDF reading, file_write cap, workbooks, shell PATH, pasted-image reason shipped |
| `106580a0d` | #2921 | Refresh tool grants between turns and recheck dispatch authorization | Covered | UPSTREAM_AUDIT_2026-10-01 #10 (tool list composed on every send) |
| `e1ff79b51` | #2913 | align model updates and osaurus connect cards with the settings card style | Covered | Views/Settings/OsaurusConnectView.swift (45/52 lines); local-update card is MLX |
| `09844d5d6` | #2867 | Require agent descriptions and guide legacy agents through repair | Covered | UPSTREAM_AUDIT_2026-09-25 #157 (descriptions, roster, repair notice in Intel shape) |
| `93513e8d6` | #2861 | Fall back from an unavailable or hung Foundation core model | Covered | UPSTREAM_AUDIT_2026-09-25 #150 (a303bc3f7 Core Model deadline and breaker) |
| `a2dd43d30` | #2838 | Keep channel chat tab live across follow-ups; add Focus Chat on Incoming Messages setting | Covered | W-background-runs-sync stages 1-3 (BackgroundTaskManager fresh chat per run, eviction); channel-only parts stay deferred |
| `4a329449b` | #2802 | fixed tab strip jumping and overlapping the sidebar on window resize | Covered | UPSTREAM_AUDIT_2026-09-25 (chat tabs, history filters, stuck chip, provider polish); 90%+ lines present |
| `1bbc984f9` | #2799 | fix history dialog stacking when the toolbar button is tapped repeatedly | Covered | Intel history is a pane (Views/Chat/ChatHistoryPane.swift), no dialog to stack |
| `a188a57e4` | #2795 | Show composer stuck chip only when a run is actually silent | Covered | UPSTREAM_AUDIT_2026-09-25 (chat tabs, history filters, stuck chip, provider polish); 90%+ lines present |
| `e20ffcfb0` | #2787 | Orchestrator polish and simplification | Covered | W-subagents stages 3-6 (SpawnAgentTool, waves) + ORCHESTRATOR_INTEL_PLAN.md; the 2026-09-29 N/A reason no longer holds |
| `6e67eec21` | #2768 | Reject unsupported embedding model requests instead of substituting Potion | Covered | W-server-api complete 2026-11-02 (SERVER_API_INTEL.md) |
| `83eac58f0` | #2757 | reduce main thread work behind app hang | Covered | App-hang ports (LCached, AvatarExistenceCache Agent.swift:1053, theme fingerprint off main) per UPSTREAM_AUDIT_2026-10-26 / UPSTREAM_SYNC |
| `7842b4713` | #2755 | qol improvements for providers and the chat sidebar | Covered | UPSTREAM_AUDIT_2026-09-25 (chat tabs, history filters, stuck chip, provider polish); 90%+ lines present |
| `f158416e2` | #2721 | added right click context menu to chat tabs | Covered | UPSTREAM_AUDIT_2026-09-25 (chat tabs, history filters, stuck chip, provider polish); 90%+ lines present |
| `b2bffc63b` | #2734 | Show execution surface (sandbox VM vs native Mac) on tool approval cards | Covered | Execution-surface chip on approval cards (120/138 lines present) |
| `e4734a216` | #2720 | Queue tool permission prompts and run sibling spawn calls as one wave | Covered | Subagent/SpawnWaveGate.swift + Services/Chat/IntelParallelToolBatch.swift (488/538 lines) |
| `7e90a7269` | #2711 | added filters in chat history modal | Covered | UPSTREAM_AUDIT_2026-09-25 (chat tabs, history filters, stuck chip, provider polish); 90%+ lines present |
| `d2510a087` | #2665 | fix update_skill never reaching slash invoked skills | Covered | Tools/SkillUpdateTool.swift:23; Managers/SkillManager+Import.swift:575-650 (slash-skill preload, `update_skill` on demand) |
| `835ee1fec` | #2666 | added x-opencode-session affinity header for opencode hosts | Covered | Services/Chat/CloudChatEngine.swift `isOpenCodeHost` (x-opencode-session header) |
| `4c9bbdd3f` | #2657 | Bounded incomplete-work finalization: exhausted announcements and repeated retrieval failures e | Covered | CloudChatEngine / IntelAgentLoopTerminal.swift `wrapsUpIncompleteWork`, `repeatedRetrievalWrapUp` (stage 5c rows 7-8, cca77a0a8) |
| `7b6d05cbb` | #2648 | added update_skill tool so agents can edit user skills on request | Covered | Tools/SkillUpdateTool.swift:23; Managers/SkillManager+Import.swift:575-650 (slash-skill preload, `update_skill` on demand) |
| `75c206997` | #2645 | Session tool scope follows the agent chip; advisory after repeated tool_not_found; canonicalise | Covered | Stage 5c row 20: `resolvedOfferedToolName` + IntelToolScopeGate; tool_not_found counter AgentTaskState.swift:291 |
| `69e19e069` | #2643 | Watcher: run against the chosen folder, not the agent sandbox workspace | Covered | WatcherManager.swift:607 passes the resolved path; Folder/ChatFolderState.swift:93 restores path-only; no VM bridge to guard |
| `7cd8c0ae3` | #2640 | Agent loop: log when the invalid-args notice is staged | Covered | AgentTaskState.swift (log line present) |
| `c6737abd5` | #2638 | Capability grounding follow-ups: honest enum errors, Host Files scope copy, ungrounded file-sid | Covered | AgentTaskState/AgentToolLoop symbols 51/54; stage 5c rows 22-23 grounded-claim guards |
| `0520691a9` | #2626 | Capability grounding: folder-mode agents get their manifest back; gateway honors its own contra | Covered | COV 3c-3 (5d16b603f, #2309): group-id call rescue in IntelToolScopeGate |
| `ecd027a90` | #2575 | fix unreadable approval content in tool approval modal | Covered | Views/Plugin/ToolPermissionView.swift (24/24 changed lines present) |
| `1517ceac6` | #2555 | Give loaded skills a directory anchor for bundled resources | Covered | Models/Chat/IntelConformers/IntelDataConformers.swift:1503 `Skill directory:` anchor |
| `78fccf9c1` | #2539 | Make denied chat tool outcomes visible and bounded | Covered | Stage 5c row 9 (denied or rejected call ends the chat run, cca77a0a8) |
| `bd5cc8d8d` | #2541 | Remove the hidden Orchestrator tool kill switch | Covered | Intel never had `toolsDisabledForTesting` (grep: none); no hidden kill switch |
| `dd9de43f8` | #2534 | simplify tools and plugins in settings | Covered | W-tools-tab-sync complete 2026-11-12 (0dbdf399f); PluginsView/ToolsManagerView 78/82 symbols |
| `bebc6f3fd` | #2522 | fix settings crash on macos 15 when opening tabs with header sub tabs | Covered | HeaderTabsRow is a plain HStack (Views/Management/ManagerHeader.swift:429); it never had the ViewThatFits that crashes on macOS 15 |
| `affef475d` | #2411 | fix custom agents failing to spawn subagents by name | Covered | W-subagents (SubagentCapabilityRegistry); 42/45 lines present |
| `b9b8b7fc8` | #2392 | Persist the cancelled marker when Stop beats the first delta | Covered | COV stage 2 (c02c007cd): `ChatTurn.terminalStopReason`, `stop(preservesCancelledMarker:)` |
| `ccd310ed0` | #2388 | Record a user Stop as `cancelled`, not as a natural `stop` | Covered | COV stage 2 (c02c007cd): `ChatTurn.terminalStopReason`, `stop(preservesCancelledMarker:)` |
| `24bf2af2a` | #2380 | fix skill editor sheet clipping on small screens | Covered | Views/Skill/SkillEditorSheet.swift (12/12 lines) |
| `4e2bcb03a` | #2378 | Give a quarantined plugin one retry after it or the app is upgraded | Covered | Managers/Plugin/PluginManager.swift quarantine stamp (18/19 symbols) |
| `180c4f3a4` | #2306 | Improve agent abilities context guidance | Covered | Views/Agent/AgentAbilityContextPreviewBar.swift + Services/Chat/AgentAbilityContextPreview.swift (stage 5b row 43) |
| `42e64580a` | #2300 | Fix custom agent capability dispatch | Covered | CapabilityTools per-iteration schemas + KnowledgeTools prefixed paths (symbols 20/35 and 10/11; rest is channel or execution-mode fingerprint) |
| `84bdc5c81` | #2287 | fix agent recovery for deferred tools and knowledge reads | Covered | CapabilityTools per-iteration schemas + KnowledgeTools prefixed paths (symbols 20/35 and 10/11; rest is channel or execution-mode fingerprint) |
| `69519a140` | #2281 | Add cloud image and video generation | Covered | W-media-generation closed 2026-10-28 (Tools/VideoTool.swift, Tools/IntelImageTool.swift, MEDIA_GENERATION_INTEL.md) |
| `eee9c5cfc` | #2268 | Revamp the default Osaurus agent: bundled guide, settings/watcher tools, expanded read scopes | Covered | W-declarative-config stages 1-5 (Configuration/Declarative, `osaurus_config`, DefaultAgentSystemPromptBuilder) |
| `13ab0a188` | #2255 | Harden AgentDB imports and saved views | Covered | Agent DB tools and saved views (64/65 and 11/12 lines present) |
| `00a237738` | #2243 | i18n: split the "Server" key, which three unrelated UI elements share | Covered | W-voice shipped 2026-09-29 (VOICE_INTEL.md); Views/Voice/TranscriptionSettingsTab.swift:305-315, `voice.tts.remote.title` present |
| `f33c9eca1` | #2234 | Unify subagent and server batching concurrency | Covered | Models/AgentDelegation/SpawnBatchConcurrencyContract.swift:14 |
| `7f39220f6` | #2232 | Make headless dispatches follow the agent's current default model | Covered | COV 2026-11-06 headless default model (BackgroundTaskManager) |
| `bfa62f655` | #2221 | Add safe heterogeneous subagent batching and delegation controls | Covered | W-subagents stages 3-6 (Subagent/SubagentBatchAdmissionPlanner.swift, SpawnWaveGate.swift); local residency parts stay MLX |
| `92353afea` | #2199 | fix(i18n): two render sites that bypass localization | Covered | W-voice shipped 2026-09-29 (VOICE_INTEL.md); Views/Voice/TranscriptionSettingsTab.swift:305-315, `voice.tts.remote.title` present |
| `6dc2f190d` | #2149 | fix mcp tool calls failing after invoking a skill via slash command | Covered | COV 3c-3 ported (request may only execute the tools it exposed) |
| `01de80e63` | #2131 | Fix Computer Use and AppleScript completion regressions | Covered | W-applescript-agent closed 2026-10-28 (AppleScript/Tool/AppleScriptTool.swift); #2071's terminal-failure rule is stage 5c row 30 (7e8b2772d) |
| `40aa9fa2c` | #2126 | seatbelt sandbox fallback for macos 15 and earlier | Covered | Intel Seatbelt executor/profile (Services/Sandbox/Seatbelt/SeatbeltExecutor.swift, SeatbeltSandbox.swift; W-seatbelt-sandbox stages 1-2) |
| `1844ed294` | #2123 | Native Browser Use: replace the osaurus.browser plugin with a built-in browser feature | Covered | W-browser-use closed 2026-10-28 (Browser/Tool/BrowserUseTool.swift) |
| `cee858bc8` | #2118 | Fix AppleScript completion and persistent SSD warmups | Covered | W-applescript-agent closed 2026-10-28 (AppleScript/Tool/AppleScriptTool.swift); #2071's terminal-failure rule is stage 5c row 30 (7e8b2772d) |
| `402060bce` | #2115 | Adopt native macOS theme defaults with system accent following | Covered | W-ui-misc closed 2026-10-27 (system accent, release UX) |
| `ac3a04172` | #2112 | Continue cap-truncated file_read to the end of the file | Covered | Folder/ChatFolderState.swift:93 per-session folder; file_read continue present (26/26) |
| `9b5decf83` | #2099 | add openai compatible tts server support | Covered | W-voice shipped 2026-09-29 (VOICE_INTEL.md); Views/Voice/TranscriptionSettingsTab.swift:305-315, `voice.tts.remote.title` present |
| `26fde677e` | #2092 | Isolate working-folder context per chat session | Covered | Folder/ChatFolderState.swift:93 per-session folder; file_read continue present (26/26) |
| `6b1e91f96` | #2083 | Harden Agent DB tool contracts for import modes and saved views | Covered | Agent DB tools and saved views (64/65 and 11/12 lines present) |
| `8fd75506e` | #2078 | Track chat file changes with undo, and add writable combined mode | Covered | W-file-history (FILE_HISTORY_INTEL.md, FileChangeJournal; upstream #2907 supersedes #2078) |
| `c64b7499d` | #2075 | Fix JANG AppleScript success finalization | Covered | W-applescript-agent closed 2026-10-28 (AppleScript/Tool/AppleScriptTool.swift); #2071's terminal-failure rule is stage 5c row 30 (7e8b2772d) |
| `d7be82407` | #2073 | Overhaul Tools management UX around an everyday-user catalog | Covered | W-agent-detail-redesign closed 2026-10-28 (AgentDetailChrome.swift); Tools UX 756/769 lines present |
| `c8afeca2d` | #2072 | Redesign agent detail navigation and restyle the Tools tab | Covered | W-agent-detail-redesign closed 2026-10-28 (AgentDetailChrome.swift); Tools UX 756/769 lines present |
| `345100606` | #2071 | Fix AppleScript Computer Use finalization and failure containment | Covered | W-applescript-agent closed 2026-10-28 (AppleScript/Tool/AppleScriptTool.swift); #2071's terminal-failure rule is stage 5c row 30 (7e8b2772d) |
| `05a129631` | #1794 | Stabilize Watchers pane layout | Covered | Views/Watcher/WatchersView.swift:37 (empty state and content layout present); old reason (local inference) was wrong |
| `29ebe5c16` | #2061 | Reliability audit: install integrity, loader/ABI validation, route timeouts, lifecycle ordering | Covered | W-plugin-reliability (ExternalPlugin.swift:696 shutdown latch, GitHub token, load checks) |
| `96dfa9db3` | #1815 | knowledge collections | Covered | W-web-search-sync shipped 2026-10-10 / knowledge tools (KnowledgeTools.swift, WebSearchTools.swift; 454/560, 485/505 symbols) |
| `d16b06763` | #2055 | Premium web search through the Osaurus router with search credits | Covered | W-web-search-sync shipped 2026-10-10 / knowledge tools (KnowledgeTools.swift, WebSearchTools.swift; 454/560, 485/505 symbols) |
| `f81405970` | #2053 | Redesign agent feature flags into an Abilities overview with live context estimate | Covered | Views/Agent/AgentAbilityContextPreviewBar.swift + Services/Chat/AgentAbilityContextPreview.swift (stage 5b row 43) |
| `5c8257b9b` | #2052 | Redesign agent Database workspace and settings navigation UX | Covered | W-agent-detail-redesign closed 2026-10-28 (AgentDetailChrome.swift); Tools UX 756/769 lines present |
| `5aafd7392` | #1852 | Handle empty voice transcriptions | Covered | W-voice shipped 2026-09-29 (VOICE_INTEL.md); Views/Voice/TranscriptionSettingsTab.swift:305-315, `voice.tts.remote.title` present |
| `37bd1f034` | #2050 | Universal skills library and tools-only agent UX | Covered | W-tools-tab-sync complete 2026-11-12 (universal skills library) |
| `eaba91d05` | #2041 | Fix Bonsai structured charts and hybrid memory safety | Covered | W-web-search-sync shipped 2026-10-10 / knowledge tools (KnowledgeTools.swift, WebSearchTools.swift; 454/560, 485/505 symbols) |
| `ecb0b1073` | #2031 | fix scheduled runs never completing by evicting finished headless tasks | Covered | W-background-runs-sync stages 1-3 (BackgroundTaskManager fresh chat per run, eviction); channel-only parts stay deferred |
| `087b5ba99` | #2023 | Agent request lifecycles independent of the chat window | Covered | Managers/BackgroundTaskManager.swift:49 six-state lifecycle incl. waitingForInput |
| `b73015a22` | #2018 | A request may only execute the tools it exposed | Covered | COV 3c-3 ported (request may only execute the tools it exposed) |
| `237050653` | #1955 | added in-app github token to fix plugin update rate limit errors | Covered | W-plugin-reliability (ExternalPlugin.swift:696 shutdown latch, GitHub token, load checks) |
| `57900df56` | #1845 | Harden plugin repository refresh diagnostics | Covered | W-plugin-reliability (ExternalPlugin.swift:696 shutdown latch, GitHub token, load checks) |
| `70346b6f4` | #1938 | Native web search: pluggable providers + Search settings tab | Covered | W-web-search-sync shipped 2026-10-10 / knowledge tools (KnowledgeTools.swift, WebSearchTools.swift; 454/560, 485/505 symbols) |
| `1915feae5` | #1931 | Polish release UX details | Covered | W-ui-misc closed 2026-10-27 (system accent, release UX) |
| `55c67634d` | #1869 | Agent DB: sandbox file paths, db_export, and token-efficiency fixes | Covered | Agent DB (AGENT_DATABASE_INTEL_PLAN.md; 138/143 and 222/225 symbols); channel tools stay deferred |
| `27c6bf4c3` | #1862 | Fix ExternalPlugin shutdown teardown race and recurring app-side hangs | Covered | W-plugin-reliability (ExternalPlugin.swift:696 shutdown latch, GitHub token, load checks) |
| `df969d9b5` | #1855 | Fix self-scheduled runs not auto-starting; fresh chat per wake | Covered | W-background-runs-sync stages 1-3 (BackgroundTaskManager fresh chat per run, eviction); channel-only parts stay deferred |
| `0e5203220` | #1831 | Handle empty voice transcriptions | Covered | W-voice shipped 2026-09-29 (VOICE_INTEL.md); Views/Voice/TranscriptionSettingsTab.swift:305-315, `voice.tts.remote.title` present |
| `2904fbe74` | #1816 | added transcription cleanup toggle and redesign the dictation overlay | Covered | W-voice shipped 2026-09-29 (VOICE_INTEL.md); Views/Voice/TranscriptionSettingsTab.swift:305-315, `voice.tts.remote.title` present |
| `938cf5b8c` | #1812 | AppleScript subagent upgrade: capability reach, latency, consent UX, reliability | Covered | W-applescript-agent closed 2026-10-28 (AppleScript/Tool/AppleScriptTool.swift); #2071's terminal-failure rule is stage 5c row 30 (7e8b2772d) |
| `c7c3f92ce` | #1797 | Subagent harness hardening: admission gate, mid-run interrupt, tool-capable workers, RAM coexis | Covered | W-subagents stages 3-6 (Subagent/SubagentBatchAdmissionPlanner.swift, SpawnWaveGate.swift); local residency parts stay MLX |
| `6d9e0029d` | #1771 | Add AppleScript Computer Use subagent with safe on-device execution | Covered | W-applescript-agent closed 2026-10-28 (AppleScript/Tool/AppleScriptTool.swift); #2071's terminal-failure rule is stage 5c row 30 (7e8b2772d) |
| `dfd412f63` | #1776 | fixed app hang sentry issues | Covered | App-hang ports (LCached, AvatarExistenceCache Agent.swift:1053, theme fingerprint off main) per UPSTREAM_AUDIT_2026-10-26 / UPSTREAM_SYNC |
| `630ea9bec` | #1767 | cap tool rows in remote and plugin cards to prevent layout hang | Covered | W-plugin-reliability (ExternalPlugin.swift:696 shutdown latch, GitHub token, load checks) |
| `895b05fe2` | #1656 | unify local and remote agent detail views | Covered | W-agent-detail-redesign closed 2026-10-28 (AgentDetailChrome.swift); Tools UX 756/769 lines present |
| `285d6b629` | #1640 | agent db upgrade | Covered | Agent DB (AGENT_DATABASE_INTEL_PLAN.md; 138/143 and 222/225 symbols); channel tools stay deferred |
| `fd6b4947d` | #1635 | fix /memory/ingest distillation and harden launch crashes (#1632) | Covered | W-memory-db-sync done 2026-10-27; storage merge marker (COV 2026-11-02) |
| `9c41d3a83` | #1590 | disable settings save buttons until there are unsaved changes | Covered | Settings save-disable on unchanged (31/34 symbols; Views/Skill/SkillEditorSheet.swift etc.) |
| `9124d6964` | #1561 | fixed issue with share artifact tool | Covered | Tools/ShareArtifactTool.swift:65 (no root anyOf; #1560) |
| `395fe51e4` | #1552 | Allow manual provider models during connection tests | Covered | Provider parity (stage 5d) / UPSTREAM_SYNC window 24924e6f..7901ec42; lines 100% present |
| `07ba93e14` | #1536 | Route MCP OAuth through global proxy | Covered | Provider parity (stage 5d) / UPSTREAM_SYNC window 24924e6f..7901ec42; lines 100% present |
| `7901ec42e` | #1556 | fixed main thread blocking processes | Covered | App-hang ports (LCached, AvatarExistenceCache Agent.swift:1053, theme fingerprint off main) per UPSTREAM_AUDIT_2026-10-26 / UPSTREAM_SYNC |
| `b768bbcbc` | #1540 | fixed anthropic api failing on remote providers | Covered | Services/Chat/CloudChatEngine.swift:556 `appendingTransientNotices` folds notices into the trailing tool result, so no duplicate tool_result ids reach Anthropic |
| `5b3c2fa68` | #1528 | Fix pasted provider model-list URLs | Covered | Provider parity (stage 5d) / UPSTREAM_SYNC window 24924e6f..7901ec42; lines 100% present |
| `dee498b84` | #1526 | Add tool exposure search diagnostics | Covered | Tool exposure search diagnostics (51/57 symbols) |
| `ae34ca6ac` | #1522 | Add legacy storage merge marker | Covered | W-memory-db-sync done 2026-10-27; storage merge marker (COV 2026-11-02) |
| `24924e6f7` | #1523 | fixed app hangs | Covered | App-hang ports (LCached, AvatarExistenceCache Agent.swift:1053, theme fingerprint off main) per UPSTREAM_AUDIT_2026-10-26 / UPSTREAM_SYNC |
| `58aab452f` | #1512 | added hosted inference | Covered | Hosted inference = Osaurus Router (W-router-billing, W-credits-router); 647/810 symbols |
| `2c2b60d54` | #1452 | fixed v5 memory migration aborting on a foreign key constraint | Covered | W-memory-db-sync done 2026-10-27; storage merge marker (COV 2026-11-02) |
| `82d88b774` | #1444 | fixed memory repair that silently kept failing on affected installs | Covered | W-memory-db-sync done 2026-10-27; storage merge marker (COV 2026-11-02) |
| `95ad4ef3e` | #1396 | updated onboarding screens | Covered | W-ui-misc onboarding design system done 2026-10-27 (ONBOARDING_INTEL.md) |
| `4fc801570` | #1390 | improved onboarding create agent view | Covered | W-ui-misc onboarding design system done 2026-10-27 (ONBOARDING_INTEL.md) |
| `5a9207c17` | #1384 | auto split full urls pasted into provider host fields | Covered | Views/Settings/RemoteProviderEditSheet.swift `parsePastedEndpoint` present (18/18 symbols) |
| `4de8be1ec` | #1323 | launch stability improvements | Covered | W-memory-db-sync + launch hardening ported (608/1220 lines; MLX remainder I) |
| `d9fd0db15` | #1316 | added MiniMax provider | Covered | Provider parity (stage 5d) / UPSTREAM_SYNC window 24924e6f..7901ec42; lines 100% present |
| `a0ebae226` | #1304 | [codex] Add AtlasCloud provider preset | Covered | Provider parity (stage 5d) / UPSTREAM_SYNC window 24924e6f..7901ec42; lines 100% present |

## Still declined (reasons that still hold, no per-row table)

- **232** Local MLX runtime, vMLX pins, local-model UI (Incompatible: Metal, Apple Silicon): vmlx-swift pins, MTP/DFlash/SSD-cache/KV/prefill, model-specific runtimes (Bonsai, Gemma, Qwen, GLM, DeepSeek-V4.1 local, K2, Liquid, MiMo, Flint, Allosaurus), local image models (FLUX, Qwen-Image, SeedVR2), local model catalog/download/update/residency/RAM banners, local-only /api/show. MLX needs Metal on Apple Silicon: hard x86_64 / macOS 13 limit.
- **28** Upstream release/marketing content, telemetry and translation-only commits (Omit): What's New copy, Product Hunt dialogs, retention telemetry (telemetry = Omit), Chinese/Korean translation batches (handled by the Localizable.xcstrings merge rule in UPSTREAM_SYNC.md), docs-only commits.
- **16** Eval harness, proof gates and dev telemetry (Omit): OsaurusEvals catalog, proof lanes, loop-exit diagnostics, context-optimisation harness: dev tooling, not shipped.
- **15** Agent Channels (W-channels, deferred by owner until someone asks): Slack, Telegram, Discord, WhatsApp, iMessage channel commits. Owner policy (2026-10-11): deferred until someone asks (INTEL_MISSING_FEATURES_BACKLOG.md).
- **2** Sandbox VM runtime (Virtualization.framework, Incompatible): CoW rootfs, resumable VM delivery, vmnet egress: no VM on macOS 13 / x86_64 (Seatbelt replaces it; see Needs work rows).
- **2** Local-model optimisation loops for MLX (Incompatible): Gemma/E4B harness fixes for local MLX loops.
- **2** Remote agent / Mac-to-Mac (W-workspaces-sharing, deferred by owner): Remote-agent connect UX (Bonjour, relay between Macs); deferred with W-workspaces-sharing.
- **1** Superseded upstream (notch UI deleted in #2683): #2036 notch task navigation: upstream deleted the notch UI in #2683 (`940d86a31`); the keep-awake half already shipped as `AgentRunPowerManager`.

A few rows in the MLX group were checked individually because they looked portable and are not: `ac169df39` (#2815, `ChatToolChoicePolicy` has no production caller upstream either), `138d7d174` and `96da338ac` (`/api/show` serves local `ModelInfo` only, always 404 on Intel), `cb0dac4eb` (#2848, the "Finishing up" tail is the local cache-store wait).

## Recommended port batches

1. **Batch A, agent data (M):** `85d531362` (#2355): wipe an agent's chats, pinned facts, episodes and vector index on delete, plus the Delete all data card. Needs Rosy (data deletion).
2. **Batch B, agent and tool correctness (S x4):** `605f862a3` (#2647 duplicate-agent capability copy), `9d7d0712d` (#2625 fetch-name steering and `search_and_extract` exposure, fix Skill.swift text), `1b8ae239d` (#2632 wire `dynamicToolClassifier` on four surfaces), `64f54a670` (#2505 delete persisted `disableTools`).
3. **Batch C, plugins and peers (S x4):** `063ac5fd6` (#1949 update all), `389a816e0` (#1880 search), `d5aea7fdf` (#1838 plugin load after server bind), `661eaeaca` (#1676 PeerCallNotifier).
**Batches A and B merged 2026-11-26:** #2355 (Delete all data card in the agent's General tab; deleting an agent also removes its chats, pinned facts, episodes and transcripts, as upstream's `AgentManager.delete`, scoped to that agent id, and the confirmation says so), #2647 item 4 only (duplicate copies tool mode, manual tools, capability settings; items 3, 5, 6 still open), #2625 (fetch-name steering, Research skill text; `search_and_extract` exposure was Covered), #2632 (same-name advisory wired once in `CloudChatEngine`), #2505 (global Disable Tools switch removed; a stale `disableTools` in `chat.json` is ignored and dropped on next save). **Batches C and D merged 2026-11-26:** #3212 (cached tokens through Intel's usage hint to streamed and non-streamed chat and the Anthropic response), #2837 (picker hover and re-measure; Intel's picker has no heart), #1775 (`AgentsView` sizes), #1949 (Update all banner through the signed installer, one click by the user), #1676 (`PeerCallNotifier`, local toast only); #1880 and #1838 Covered (substring-only plugin search; plugins already load after `server.start`).

4. **Batch D, small UI and API (S x3):** `dc6a9013c` (#2837 picker hover), `7ff316c3f` (#3212 streaming `cached_tokens`), `94921b451` (#1775 cosmetic).

Open W-items these rows feed, none new: `W-seatbelt-sandbox` stages 3-5 (6 commits), `W-computer-use` (3), `W-media-generation` image/video subagent kinds (2), `W-privacy-filter` (2).

## Notes for the manuals

- COV_REAUDIT.md Stage 6 should record: declined reasons "Skills / Agent / Plugin / Sandbox / Voice / Browser / AppleScript / Subagents amputated" are stale; the cov tool's DECLINED regex matches any doc line containing the words skip/MLX/Omit, so a commit can be counted as declined while a later W-item ported it. Candidate tool fix: treat a line containing Ported/Covered/Done in the same doc row as superseding.
- Intel's `Packages/OsaurusCore/Package.swift` excludes upstream `AgentManager.swift`, `ChatSessionsManager.swift`, `SystemPromptComposer.swift`, `ToolRegistry.swift`, `PluginHostAPI.swift`; a hunk to those files must be checked in `Models/Chat/IntelConformers/*` (the cov presence score counts both, so "C" in the tool does not mean the upstream file is live).
