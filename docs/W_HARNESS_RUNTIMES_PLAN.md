# W-harness-runtimes: plan and status

Backlog row: `W-harness-runtimes` in `INTEL_MISSING_FEATURES_BACKLOG.md`.
Upstream source: Classic `upstream/classic`, commits #3175 (`993c12f8e`), #3180
(`0f7a4ed83`), the Classic follow-ups #3210 (stderr drain), #3229 (thinking
display), #3293 (`81d047dfb`, hidden tools and the effort picker). Never port
from 1.x `upstream/main`. Upstream's contract for harness authors is
`docs/HARNESS_RUNTIMES.md` on `upstream/classic` (`git show
upstream/classic:docs/HARNESS_RUNTIMES.md`); read it before stage 3.

## Owner policy (hard rules for every stage)

- A harness runtime launches a local process (Claude Code CLI, Pi). It must
  never start unless the user chose that runtime for an agent.
- Detection only looks (resolve the command on the login-shell PATH, read the
  file header, run `--version` / `auth status` for Claude Code on the Test
  button). Nothing is downloaded or installed automatically. Any install offer
  stays a user action with its existing confirmation (Intel has none today).
- Secrets never go on a command line or into a log. The agent token and the
  system prompt travel by environment and 0600 file, as upstream does.
- The agent's tool permissions and "Ask" still apply; the agent token adds no
  rights. No change to network exposure (the token is honoured on loopback
  only).
- Nothing spends money without a user action (a Claude Code run uses the
  user's own signed-in subscription; the chosen runtime is the user's action).
- Tests never launch a real external process, never use the network, the
  keychain or `~/.osaurus`.

## How upstream's runtimes map onto Intel's Claude Code integration

Decision (follow upstream): **upstream's harness runtime replaces Intel's own
Claude Code path; Intel's pieces that upstream also has are kept as the shared
parts.** Evidence, from reading both sides:

| Piece | Intel today | Upstream Classic | Mapping |
|---|---|---|---|
| Selection | Fake models `claude-code/<alias>` in the model list (`IntelManagerConformers.swift` ~1287, only when `claude` resolves), routed by `IntelClaudeCodeService.handles` from `CloudChatEngine` (~1421, ~3469) | Per-agent `Agent.runtime = .harness(<runtime id>)`; models are a column in the picker | Stage 4 moves selection to `Agent.runtime`; migrate `claude-code/*` agents as upstream does (alias becomes `ClaudeCodeAgentConfig.model`) |
| Process | One `claude -p` per turn, `--no-session-persistence`, transcript re-rendered into the prompt (`IntelClaudeCodeService.renderPrompt`, `ClaudeCodeProcessRunner.stream`) | One long-lived process per chat (`HarnessProcess`, `HarnessSession`), only the newest message is sent, `--resume <chat id>` | Replace in stage 3 and 4; `ClaudeCodeProcessRunner.capture` stays for the control commands |
| Per-agent options | `Agent.claudeCode: ClaudeCodeAgentConfig` (mode, allowWrites, allowShell, allowOsaurusTools, allowOsaurusConfigWrites, effort); effort and `--disallowedTools` already ported (#3293 CLI part) | Same struct plus `model` | Same struct, `model` added in stage 1. Already compatible |
| Stream decoding | `ClaudeCodeStreamDecoder` (shared file) | Same file; `control_request` answering added later in 1.x | Kept; stage 3 checks the `control_request` stall question (`UPSTREAM_AUDIT_2026-11-11` §29) |
| Osaurus tools for Claude Code | Per-turn `--mcp-config` + `OSAURUS_MCP_BRIDGE_GRANT` from `ClaudeCodeBridgeGrantStore`-style grants | `HarnessGrantStore` tokens (`OSAURUS_AGENT_TOKEN`, loopback only, tool scope) | Stage 4, on Intel's own HTTP handlers (`IntelHTTP*`), no exposure change |
| Settings | Claude Code setup step (`ClaudeCodeSetupStep`), agent editor Claude Code options | Settings > Agent Runtimes (`AgentRuntimesView`), editor "Runtime" row | Stage 5 |
| Config documents | `AgentClaudeCodeEntry` (`claude_code`) in `ConfigHarnessSections.swift`; the `runtime` / `harness_runtimes` keys were left out | `ConfigHarnessSections`, planner/applier lines | Stage 6 |
| Bundles | Runtimes left out of `PendingImportProcessor` | `harness_runtimes` in `osaurus-bundle.json` | Stage 6 |

Divergences to keep: **Intel's narrow subprocess environment, decided
2026-11-26 (Renée).** A harness process (chat, Test button, Pi probe) inherits
only `ClaudeCodeConfiguration.subprocessEnvironment` (PATH, HOME, USER, LOGNAME,
TMPDIR, LANG, LC_ALL, LC_CTYPE), where upstream inherits the whole app
environment (so `ANTHROPIC_BASE_URL`, proxies, cloud keys, `NVM_DIR`,
`CLAUDE_CONFIG_DIR` never reach the child). On top of that, and nothing else:
the login-shell PATH, the runtime's own `environment` overlay (user-set, per
runtime), and the `OSAURUS_*` contract. A runtime that needs a variable (a Pi
wrapper's provider key, a custom `CLAUDE_CONFIG_DIR`) gets it from that overlay
(Settings > Agent Runtimes arrives with stage 5).

## x86_64 / macOS 13 findings per runtime

| Runtime | Binary | Intel (x86_64, Ventura) |
|---|---|---|
| Claude Code | `claude`: Anthropic ships a native build per CPU (darwin x64 exists) or an npm package (a node script, `#!/usr/bin/env node`). The native installer lists macOS 13+ as its floor (recollection of Anthropic's docs; not verified on Rosy, check with Rosy QA) | Works when it is the x64 build or the npm script. An arm64-only `claude` copied from an Apple silicon Mac is **Incompatible** (no Rosetta on Intel). Detection reads the Mach-O header (stage 2) and refuses before spawning |
| Pi (RPC) | `pi`: an npm package (node script). Compiled releases, if any, must carry an x86_64 slice | Script: fine, node's own architecture decides. Mach-O: same header check. Not verified on Rosy |
| User-added runtime | Anything the user registers | Same header check; scripts are assumed fine |

`ExecutableLocator.searchPath` and `LoginShellPath` already exist on Intel and
match upstream, so PATH detection (nvm, mise, Homebrew `/usr/local/bin`) needs
no port.

## Stages

1. **Runtime model and registry** (done in this branch). `HarnessKind`,
   `HarnessRuntime`, `HarnessArgumentPlaceholder`, `AgentRuntime`,
   `HarnessRuntimeStore` (`~/.osaurus/config/harness-runtimes.json`, Claude Code
   seeded once on first load), `Agent.runtime` and
   `ClaudeCodeAgentConfig.model` as inert persisted fields, with upstream's
   model and store tests. Nothing launches; nothing reads `Agent.runtime` yet.
2. **Detection** (done in this branch). `HarnessBinaryArchitecture`
   (Mach-O header check, Incompatible verdict), `HarnessControlCommand` (resolve
   with the chat environment), `HarnessEnvironment` constants,
   `ClaudeCodeConfiguration.setupState(command:overlay:)` and friends,
   `HarnessRuntimeProbe` for Claude Code (`claude auth status`) and a
   detection-only Pi probe. No process is spawned by tests (fake runners).
3. **Process and session core** (done in this branch, see Status).
   `HarnessProcess` (pipe reader, framing, stderr
   drain #3210, escalating shutdown, `HarnessProcessRegistry` wired into app
   quit), `HarnessError`, `HarnessAdapter` / codec, `ClaudeCodeHarnessAdapter`,
   `PiRPCAdapter` + `Resources/Harness/osaurus-pi-extension.ts`,
   `HarnessSession`, `HarnessTurnDriver`, `HarnessGrantStore`. Tests with
   upstream's fake adapters; upstream's `HarnessLiveTests` (real process) is not
   ported. The Pi probe becomes the real `get_state` probe. Launch refuses an
   Incompatible binary with a clear error.
4. **App integration** (4a and 4b done in this branch, see "Stage 4 notes" and "Stage 4b notes").
   `AgentManager+Harness` (effective runtime, unsupported paths,
   `claude-code/*` migration), `ChatSession+Harness`, `IntelClaudeCodeService`
   and its `CloudChatEngine` routing removed, the `claude-code/*`
   pseudo-models removed. 4b: agent token on the loopback MCP and API routes
   through Intel's HTTP handlers (`Networking/`).
5. **UI.** Settings > Agent Runtimes (`AgentRuntimesView`), picker columns
   (`ChatHarnessPickerOption`, #3180), composer controls, agent editor Runtime
   section, effort picker (#3293), onboarding step, settings search entries,
   guide topics. Ventura rules; `L()` strings and the i18n scripts.
6. **Config and bundles.** `harness_runtimes` and `runtime` in the declarative
   schema, planner / applier lines (high-risk lines need approval),
   `default_agent.claude_code` / `runtime`, `harness_runtimes` in bundles and
   `PendingImportProcessor`, sample documents, `HARNESS_RUNTIMES.md`.

## Status

| Stage | State |
|---|---|
| 1 | Done (see the commit "Port #3175 (stage 1)") |
| 2 | Done (see the commit "Port #3175 (stage 2)") |
| 3 | Done (see "Stage 3 notes") |
| 4a | Done: chat runs on the harness, migration, narrow environment (see "Stage 4 notes") |
| 4b | Done (2026-11-27, see "Stage 4b notes"): agent-token gate and `/mcp/*`, `/agents/{id}/run` refusal, spawn targets, built-in-loop tool refusal |
| 5-6 | Not started |

## Facts learned

- Since 2026-11-27 a `claude-code/…` model is never the automatic default
  (`Array.automaticDefault`, `ChatSession.needsModelChoice`). Stage 4a removes
  those model ids, so stage 4a/5 must keep the rule for `Agent.runtime` and the
  harness picker: the subscription runs only when the user chose it.
- Upstream Classic's harness code is 11 files (~3.7k lines) in
  `Services/Harness`; `ClaudeCodeConfiguration` was rewritten and
  `ClaudeCodeService` / `ClaudeCodeBridgeGrantStore` deleted by #3175. Intel's
  copy of `ClaudeCodeConfiguration` is still the pre-#3175 shape plus later
  Classic fixes, so stage 3 and 4 must edit it, not overwrite it.
- Intel already has `ClaudeCodeEffort`, `ClaudeCodeAgentConfig.effort`,
  `--disallowedTools` and the `toolDenied` decoder case (#3293 CLI part); only
  the picker row is missing.
- `ConfigHarnessSections.swift` (`claude_code` entries) already exists on
  Intel; only `harness_runtimes` and `runtime` are missing.
- Adding `ClaudeCodeAgentConfig.model` / `resolvedModel` is inert until stage 4.
  `Agent.runtime` encodes only when set, so agents written by this build stay
  readable by the previous one.

## Stage 3 notes (process and session core)

Ported from Classic's final state of `Services/Harness` (so #3210's stderr
drain and #3293's effort and hidden tools are included). Stage 3 added no
caller; stage 4 wires `Agent.runtime` into the chat.

- **Files.** `HarnessProcess` (with `HarnessLineFramer`,
  `HarnessProcessRegistry`, `HarnessDrainGate`), `HarnessError`,
  `HarnessAdapter` (events, codec protocol, `HarnessEnvironment.contract`),
  `ClaudeCodeHarnessAdapter` (+ `ClaudeCodeSessionLocator`, `HarnessScratch`),
  `PiRPCAdapter` (+ `PiRPCCodec`), `HarnessSession` /
  `HarnessSessionManager`, `HarnessTurnDriver`, `HarnessGrantStore`. The Pi
  probe is now the real `get_state` round trip (`HarnessRuntimeProbe.probePi`,
  injectable as `Dependencies.piState`).
- **Launch is gated by construction.** The only path to a process is
  `HarnessSession.send` -> `HarnessProcess.launch`; stage 3 adds no caller.
  `HarnessProcess.init` also refuses an Incompatible (arm64-only) binary
  before spawning, with the Test button's message (`launchFailed`).
- **Secrets.** The agent token is minted per process
  (`HarnessGrantStore.mint`, `HarnessSession.launch`), handed to the child only
  in its environment (`OSAURUS_AGENT_TOKEN`, `OSAURUS_MCP_BRIDGE_GRANT`) and,
  for Claude Code, inside the 0600 `--mcp-config` file's server `env`. The
  system prompt goes through a 0600 file (`--append-system-prompt-file`),
  written in `harness/.private/<chat id>/` (0700), beside the scratch cwd. No
  secret is on a command line or in a log (the grant store logs agent ids
  only). Revoked when the process exits, the session closes or the app quits.
- **Subprocess environment is injectable and Intel's narrow one (decided
  2026-11-26).** `HarnessProcess.defaultInheritedEnvironment` returns
  `ClaudeCodeConfiguration.subprocessEnvironment()` and is the single place the
  choice lives. `HarnessSession(chatId:inheritedEnvironment:)` and
  `HarnessProcess.launch(_:inheritedEnvironment:)` take it as an input.
- **Registry.** `ClaudeCodeProcessRegistry` (actor) is gone; the one-shot
  Claude Code runs and every harness child register with
  `HarnessProcessRegistry.shared`, and `AppDelegate` quit calls its
  `terminateAll()`. `HarnessSessionManager.closeAll()` is not wired into quit
  yet (stage 4 with the chat).
- **Tool names follow upstream.** `ClaudeCodeConfiguration` now lists
  `osaurus_inspect` / `osaurus_help` (+ `osaurus_config` behind its own
  opt-in) like #3175. Intel's list still named the older `osaurus_status` /
  `osaurus_list` tools, which are not what a custom agent's token reaches. The system note
  mentions "Allow Osaurus read tools" in the agent's Claude Code Options; that
  UI label arrives with stage 5.
- **Intel adaptations.** `ClaudeCodeAgentConfig` is `Hashable` (launch
  fingerprint). `HarnessGrantStore` names the four built-in-loop tools by
  string, as `SubagentCapabilityRegistry` does, and checks a custom agent's
  `toolsEnabled` directly because Intel has no `effectiveCapabilities`.
- **Not ported.** `HarnessLiveTests` (real `claude` / `pi`). The plan listed
  `Resources/Harness/osaurus-pi-extension.ts`, but it does not exist on
  `upstream/classic` (`git grep osaurus-pi-extension upstream/classic` is
  empty); nothing to port. The `control_request` stall question
  (`UPSTREAM_AUDIT` section 29) is untouched: the harness decoder handles no
  `control_request` records, same as Classic.
- **Tests.** `HarnessPlumbingTests`, `HarnessSessionLifecycleTests`,
  `ClaudeCodeHarnessAdapterTests`, `PiRPCCodecTests` as upstream. The lifecycle
  and Pi-probe suites run a hermetic `/bin/sh` fake harness script from a
  temporary folder (never `claude` or `pi`, no network, keychain or
  `~/.osaurus`); the registry test kills only that script.

## Stage 4b notes (HTTP, spawn, built-in-loop tools; 2026-11-27)

- **Rule kept after 4a removed the `claude-code/*` models.** The 2026-11-27
  fix `83bf7264c` (`ModelPickerItem.isClaudeCode`, `Array.automaticDefault`,
  `ChatSession.needsModelChoice`, the send guard and the `FloatingInputCard`
  picker opener) existed only because those rows could be picked
  automatically. With no such rows it was dead, so it was reverted
  (`git revert` of that commit applied cleanly onto 4a; its tests and the one
  catalog string went with it). The rule now lives in the data model: only
  `Agent.runtime` / `DefaultAgentConfiguration.runtime` start a harness, they
  are nil for new agents, and nothing but the user's choice (the onboarding
  Claude Code step, the future stage 5 picker) or the migration writes them.
  Test: `HarnessAppIntegrationTests` `aHarnessRuntimeIsNeverTheDefaultOrAFallback`.
  Leftover dead guards `!item.id.hasPrefix("claude-code/")` remain in
  `OsaurusInspectTool`, `IntelSpawnAdmission`, `IntelOrchestratorDelegationTool`,
  `OrchestratorDelegationSheet`, `SpawnConfigurationEditor` (harmless; left to
  avoid conflicts with parallel work in `Subagent/` and the views).
- **Migration only moves what the user saved.** The chat picker selection is
  session-local (`ChatSession` init comment, 2026-09-13) and auto-selection runs
  under `isLoadingModel`, so it never writes `Agent.defaultModel` or the global
  `ChatConfiguration.defaultModel`. The only writers of those fields are
  explicit: Agent editor / Orchestrator settings, `/agents` HTTP, the
  declarative config applier, and onboarding (user's brain choice). A
  `claude-code/*` value in those fields is therefore a saved choice. Per-chat
  saved models in chat session files are not migrated (a stale id falls
  through to the normal default, which is never a harness).
- **HTTP auth gate** (`HTTPHandler.admit`): after the browser guard and before
  the access-key gate, a live token (bridge header or `Bearer osh_...`) over
  PHYSICAL loopback binds `RequestState.harnessGrant` and skips the key
  gate, as upstream: it passes whether or not loopback trust is on and whether
  or not "Require an access key for local apps" is on. Routes outside
  `HarnessGrantStore.allowedRoutes` get 403 `harness_token_scope`. The browser
  guard (unlisted Origin, cross-site / same-site fetch metadata, foreign Host)
  runs BEFORE the token block, so a token cannot bypass it. Relay-origin
  requests are never physical loopback, so they get no grant.
- **`/mcp/*`** (`IntelHTTPMCP`): `/mcp/tools` is narrowed to
  `HarnessGrantStore.agentPolicyAllows` for the token's agent; a presented but
  dead token gets 401 (list) / `rejected` envelope (call), never the unscoped
  loopback catalog; `/mcp/call` refuses tools outside the token's scope and
  built-in-loop tools (`computer_use`, `browser_use`, `applescript`,
  `mac_query`) with `HarnessError.unsupportedPath` when the agent is on a
  harness, and otherwise binds `currentAgentId` and the new
  `ChatExecutionContext.harnessTokenAgentId` while the call stays an external
  surface (Ask tools still refused). **Intel difference:** the bridge header is
  resolved in the handlers only for physical-loopback callers (upstream
  resolved it for any caller that passed the gate).
  `harnessTokenAgentId` has no reader on Intel yet: upstream uses it to let
  custom harness agents call `osaurus_help` / `osaurus_inspect` through
  `ConfigurationToolBase`; Intel's `osaurus_config` gate stays Default-agent
  only, and Intel's help / inspect tools carry no such gate.
- **Computer Use / AppleScript.** Computer Use is already on Intel's external
  deny list (`externallyDeniedHostToolNames`), so `/mcp/call` answers
  `tool_not_exposable` before the harness check; AppleScript, Browser and Mac
  Query get the typed harness refusal. No Computer Use view or setting was
  touched.
- **`/agents/{id}/run`** (`IntelHTTPAgentRun`) refuses a harness agent (also
  a runtime id that no longer resolves) with the typed message before any
  model is resolved. **Spawn:** `IntelSpawnAdmission.resolveTargets` marks a
  pool member on a harness `SpawnTargetState.harness` (not runnable);
  Intel has no `SpawnDescriptors` source struct, so upstream's `runsOnHarness`
  field has no equivalent beyond that.
- **Test pitfalls found.** `HTTPServerTestLock` is not re-entrant: shut one
  test server down before starting another in the same test. A `@MainActor`
  test must not block on a raw socket read: the handler hops to the main actor
  and the read times out (run it in `Task.detached`).
- **Tests.** `HarnessTokenHTTPTests` (token alone with and without loopback
  trust, the local-key switch on and off, route confinement, revoked / tampered
  tokens, relay marker, browser guard with a token (Origin, fetch metadata,
  foreign Host), no added rights (Auto runs attributed, Ask refused, out-of-scope
  refused, spawn / loop-only tools refused), AppleScript-family refusal for a
  harness agent, spawn targets), `IntelHTTPAgentRunTests`
  `run_refusesAnAgentOnAHarnessRuntime`. Stage 5 needs: nothing from 4b beyond
  the picker; the dead `claude-code/` prefix guards can go whenever convenient.

## Stage 4 notes (app integration, 4a)

Ported from #3175's app-side changes on `upstream/classic`. After this stage an
agent whose runtime the user chose runs its chat turns in its harness process;
nothing launches for any other agent.

- **Chat.** `ChatSession.send` resolves `harnessSelection` at send time and, for
  a harness agent, calls `ChatSession.runHarnessTurn` (new file
  `Views/Chat/ChatSession+Harness.swift`) before the media and built-in paths:
  `HarnessTurnDriver.launchContext` -> `HarnessSessionManager.session(for: chat id)`
  -> `send`. Text, thinking, stats, notices and questions (clarify overlay) render
  as upstream. A missing runtime (deleted) fails the turn with
  `HarnessError.runtimeMissing`. Built-in-only behaviour is skipped for harness
  agents: manual compaction (`compactConversation`), title and follow-up model
  fallback (`auxiliaryChatModel` is nil), the reasoning validation in the
  composer. The harness process closes when the chat's session id changes, its
  tab or window closes (`teardownTabSession`, `cleanup`,
  `prepareForSessionDeletion`) or the chat is deleted
  (`ChatSessionsManager.delete`).
- **Intel adaptation: tool steps are a status chip, not cards.** Intel's `ChatTurn`
  has no remote tool activity (upstream #1636 / #2848). `toolStarted` sets
  `pendingToolName`, `toolFinished` clears it; a refused tool leaves no card
  (same as the old per-turn path). Port the card display with that feature.
- **Runtime selection.** `AgentManager+Harness`: `effectiveRuntime`,
  `effectiveHarness` (`.resolved` / `.missing`), `harnessUnsupportedError`,
  `updateRuntime` (closes idle sessions). `DefaultAgentConfiguration` gained
  `claudeCode` and `runtime` (encoded only when set), and
  `effectiveClaudeCodeConfig` / `updateClaudeCodeConfig` now cover the Default
  agent (it had no own Claude Code settings on Intel).
- **Migration of existing Claude Code agents** (runs at every launch, no flag, in
  `AgentManager.init`, tested in `HarnessAppIntegrationTests`). An agent whose
  effective model (own, else the global one, else the Orchestrator's) is
  `claude-code/<alias>` gets `runtime = .harness(Claude Code runtime id)` and
  `claudeCode.model = <alias>`; its dead model id is cleared; an agent that
  already has a runtime keeps it. The Claude Code runtime is seeded only if an
  agent actually moves. The global `claude-code/*` default is cleared. **Intel
  difference:** the Default agent also moves when it only inherits the global
  `claude-code/*` model (upstream moved it only for its own). The migration
  starts no process; the agent's tool permissions (`claudeCode` options) carry
  over unchanged.
- **Removed.** `IntelClaudeCodeService` (per-turn `claude -p`, prompt
  re-rendering), its `CloudChatEngine` routing, the `claude-code/<alias>` picker
  rows, and `ClaudeCodeProcessRunner.stream` (only `capture` for the control
  commands, the pipe pump and the terminator remain). External API callers that
  asked for model `claude-code/sonnet` now get "no endpoint for model". The
  service's tests went with it; the config, decoder and argument tests stay.
- **Narrow environment.** Besides the chat process, the Test button and setup
  probe (`HarnessControlCommand.resolve` / `searchedPath`) now use the same
  narrow inherited environment, so a passing Test means a chat can launch. The
  resume lookup (`ClaudeCodeSessionLocator.configDirectory`) reads
  `CLAUDE_CONFIG_DIR` only from the runtime's own environment: upstream also
  read the app's value, which the narrow child never receives.
- **Onboarding.** The Claude Code step ensures the runtime, sets
  `claudeCode.model = sonnet` and `updateRuntime(.harness(id))` for the agents
  (upstream's hunk). `AgentsView` saves `runtime` through unchanged (the editor
  rebuilt the whole `Agent` and would have dropped it), and its Claude Code
  options explain themselves when the agent is not on the runtime.
- **`spawn_agent`** refuses a harness agent (`SpawnAgentTool`, like upstream).
- **(Was open, done in 4b, see "Stage 4b notes"; blocked on another agent in `Networking/` and
  `Subagent/` (2026-11-26):** (1) the HTTP auth gate and `/mcp/*` handlers
  honour `X-Osaurus-Bridge-Grant` / `Authorization: Bearer osh_...` through
  `HarnessGrantStore` (upstream `HTTPHandler.harnessGrant`, `resolvedHarnessGrant`,
  `ChatExecutionContext.harnessTokenAgentId`). Until then the grant is ignored
  and the harness's Osaurus tools reach `/mcp/call` as an unattributed
  loopback caller: no agent identity, `.ask` tools refused, nothing widened. (2)
  `harnessUnsupportedError` on `/agents/{id}/run` (`IntelHTTPAgentRun`), and
  `runsOnHarness` in `SpawnDescriptors` (`Subagent/`). (3) Computer Use and
  AppleScript do not refuse harness agents yet.
- **Not shippable without stage 5.** There is no picker or editor row to choose a
  runtime yet; today only the onboarding Claude Code step and the migration set
  one. Do not ship 4a alone to testers without those (the `claude-code/*`
  models are gone).
- **Tests.** `HarnessAppIntegrationTests`: migration (custom agents, Default
  agent own and inherited, idempotence, backup restore, explicit runtime wins),
  `updateRuntime`, Default-agent persistence (old files decode, nil is not
  written), a real `ChatSession` turn against a throwaway `/bin/sh` fake harness
  in a temp folder (no built-in loop, the exact environment names), a deleted
  runtime failing the turn, and the narrow-environment policy.

**Where stage 4a stopped (2026-11-26, coordinator paused the round).** Code and
tests are committed. Filtered gate (`Harness|ClaudeCode|ChatSession|IntelChat|
IntelVenturaControlGuard|AgentRuntime|Spawn`): 382 tests in 61 suites passed;
`bash scripts/i18n/check.sh` passes. **Not run:** the full suite
(`gate_pty.sh`) and the broader filter with `Runtime|Agent|ChatEngine` (a first
run died on a test-compile error in the new test file, fixed). Not built or run
in the app. Next: run the full suite, then 4b (Networking/Subagent hooks above),
then stage 5 (UI to choose a runtime; without it 4a must not reach testers).
A found-by-test note: Intel's automatic chat title falls back to a hard-coded
cloud model (`deepseek-flash`); a harness chat without a configured core model
now keeps the first-line title instead of sending the chat there.

