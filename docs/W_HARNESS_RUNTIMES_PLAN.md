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

Divergences to keep: Intel's narrow subprocess environment
(`ClaudeCodeConfiguration.subprocessEnvironment`) applies to the live per-turn
path until stage 4 swaps it; the harness path uses upstream's environment
(login-shell PATH, inherited env minus `CLAUDECODE`, the bridge grant and
`ANTHROPIC_API_KEY`). **Decided 2026-11-26 (Renée): Intel's narrow environment**, plus what each
tool needs. (Was the owner question: harness chats then inherit whatever the Osaurus app process has, e.g.
`ANTHROPIC_BASE_URL`).

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
4. **App integration.** `AgentManager+Harness` (effective runtime, unsupported
   paths, `claude-code/*` migration), `ChatSession+Harness`, replace
   `IntelClaudeCodeService` routing in `CloudChatEngine` (coordinate with the
   Insights agent: avoid the usage / finish-reason code), agent token on the
   loopback MCP and API routes through Intel's HTTP handlers, remove the
   `claude-code/*` pseudo-models.
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
| 3 | Done, nothing calls it yet (see "Stage 3 notes") |
| 4-6 | Not started |

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
drain and #3293's effort and hidden tools are included). Nothing in the app
calls `HarnessSession` yet: the only callers are the tests, so no user can
start a harness process until stage 4 wires `Agent.runtime` into the chat.

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
- **Subprocess environment is injectable and still Intel's narrow one.**
  `HarnessProcess.defaultInheritedEnvironment` returns
  `ClaudeCodeConfiguration.subprocessEnvironment()` (PATH, HOME, USER, LOGNAME,
  TMPDIR, locale) and is the single place to flip to upstream's
  `ProcessInfo.processInfo.environment`. `HarnessSession(chatId:inheritedEnvironment:)`
  and `HarnessProcess.launch(_:inheritedEnvironment:)` take it as an input.
  Owner decision still open; needed before stage 4 (a narrow environment drops
  things a Pi wrapper may expect, e.g. provider API keys, `NVM_DIR`).
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
