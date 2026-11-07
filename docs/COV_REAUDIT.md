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

## Plan (each stage a report and push)

1. **Stage 1 (this doc):** the tool and the triage.
2. **Stage 2, the six gaps (done 2026-11-07, five ported; #2306 moved to
   stage 5):** skill file path containment (#1275, security);
   DeepSeek thinking-mode `tool_choice` downgrade (#1940); window frame
   recovery (#2154); the cancelled-turn record and its "Interrupted" row
   (#2516, with upstream's `stop(preservesCancelledMarker:)` /
   `terminalStopReason`); the Data Visualizer skill loading `render_chart`
   (#2084); the Abilities context-impact readout (#2306, #2323).
3. **Stage 3, the Check groups and the 166 examined-but-absent commits**
   by area: providers (#1594, #2108, #1428),
   capabilities (#1679, #2393, #2308), knowledge (#2067, #2117, #2132,
   #2338, #2383), chat UI (#1259, #1272, #1283, #1352, #1468, #2486),
   context preview (#1324), crashes and hangs (#1337, #1353, #1359, #1431),
   voice (#2016, #2321), memory (#1613), agents (#1837), the rest (folders,
   server, flags, prompt, AppleScript, windows, misc).
4. **Stage 4, translations:** bring upstream's translations for keys Intel
   shows.
5. **Stage 5, behaviour audit of the `COV-intel-own` files** (the item's
   original scope): commits since the fork are covered by stages 1–4; this
   compares behaviour Intel's replacements never had at all, starting with
   chat storage, the prompt composer (with the Abilities context-impact
   readout, #2306 / #2323), `ChatEngine` and `RemoteProviderService`.

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
| Check:capabilities | `1a6bbd339` | #1679 | 1/3 | stop wasted iterations on repeated failing capabilities_load calls | Repeated failing `capabilities_load` calls end early. |
| Check:capabilities | `9a593c5d3` | #2393 | 17/27 | Answer a bare capabilities call with the enabled list, not a rejection | A bare `capabilities` call answers with the enabled list. |
| Check:capabilities | `f6384c3ce` | #2308 | 4/39 | Fix MCP capability indexing and custom agent scope | MCP capability indexing and custom-agent scope in upstream's `ToolSearchService`; Intel's tool discovery is its own (`COV-tool-discovery`). |
| Check:chat-errors | `f6657eb53` |  | 7/25 | Fix plugin tool-loop default iterations | `ChatErrorMessages` (system-resource exhaustion message) and plugin tool-loop default iterations; Intel has no `ChatErrorMessages`. |
| Check:chat-ui | `10dd0e915` | #1259 | 263/652 | chat improvements | "chat improvements" #1259 (large). |
| Check:chat-ui | `6d841a22b` | #1352 | 21/51 | save chart as image | Save a chart as an image. |
| Check:chat-ui | `8b86266fb` | #1468 | 65/146 | cascading esc on chat view states | Cascading Esc across chat view states. |
| Check:chat-ui | `972e49b31` |  | 75/315 | chat polish with smoother streaming, stable tool call animations and scroll cache fixes (# | Chat polish #1283: chart-drawn tracking in `MessageTableRepresentable`, delta processor `finalize()`; Intel's chat views are partly its own. |
| Check:chat-ui | `a69299136` | #1272 | 18/39 | fixed scroll to bottom lag & mid stream jumps during streaming | Scroll-to-bottom lag and mid-stream jumps. |
| Check:chat-ui | `ca2c1d202` | #2486 | 4/6 | fix leaked pacing timer on mid-stream processor dealloc | Leaked pacing timer when the delta processor is freed mid-stream. |
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
| Check:misc | `e2eec4a9e` | #1362 | 8/10 | disable generative greetings globally and moved to per agent configuration | Generative greetings per agent. |
| Check:prompt | `76614779f` | #1317 | 31/48 | improve prompt for better guidance | Prompt guidance (#1317). |
| Check:providers | `390eb33e2` | #1594 | 68/139 | anthropic compaction fix | Anthropic tool_use/tool_result pairing on the wire and duplicate-result merge; Intel keeps pairs together when trimming (`IntelContextBudgetManager`) but has no wire-level pairing pass. |
| Check:providers | `76c1f6ae8` | #2108 | 21/76 | Fix truncated remote tool arguments | Truncated remote tool-call arguments on `finish_reason=length`; Intel's `CloudChatEngine` has its own output-limit error for text only. |
| Check:providers | `b3472ce02` | #1428 | 20/26 | moved remote provider diagnostics to edit | Remote provider diagnostics moved to the edit sheet. |
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
| N | `1877babba` | #1507 | 15/41 | Fix test-core CI failure by skipping TCC status probes under tests | CI: skip TCC probes under tests. |
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
