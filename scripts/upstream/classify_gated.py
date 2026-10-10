#!/usr/bin/env python3
"""Classify what Intel compiles but switches off, which classify_gap.py can't see.

Usage (from the repo root):  python3 scripts/upstream/classify_gated.py [upstream-ref]

classify_gap.py lists upstream files Intel does not compile. This script covers
the three blind spots found on 2026-10-10 (W-gated-sweep):

1. compiled files that are wholly `#if !OSAURUS_INTEL` (upstream body switched
   off, sometimes with an Intel `#else` body);
2. files that render `AppleSiliconOnlyTab` placeholders;
3. upstream App-target Swift files (App/osaurus/...) missing from Intel.

Each must be assigned in GATED below (path -> (feature id, verdict, note)).
Verdicts as in gap_features.py, plus R = retired upstream (upstream deleted the
file in a redesign; Intel's leftover copy may still be referenced by other
leftovers, so remove it together with the feature that replaced it) and
P = ported (the placeholder was wrong and is gone).
Unassigned entries make the script exit non-zero: classify them and add the
feature to docs/INTEL_MISSING_FEATURES_BACKLOG.md.
"""
import os, re, subprocess, sys

REF = sys.argv[1] if len(sys.argv) > 1 else "upstream/main"
PRE = "Packages/OsaurusCore/"

GATED = {
    # --- Intel's own implementation lives in the #else body (content may drift) ---
    "Managers/Chat/ChatWindowManager.swift": ("COV-intel-own", "C", "Intel window manager"),
    "Managers/Chat/ChatWindowState.swift": ("COV-intel-own", "C", "Intel window state"),
    "Managers/Plugin/PluginManager.swift": ("W-plugin-reliability", "C", "Intel slim plugin manager (M9)"),
    "Views/Memory/MemoryComponents.swift": ("COV-intel-own", "C", "Intel Memory UI"),
    "Views/Memory/MemoryDiagnosticsViews.swift": ("COV-intel-own", "C", "Intel Memory UI"),
    "Views/Memory/MemoryView.swift": ("COV-intel-own", "C", "Intel Memory UI"),
    "Views/Model/ModelPickerView.swift": ("COV-intel-own", "C", "Intel model picker"),
    "Views/Settings/ServerSettings/AuthenticationSection.swift": ("COV-intel-own", "C", "Intel server auth section"),
    "Views/Settings/ServerSettings/ConnectionSection.swift": ("COV-intel-own", "C", "Intel connection section"),
    "Views/Settings/StatusPanelView.swift": ("COV-intel-own", "C", "IntelStatusPanelView is the menu-bar panel"),
    # --- Apple Silicon only (MLX local runtime, containers) ---
    "Services/ExternalModelLocator.swift": ("INC-mlx", "I", "local model folders"),
    "Services/ModelCompatibilityDiagnostics.swift": ("INC-mlx", "I", "local model checks"),
    "Views/Model/ModelCacheInspectorView.swift": ("INC-mlx", "I", ""),
    "Views/Model/ModelDetailView.swift": ("INC-mlx", "I", ""),
    "Views/Model/ModelDownloadView.swift": ("INC-mlx", "I", ""),
    "Views/Model/ModelPickerTableRepresentable.swift": ("INC-mlx", "I", ""),
    "Views/Model/ModelRowView.swift": ("INC-mlx", "I", ""),
    "Views/Common/EmptyStateView.swift": ("INC-mlx", "I", "model list empty state; no other users"),
    "Views/Common/SimpleComponents.swift": ("INC-mlx", "I", "model views' components; no Intel users"),
    "Views/Settings/DirectoryPickerView.swift": ("INC-mlx", "I", "models directory"),
    "Views/Settings/ExternalModelsSettingsView.swift": ("INC-mlx", "I", ""),
    "Views/Settings/ServerSettings/CacheSection.swift": ("INC-mlx", "I", ""),
    "Views/Settings/ServerSettings/ConcurrencySection.swift": ("INC-mlx", "I", ""),
    "Views/Settings/ServerSettings/GenerationDefaultsSection.swift": ("INC-mlx", "I", ""),
    "Views/Settings/ServerSettings/LiveActivitySection.swift": ("INC-mlx", "I", "MLXBatchAdapter snapshot"),
    "Views/Settings/ServerSettings/MTPSection.swift": ("INC-mlx", "I", ""),
    "Views/Settings/ServerSettings/ModelResidencySection.swift": ("INC-mlx", "I", ""),
    "Views/Settings/ServerSettings/MultimodalSection.swift": ("INC-mlx", "I", ""),
    "Views/Settings/ServerSettings/PowerSection.swift": ("INC-mlx", "I", ""),
    "Views/Settings/ServerSettings/ServerSettingsBanners.swift": ("INC-mlx", "I", ""),
    "Views/Settings/ServerSettings/ToolsTemplatesSection.swift": ("INC-mlx", "I", "local chat templates"),
    "Views/Plugin/SandboxPluginEditorView.swift": ("INC-containers", "I", ""),
    "Views/Sandbox/PostStartTasksCard.swift": ("INC-containers", "I", ""),
    "Views/Sandbox/ProvisioningJourneyView.swift": ("INC-containers", "I", ""),
    "Views/Sandbox/SandboxView.swift": ("INC-containers", "I", ""),
    # --- Needs work: a feature Intel lacks, not hardware-bound ---
    "AppIntents/OsaurusLocalClient.swift": ("W-app-intents", "C", "Intel in-process client in the #else body (no /agents routes on Intel)"),
    "Models/Plugin/ExternalPlugin.swift": ("W-plugin-reliability", "W", "upstream plugin host"),
    "Views/Plugin/PluginConfigView.swift": ("W-plugin-reliability", "W", "per-agent plugin config sections"),
    "Services/Chat/DefaultAgentSystemPromptBuilder.swift": ("W-declarative-config", "W", "Default-agent guide addendum (#2268)"),
    "Tools/Configuration/ConfigurationDomain.swift": ("W-declarative-config", "W", ""),
    "Services/Context/CapabilityClaimsEvaluator.swift": ("W-agent-loop-tools", "W", "grounded claim checks"),
    "Services/Documents/PDFPPTXWorkflowService.swift": ("W-doc-editing", "W", ""),
    "Services/Provider/ProviderNetworkDiagnostics.swift": ("W-providers-ux", "W", "connectivity centre"),
    "Views/Settings/ProviderDiagnosticsRowsView.swift": ("W-providers-ux", "W", "connectivity centre"),
    "Services/Plugin/InstalledClaudePluginsAggregator.swift": ("W-skills-plugins-import", "W", "Claude plugins"),
    "Services/Skill/ClaudePluginManifestStore.swift": ("W-skills-plugins-import", "W", "Claude plugins"),
    "Views/Plugin/ClaudePluginCard.swift": ("W-skills-plugins-import", "W", "Claude plugins"),
    "Views/Plugin/ClaudePluginDetailView.swift": ("W-skills-plugins-import", "W", "Claude plugins"),
    "Views/Skill/GitHubImportSheet.swift": ("W-skills-plugins-import", "W", "GitHub import (upstream moved it to Views/Plugin/)"),
    "Views/Agent/NextRunPanelView.swift": ("W-agent-detail-redesign", "W", "Next Run panel"),
    "Views/Theme/ShareThemeSheet.swift": ("W-ui-misc", "W", "theme sharing (themes.osaurus.ai, identity-signed)"),
    "Views/Theme/ImportThemeByIdSheet.swift": ("W-ui-misc", "W", "theme import by id"),
    "Views/Agent/IncomingPairSheet.swift": ("W-workspaces-identity-mobile", "W", ""),
    "Views/Agent/RemoteAgentViews.swift": ("W-workspaces-identity-mobile", "W", ""),
    "Views/Agent/ShareAgentSheet.swift": ("W-workspaces-identity-mobile", "W", ""),
    "Views/Onboarding/OnboardingConfigureAIView.swift": ("W-ui-misc", "W", "onboarding"),
    "Views/Onboarding/OnboardingCreateAgentView.swift": ("W-ui-misc", "W", "onboarding"),
    "Views/Onboarding/OnboardingTokens.swift": ("W-ui-misc", "W", "onboarding"),
    "Views/Onboarding/OnboardingView.swift": ("W-ui-misc", "W", "onboarding"),
    "Views/Onboarding/OnboardingWelcomeView.swift": ("W-ui-misc", "W", "onboarding"),
    # --- Covered by Intel's own implementation elsewhere ---
    "Services/Context/CapabilitySearch.swift": ("COV-tool-discovery", "C", "TOOL_DISCOVERY_INTEL.md"),
    "Services/Context/SessionToolState.swift": ("COV-tool-discovery", "C", "TOOL_DISCOVERY_INTEL.md"),
    "Models/Chat/IntelConformers/IntelAgentConformers.swift": ("COV-intel-own", "C", "agent DB tab placeholders are unreachable: Intel hides dbTabs and shows DatabaseWorkspaceView"),
    # --- Not a user feature ---
    "Services/Context/EvalHostBootstrap.swift": ("N-dev-tooling", "N", ""),
    # --- Wrong placeholders, ported 2026-10-10 ---
    "Views/Agent/AgentReorderSheet.swift": ("W-gated-sweep", "P", "ported (AgentManager.reorder existed)"),
    "Views/Chat/MarkdownImageView.swift": ("W-gated-sweep", "P", "ported; also the full-screen image preview"),
    "Views/Plugin/ToolSecretsSheet.swift": ("W-plugin-reliability", "P", "ported in stage 1"),
    "Views/Chat/TerminalDisplayView.swift": ("W-chat-ux", "P", "ported 2026-10-10"),
    "Views/Chat/TerminalSnapshot.swift": ("W-chat-ux", "P", "ported 2026-10-10"),
    # --- App target (App/osaurus/...) ---
}

pkg = open(PRE + "Package.swift").read()
excluded = set()
for block in re.findall(r"exclude:\s*\[(.*?)\]", pkg, re.S):
    excluded.update(re.findall(r'"([^"]+)"', block))


def upstream_has(path):
    return subprocess.run(["git", "cat-file", "-e", f"{REF}:{path}"], capture_output=True).returncode == 0


def wholly_gated(text):
    lines = [l.strip() for l in text.splitlines() if l.strip() and not l.strip().startswith("//")]
    return bool(lines) and lines[0] == "#if !OSAURUS_INTEL"


entries = []  # (path, what)
for root, _, files in os.walk(PRE):
    if any(part in root for part in ("/.build", "/Tests", "/SQLCipher")):
        continue
    for name in files:
        if not name.endswith(".swift"):
            continue
        full = os.path.join(root, name)
        rel = full[len(PRE):]
        if rel in excluded:
            continue
        text = open(full, encoding="utf-8", errors="ignore").read()
        kinds = []
        if wholly_gated(text):
            kinds.append("gated")
        if "AppleSiliconOnlyTab(" in text and not rel.endswith("AppleSiliconOnlyTab.swift"):
            kinds.append("placeholder")
        if kinds:
            entries.append((rel, "+".join(kinds), upstream_has(PRE + rel)))

listing = subprocess.run(["git", "ls-tree", "-r", "--name-only", REF, "App/"], capture_output=True, text=True, check=True).stdout.split()
for path in listing:
    if path.endswith(".swift") and not os.path.exists(path):
        entries.append((path, "app-target", True))

unassigned = []
counts = {}
for rel, what, on_upstream in sorted(entries):
    verdict = GATED.get(rel)
    if verdict is None and not on_upstream:
        verdict = ("retired-upstream", "R", "deleted upstream; leftover may still be referenced")
    if verdict is None:
        unassigned.append((rel, what))
        continue
    fid, v, note = verdict
    counts[(fid, v)] = counts.get((fid, v), 0) + 1
    print(f"{v} {fid:30s} {what:21s} {rel}" + (f"  ({note})" if note else ""))

print(f"\n{len(entries)} gated / placeholder / app-target entries ({REF})")
for (fid, v), n in sorted(counts.items()):
    print(f"  {v} {fid:30s} {n}")
stale = [k for k in GATED if k not in {e[0] for e in entries}
         and GATED[k][1] != "P"]
if stale:
    print("NO LONGER GATED (drop from GATED once verified):")
    for k in stale:
        print("  ", k)
print("UNASSIGNED", len(unassigned))
for rel, what in unassigned:
    print("  ", what, rel)
sys.exit(1 if unassigned else 0)
