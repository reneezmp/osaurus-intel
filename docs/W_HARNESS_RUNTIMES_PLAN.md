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
`ANTHROPIC_API_KEY`). Decide at stage 4 whether to narrow it further (owner
question: harness chats then inherit whatever the Osaurus app process has, e.g.
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
3. **Process and session core.** `HarnessProcess` (pipe reader, framing, stderr
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
| 3-6 | Not started |

## Facts learned

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
