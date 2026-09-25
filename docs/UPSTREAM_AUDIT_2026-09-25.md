# Upstream feasibility audit — 2026-09-25

**Range:** `7e109ade6..a4daf94c4` on `osaurus-ai/osaurus/main`, fetched
2026-09-25. **171 commits, 171 classified below.** The last full classification
ended at `7e109ade6` on 2026-09-07. The 2026-09-25 DeepSeek review examined
through `535ea3557` for one model change; it did not classify that range.

This is a read-only porting assessment. It does **not** advance the last synced
upstream commit or claim that a feature works on Intel. The authoritative
product states remain in [FEATURE_PARITY.md](FEATURE_PARITY.md). The current
Rosy candidate is `1.0.52` (`53`); none of the newly proposed ports below are
in that candidate. The DeepSeek slug slice of `a0aaa945d` is in that candidate
and still awaits Rosy testing.

## How verdicts were assigned

Each commit's message, changed paths, and relevant patch were compared with
the Intel `Package.swift` exclusions and current compiled counterparts. For
multi-file changes, the verdict names the useful Intel slice. A missing or
excluded file increases adaptation effort; it is never itself a rejection.

| Verdict | Meaning |
|---|---|
| **Port** | Feasible, useful work against a current Intel seam; implement and test. |
| **Stage** | Feasible feature or fix, with the named backend/policy dependency first. |
| **Covered** | Equivalent Intel behavior exists; keep its own verification gate. |
| **Split** | Commit mixes useful Intel work with a staged or non-Intel slice. |
| **Superseded** | Review the later replacement as the implementation source. |
| **Omit** | No useful behavior in the current Intel product; reason is stated. Revisit if that product scope changes. |

## Conclusions and dependency order

1. **Protect existing data and tool calls first.** `ff92720ee` still reproduces
   in Intel source: `MCPProviderTool.convertToMCPValue` tests `Bool` before
   `Int`, so Foundation can send JSON `0`/`1` as false/true. Port that together
   with no-arg schema normalization (`19c6786e7`), canonical MCP names
   (`fb2efe4db`), and null/primitive-call handling (`ffbd07bf6`). The
   originating-provider scope and live allowlist must remain authoritative.
   `219640c82` requires a separate Intel chat-history repair: upstream fixes a
   SQLite migration, while Intel's compiled history uses its own storage path.
2. **Fix schedule and core-model reliability.** `7666cc6ba` fixes an active
   pattern in Intel's `ScheduleManager`: `executeSchedule` writes `Date()` as
   `lastTriggeredAt`, and the timer can wake before the due slot. Port the
   consumed-slot anchor, per-schedule catch-up, and overlapping-run guard.
   `93513e8d6` is likewise relevant to Intel's compiled
   `CoreModelService`, which currently falls back for unavailable models but
   not for a timed-out configured primary. Preserve cancellation and an
   explicit no-fallback residency decision.
3. **Take cheap UI and provider corrections next.** Theme hex alpha is still
   emitted as `#AARRGGBB` in Intel, while parsing expects `#RRGGBBAA`
   (`11f26f9a8`). The attachment picker (`5c6b998ec`), small-screen window
   sizing (`210685eb9`), source-specific prompt-cache fields (`9b3336d68`),
   and GPT-6 Astra/Codex discovery, context, and reasoning profiles
   (`a0aaa945d`) have current Intel seams. Only DeepSeek was ported from the
   last of these; its other model/provider changes remain open.
4. **Build larger features in dependency order.** Rich folder formats
   (`65ff7cc4e`) can use Intel's existing folder tools and document parser,
   without importing the sandbox `/workspace` share. Native Apple app tools
   (`348bc70cb`) are a feasible, valuable Intel feature, but their upstream
   Calendar/Reminders authorization uses macOS 14 `fullAccess` APIs and needs a
   Ventura-compatible EventKit path plus per-agent opt-in, TCC, approval, and
   plugin migration. Channels/n8n (`a609acdb5`, `94af9d41a`, `338425936`,
   `ef26b55b7`) need the B3 transport/credential/outbox boundary. Workspaces
   (`940d86a31` and follow-ups) need B1/B2 pairing, relay, host grants,
   identity, and the matching Router workspace/billing endpoints. Native
   subagent and computer-use changes need their own request-scoped budgets and
   capability spike. These are **Stage**, never blanket No.
5. **Retain actual omissions.** vMLX/MLX runtime pins, local GPU residency,
   bundled Raptor/Gemma/MiMo model behavior, upstream arm64 appcast/release
   artifacts, and optional install-cohort telemetry have no direct behavior in
   the present Intel cloud-first build. The generic safety or UX portion of a
   mixed commit is classified separately below.

### Product-level state after this audit

| State | Affected features and remaining dependency |
|---|---|
| **Working and tested** | Existing Intel Knowledge, Projects, Claude Code, Web Search, Insights, and native-control acceptance remain as recorded in FEATURE_PARITY; this audit adds no tested feature. The bounded top-up parser already covers `8de938f91`. |
| **Partial** | Chat/session persistence and UI, MCP tool interoperability, Automation timing, Memory/Core Model fallback, provider catalog and cache accounting, folder formats, Credits local API, and bounded Orchestrator all have port candidates below. Current Rosy gates remain open where the parity ledger says so. |
| **Dependency-blocked** | Relay/remote grants/Workspaces billing, Channels and n8n, native subagent execution, and sandbox-backed tools require their named service/runtime clusters. |
| **Absent** | Native Apple app tools, the upstream Privacy filter, Computer Use/Browser Use, and rich document generation are not shipped on Intel. Their absence is an implementation backlog, not a feasibility verdict. |
| **Intentionally omitted** | MLX/vMLX-only inference and local-model onboarding/cache paths, upstream arm64 release/appcast artifacts, the Raptor marketing campaign, and new cohort telemetry. |

## Complete commit inventory

Short hashes are unambiguous in this fetched range. Entries are in upstream
ancestry order, not author-date order. “Port” and “Stage” mean **unimplemented
as of this audit**, unless the row explicitly says otherwise.

| # | Commit | Verdict | Intel analysis / action |
|---:|---|---|---|
| 1 | `370277f45` | Omit | Gemma-4 MLX bundle preflight only; Intel never invokes that loader. |
| 2 | `888d8a55a` | Covered | Intel consolidator already persists last successful run in encrypted processing log and checks due work at launch; keep Rosy Memory gate. |
| 3 | `11f26f9a8` | Port | Theme alpha round-trip, picker feedback, stale JSON, gradient direction; current Intel `toHex` still emits alpha first. **Ported 2026-09-25** (`2d2606891`): macOS 13 single-value `onChange`, lock-free background helper; preview shows stored accent because Intel does not apply system-accent following (`402060bce` unported). |
| 4 | `438b01222` | Split | Intel project folders already work; sandbox-off polarity applies only when native sandbox is restored. |
| 5 | `176eb4769` | Omit | MiniCPM5/vMLX runtime pin and local-native model controls. |
| 6 | `5c6b998ec` | Port | Add extension-bound markdown and text UTTypes to Intel attachment picker. **Ported 2026-09-25** (`2d2606891`), applied cleanly. |
| 7 | `6e26730bb` | Omit | Local-model residency/predicted memory warnings; no Intel local loader. |
| 8 | `940d86a31` | Stage | Workspaces, shared agents, team billing: B1/B2 relay, identity, host grants, Router workspace schema 0041, billing. |
| 9 | `f79b88a1c` | Stage | Native Seatbelt runner exit safety if an Intel sandbox runner is introduced. |
| 10 | `4bf6ff744` | Split | Settings menu responsiveness can port; idle local-model residency is out of scope. **N/A 2026-09-25**: local idle residency / server settings. |
| 11 | `92fb38a15` | Stage | iMessage helper process-generation guard after B3 channel helper exists. |
| 12 | `c44eb3b2d` | Omit | Spark local runtime/template pin; inspect generic HTTP slice only if local model API returns. |
| 13 | `aaa359852` | Port | Show inherited sampling values honestly in Intel settings. **N/A 2026-09-25**: Intel's cloud stream does not send those sampling settings. |
| 14 | `c6bb483e5` | Stage | Preserve unknown versus zero child-token telemetry when native subagent sessions land. |
| 15 | `d8e9cd60c` | Stage | Workspace UX/roster improvements follow #8 backend. |
| 16 | `ff92720ee` | Port | Fix MCP `NSNumber` 0/1 boolean bridging and floating-point distinction; directly applicable. **Ported 2026-09-25** (`e84a7ba21`). |
| 17 | `979d53b40` | Port | Single mutable owner for a saved chat; adapt to Intel session/tombstone store. **Ported 2026-09-25** (`31fb9ef1e`): Intel windows hold one session (no tabs); opening an owned chat reveals its window. |
| 18 | `a4cb24b65` | Stage | Workspace agents as dispatch/orchestration targets after shared-agent identity and grants. |
| 19 | `00486cc80` | Split | Bounded Intel delegation already validates and forwards its admitted model; native delegated-session override follows native runtime. |
| 20 | `de85ba3bd` | Stage | Binary-read hint for sandbox file route after sandbox tools; Intel folder read has its own binary error. |
| 21 | `f2a308d57` | Stage | Workspace dispatcher admitted-model forwarding after #18. |
| 22 | `c1ceafe59` | Omit | Upstream 0.25.0 appcast; Intel has separate version/signing/release flow. |
| 23 | `dcb041654` | Omit | Local-model alignment/preparation UI tied to removed model runtime. |
| 24 | `6db0f029a` | Stage | Peer model-sharing toggle after pairing, remote grants, and host inference policy. |
| 25 | `97498c331` | Split | Agent working-folder default is feasible; decide explicit default vs Intel's already tested per-chat/project folder ownership. Sandbox interplay later. |
| 26 | `026bebe32` | Stage | `/v1/responses` non-function input and decode errors need Intel local Responses endpoint contract. |
| 27 | `598d8ee7a` | Superseded | Workspace intro dialog replaced by inline empty state in `16ec3a7a3`. |
| 28 | `a48a58cf4` | Stage | Delegated child file writes only after native child lifecycle, folder grants, and per-child permission policy. |
| 29 | `00c613e1b` | Omit | Flash QSA vMLX pin only. |
| 30 | `2e8e57d8d` | Omit | Flash Next vMLX pin only. |
| 31 | `7e90a7269` | Port | History modal filters can use Intel session-source/agent metadata. **N/A 2026-09-25**: Intel has no chat-history dialog. |
| 32 | `ee9adf6ae` | Port | Dismiss Projects page when selecting an agent from sidebar. **Ported 2026-09-25** (`4f1368b11`). |
| 33 | `f0c6f8e9a` | Omit | Native local-model MTP controls and server runtime setting. |
| 34 | `d9d68157a` | Split | Restore small-screen chat minimum; obsolete workspace intro sizing follows #27. **Ported 2026-09-25** with #43 (`4e90ed017`). |
| 35 | `65cbb73e0` | Port | Persist unsent composer drafts across chat/agent switches in Intel chat state. **Ported 2026-09-25** (`ffb1dc65a`) to Intel's local-text composer; in-memory as upstream. |
| 36 | `51c8c1ba5` | Omit | Qwen Flash vMLX cache pin only. |
| 37 | `e4734a216` | Split | Queue permission dialogs in Intel tool loop; sibling spawn-wave semantics need native child runtime. **Intel slice 2026-09-25** (`e3bb2c82b`): FIFO approval prompts with post-wait policy revalidation; fixes one Enter approving two concurrent prompts. Spawn waves N/A. |
| 38 | `80e1e3d13` | Omit | Upstream 0.25.1 appcast. |
| 39 | `74b326f22` | Omit | Flash Next local runtime pin and local token-rate memoizer. |
| 40 | `4680ce594` | Split | Per-agent drafts, badges, spell check, sidebar highlights can port; subagent labels need native children. **Spell-check slice 2026-09-25** (`8a52c3929`); per-agent drafts covered by #35; rest targets tabs/workspaces/subagents. |
| 41 | `8fcd06156` | Omit | Freed GPU-buffer admission for local child models. |
| 42 | `246609942` | Stage | Computer Use audit/readiness/verified completion needs Intel Ventura Accessibility and capture capability spike. |
| 43 | `3a17bc04d` | Port | Orchestrator row selection and small-screen chat geometry fit current Intel UI. **Ported 2026-09-25** (`4e90ed017`): per-window chat floor clamp; the Orchestrator gesture bug is absent on Intel. |
| 44 | `b2bffc63b` | Split | Label current native-Mac tool approval surface; VM label only after sandbox. **N/A 2026-09-25**: Intel runs tools on one surface (native Mac); nothing to disambiguate. |
| 45 | `f158416e2` | Port | Right-click chat tab actions and project naming UI. **N/A 2026-09-25**: tab-strip only; Intel has no tabs. |
| 46 | `40be05cb8` | Stage | Claude plugin GitHub import after Intel plugin/skill installer route is restored; CLI integration already works. |
| 47 | `879a6a6a9` | Omit | Qwen AR vMLX scheduling pin. |
| 48 | `dec325484` | Stage | Osaurus ID/Workspace refresh depends on Router identity and Workspaces service. |
| 49 | `53c24678a` | Port | Make Intel Settings searchable/grounded for bounded Orchestrator and Management help; exclude nonexistent routes. |
| 50 | `a609acdb5` | Stage | First-party n8n ingress needs B3 channel store, signed webhook, credential lifecycle, and dispatch. |
| 51 | `9beb51ef7` | Omit | Upstream 0.25.2 appcast. |
| 52 | `219640c82` | Port | Repair incomplete chat-history schema/turn persistence in Intel's compiled session store; do not copy upstream SQL migration blindly. **Intel analogue fixed 2026-09-25** (`5bccc4bef`): no SQLite open path on Intel, but queued whole-session metadata writes could overwrite a newer turn; per-session write generations now drop stale snapshots. |
| 53 | `c240123ed` | Port | Persist open chat tabs through window close/relaunch using Intel chat store. **Intel analogue 2026-09-25** (`4abd1671f`): no tabs, so the last saved chat a window showed reopens once when chat is summoned with no window. |
| 54 | `7842b4713` | Split | Provider/sidebar QoL can port; keep Intel provider editor and scoped-tab differences. **N/A 2026-09-25**: Intel sidebar has no agent rows; provider-picker regrouping not pursued. |
| 55 | `83eac58f0` | Split | Main-thread theme/content/agent work can port; MLX model and sandbox-only parts wait or omit. **Theme slice 2026-09-25** (`09c433587`). ModelProfileRegistry memo deliberately not ported (AutoThinkingProfile is runtime-dependent; see #119). |
| 56 | `dc1a250f7` | Omit | Installed local vision/MLX bundle evidence and admission. |
| 57 | `fb043ae7d` | Stage | LAN-discovered shared agents in sidebar after B1/B2 peer identity and grants. |
| 58 | `a6554f94b` | Superseded | Intro sequencing belongs to removed dialog; inline replacement `16ec3a7a3` is the workspace UX source. |
| 59 | `94af9d41a` | Stage | n8n secure pairing code requires B3 ingress, pairing, local network address, and credential store. |
| 60 | `2ad1d93dc` | Stage | Disable folder attachment for shared-agent chats after shared-session ownership exists. |
| 61 | `210685eb9` | Port | Fit Intel Settings window to Rosy's smaller Ventura displays; preserve traffic-light frame-root rule. **Ported 2026-09-25** (`edfa4d64f`) into Intel's AppDelegate Settings window (WindowManager excluded). |
| 62 | `d18c54278` | Omit | Upstream 0.25.3 appcast. |
| 63 | `3034800ef` | Port | Recent folders and agent working-folder setting; keep explicit chat/project folder precedence. **Adapted 2026-09-25** (`c38cbc96f`): path-only store; recents in the folder chip context menu. Agent-editor list waits for #25. |
| 64 | `ad4de6abd` | Omit | MLX 0.32.2/MTP local-runtime policy. |
| 65 | `6e67eec21` | Omit | Local embedding-model endpoint substitutes Potion; Intel has no compiled local embeddings endpoint. Revisit if exposed. |
| 66 | `7666cc6ba` | Port | Daily/cron consumed-slot anchor, catch-up and overlap protection in compiled `ScheduleManager`. **Ported 2026-09-25** (`ae337cc0f`): consumed-slot anchor, latest-due catch-up, dispatch-time overlap guard, honest Run Now result. Run-history test omitted (no Intel run history). |
| 67 | `4a78f169d` | Stage | Multi-device agent addresses/owner redeem need B1/B2 identity, relay, Keychain migration. |
| 68 | `163a97552` | Port | Centered themed declarative-config approval modal fits Intel Gate 5B. |
| 69 | `3fd0e69a3` | Omit | Installed MLX vision-bundle discovery/admission and local model-format checks. |
| 70 | `ac96bcbb4` | Split | History/tab/agent QoL can port; ModelManager suggested local-model changes do not. **N/A 2026-09-25**: tabs, history dialog, workspaces. |
| 71 | `338425936` | Stage | n8n setup readiness follows B3 ingress and #59 pairing; prevent unusable codes. |
| 72 | `9b3336d68` | Port | Provider-specific prompt-cache keys/TTL and cached token accounting in Intel CloudChatEngine, Router ledger, Credits UI; never send unknown fields to generic gateways. **Intel slice 2026-09-25** (`76f906f8d`): per-chat `prompt_cache_key` (Router, Azure, OpenAI hosts, OpenRouter + `session_id`), Router cache split in usage rows/summary/ledger v3, usage-center Cached input. Anthropic/Gemini wires and the BYOK turn chip do not apply (Intel never surfaces the Router summary frame in chat). |
| 73 | `6cf600fce` | Split | Xcode 27 theme/crypto compile corrections are feasible where Intel compiles the paths; package pin is not. Verify with Intel toolchain. |
| 74 | `922bf3cfd` | Omit | Upstream arm64 release script plugin trust; Intel Rosy build has separate script. |
| 75 | `ccab67125` | Port | Menu-bar Ask AI can open an Intel chat tab in the existing window. **Covered 2026-09-25**: Intel's Ask AI already focuses the existing chat window. |
| 76 | `abfef96fa` | Omit | Upstream 0.25.4 appcast. |
| 77 | `0b33e116e` | Omit | Raptor 0.6 local-model onboarding default. |
| 78 | `417da91f0` | Superseded | SSD cache popup replaced by settings-only notice/clear flow in `5c674f087`; local cache itself absent. |
| 79 | `94c5647ea` | Omit | Local model idle residency/utility ownership and memory-pressure policy. |
| 80 | `f6b872371` | Split | Local GPU RAM planner is out of scope; request-scoped child token budget is a future native-delegation contract. |
| 81 | `05d291a5c` | Omit | Local vision processor, image/cache input, and vMLX admission. |
| 82 | `225f102ab` | Omit | Resident local child RAM and external local-model tracking. |
| 83 | `1bf922253` | Omit | MTP opt-in and native local runtime settings. |
| 84 | `d73fd0939` | Split | Generic image chat completion/usage safety can port to Intel cloud Chat/API; native local usage math does not. **N/A 2026-09-25**: local runtime usage accounting. |
| 85 | `39fc21b58` | Omit | Local model repair/download integrity and progress in removed model manager. |
| 86 | `e20ffcfb0` | Split | Bounded Orchestrator UX and declarative approval polish can port; native spawn/sandbox/workspace simplification belongs to their later clusters. |
| 87 | `156c5eee4` | Omit | Upstream 0.25.5 appcast. |
| 88 | `d42dee07a` | Omit | Local model manifest/update enforcement; no Intel local model manager. |
| 89 | `fa706a5de` | Stage | Warning-pressure spawn refusal copy after native child/RAM policy; bounded cloud delegation has different limits. |
| 90 | `8de938f91` | Covered | Intel `CreditsTopUpSheet.currentMicro` calls bounded `OsaurusRouter.parseMicroUSD` rather than overflowing `Int`. |
| 91 | `65ff7cc4e` | Split | Port rich folder reads/search/writes, media bridge, safe undo and format errors; sandbox `/workspace` share and DB import wait for their backends. **Deferred to its own project 2026-09-25**: ~6,000 lines across folder read/write/search formats, OCR, workbook previews and media bridge; too large for a batch port. |
| 92 | `ebabfb72a` | Omit | Complete native MLX tool-call batch mapping; Intel cloud engine owns remote batches separately. |
| 93 | `437ca4257` | Stage | Privacy redaction fixes require an Intel cloud-path filter and compatible detector before enabling; portable span/skip fixes are reusable. |
| 94 | `51ee70e3e` | Stage | Computer Use/AppleScript privacy and trace repair after those engines and privacy filter exist. |
| 95 | `66ea84b91` | Port | Delay Sparkle check until chat readiness rather than Settings, adapting Intel window lifecycle. **Ported 2026-09-25** (`439b2de28`): Intel previously checked for updates only when Settings opened. |
| 96 | `a188a57e4` | Port | Only show the stuck composer chip when Intel run progress is actually silent. **N/A 2026-09-25**: Intel has no composer stuck chip. |
| 97 | `1bbc984f9` | Port | Prevent repeated toolbar taps from stacking chat-history dialogs. **N/A 2026-09-25**: Intel has no chat-history dialog. |
| 98 | `8ef1a9418` | Port | Warn before Add Model discards an agent-creation draft. **Adapted 2026-09-25** (`439b2de28`): Intel's picker offers Add Provider → Providers tab; the editor confirms before discarding a draft. |
| 99 | `78396083b` | Omit | Upstream 0.25.6 appcast. |
| 100 | `4c17cba54` | Superseded | SSD-cache popup preference retired by `5c674f087`; no Intel cache surface. |
| 101 | `4a329449b` | Port | Keep tab strip stable and clear of sidebar during window resize. **N/A 2026-09-25**: Intel has no tab strip. |
| 102 | `0901780cc` | Port | Preserve MCP image result payloads in Intel chat/history; account for cloud-provider image wire formats. **Intel analogue 2026-09-25** (`1b3104f92`): Intel is text-only; MCP image/audio base64 is replaced by a size/type placeholder instead of being billed as text. |
| 103 | `61ba32da8` | Omit | New agent-count product telemetry is not an Intel feature; no user benefit or requested cohort analytics. |
| 104 | `2d715b51a` | Omit | Bonsai2/native Qwen tokenizer runtime pin. |
| 105 | `16ec3a7a3` | Stage | Workspaces inline empty-state explainer is the current UX source once Workspaces backend exists. |
| 106 | `c31a9256b` | Omit | Upstream 0.25.7 appcast. |
| 107 | `97a390380` | Omit | Buffered native vMLX tool-stream cancellation; Intel cloud stream cancellation needs separate audit. |
| 108 | `fabd1f043` | Omit | Explicit Gemma native-media tool selection/pin. |
| 109 | `9222379e3` | Stage | Unified parent handoff after native text/image/other child kinds; preserve bounded Intel delegation separately. |
| 110 | `ac169df39` | Port | Extend compiled `ChatToolChoicePolicy` no-tool language before Intel tool selection. **N/A 2026-09-25**: nothing in Intel calls `ChatToolChoicePolicy`; CloudChatEngine always sends `tool_choice: auto`. Revisit if Intel adopts the policy. |
| 111 | `08a4049ab` | Omit | Loaded local-bundle sampling defaults and MLX batch adapter. |
| 112 | `99a87c20f` | Stage | Image/compaction parent residency handoff after child and local-residency runtime. |
| 113 | `cc1823517` | Split | Composer/sidebar/markdown main-thread fixes can port; local vision/model path segment does not. **Paths slice 2026-09-25** (`09c433587`): `ProcessEnvironment` getenv lookups. |
| 114 | `b8b18b7b7` | Omit | Bonsai vMLX loading/media-prefill pin. |
| 115 | `7802bcd49` | Port | Rehydrate persisted document text in Intel chat/warm-up and keep security bounds. **Ported 2026-09-25** (`edfa4d64f`); upstream test file is excluded on Intel for unrelated reasons. |
| 116 | `0ef3d8335` | Stage | Sandbox provisioning attribution/quit-time VM cleanup after an Intel sandbox backend exists. |
| 117 | `a916daee0` | Omit | Bonsai FP16/FP32 local runtime pin. |
| 118 | `3d0a0a795` | Omit | Upstream 0.25.8 appcast. |
| 119 | `56b3eb502` | Split | Preserve reasoning rail on Intel cold cloud send/bounded child; native model/child controls need later runtime. **Covered 2026-09-25**: Intel's `ModelProfileRegistry` does not memoize, and cloud options load synchronously on model selection, so the cold first-send loss does not reproduce. |
| 120 | `13cc78ae3` | Port | Compact dispatch source badge for scheduled/watched Intel chats instead of exposing raw envelope. **Intel analogue 2026-09-25** (`7c36f34c2`): only Intel's watcher framing exists; stripped for display via shared constants. |
| 121 | `f44c9c771` | Omit | Empty upstream commit (tree identical to parent); no patch to port. |
| 122 | `a0aaa945d` | Split | DeepSeek Flash slug/reasoning slice ported in build 53; GPT-6 Astra Codex OAuth discovery/fallback, official API context/reasoning profile, and Claude Opus 5 sampler omission remain to port. **Remainder ported 2026-09-25** (`b554b4bb0`): Codex GPT-6 slug rule, fallback list incl. 5.6-luna (Intel already sends the Codex UA), client 0.155.1, GPT-6 effort profile, no `temperature` to reasoning models. Official-API context table and documented `max` profiles need upstream's GPT-5.x capability layer. |
| 123 | `ef26b55b7` | Stage | n8n pending approval card/preset allowlists after B3 signed ingress and pairing. |
| 124 | `dbab94a77` | Port | Avoid main-thread hang in selectable chat text hit testing; Intel has same view. **Ported 2026-09-25** (`edfa4d64f`). |
| 125 | `c4320c825` | Omit | Upstream 0.25.9 appcast. |
| 126 | `15374269f` | Stage | Router cache-stat getter hang fix when #72 cache telemetry and its chat property are present. |
| 127 | `289a52272` | Omit | Native local generation-output relay step scoping; Intel cloud engine has separate streaming. |
| 128 | `f1ad85c42` | Omit | Install-cohort/age retention telemetry does not serve current Intel product and needs separate privacy decision. |
| 129 | `dc6a9013c` | Port | Correct hover/favorite controls on bottom model-picker rows. **N/A 2026-09-25**: Intel's compiled `ModelPickerView` is the non-table variant. |
| 130 | `2ab74c0fd` | Superseded | Local SSD sizing/notices converge on settings-only `5c674f087`; no Intel local cache. |
| 131 | `9631a3b41` | Port | Read-only authenticated `/credits/balance` can use Intel Router account client; require master-key/origin checks and no wallet mutation. **Staged 2026-09-25**: Intel's local HTTP server has no access-key authentication, and upstream requires a master key; do not expose the Router balance until Intel's local API authenticates callers. |
| 132 | `a2dd43d30` | Stage | Channel follow-up tab lifetime and Focus Chat preference after B3 inbound relay. |
| 133 | `5c674f087` | Omit | Final SSD cache notice moves to local cache settings, which Intel does not ship. |
| 134 | `348bc70cb` | Stage | Nine built-in Apple app tool families are feasible with Ventura EventKit compatibility, per-agent opt-in, TCC, forced approvals, plugin-name migration, and live revocation. Upstream macOS 14 `fullAccess` calls cannot be copied unchanged. |
| 135 | `3321cf6e5` | Omit | vMLX learned-resume/history checkpoint pin. |
| 136 | `2ac423378` | Stage | Cloud-compatible context compaction, model fallback, preserved draft, visible failure, manual action; requires Intel compaction service/session integration. |
| 137 | `b5c704f68` | Omit | Hang in local vision bundle path absent from Intel. |
| 138 | `cb0dac4eb` | Port | Keep Intel cloud-run progress visible through final processing and label it “Finishing up…”. **N/A 2026-09-25**: local vMLX engine tail. |
| 139 | `19c6786e7` | Port | Normalize missing MCP object `properties` at ingest and provider schema encoding. **Ported 2026-09-25** (`e84a7ba21`) at MCP ingest and Intel's `ChatEngine.encodeTools`; upstream's `OpenAIAPI`/`RemoteProviderService` encoders are excluded here. |
| 140 | `c1c4d712f` | Stage | Codex CLI local-provider card/Responses input shapes after Intel `/v1/responses` and server auth contract are audited. |
| 141 | `3485efb41` | Omit | Hugging Face local-model deep link and token/download flow; no Intel model download manager. |
| 142 | `d6b04ce4e` | Stage | Codex CLI local-server context window and `prompt_cache_key` session affinity after #140 Responses contract. |
| 143 | `ffbd07bf6` | Split | Port null/scalar tool-call safety, primitive JSON, no-arg schema and display cleanup to Intel tool/CloudChatEngine paths; absent sandbox/message-helper segments await their backends. **Intel slice ported 2026-09-25** (`e84a7ba21`): validate before serializing a non-container MCP argument. Inline detection, Responses tools, sandbox/message helpers and upstream HTTP handler are excluded on Intel; Intel's MCP endpoint receives typed SDK values. |
| 144 | `83a5e5f01` | Omit | Upstream 0.25.10 appcast. |
| 145 | `7bdb58e89` | Omit | Raptor Product Hunt campaign dialog has no Intel product purpose. |
| 146 | `fb2efe4db` | Port | Resolve canonical MCP tool names only within unique offered provider; preserve Intel request scope and denied-tool errors. **Ported 2026-09-25** (`e84a7ba21`): description naming hint verbatim; canonical names resolve only to the single tool OFFERED this turn (in `CloudChatEngine`), so not-offered rejection, policy and approval run on the resolved name. |
| 147 | `b6f71056f` | Omit | Upstream 0.25.11 appcast. |
| 148 | `04e763bf7` | Port | Make permission probe decision a typed status/error, never a localized `SUCCESS` prefix; useful now in Permissions and required before #134. **Intel slice ported 2026-09-25** (`a303bc3f7`): Intel probe strings are not localized, so the translated-prefix bug does not reproduce; write-only Calendar/Reminders no longer counts as granted. |
| 149 | `a2388f323` | Omit | Date shift for Raptor Product Hunt campaign; campaign omitted by #145. |
| 150 | `93513e8d6` | Port | Core Model first-token deadline, primary breaker, chat-model fallback on hang/unavailable, cancellation and distillation recovery; adapt out local MLX/Foundation assumptions for Ventura. **Ported with Intel policy 2026-09-25** (`a303bc3f7`): 150 s distill deadline and 10-minute Core Model breaker; only a not-billed unavailable primary (no endpoint/404) retries immediately on the chat model, a hung one is not re-sent. |
| 151 | `bc7e2f628` | Omit | Upstream 0.25.12 appcast. |
| 152 | `849bc4837` | Port | Correct nonexistent Settings shortcut and stale route names in Intel guides/help; respect actual Intel sidebar. **Intel slice 2026-09-25** (`699a42a4a`): Knowledge guide now quotes ⌘,. |
| 153 | `c3eb4ef26` | Port | Move Markdown link opening off main-thread hit path; preserve URL safety. **Ported 2026-09-25** (`2d2606891`), applied cleanly. |
| 154 | `70546416f` | Stage | Preserve runtime policy in isolated evals if Intel adopts that eval harness; test infrastructure, not shipped app behavior. |
| 155 | `32a8b845d` | Omit | MiMo native local capabilities and resident allocator reuse. |
| 156 | `576e202c9` | Split | An Intel DMG pipeline is feasible if distribution needs it; bundled Raptor/local-model seeding and upstream arm64 release archive do not apply. Keep current signed ZIP contract. |
| 157 | `09844d5d6` | Port | Agent-purpose descriptions, active chat model on creation, guided legacy repair, bounded Orchestrator roster text; do not invalidate existing Rosy agents. |
| 158 | `c9021e91c` | Port | Generate missing descriptions from system prompts with explicit review/migration and Intel cloud Core Model; preserve user-authored text. |
| 159 | `3e208b2ba` | Stage | Headless DefaultAgent eval worker model binding if Intel adopts same eval harness; no app-runtime change. |
| 160 | `3085b242a` | Split | Keep local Intel agent-purpose metadata current after #157; remote workspace/voice consumers follow their own backends. |
| 161 | `0ee10ec79` | Omit | Native SSD prefix cache clearing. |
| 162 | `b1477660d` | Omit | Native SSD cache-directory save/clear guard. |
| 163 | `2fecfc883` | Omit | Preserve omitted native bundle/template thinking defaults; Intel remote reasoning has separate explicit policy. |
| 164 | `f9e33e3c5` | Stage | CI split between cold compile and tests is reusable for Intel CI if that workflow is maintained; no runtime port. |
| 165 | `f6aa293e0` | Omit | vMLX rotating-checkpoint prefix reuse pin. |
| 166 | `c48f9112c` | Omit | Legacy local-model revision verification UI; no Intel local model catalog. |
| 167 | `9d97c71eb` | Omit | Spark local large-prefill activation pin. |
| 168 | `535ea3557` | Omit | vMLX batched prefill cache finalization pin; this was the tip of the targeted DeepSeek review, not a full classification. |
| 169 | `b0de92d32` | Omit | Raptor q6 local decode fusion pin. |
| 170 | `0779420b5` | Split | vMLX prefill pin is out; retain local model-discovery checks only if Intel later restores a local catalog. Current cloud discovery has its own implementation. |
| 171 | `a4daf94c4` | Split | Adopt deterministic cancellation/runtime-settings test patterns for compiled Intel suites; native Metal/server-runtime tests are excluded. |

## Implementation and verification gates

- **Quick correctness batch:** port #3, #6, #16, #52, #66, #90-equivalent
  verification, #139, #143, #146, #148, #150 and #153. For path-backed
  tests, obey [TEST_STORAGE_SAFETY.md](TEST_STORAGE_SAFETY.md): isolated
  `OSAURUS_TEST_ROOT`, shared lock, explicit serial suite, live-data hashes.
- **Provider/chat batch:** #17, #35, #53, #72, #91's folder-only slice, #102,
  #119's cloud slice, #122 remainder, #131 and #136. Test model requests,
  session relaunch, errors, and Ventura presentation separately.
- **Feature gates:** Apple apps (#134) need macOS 13/14 authorization matrix,
  entitlements, one app family at a time, explicit approvals and migration
  rollback; Channels/n8n need B3; Workspaces need B1/B2 plus Router contract;
  native child/computer use need request-scoped budgets and host permissions.
- **Quick correctness batch status (2026-09-25):** every item above is
  ported or has its Intel analogue fixed; #90 was already Covered. Gate:
  1,108 tests in 164 suites under an isolated root, no live-data writes.
  Rosy acceptance for these ports is still pending.
- **Provider/chat batch status (2026-09-25):** #17, #35, #53 (analogue),
  #72 (Intel slice), #102 (analogue), #122 remainder ported; #119 Covered;
  #131 Staged behind local-API authentication; #91 deferred as its own
  project; #136 remains Stage. Gate: 1,141 tests in 171 suites, isolated
  root, x86_64 package build. Rosy acceptance pending.
- **Smaller-fixes batch status (2026-09-25):** 15 ported or adapted, 1
  Covered, 13 N/A with reasons in the rows. Still open as features, not
  fixes: #49 Settings search, #68 approval modal, #86 Orchestrator polish,
  #157/#158/#160 agent descriptions, #25/#4 agent working folder, #73 only
  if a newer Xcode requires it, #170/#171 test patterns. Gate: 1,159 tests in
  178 suites, x86_64 package build. Rosy acceptance pending.
- **No promotion from this audit alone.** The user is testing build 53 now.
  Add any subsequent port to a new candidate and the focused Rosy checklist.

The next upstream review begins at `a4daf94c4` (exclusive). Any future
correction to a verdict updates this audit, the sync ledger and feature parity
together; avoid silently reclassifying the range.
