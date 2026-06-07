# Upstream → Intel Sync Ledger

**Base commit:** `d0782cbb` (Pin vMLX main runtime and harden server boundaries, #1201)  
**Intel fork:** `github.com/reneezmp/osaurus-intel` (`intel-fork`)  
**Upstream:** `github.com/osaurus-ai/osaurus` (`main`)  
**Last sync:** 2026-06-07  

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

> vMLX pins (commits #1–97) batch-marked SKIP on 2026-06-07.  
> Commits #98→ are the substantive upstream changes.

| # | Upstream Hash | Class | Intel Action | Files | Result |
|---|---|---|---|---|---|
| 1–97 | vMLX pins | SKIP | — | Package.resolved, Package.swift | vMLX version pins; irrelevant to Intel (uses IntelStubs) |
| 98 | `61245f1a` | PORT | cherry-pick | IdentityView.swift | ⏳ pending |
| 99 | `5a9207c1` | PORT | cherry-pick | RemoteProviderEditSheet.swift | ⏳ pending |
| 100 | `4fc80157` | PORT | cherry-pick | AgentStarterTemplate.swift, AgentAvatarView.swift, OnboardingProgress.swift, +6 guarded files | ⏳ pending |
| 101 | `95ad4ef3` | PORT | cherry-pick (skip ModelManager.swift, OnboardingConsentView.swift, xcstrings) | +11 guarded onboarding files | ⏳ pending |
| 102 | `806de1a0` | PORT | create XAIOAuthService.swift + cherry-pick (discard excluded) | ProviderPresets, RemoteProviderConfiguration, OAuthLoopbackServer, OAuthSignInCoordinator, ProviderCredentialInstructions, RemoteProviderEditSheet, XAIOAuthService | ⏳ pending |

---

## Stats

- **Total upstream commits since fork:** 153
- **Processed:** 102 | **Ported:** 0 | **Skipped:** 97 | **Mirrored:** 0 | **Pending:** 51
- **Sessions:** 1 (2026-06-07, in progress)
