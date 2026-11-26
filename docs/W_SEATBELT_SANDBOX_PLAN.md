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
| 3 | **Tools.** Host-capable slice of `BuiltinSandboxTools` as Intel files: `sandbox_exec` (foreground), `sandbox_read_file`, `sandbox_write_file`, `sandbox_search_files`, `sandbox_secret_check` (#2157 output scrubbing), per-agent `AutonomousExecConfig` (`enabled`, `maxCommandsPerTurn`, `sandboxNetworkEnabled`, `backgroundProcessEnabled`), `ToolRegistry` gating, permission "Ask" for write/exec, composer sections (environment, `sandboxState`, `sandboxUnavailable`, `secretHandling`, `soul`). `sandbox_secret_set` is written but not registered; `selfImprovement` / `pluginCreator` wait for stage 4. | Done (2026-11-26) |
| 4 | **Background processes and plugins.** `sandbox_exec(background:true)`, `sandbox_process`, sandbox plugins on the host backend (`sandbox_plugin_register`, plugin tools). Avoids `BackgroundTaskManager` and the spawn tools while `W-subagents` is open. | Done (2026-11-26) |
| 5 | **UI and declarative config.** Intel Sandbox page (`IntelSandboxView`, instead of upstream's VM `SandboxView` with `isSeatbelt` branches), per-agent switches in the agent editor (network and background processes default off), `sandbox.*` keys in declarative config with high-risk flags. Ventura rules apply. | Done (2026-11-26), except `sandbox_secret_set` (see notes) |

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

## Stage 3 notes (2026-11-26)

Files: `Tools/IntelSandboxTools.swift`, `Tools/IntelSandboxSecretTools.swift`,
`Tools/SecretScrubber.swift` (upstream's, verbatim),
`Services/Sandbox/IntelSandboxToolRegistrar.swift` (`SandboxToolGate`,
`SandboxToolRegistrar`), `Services/Chat/IntelSandboxPrompt.swift`; edits in
`Agent.swift`, `IntelManagerConformers.swift`, `IntelStubConformers.swift` (the
Intel `ToolRegistry`), `IntelDataConformers.swift` (composer, snapshot).
`Package.swift` now compiles `Services/Sandbox/SandboxSecurity.swift` (path
sanitizer, exec limiter). Tests: `Tests/Sandbox/IntelSandboxToolsTests.swift`
(real confined commands on temp workspaces).

**Who gets the sandbox.** Only a custom agent whose own
`autonomousExec.enabled` is true, on a Mac where `sandbox-exec` exists
(`SandboxToolGate.config(for:)`). Upstream resolves an unconfigured custom
agent to ON; Intel resolves it to off, and the Default agent never gets it.
There is no UI switch yet (stage 5), so today the only ways to opt in are
declarative config or an agent file that already says `enabled: true`.
`SandboxManager.publishesAvailabilityToUI` stays `false`, so Onboarding, the
agent editor and the chat chip behave as before.

**What changes for everyone else: nothing.** The tools are not even
registered until an opted-in agent first composes or sends. After that the
registry hides them from every agent that did not opt in
(`openAISpecs(for:)`, `openAISpecs(named:)`, `listTools()`), refuses their
execution (`runtimeCapabilityDenial`), and denies them to external surfaces
(`externallyDeniedHostToolNames`: MCP bridge, HTTP).

**What a sandboxed agent can and cannot do.**

- Tools: `sandbox_read_file`, `sandbox_search_files` (grep/find, not `rg`),
  `sandbox_secret_check` ask nothing; `sandbox_write_file` and `sandbox_exec`
  default to "Ask" (the user can set Auto per tool). Names and schemas follow
  upstream's classic `sandbox_*` vocabulary. Upstream's newer unified
  `file_*` / `shell_run` routing into the sandbox ("combined mode") is not
  ported; the Intel folder tools are unchanged and independent.
- Every file operation is a confined command, never an app-side read or
  write, so a symlink planted in the workspace cannot make the app touch
  anything outside. Paths must be under the agent home (`/workspace/agents/<id>`)
  or `/workspace/shared` (stricter than upstream: a sibling home such as
  `<home>-two` is rejected).
- Commands can read system tools and the workspace, and write only the
  workspace and the private scratch folder. They cannot read the user's home
  folder, and cannot write outside the workspace (both pinned by tests).
  The whole workspace is one writable root, so one sandboxed agent can still
  modify another agent's home; per-agent narrowing is a possible later
  restriction, not done.
- Network is off. It turns on only when the agent's own
  `sandboxNetworkEnabled` is true (default false; missing key decodes to
  false) AND the shared sandbox config allows it. A command that fails to
  resolve a host while the network is off gets a warning naming the setting.
- `sandbox_exec`: per-turn command cap (`maxCommandsPerTurn`, default 10),
  idle timeout (default 120 s, max 1800 s; the registry's 120 s wall clock is
  bypassed like upstream, so cancelling the run kills the process), output
  capped at ~50 KB head+tail, stored secrets injected as env vars and
  scrubbed from stdout/stderr by exact value.

**Deliberate differences from upstream.**

- `sandbox_secret_set` is not registered. Upstream's prompt path returns a
  marker that the chat view turns into a secure dialog; Intel's tool loop runs
  inside `CloudChatEngine`, which does not intercept it, so the marker would
  reach the model and nothing would be stored. The direct `value` argument is
  not offered at all (it would put a secret in the tool call, and Intel has
  not ported `SecretArgumentScrubber`'s recording-side redaction). The
  secret-handling prompt tells the model to ask the user to add the secret in
  the agent's settings. The tool, the real `SecretPromptParser` and
  `SecretToolResult` are in place for when the engine intercept lands
  (it is in code the unattended-approvals work owns).
- Prompt wording is Intel's own (`IntelSandboxPrompt`): upstream's blocks
  describe the Linux VM or the unified file tools. No `selfImprovement` or
  `pluginCreator` yet (they reference plugins, stage 4). The sandboxState
  section lists secret names only (no package manifest: no `sandbox_install`).
- SOUL.md is read from the agent home on every compose (capped at 8 KB);
  upstream freezes it per session. Edits therefore show on the next message.
- No file-history journalling for sandbox writes (the Intel registry's journal
  only knows the chat's folder root), no live terminal row / Terminate button
  (`LiveExecSink` is Containerization-only); the run's cancel button kills the
  process instead.
- `SandboxAgentProvisioner.linuxName` on Intel still returns a constant for
  the older callers (`share_artifact`, plugin host); the sandbox uses
  `SandboxToolRegistrar.hostAgentName` (upstream's real logic). Sharing a
  sandbox file with `share_artifact` is therefore not wired yet.

**Manual checks on Ventura** (profile behaviour on 13 is only confirmed by
hand; the suite runs on the build Mac): see the stage 3 report steps. Short
form: an opted-in agent runs `echo hi`; a write outside the workspace fails;
`ls ~` fails; `curl` fails with the network warning; an agent that did not opt
in shows no sandbox tool.

## Stage 4 notes (2026-11-26)

Files: `Services/Sandbox/IntelSandboxBackgroundJobs.swift` (job registry),
`SeatbeltExecutor.launchBackground` / `BackgroundProcess` (in
`Seatbelt/SeatbeltExecutor.swift`), `SandboxManager.execBackground`,
`Tools/IntelSandboxProcessTool.swift`, `Managers/Plugin/IntelSandboxPluginManager.swift`,
`Tools/IntelSandboxPluginRegisterTool.swift`; `Tools/SandboxPluginTool.swift`
is compiled again (upstream's current file, adapted); edits in
`IntelSandboxTools.swift` (`background` flag), `IntelStubConformers.swift`
(registry gates, plugin tool registration), `IntelSandboxPrompt.swift`,
`ChatView.completeRunCleanup`, `AppDelegate.applicationWillTerminate`.
Tests: `Tests/Sandbox/IntelSandboxBackgroundTests.swift`.

**Background jobs differ from upstream on purpose.** Upstream starts a job in
the Linux guest with `nohup setsid ... &` and probes it with `kill -0` and
`/proc`. macOS has no `setsid`, and a `kill` from a second `sandbox-exec`
cannot signal the first (Seatbelt's `signal (target same-sandbox)`), so the app
owns the process instead: `posix_spawn` of `sandbox-exec -p <profile> /bin/sh -c`
as the leader of its own process group (`POSIX_SPAWN_SETPGROUP`, and
`POSIX_SPAWN_CLOEXEC_DEFAULT` so no app file descriptor leaks into the child).
Poll, wait and kill go through the registry; kill signals the whole process
group. The job's output goes to `bg-<id>.log` in the agent home through a
redirect INSIDE the confined shell (`exec >log 2>&1`), so the app never opens a
path the sandbox could have swapped for a symlink; the log tail is read by a
confined `tail` and scrubbed of stored secrets.

**Owner-policy behaviour.**

- Same profile as a foreground exec: writes only in the workspace, no home
  read, network only if the agent's own `sandboxNetworkEnabled` AND the shared
  config allow it (default off).
- `background:true` and `sandbox_process` exist only for an agent whose own
  `backgroundProcessEnabled` is on (default off). The registry strips the
  `background` property from `sandbox_exec`'s schema for every other agent, and
  the tool refuses the flag anyway. `sandbox_process` only touches jobs this
  agent started: an arbitrary pid is "unknown", never signalled.
- Jobs stop when the run that started them ends (`ChatView.completeRunCleanup`,
  owner = chat session id), when the sandbox is stopped / reset / removed
  (`stopContainer`), at app quit (`applicationWillTerminate`, SIGKILL of every
  group), and after a one-hour lifetime ceiling. At most 4 run per agent.
- Not stopped by a run end: jobs started by a surface that is not the chat
  window (they have no owner; external surfaces are denied the sandbox tools, so
  only a schedule-style internal run could do this). They still die at the
  ceiling, on stop and at quit. A grandchild that starts its own session
  (`setsid`) escapes the group kill but is still confined by the profile.

**Plugins on the host backend.** An agent with `pluginCreate` writes
`plugins/<id>/plugin.json` (+ files) in its home and calls
`sandbox_plugin_register`. The manager validates (safe ids, no `..`, absolute
or odd file names, at most 64 files / 256 KB / 16 tools, no tool named like a
built-in), seeds the files and runs `setup` as confined commands (never an
app-side write into the workspace), under the agent's own network switch.
Differences from upstream:

- `plugin.json` and the other files are read by a confined `base64`; a symlinked
  `plugin.json` is refused and symlinked or hidden files are not packaged.
- System `dependencies` (apk) are refused with upstream's own message; `daemon`
  and `events` are accepted by the format but not run.
- Agent-created plugins get upstream's restricted defaults (network `none`, no
  inference). Plugin tools and `sandbox_plugin_register` default to "Ask".
- A plugin's tools are visible to, and runnable by, only the agent that
  installed it (`SandboxToolGate.allows`); the tool runs that agent's own copy
  of the plugin. A plugin can never shadow another tool
  (`canRegisterSandboxPluginTool`).
- No plugin library, no toast, no post-start repair pass, no HTTP bridge
  endpoint (`/api/plugin/create` stays excluded). The record is
  `agents/<id>/sandbox-plugins/installed.json` like upstream; an agent delete
  does not yet call `removeAgentState` (another stage-6 batch owns that path).
- The Intel default for `AutonomousExecConfig.pluginCreate` is now `false`.

## Stage 5 notes (2026-11-26)

Files: `Views/Sandbox/IntelSandboxView.swift` (the Sandbox page; the old
"Apple Silicon only" placeholder in `SandboxView.swift`'s Intel branch now
shows it), `Views/Agent/AgentsView.swift` (Sandbox tab and the Overview row),
`Views/Chat/FloatingInputCard.swift` (chip), `Models/Configuration/ManagementTab.swift`
(`.sandbox` is available on Intel), `SandboxManager.publishesAvailabilityToUI`
(now `true`); declarative config in `Configuration/Declarative/*`
(`OsaurusConfigDocument`, `ConfigManifest`, `ConfigPlanner`, `ConfigApplier`,
`ConfigExporter`, `ConfigRisk`). Tests: `Tests/Configuration/IntelSandboxConfigTests.swift`.
New strings are in the catalog (de, zh-Hans, ko, ru).

**Settings and defaults (all off).** Per agent, in the agent editor's Sandbox
tab (custom agents only; the Overview tab has the first switch too):
Autonomous Execution (`enabled`, off), then once it is on: Network Access
(`sandboxNetworkEnabled`, off), Background Processes
(`backgroundProcessEnabled`, off), Plugin Creation (`pluginCreate`, off; Intel
changed this default, upstream's is on). The page's own switch is the shared
master switch for the network (`sandbox.json` `network`, "outbound" = allowed,
"none" = never): a command reaches the network only if this master switch AND
the agent's own switch are on.

**Sandbox page** (Management > Sandbox): status with Start / Stop, the master
network switch, the running background processes with Stop / Stop All, the
confinement self-test (loopback only, never leaves the Mac), and a button for the
workspace folder. There is no provisioning journey, CPU / memory, image or
per-agent environment list: none of that exists under Seatbelt.

**Availability.** With `publishesAvailabilityToUI` on, the chat's sandbox chip
and the Sandbox tab appear for custom agents on a Mac that has `sandbox-exec`.
The chip is hidden for the Default agent (the gate never gives it the sandbox,
so its switch would do nothing). Onboarding saves the default `sandbox.json`
once (that is all it does with availability). A phone's
`autonomous_exec_enabled` patch (PhoneAgentEditing) is accepted now; it goes
through the same stored setting and the same gate.

**Declarative config (through `osaurus_config`, so through the planner and the
user's approval).** `agents[].sandbox` accepts `enabled`, `network_enabled`,
`allowed_domains`, `max_commands_per_turn`, `background_process_enabled`,
`plugin_create`. Differences from upstream: `allowed_domains` is rejected unless
empty (the macOS sandbox cannot filter by domain); upstream flags none of these
as risky, Intel flags each switch that turns something ON as a high-risk line
(`ConfigRisk.sandboxEnabled`, `sandboxNetwork`, `sandboxBackground`,
`sandboxPluginCreate`), which forces an explicit approval even under
always-allow. Turning something off, or leaving it out, is not a risk. The
exporter writes `network_enabled` and `background_process_enabled` (not
`allowed_domains`). Applying a change that switches the sandbox or Background
Processes off stops the agent's running background jobs
(`SandboxToolGate.enforcePolicy`, called from `AgentManager.update`).

**`sandbox_secret_set` stays unregistered.** Registering it needs the chat to
show a secure secret prompt when the tool returns its marker: upstream does it in
`ChatView` with `SecretPromptOverlay` and `PromptQueue`, which Intel does not
have; stage 5 did not add them. The user adds secrets in the agent's Sandbox tab
(the existing secrets list) and the prompt says so. When the overlay lands, add
`SandboxSecretSetTool` to `BuiltinSandboxTools.register()` and
`sandbox_secret_set` to the prompt's tool list.

## Hardening after stage 5 (2026-11-26)

- **App-side reads of the agent home never follow links.** The sandbox can write
  its own home, so a planted symlink could have put an outside file into the
  prompt. `IntelSandboxPrompt.soul` now reads SOUL.md through
  `readConfined`: `O_NOFOLLOW`, regular file only, the descriptor's real path
  (`F_GETPATH`) must equal `<real workspace>/agents/<name>/SOUL.md` (so a
  symlinked agent folder is refused too), names with `/` or `..` are refused,
  and at most 8 KB is read. Any new app-side read of a path in the workspace
  must use the same helper (or a confined command). Tests:
  `IntelSandboxSoulTests`.
- **Agent deletion** (`AgentManager.delete`) now stops that agent's background
  jobs and calls `SandboxPluginManager.removeAgentState(for:)` (its plugin record;
  the tools unregister when no other agent has the plugin). Other agents'
  records are untouched (tested).
