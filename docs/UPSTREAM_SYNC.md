# Upstream → Intel Sync Ledger

**Base commit:** `d0782cbb` (Pin vMLX main runtime and harden server boundaries, #1201)  
**Intel fork:** `github.com/reneezmp/osaurus-intel` (`intel-fork`)  
**Upstream:** `github.com/osaurus-ai/osaurus` (`main`)  
**Last synced upstream commit:** `7901ec42` (fixed main thread blocking processes, #1556)  
**Upstream version era:** `0.20.3`  
**Last sync date:** 2026-06-14  
**Status:** 🟢 Synced through `7901ec42` (0.20.3). Intel releases: 1.0.20 (cache + Ventura layout), 1.0.21 (0.19.15→0.20.0 absorb), 1.0.22 (deferred-shelf incl. hosted inference — untested live), 1.0.23 (0.20.0→0.20.3 sync).  

## Sync 0.20.0 → 0.20.3 (2026-06-14, Session 9)

21 commits in `24924e6f..7901ec42`. **Ported (7):**

| Upstream | Intel action |
|---|---|
| `8dd49a65` | Codex OAuth diagnostic context (`ProviderNetworkDiagnostics`) |
| `4569b76f` | OAuth → global proxy — adapted `GlobalProxySettings.sharedSession()` (unported) → `makeSession()` |
| `13bb8b47` | configurable Hugging Face cache path (down-leveled the new `onChange`) |
| `ef180dd8` | local access-key lifecycle — `AccessKeyLifecycleService`; ServerView adapted (`ServerController` excluded → server is loopback-only) |
| `7901ec42` | **partial** — ChatView static `ISO8601DateFormatter` cache (main-thread alloc); `PluginRepositoryService` part skipped (excluded) |
| `6c18cb91` | **partial** — `ToolConfigurationStore` only; the ToolsManagerView tools-section hang fix needs the **unported `37a2291b` `ToolAvailability`** + a card refactor that would lose the M16 blank-gap fix |
| `bd0e196d`+`54d650ba` | `Localizable.xcstrings` full-file from upstream |

**SKIP (excluded/divergent):** `b768bbcb` (RemoteProviderService — Intel uses CloudChatEngine),
`9e390950` (PluginHostAPI), `33c41661`/`8ff06de3` (host stdio MCP → excluded `SandboxStdioRunner`),
`dee498b8` (ToolIndexService/CapabilityTools), `e5419a3b` (MLX kv-cache), `5b3c2fa6` (paste-URL — a
*fix* to a feature Intel's divergent `RemoteProviderEditSheet` never had). **DEFER:** `e8bcba8a`
(onboarding model-selection — mixed with excluded RemoteProviderManager/ToolIndexService).
**IGNORE:** 3 appcasts, `44bc8ae6` (whats-new), `ae34ca6a` (legacy storage marker).

> **Versioning note:** the fork keeps its **own** version line (`1.0.x`) — we do
> NOT peg it to upstream's number (the fork amputates whole subsystems, so a
> pegged number would imply false parity). The upstream correspondence is shown
> as *metadata* in the About panel + release notes, sourced from a single
> constant: `IntelBuildInfo.upstreamBase` / `upstreamCommit`. Keep that constant
> in lockstep with the two values above.

## Sync 0.19.15 → 0.20.0 (2026-06-14, Session 6)

95 commits in `d132b728..24924e6f`. The exclude-list amputates MLX/memory/skills/
slash-registry/sandbox/p2p, so most were SKIP. **Ported (15 substantive):**

| Area | Upstream | Notes |
|---|---|---|
| tok/s accuracy | `26573b24` | new `RollingTokenRate` (shared) |
| image context tokens | `0da56927` | `Attachment` resolution-based estimate |
| theme button colors | `0c5b4bf0` | `ThemeEditorView` |
| raw JSON theme editor | `15df6096` | new `ThemeJSONEditorCodec` + editor; resolved union with the bg-decode hang fix |
| theme-editor + watcher hang | `76a07e24` | bg image decode off-main (`decodeThemeBackgroundImage`) |
| fatal crashes | `62191278` | only `ModelMediaCapabilities` applies — PrivacyFilter is DU (Intel lacks it); `osaurusApp` kept ours |
| quit/plugin-teardown crash | `0168ff40` | `ExternalPlugin`/`DebugLog`; `AppDelegate` kept ours (excluded teardown deps), `TelemetryService` DU |
| ClipboardService main-thread hang | `f1b069de` `374e3190` `1bb474c1` | pasteboard XPC moved off-main (recurring fix; `ModelDetailView`/`ManagementBadgeStore` kept ours) |
| tool-envelope hang | `69753ad8` | `ToolEnvelope` shared; `ToolRegistry` excluded (took theirs, dead code) |
| chat-jump-on-completion | `2c4d6089` | **merged** into our Intel `handlePostSnapshotScroll` — kept our `isNewTurn`/`wasPinnedToBottom` structure, added the `isStreaming` gate |
| sidebar rename | `24a5e3e9` | sidebar UI auto-merged; the view-model sync (`session.title`/`archived`) hand-ported into Intel `ChatContentView` callbacks (chat layout is extracted on Intel) |
| visual/interaction polish | `3a4edaae` | theme polish (CustomTheme/Theme/AgentInlineBlocks) only; `FloatingInputCard` budget-tint kept ours (needs excluded `ContextBudgetManager`), `ShimmerLabel` DU dropped |
| localization | `392954aa` … `e6894ce5` | full-file `Localizable.xcstrings` from upstream (both Intel strings present) |

**SKIP (bulk):** all vMLX pins + Gemma/DiffusionGemma/MLX runtime + memory/episodes +
skills/slash-registry + WindowManager/ModelManager hang fixes (excluded) + appcasts/CI.

**DEFER (revisit in a focused session):**
- `58aab452` **hosted inference** (0.20.0 marquee) — `ContentBlock`/`ChatTurn`/`OpenAIAPI`/
  `RemoteProviderManager` mirrored/excluded; conflicts with `CloudChatEngine`.
- `a39b2d89` **p2p e2e encryption** — isolated `Identity/*` pairing; not exposed on Intel.
- `7068b131` **sandbox-by-default** — `BuiltinSandboxTools`/`SandboxToolRegistrar` excluded.
- `2a58c239` + `ae4541d4` **model-picker UX** — Intel's `ModelPickerView` diverged
  (`cachedGroupedOptions`/`groupedBySource()` vs upstream's `rebuildTabs()` tabs); reconcile later.
- `c2231910` slash command (excluded registry), `4a9a23f0` system prompts (excluded composer),
  `37a2291b`/`be43da1a` tool/MCP diagnostics (excluded deps), `3a743373` external-model-mgmt
  (Intel-kept `ModelDetailView`/`AppDelegate`), `e6b78e36` onboarding polish, `fc1626c6` whats-new.

### Deferred-shelf deep dive (2026-06-14, Session 7)

Re-examined the deferral list for faithful portability. Outcome:

**✅ Ported faithfully:**
- `c2231910` **`/agent` slash command** — `SlashCommand` + picker UI (`SharedHeaderComponents`)
  applied verbatim; `chatToolbarOpenAgentPicker` was added only to `ChatWindowManager`'s
  `#if !OSAURUS_INTEL` branch, so it was **mirrored into `IntelDataConformers`** and the listener
  bridged into the Intel `IntelToolbarAgentView` (`openPickerTrigger` + `.onReceive`) so the command
  actually opens the picker. (3× two-param `onChange` down-leveled for Ventura.)
- `3a743373` **prune-deleted external models** — `ExternalModelLocator` +`pruneMissing()` call in
  `ModelPickerView`. The reveal-in-Finder **UI** lives in the divergent `ModelDetailView` → kept ours.

**🧱 Architecturally incompatible (NOT faithfully portable — rooted in amputated subsystems):**
- `a39b2d89` **p2p e2e** — crypto is self-contained but its transport (`BonjourBrowser`/
  `RelayTunnelManager`) is excluded; encrypting a channel Intel never opens = dead code. *(still blocked)*
- `be43da1a` **local MCP probe** — `MCPProviderProbeService` hard-needs excluded `SandboxStdioRunner`. *(still blocked)*

**🔧 Ported as Intel glue (Session 8, 2026-06-14 — `dfcc19cc`):**
- `58aab452` **hosted inference / "Osaurus Router"** — initially called incompatible, but
  `CloudChatEngine` already routes to any OpenAI-compatible provider via the stubbed
  `RemoteProviderManager`, so it WAS doable as a glue port. The "wallet" is the user's
  existing Osaurus identity (EIP-191 `deriveOsaurusId`→EVM address), not a separate wallet.
  Added `.osaurusRouter` provider type, the self-contained Router/credits files, a managed
  provider registration + signed catalog fetch in the stub, request signing in
  `CloudChatEngine` (stream+complete), and a `ManagementTab.credits` entry. Dropped the
  redundant `OpenAICompatibleStreamParser` (CloudChatEngine streams natively) and decoupled
  `StorageMutationGate`/`FeatureTelemetry`/insights cross-refs. **Compiles app-wide; live use
  needs a funded router account (untested).** Composer credits-chip deferred.
- `a39b2d89` **p2p e2e** — crypto is self-contained but its transport (`BonjourBrowser`/
  `RelayTunnelManager`) is excluded; encrypting a channel Intel never opens = dead code.
- `be43da1a` **local MCP probe** — `MCPProviderProbeService` hard-needs excluded `SandboxStdioRunner`.

**⏭ Skipped / needs-rewrite:** `2a58c239`+`ae4541d4` model-picker (Intel's grouping model would need
re-architecting to upstream's tabs — not a faithful diff), `7068b131` sandbox-default (enforcement in
excluded `BuiltinSandboxTools`), `fc1626c6` whats-new (keyed on excluded sandbox/pairing), `e6b78e36`
onboarding polish (low value).

## Sync workflow (monthly)

```bash
git fetch upstream
# Only NEW commits since last sync — never reparse old ones
git log d132b728..upstream/main --oneline
# Classify → PORT/SKIP/MIRROR → cherry-pick/ignore → update this ledger
# When done:
#   1. update the "Last synced upstream commit" hash + "Upstream version era" above
#   2. update IntelBuildInfo.swift (upstreamBase + upstreamCommit) to match
#      — that constant feeds the About panel and the release-notes footer.
```  

---

## Triage Rubric

```
For each upstream commit:
  git show --stat <commit>

  IF all files in Package.resolved + Package.swift
    → SKIP "vMLX version pin"

  IF all files in exclude: list AND no Intel mirror exists
    → SKIP "amputated subsystem"

  IF all files in test directories
    → IGNORE "test-only"

  IF any file in exclude: list WITH an Intel conformer mirror
    → MIRROR "re-implement in <conformer file>"

  IF all files in shared (non-excluded, non-test) code
    → PORT — cherry-pick

  IF mixed (some shared, some excluded)
    → EVALUATE — port shared subset, skip excluded
```

## Perpetual Conflict Files (always `--ours`)

- `Package.swift` — different dependencies, exclude list, OSAURUS_INTEL flag
- `Package.resolved` — different dependency graph
- `RuntimePolicySourceTests.swift` — vMLX source-policy tests

---

## Sync Log

> **vMLX pins (~97 commits):** Batch-classified SKIP based on 30-commit sample analysis (63% ratio).  
> These touch only `Package.resolved` + `Package.swift` for vmlx-swift version bumps.  
> Intel uses `IntelStubs` — all harmless noise. Not individually listed; covered by the hash  
> range `d0782cbb..109e0306`. Individual hashes can be retrieved with:  
> `git log d0782cbb..109e0306 --oneline -- Packages/Package.resolved Packages/OsaurusCore/Package.swift`  
>  
> Commits below are the **substantive** upstream changes that required Intel action.

| # | Upstream Hash | Class | Intel Action | Files | Result |
|---|---|---|---|---|---|---|
| 1 | `61245f1a` | PORT | cherry-pick | IdentityView.swift | ✅ Clean — auto-merged |
| 2 | `5a9207c1` | PORT | deferred | RemoteProviderEditSheet.swift | ⚠️ Deferred — upstream file diverged too far; Intel version kept. URL-split feature to be manually ported later. |
| 3 | `4fc80157` | PORT | cherry-pick (skip xcstrings, keep test deleted) | AgentStarterTemplate.swift, AgentAvatarView.swift, OnboardingProgress.swift, +6 guarded files | ✅ Conflicts resolved; guards re-added |
| 4 | `95ad4ef3` | PORT | cherry-pick (skip ModelManager, OnboardingConsent, xcstrings) | +11 guarded onboarding files | ✅ Conflicts resolved; guards re-added |
| 5 | `a0ebae22` | PORT | cherry-pick (skip test file, keep guarded file) | ProviderPresets.swift, ProviderCredentialInstructions.swift, OnboardingConfigureAIView.swift | ✅ AtlasCloud provider preset — pre-req for Grok OAuth |
| 6 | `d9fd0db1` | PORT | cherry-pick (skip RemoteProviderService, xcstrings) | ProviderPresets.swift, ProviderCredentialInstructions.swift, +5 files | ✅ MiniMax provider preset — pre-req for Grok OAuth |
| 7 | `806de1a0` | PORT | created XAIOAuthService.swift + cherry-pick (discard excluded/guarded files) | ProviderPresets, RemoteProviderConfiguration, OAuthLoopbackServer, OAuthSignInCoordinator, ProviderCredentialInstructions, RemoteProviderEditSheet (reverted), XAIOAuthService | ✅ Core shared files ported; RemoteProviderEditSheet kept Intel version; RemoteProviderService/RemoteProviderManager changes discarded (excluded/irrelevant) |
| 8 | xcstrings sync | SYNC | `git checkout upstream/main` — full-file replacement | Localizable.xcstrings (38 commits worth of localization changes) | ✅ 2761 strings; both Intel strings already present upstream |
| 9 | `aa444a5a` | PORT | cherry-pick | MCPProviderManager.swift, ModelPickerItemCache.swift | ✅ Clean auto-merge — MCP hangs fix |
| 10 | `3ff495ef` | PORT | cherry-pick (manual conflict resolution) | ChatWindowManager.swift, NativeToolCallGroupView.swift, SystemPermissionService.swift | ✅ Resolved: VLMDetection excluded, SystemPermissionService took upstream, ChatWindowManager kept Intel, NativeToolCallGroupView manually patched |
| 11 | `c43cf17e` | PORT | cherry-pick | ChatSessionSidebar.swift | ✅ Clean auto-merge — chat rename guard |
| 12 | `9b79161b` | PORT | selective shared-file port (DIFF application, NOT whole-file replacement) | ChatToolChoicePolicy (NEW), FloatingInputCard, ToolsManagerView, ModelFamilyNames, ModelFamilyGuidance, ModelOptions, ModelOptionsStore, ModelMediaCapabilities, ModelMetadataParser, SystemPromptTemplates, ToolEnvelope, OsaurusPaths, FolderTools, StorageKeyManager, KeychainQueryHelpers, ToolSecretsKeychain, MCPProviderKeychain, RemoteProviderKeychain, DocumentChip (onInline param) | ✅ Partial — shared files only. HTTPHandler, Router, AppDelegate, CacheSection, ConcurrencySection, ChatView kept Intel versions (upstream too divergent). Intel conformers: added .required to ToolChoiceOption; Phase B ToolRegistry upgrades (folderToolNames, runtimeManagedToolNames, builtInSandboxToolNamesSnapshot, invalidToolArgumentsEnvelope).
| 13 | `1dbe7ed3` | PORT | selective diff (3 shared, 3 skipped) | OsaurusPaths, FloatingInputCard, SystemMonitorService | ✅ Free-space query swap, paste monitor crash fix, doc. AppDelegate/HTTPHandler/OsaurusServer skipped (MLX-specific). |
| 14 | `a213f3ce` | SKIP | MLX-only load policy | AppDelegate.swift | ⏭ Intel AppDelegate doesn't use ToolIndexService. |
| 15 | `f59a6cf0` | SKIP | MLX-only telemetry | HTTPHandler.swift | ⏭ Telemetry field in MLX orchestration path. |
| 16 | `c46c0682` | SKIP | MLX-only cold-tier pin | OsaurusServer.swift | ⏭ Intel OsaurusServer already minimal (no IdleStateHandler). |
| 17 | `8e1b42ba` | PORT | cherry-pick (resolved: re-added guard) | Localizable.xcstrings, 2 Onboarding views | ✅ OnboardingCreateAgentView + OnboardingWelcomeView guards re-added. |
| 18 | `a8d336ec` | PORT | cherry-pick (resolved: re-added guard) | xcstrings, 8 Onboarding files | ✅ Guards re-added; 2 excluded files kept deleted. |
| 19 | `edadc1f2` | PORT | cherry-pick (kept Intel ChatView/PluginsView) | xcstrings + 28 files | ✅ Chinese translations; Intel views preserved. |
| 20 | `396abe4f` | PORT | cherry-pick (gated new codex file) | PDFPPTXWorkflowService (NEW) | ✅ Gated behind #if !OSAURUS_INTEL. |
| 21 | `5145c37a` | PORT | cherry-pick (reverted FolderTools) | WorkspaceWriteSafety (NEW) | ✅ New file kept; FolderTools reverted (sandbox deps). |
| 22 | `8d94f864` | PORT | cherry-pick (reverted ProvidersView/RemoteProvidersView, gated diagnostics) | ProviderNetworkDiagnostics (NEW), ProviderDiagnosticsRowsView (NEW) | ✅ New files gated; Intel views preserved. |
| 23 | `d132b728` | PORT | cherry-pick (clean auto-merge) | ManagementBadgeStore, ServerView | ✅ Main thread hang fix — key gen off main actor. |
| 24 | `63bf3a3c` | PORT | cherry-pick (resolved: took upstream OAuth) | RelayTunnelManager, MCPOAuthService, XAIOAuthService, OpenAICodexOAuthService, NativeBlockViews, NSWorkspaceAsyncOpen (NEW) | ✅ Streaming/OAuth/relay hang fixes. |
| 25 | `dfca2325` | PORT | cherry-pick (gated WatcherManager, kept Intel ModelDownloadService) | WatcherManager, FloatingInputCard, DirectoryFingerprint, CustomTheme | ✅ Unresolved app hangs fix; Agent.rejectBuiltInForExternalSurface gated. |
| 26 | `bfa4aa01` | PORT | cherry-pick (clean auto-merge into AS branch) | PluginManager.swift | ✅ Keychain reads off main thread; Intel branch unaffected. |
| 27–36 | vMLX pins (4) + CI/appcast (6) | SKIP/IGNORE | — | Package.resolved, Package.swift, CI workflows, appcast XML | ⏭ Batch-skipped. |
| 37 | `0c494229` | PORT | cherry-pick -X ours + gating | 90 files, ChatView kept Intel | ✅ Capabilities refactor; 6 new files gated, 3 shared views reverted. |
| 38 | `6df10354` | PORT | cherry-pick (kept Intel ChatView) | 14 files | ✅ Capabilities persistence fix. |
| 39 | `5737790a` | PORT | cherry-pick (gated RemoteProviderReorderSheet) | RemoteProviderManager, RemoteProvidersView, RemoteProviderReorderSheet | ✅ Provider reorder; new sheet gated. |
| 40 | `f694bbaa` | PORT | cherry-pick (took ours for shared views, gated 3 files) | ExternalModelLocator, ModelCompatibilityDiagnostics, ExternalModelsSettingsView, ModelDetailView | ✅ Model diagnostics; 3 files gated, ModelDetailView reverted. |
| 41 | `522b8a69` | PORT | cherry-pick (removed App/AppIntents — no OSAURUS_INTEL in App target) | AppDelegate (ours), HTTPHandler (ours), ServerController, App/AppIntents | ✅ App Intents removed from Intel App target. |
| 42 | `2f7ff107` | PORT | cherry-pick (resolved test conflicts) | DocumentFormatRegistry, BusinessDocumentSummary (NEW) | ✅ Business document attachment summaries. |
| 43 | `e361e78b` | PORT | cherry-pick (kept Intel PluginsView, gated Claude files) | ClaudePlugin* (NEW, gated), PluginsView (ours) | ✅ Claude plugin marketplace; 7 files gated. |
| 44 | `62c66db5` | SKIP | MLX infrastructure | RuntimeProofValidation, tests | ⏭ ModelRuntime subsystem. |

### Intel-Specific Fixups (commit `8f86d6d5`)

| Fix | Reason |
|---|---|
| RemoteProviderEditSheet.swift reverted to Intel version | Upstream file depends on unported types (ProviderTextField, ProviderSecureField, OpenAICodexOAuthService, disableTimeout) |
| Package.swift: exclude RemoteReasoningPolicy.swift | Depends on excluded ThinkingConfig / RemoteProviderService |
| Stripped `public` from OAuthSignInCoordinator + ProviderCredentialInstructions | Intel module is internal; upstream uses library visibility |
| Re-added `#if !OSAURUS_INTEL` guards to 5 onboarding files | Lost during `--theirs` conflict resolution |
| Removed duplicate ProviderInputFields.swift | Intel defines ProviderTextField/ProviderSecureField inline in RemoteProviderEditSheet |

---

## Stats

- **Total upstream commits processed:** 44 substantive + ~97 vMLX pins + ~38 xcstrings
- **Sessions:** 5 (2026-06-07/2026-06-08) | **Fully caught up to upstream/main** ✅

---

## Deferred / watch-list

- **Chat "bubble" rendering for thoughts + tool-calls.** The Apple-Silicon
  Osaurus renders reasoning/tool-call blocks in a newer "bubble" style; Intel
  renders the 0.19.15 "card" style. The `Native*` chat views
  (`NativeThinkingView`, `NativeToolCallGroupView`, `NativeMessageCellView`,
  `NativeBlockViews` — ~5.3k lines of hand-tuned AppKit) are SHARED, not
  Intel-divergent, so this is **not** an Intel reimplementation — it's a newer
  upstream redesign. It is NOT in the 41 commits after `d132b728` (by subject).
  **Decision (Renée, 2026-06-11): do NOT reinvent it.** If a future upstream
  sync brings the redesign as a real commit, port it then. Otherwise leave the
  card style as-is.

---

## ⚠️ Intel-owned files & post-sync verification (GUARDRAIL)

The `9b79161b` / App-Intents syncs silently **reverted** Intel customizations by
taking "theirs" on cherry-picks (found + fixed in 1.0.15): the README was
replaced with upstream's, and `RemoteProviderKeychain` lost its Intel isolation.
These compile fine reverted, so they slip through. **After EVERY sync, verify
these Intel-owned customizations survived:**

| File | Must contain (Intel) | Not (upstream) |
|---|---|---|
| `README.md` | `🦕 Osaurus (Intel)` header, "Run a model locally" | `Own your AI`, `brew install --cask osaurus` |
| `RemoteProviderKeychain.swift` | `ai.osaurus.remote.intel` (`#if OSAURUS_INTEL`) | bare `ai.osaurus.remote` only |
| `MCPProviderKeychain.swift` | `ai.osaurus.mcp.intel` | bare `ai.osaurus.mcp` only |
| `App/osaurus/Info.plist` | `SUFeedURL` → `reneezmp/osaurus-intel`, `SUPublicEDKey` `7Nh8jSxF…` | `osaurus-ai` / missing |
| `scripts/release/cut_intel_release.sh` | `REPO="reneezmp/osaurus-intel"` | upstream repo |
| `scripts/build/build_rosy.sh` | bakes `OsaurusCanonicalData` | — |
| `MasterKey.swift` (DO NOT isolate) | `com.osaurus.account`, synchronizable — **shared identity, leave as-is** | a `.intel` variant (would fracture identity) |

**Revert-detector** (run after each sync — lists Swift files that lost ALL their
Intel guards vs the last known-good tag):

```bash
comm -23 \
  <(git grep -l OSAURUS_INTEL <good-tag> -- '*.swift' | sed 's/^[^:]*://' | sort -u) \
  <(git grep -l OSAURUS_INTEL HEAD       -- '*.swift' | sed 's/^[^:]*://' | sort -u)
```

**Rule:** the README, the two provider/MCP keychain service names, the updater
config (Info.plist), and the release/build scripts are Intel-owned — on a
cherry-pick conflict, ALWAYS keep ours. The Master Key (`com.osaurus.account`)
is the opposite: shared + iCloud-synced identity, never give it an Intel variant.

---

## ⚠️ Ventura (macOS 13) backport maintenance (Phase B, 2026-06-12)

The deployment target is **macOS 13**, enforced by the compiler. After every
upstream sync, the build will fail on any new API that requires 14+. Recurring
categories to watch for:

| Pattern | Fix |
|---|---|
| `@Observable` macro | Convert to `ObservableObject` + `@Published` |
| `.onChange(of:){ _, v in }` | Down-level to `{ v in }` (bulk Perl regex available) |
| `.onChange(of:){ named, v in }` | Manual: `@State` prev-value var |
| `.symbolEffect` | Remove or `.contentTransition(.opacity)` |
| `.activateAllWindows` | Use `.activateIgnoringOtherApps` |
| new 14+ decorative APIs | Plain 13-compatible replacement (no `#available` gates) |

**Post-sync Ventura build check:**
```bash
cd Packages/OsaurusCore && swift build --arch x86_64
```
Fix every "only available in macOS 14/15" error, rebuild, repeat until clean.
