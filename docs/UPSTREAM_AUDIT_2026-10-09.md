# Upstream audit and port — 2026-10-09

**Range:** `02604ca60..ec654e8c5` on `osaurus-ai/osaurus/main`, fetched
2026-10-09. **5 commits (no merges), 5 classified.** Verdicts follow the rule
in
[`UPSTREAM_SYNC.md`](UPSTREAM_SYNC.md#verdict-rule-doesnt-apply-is-not-a-verdict--2026-09-29):
Incompatible only for Apple Silicon (MLX/Metal local inference) or
upstream-only artifacts; "Intel doesn't have X yet" is **Needs work** with X
named on the backlog. The next review begins at `ec654e8c5` (exclusive).

## Classification

| # | Commit | Verdict | Intel note |
|---:|---|---|---|
| 1 | `377cde12e` #3049 | **Incompatible** | Upstream's own appcast (0.25.20 notes). |
| 2 | `0e109894d` #3055 | **Split:** Port + Covered | Port: an OpenRouter "Provider returned error" now carries the real reason from `metadata.raw`, and numeric error codes are shown. Covered: the forced `tool_choice` downgrade for Claude 5.5 / Fable / Mythos. Intel's cloud engine always sends `tool_choice: "auto"` and never forwards a forced choice, so those models can't hit the 400. |
| 3 | `b9e832288` #3054 | **Needs work** (`W-app-menus`) | `LCached` for the Schedules and Watchers submenu labels (Sentry hang). Intel's menu bar has neither submenu. `LCached` itself is already on Intel. |
| 4 | `a7859ba99` #3052 | **Split:** Port + **Needs work** (`W-app-menus`) | Port: no `@ObservedObject` on the App struct. Intel's zoom items observed `ThemeManager` from the App, so any theme change rebuilt the whole menu bar on the main thread; they now live in `ZoomMenuItems`. Needs work: upstream's `VADToggleMenuItem` and `ThemeMenuItems` belong to menus Intel doesn't have. |
| 5 | `ec654e8c5` #3057 | **Split:** Port + **Needs work** (`W-plugin-reliability`) | Port: the plugin card and detail view check required secrets off the main thread (`PluginSecretsStatus`), which fixes the Plugins tab freezing on scroll. Needs work: the `hasResolvedSecret` memo, because Intel's `ToolSecretsKeychain` predates upstream #2061's `resolvedSecret`. |

**Totals:** Split (with a Port part) 3 · Needs work 1 · Incompatible 1.

## Shipped on Intel (awaiting Rosy)

| Upstream | What Intel got |
|---|---|
| #3055 `0e109894d` (part) | `extractAPIErrorMessage` (cloud chat and one-shots) appends OpenRouter's upstream reason (`metadata.raw`, as JSON `message` / `error.message` or the first 300 characters of plain text). It also adds ` (code: …)` for string and numeric codes, as upstream's `RemoteProviderService.extractErrorMessage` does. **Visible change:** cloud errors that carry a code now show it, e.g. "Incorrect API key provided (code: invalid_api_key)". Upstream's two tests run against Intel's function. |
| #3052 `a7859ba99` (part) | `ZoomMenuItems` owns the `ThemeManager` observation; the App struct observes nothing (upstream's warning comment is kept on it). |
| #3057 `ec654e8c5` (part) | `PluginSecretsStatus.anyAgentMissing` runs the per-agent keychain checks in a detached task. `PluginCard` and `PluginDetailView` await it instead of reading the keychain on the main thread on every appear. |

## Found while porting

- **Plugin stack drift (`W-plugin-reliability`).** Intel's `PluginManager`,
  `ExternalPlugin`, `ToolSecretsKeychain` and `OsaurusRepository` installer
  are compiled, so the 2026-09-29 missing-features sweep (which lists files
  Intel does not compile) never flagged that their contents lag upstream by
  months. Upstream #2061 (2026-07-17) is the clearest case: Intel's tool
  calls merge the Default agent's plugin secrets, but initial config delivery
  and the card's "missing secrets" check read only the exact agent.
  **Method gap:** future audits should diff any compiled file a commit
  touches against upstream, not just the commit's hunks, before calling the
  file current.
- **Menu bar gap (`W-app-menus`).** Intel's `osaurusApp.swift` is a trimmed
  entry point. Upstream's Schedules, Watchers, Agents, Voice Detection, Theme,
  Window and full Help menu items are missing and were not on the backlog.
- **macOS 13 note:** menu-item views that observe an object inside
  `Commands` (`ZoomMenuItems`) are a long-standing SwiftUI pattern on
  macOS 11+. Rosy checks that the zoom items still enable and disable.
- i18n: no new strings (the menu labels already exist; error text comes from
  the provider).

## Follow-up: `W-app-menus` shipped 2026-10-10

The Needs-work parts of #3052 (`VADToggleMenuItem`, `ThemeMenuItems`) and
#3054 (`LCached` submenu labels) shipped with the full menu bar port (see
`UPSTREAM_SYNC.md`, "App menu bar"). `ZoomMenuItems` was folded back into
upstream's `ThemeMenuItems`. Upstream moved on meanwhile: #3056 (`shell_run`
login-shell PATH) and #3059 (Qwen image bundles) are for the next audit,
which starts after `ec654e8c5`.

## Correction (2026-10-10)

"Plugin stack drift" above was partly wrong. `ExternalPlugin.swift` and the
first half of `PluginManager.swift` are wholly `#if !OSAURUS_INTEL`; Intel's
live plugin host is M9's `IntelPluginExecution`. Tool calls did **not** merge
Default-agent secrets: Intel injected no secrets at all, kept config in a
plaintext file, and stubbed upstream's secrets sheet. Fixed in
`W-plugin-reliability` stage 1. The method gap is wider than stated, too:
86 wholly gated files are invisible to the sweep (`W-gated-sweep`).

