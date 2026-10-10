# Upstream audit and port — 2026-10-08

**Range:** `66ea7ebc4..02604ca60` on `osaurus-ai/osaurus/main` (upstream
0.25.20), fetched 2026-10-08. **14 commits (no merges), 14 classified.**
Verdicts follow the rule in
[`UPSTREAM_SYNC.md`](UPSTREAM_SYNC.md#verdict-rule-doesnt-apply-is-not-a-verdict--2026-09-29):
Incompatible only for Apple Silicon (MLX/Metal local inference) or
upstream-only artifacts; "Intel doesn't have X yet" is **Needs work** with X
named on the backlog. The next review begins at `02604ca60` (exclusive).

## Classification

| # | Commit | Verdict | Intel note |
|---:|---|---|---|
| 1 | `3e596da00` #3029 | **Incompatible** | Bundle-aware speculative decoding defaults (MTP / DFlash) before local model load: MLX runtime and its settings rows. |
| 2 | `672db10f1` #3041 | Covered (net no-op) | Moved the agent action bar into an Actions tab; #3045 reverted it the same day. The pair leaves the files byte-identical. |
| 3 | `8243d528d` #3034 | **Split:** Port + **Needs work** (`W-channels`) | Longer and tilde code fences, labelled prose fences render as code. Intel's Markdown files matched upstream, so the patch applied cleanly; upstream's `CodeFenceParsingTests` came along. The channel-message formatter half waits for channels. |
| 4 | `f2b087c34` #3043 | **Incompatible** | RAM estimates for local MLX bundles exclude the SSD-resident n-gram table. |
| 5 | `88173d750` #3038 | **Port** | Host (stdio) MCP servers see version-manager toolchains (mise, nvm, asdf, fnm, Volta) through the login-shell PATH. |
| 6 | `da1aa6e2e` #3045 | Covered (net no-op) | Revert of #3041. |
| 7 | `10e66ca5c` #3042 | **Port** (adapted) | Compaction asks for reasoning off and refuses a summary cut at the output limit; "reasoning off" reaches each host in the form it reads. |
| 8 | `86ed14d91` #3033 | **Not a user feature** (`N-dev-tooling`; reclassified 2026-10-10 from Needs work: `CapabilityClaimsEvaluator` only drives the OsaurusEvals harness) | Judge polarity and ScreenContext rubric for grounded claim checks. Intel's `CapabilityClaimsEvaluator` is an older, unwired copy; it lands with the grounded-claim-checks item. Eval suite files ride along. |
| 9 | `145de994c` #3046 | **Incompatible** | `vmlx-swift` pin (tool-stream and K2 runtime fixes). |
| 10 | `7f24ca02f` #3044 | **Needs work** (`W-workspaces-identity-mobile`) | Phone secure channel and pairing hardening, phone image generation. |
| 11 | `19271bb14` #3040 | **Split:** Port + **Incompatible** | Port: a pasted image the model can't take now explains why, and the paste monitor acts only in its own focused composer. Incompatible: the local-bundle reason text (MLX vision bundles). |
| 12 | `29ecea602` #3039 | **Port** | `calculate` built-in tool for exact math. |
| 13 | `41cc89e8e` #3048 | Covered | `file_edit` with `new_string: ""` was dropped by upstream's schema coercion. Intel's registry passes arguments straight to the tool (no coercion), so deletes already worked; a regression test is added. |
| 14 | `02604ca60` | **Incompatible** | Upstream's own appcast (0.25.20). |

**Totals:** Port 3 · Split (with a Port part) 2 · Covered 3 · Needs work 2 ·
Incompatible 4.

## Shipped on Intel (awaiting Rosy)

| Upstream | What Intel got |
|---|---|
| #3034 `8243d528d` (part) | Code fences with more than three backticks or tildes close correctly; a fenced block labelled with a prose language renders as code, a bare fence stays prose. |
| #3038 `88173d750` | `LoginShellPath` resolves the login-shell PATH once, off the main thread, prewarmed at launch; stdio MCP servers get it in their environment and in the executable search, so `npx` / `uvx` from mise, nvm or asdf are found and their `#!/usr/bin/env node` scripts run. **Also:** Intel's stdio transport was an older copy; it is now upstream's, which brings `~` expansion in commands and working directories and upstream's `MCPChildSpawnLimiter` (at most 32 live MCP child processes), both previously on the `W-mcp-providers` backlog. |
| #3042 `10e66ca5c` (adapted) | Compaction asks for reasoning off explicitly and refuses a summary cut at the output limit ("… nothing was replaced"). "Reasoning off" now goes out in the form each host reads: `thinking: disabled` for DeepSeek, `chat_template_kwargs.enable_thinking: false` for self-hosted OpenAI-compatible servers (vLLM, SGLang, llama.cpp, LM Studio), nothing for strict hosted schemas (OpenAI, Mistral, Groq, OpenRouter, …) and other API families. **Before this, Intel sent DeepSeek's `thinking` field to every non-Codex endpoint**, which strict hosts reject and self-hosted servers ignore. **Intel differences:** the built-in DeepSeek path and DeepSeek hosts keep `thinking: disabled` for every model (upstream: DSV4 models only), and the Osaurus Router keeps it (upstream sends nothing there; changing it could turn reasoning back on for Router models). Intel's direct `reasoning_effort` handling is unchanged. |
| #3040 `19271bb14` (part) | Cmd+V of an image into a chat whose model can't take images shows "Cannot attach image — The current model is text-only" instead of silently dropping it. The paste monitor now acts only when its own composer has keyboard focus; before, every open composer reacted to Cmd+V in any window. |
| #3039 `29ecea602` | `calculate`: one plain-text expression evaluated exactly (operators, percentages, factorial, hex/bin/oct, variables, one-unknown equations). Offered with the agent-loop tools like `get_current_time`. **Intel:** no spawnable flag (no native subagents, `W-subagents`). Upstream's `CalculatorToolTests` pass. |

## Found while porting

- Upstream's `LoginShellPathTests.timeoutReapsShellThatIgnoresTermination`
  uses a 0.2 s deadline; under load on the x86_64 (Rosetta) test runner the
  fake shell could be reaped before it wrote its pid file. Intel uses 1 s.
- i18n: the compaction "hit its output limit" message is plain English
  upstream; Intel adds de / zh-Hans.
