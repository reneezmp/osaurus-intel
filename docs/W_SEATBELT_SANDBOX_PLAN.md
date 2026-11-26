# W-seatbelt-sandbox: plan and status

Backlog row: `INTEL_MISSING_FEATURES_BACKLOG.md`, `W-seatbelt-sandbox`.
Upstream reference: `upstream/classic` (0.25.x) `Services/Sandbox/Seatbelt/*`
and the Seatbelt branches of `SandboxManager`, `SandboxToolRegistrar`,
`BuiltinSandboxTools`, `SystemPromptTemplates` and `Views/Sandbox/SandboxView`.

## What this is, and what Intel already has

Two different things share the name "Seatbelt":

1. **Host shell confinement (already on Intel).** `Folder/ShellSandboxProfile.swift`
   wraps `shell_run` and `git_commit` in `sandbox-exec` with an allow-default
   profile that denies file writes outside the chosen folder and temp
   folders (`UPSTREAM_SYNC.md`, "`shell_run` at upstream"). It fails closed
   if `sandbox-exec` is missing.
2. **The sandbox tool family on Seatbelt (this item).** Upstream's
   `sandbox_exec`, `sandbox_read_file`, `sandbox_write_file`,
   `sandbox_search_files`, `sandbox_install`, background processes and
   sandbox plugins talk to `SandboxManager.exec`. On macOS before 26
   upstream's manager runs each command on the host under a
   **deny-default** profile (`SeatbeltSandbox.profile`) instead of the VM.
   An Intel Mac can never run the VM, so this is the only backend Intel can
   have. Intel's copies of `SandboxManager`, `BuiltinSandboxTools` and the
   registrar are an old snapshot excluded in `Package.swift`.

## Owner policy (hard rules for every stage)

- The sandbox may only make tools more restricted, never less. No silent
  widening of file or network access.
- Network access from sandboxed commands is **off by default on Intel**.
  Upstream defaults its per-agent `sandboxNetworkEnabled` to true and its
  global `SandboxConfiguration.network` to `"outbound"`. Intel must not copy
  those defaults. Network turns on only through an explicit per-agent
  setting the user sets. Intel's network keys stay out of declarative config
  until the stage that adds the setting.
- Seatbelt cannot enforce `allowed_domains` (upstream's filtering proxy is a
  vmnet construct). `NetworkPolicy.from(configNetwork:)` already maps
  `proxy` to denied; keep that. The setting is not offered on Intel.
- Every profile operation must exist on macOS 13 x86_64.
- Tool permissions and "Ask" still apply to every sandbox tool.
- Tests run sandboxed commands only on throwaway temp folders and never use
  the network.

## macOS 13 findings

The generated profile uses only these operations: `default`, `process-fork`,
`process-exec*`, `process-info*`, `signal (target same-sandbox)`,
`sysctl-read`, `file-read-metadata`, `file-ioctl`, `file-read*`,
`file-write*`, `network*`, `system-socket`. All are in Ventura's Seatbelt
operation set (the same ones Chromium, Bazel and Codex CLI use with
`sandbox-exec` on 13). `SeatbeltSandboxTests.profileUsesVenturaOperationsOnly`
pins that list so a new operation cannot slip in without review. The suite
runs on the build Mac (macOS 27), so the live behaviour on Ventura is only
confirmed by the manual steps in the stage 1 report.

Facts from upstream's profile that matter:

- No blanket `mach-lookup`, no home-folder read grant. Reads are limited to
  `/usr /bin /sbin /System /Library /private/etc /opt /dev`, the selected
  developer directory, and one xcrun cache file. Writes are limited to the
  workspace and a private scratch folder (`$TMPDIR/osaurus-seatbelt`).
- `SandboxBackend.current` is `.seatbelt` on every Intel build (adapted in
  stage 1; upstream resolves by OS version, which would pick the VM on an
  Intel Mac running macOS 26).

## Stages

| # | Stage | Status |
|---|-------|--------|
| 1 | **Seatbelt core, unwired.** `SeatbeltSandbox` (profile, backend enum, path mapper), `SeatbeltExecutor` (pipes, idle timeout, hard deadline, NUL check), Intel stand-ins for `Writer` and `SandboxError`. Tests. No behaviour change. | Done |
| 2 | **Host sandbox runtime.** A compiled Intel `SandboxManager` slice with upstream's `exec` / Seatbelt branch, workspace folders under `OsaurusPaths.containerWorkspace()`, per-agent homes, `SandboxLogBuffer`, availability cache (#3094, #3105), `SandboxError` merge. Default network denied. A confinement self-test (upstream's diagnostic: a write outside the workspace must fail). | Done (2026-11-26) |
| 3 | **Tools.** Compile the host-capable part of `BuiltinSandboxTools` (`sandbox_exec`, read, write, search, `sandbox_secret_set` with #2157 scrubbing), `SandboxToolRegistrar`, per-agent `AutonomousExecConfig` (`enabled`, `maxCommandsPerTurn`, `pluginCreate`, `backgroundProcessEnabled`), `ToolRegistry` wiring, permission "Ask", composer sections (`sandboxState`, `sandboxUnavailable`, `secretHandling`, `selfImprovement`, `pluginCreator`, `soul`). | Not started |
| 4 | **Background processes and plugins.** `sandbox_exec(background:true)`, `sandbox_process`, sandbox plugins on the host backend. Avoid `BackgroundTaskManager` and the spawn tools while `W-subagents` is open. | Not started |
| 5 | **UI and declarative config.** Seatbelt variant of the Sandbox page (`isSeatbelt` branches), per-agent switches in the agent editor including an explicit network switch that defaults off, `sandbox.*` keys in declarative config. Ventura rules apply. | Not started |

## Upstream items this row still owns

#3094, #3105 (cached availability), #2157 (secret scrubbing lands with
`sandbox_secret_set`), #2922's NUL check (done in stage 1: the executor
validates the process before launch), `OSAURUS_KEYCHAIN_FREE_SANDBOX`.

## Stage 1 notes (2026-11-26)

- Files: `Services/Sandbox/Seatbelt/SeatbeltSandbox.swift`,
  `SeatbeltExecutor.swift`; tests `Tests/Sandbox/SeatbeltSandboxTests.swift`,
  `SeatbeltExecutorProcessTests.swift`.
- Intel edits: `SandboxBackend.current` is `.seatbelt` under
  `OSAURUS_INTEL`; `SeatbeltOutputWriter` replaces Containerization's
  `Writer`; a four-case `SandboxError` is defined at top level. When stage 2
  compiles `SandboxManager`, merge its error enum into this one.
- Tests dropped from upstream's suite because they exercise VM-side code
  Intel does not compile: `firstOperationResolvesAvailability`, the two
  prompt-framing tests and the bridge-migration test. They return with stages
  2 and 3.
- Nothing calls the new code yet, so no file or network access changes.

## Stage 2 notes (2026-11-26)

- File: `Services/Sandbox/IntelSandboxManager.swift` defines Intel's compiled
  `actor SandboxManager` (upstream's `SandboxManager.swift` stays excluded: it
  is the VM stack). It holds only upstream's Seatbelt branches: cached
  availability (#3094, #3105), `provision`/`startContainer`/`stopContainer`/
  `removeContainer`/`resetContainer`, `exec`/`execAsRoot`/`execAsAgent`,
  `bootstrapAgent`/`ensureAgentUser`/`removeAgentUser` (host dirs under
  `OsaurusPaths.containerWorkspace()/agents/<name>`, mode 700, SOUL seeded
  once), `info()` and `runDiagnostics()`. The old no-op `enum SandboxManager`
  in `IntelSandboxManagerConformer.swift` is gone (that file keeps only the
  `UnavailabilityReason` stub). `SandboxError` gained `provisionFailed`,
  `removeFailed`, `userCreationFailed` (VM-only cases stay out).
- Intel adaptations: `exec` takes `networkEnabled: Bool = false`. Network is
  allowed only when that flag is true AND `sandbox.json` still says
  "outbound"; either denying wins, so upstream's "outbound" default cannot
  widen anything. Tees are `SeatbeltOutputWriter`. `removeContainer` never
  deletes the workspace folder. Agent names with `/`, `.`, `..` or empty are
  rejected. `startContainer` is a no-op after the user removed the sandbox.
- UI gate: `SandboxManager.publishesAvailabilityToUI` is `false`, so
  `State.shared.availability` stays unavailable and Onboarding / the agent
  editor / the chat chip behave as before (otherwise Onboarding would persist
  upstream's default sandbox config). Stage 3/5 flips it with the tools and UI.
- Confinement self-test (`runDiagnostics`): exec, workspace read/write, a
  write outside the workspace must fail, and a network probe that only
  connects to a loopback listener opened by the app itself (`nc -z`), so
  diagnostics never leave the Mac. With network off the connect must fail.
- Tests: `Tests/Sandbox/SandboxManagerHostTests.swift` (temp workspaces only;
  `SandboxManager(workspaceRoot:)` does not touch `State`, logs or
  `sandbox.json`). Nothing in the app calls the manager yet.
