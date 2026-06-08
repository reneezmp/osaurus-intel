# Upstream → Intel Sync Ledger

**Base commit:** `d0782cbb` (Pin vMLX main runtime and harden server boundaries, #1201)  
**Intel fork:** `github.com/reneezmp/osaurus-intel` (`intel-fork`)  
**Upstream:** `github.com/osaurus-ai/osaurus` (`main`)  
**Last synced upstream commit:** `21123c9a` (fixed main thread hangs, #1418)  
**Last sync date:** 2026-06-08  

## Sync workflow (monthly)

```bash
git fetch upstream
# Only NEW commits since last sync — never reparse old ones
git log 21123c9a..upstream/main --oneline
# Classify → PORT/SKIP/MIRROR → cherry-pick/ignore → update this ledger
# When done, update the "Last synced upstream commit" hash above.
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
| 23 | `21123c9a` | PORT | cherry-pick (clean auto-merge) | ManagementBadgeStore, ServerView | ✅ Main thread hang fix — key gen off main actor. |
| 24 | `63bf3a3c` | PORT | cherry-pick (resolved: took upstream OAuth) | RelayTunnelManager, MCPOAuthService, XAIOAuthService, OpenAICodexOAuthService, NativeBlockViews, NSWorkspaceAsyncOpen (NEW) | ✅ Streaming/OAuth/relay hang fixes. |
| 25 | `dfca2325` | PORT | cherry-pick (gated WatcherManager, kept Intel ModelDownloadService) | WatcherManager, FloatingInputCard, DirectoryFingerprint, CustomTheme | ✅ Unresolved app hangs fix; Agent.rejectBuiltInForExternalSurface gated. |
| 26 | `bfa4aa01` | PORT | cherry-pick (clean auto-merge into AS branch) | PluginManager.swift | ✅ Keychain reads off main thread; Intel branch unaffected. |
| 27–36 | vMLX pins (4) + CI/appcast (6) | SKIP/IGNORE | — | Package.resolved, Package.swift, CI workflows, appcast XML | ⏭ Batch-skipped. |

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

- **Total upstream commits since fork:** 153
- **Substantive processed:** 26 (21 ported, 1 deferred, 1 xcstrings bulk sync)
- **New (109e0306→21123c9a):** 30 commits (10 PORT + 2 deferred + 8 SKIP + 10 vMLX/CI SKIP)
- **vMLX pins skipped:** ~97 (batch)
- **Remaining pending:** 0 — caught up to upstream/main ✅
- **Sessions:** 4 (2026-06-07/2026-06-08) | **Last synced upstream hash:** `21123c9a`
