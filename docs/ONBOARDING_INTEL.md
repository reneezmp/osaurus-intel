# Onboarding on Intel

Ported 2026-10-27 (`W-ui-misc`) from upstream through `bce907045`. Before
this, Intel had no onboarding: every onboarding file was an older upstream
generation wrapped in `#if !OSAURUS_INTEL`, and launch always opened chat.

## Flow

Upstream's three screens in a fixed, dark 1000×640 window
(`AppDelegate.showOnboardingWindow`, `OnboardingView`):

1. **Welcome** (`OnboardingWelcomeView`). Get started accepts the Terms and
   selects the welcome credit (`WelcomeCreditService.selectForFirstLaunch`).
2. **Create your Dino** (`OnboardingCreateAgentView`): name, mascot avatar,
   specialty (`AgentStarterTemplate`, whose `routingDescription` becomes the
   agent's description). Saved with `AgentManager.newCustomAgentRecord` +
   `add`.
3. **Give your Dino a brain** (`OnboardingConfigureAIView`):
   - **Osaurus Cloud** card: the managed Router, welcome credit, nothing to
     set up. "Set up later" is the same choice (upstream semantics).
   - Provider chips: OpenAI, Anthropic, xAI, OpenRouter, Gemini, + More
     (`ProviderCatalog` / `ProviderPreset.apiKeyPickerGroups`), with browser
     sign-in for ChatGPT, OpenRouter and Grok, or a pasted key.
   - **Claude Code** (`ClaudeCodeSetupStep`).
   - **Custom** OpenAI-compatible endpoint (`CustomProviderForm.parse`, via
     `PastedProviderEndpoint.swift`).

On finish (or the X button): the Orchestrator becomes the active agent, the
identity master key is created when missing (no biometric prompt on a fresh
install), the chosen brain's model is pinned on the Orchestrator and the new
Dino, and `OnboardingService.completeOnboarding()` runs. Chat opens; a fresh
install then gets the one-time "Import your chat history" prompt
(`presentImportHistoryPromptIfEligible`, `ImportHistoryPromptGate`), and any
live announcement deferred behind onboarding is rechecked. The chat layout
tour is held until those dialogs are queued.

## Intel differences

| Upstream | Intel |
|---|---|
| Recommended local model card, model chooser, download progress, disk preflight, bundled Raptor skip (`BundledModelSeeder`) | Removed (MLX, Apple Silicon only). The home card is Osaurus Cloud. `BrainSource.local` stays in the enum, never selected. |
| "A private brain that runs on your Mac … even offline" | "Give your Dino a brain": start on Osaurus Cloud or connect a provider. |
| Welcome: "No account or cloud required." and a usage-data checkbox | Sentence dropped (Intel always chats through a cloud provider); no checkbox (no telemetry). |
| `OnboardingTelemetry` / `TelemetryService` (Aptabase) | No-op `OnboardingTelemetry` with upstream's call surface; `FeatureTelemetry` no-ops. |
| Claude Code = harness runtime (`HarnessRuntimeStore`) | Claude Code = picker model: the agents default to `claude-code/sonnet` (`IntelClaudeCodeService`). |
| Sandbox default config saved on finish | No-op (Intel has no sandbox; `availability` is never available). |
| `symbolEffect(.bounce)` on specialty cards | `#available(macOS 14, *)` branch; Ventura shows the plain symbol. |
| `arrow.trianglehead.2.clockwise.rotate.90` randomize badge | `arrow.triangle.2.circlepath` (the Ventura symbol guard rejects the newer one). |
| Two-value `onChange` | Single-value. |

Shared pieces taken from upstream with this port: `ProviderCatalog.swift`,
`ProviderPresets.swift` (adds Fireworks and Mistral; Intel's three
credential-mode enums are kept at the end), `ProviderCredentialInstructions`
(the two new presets), `AgentStarterTemplate`, and `ChipFlowLayout` made
internal. `RemoteProviderManager` (Intel's, in `IntelStubConformers`) gained
`firstChatCapableModelId(forProviderId:)` and
`firstRunOsaurusRouterModelId()`.

## Existing installs (important)

No Intel build before this one recorded `hasCompletedOnboarding`. Without a
guard, the first launch of this build would push every existing user into
onboarding, and announcements would stay blocked ("onboarding pending"),
which had in fact been true on Intel all along.

`OnboardingService.reconcileExistingInstall(isPristineInstall:)` runs once
per install at the very start of `applicationDidFinishLaunching`, before any
storage opens, using `StorageMigrator.isPristineInstall()` (now
`nonisolated`; it ignores empty bootstrap folders, built-in themes and the
server config files). An install with user data is marked complete; a
pristine one gets onboarding. The check records
`intelOnboardingExistingInstallReconciled` and never runs again, so a later
Identity reset (`resetOnboarding()`) does bring onboarding back on the next
launch, as the Identity screen says.

## Testing

- Package tests: `IntelOnboardingExistingInstallTests` (the decision),
  upstream's `CustomProviderFormParseTests`, `ProviderCatalogTests`,
  `ProviderPresetsTests` (minus the Fireworks discovery case, which tests
  upstream's excluded `RemoteProviderService`), `AgentStarterTemplateTests`,
  `RemoteProviderEndpointPasteTests`.
- Upstream tests not ported: `ConfigureAIStateDownloadTests`,
  `ConfigureAIStateResourceTests`, `BundledBrainOnboardingGateTests` (MLX),
  and the telemetry and crash-reporting suites (no telemetry on Intel).
- **Manual QA must not use the real setup.** Finishing onboarding changes
  the active agent, creates a Dino and pins default models. Use a separate
  macOS user account on Rosy (fresh `UserDefaults` and `~/.osaurus`); the
  checklist is "Onboarding" in `ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`.
  On the main account, check only that onboarding does *not* appear.
