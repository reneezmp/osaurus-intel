# Upstream audit and port — 2026-10-10

**Range:** `ec654e8c5..24f4c416a` on `osaurus-ai/osaurus/main`, fetched
2026-10-10. **2 commits (no merges), 2 classified.** Verdicts follow the rule
in
[`UPSTREAM_SYNC.md`](UPSTREAM_SYNC.md#verdict-rule-doesnt-apply-is-not-a-verdict--2026-09-29).
The next review begins at `24f4c416a` (exclusive). `classify_gap.py` and
`classify_gated.py` both exit 0 at this point.

## Classification

| # | Commit | Verdict | Intel note |
|---:|---|---|---|
| 1 | `85258b065` #3059 | **Incompatible** | Qwen-Image-2.1-Turbo bundles for local MLX image generation: `vmlx-swift` pin, image runtime policy, composer size label, image subagent delegation ownership. All `INC-mlx`. Two strings are composer-only. |
| 2 | `24f4c416a` #3056 | **Port** | `shell_run` children get the login shell's PATH (mise, nvm, asdf, fnm…), with relative entries dropped. The first call waits for the bounded probe. Upstream's code and `ShellRunEnvironmentTests` came over verbatim; `LoginShellPath` and `ExecutableLocator.childPath` were already on Intel (#3038). |

**Totals:** Port 1 · Incompatible 1.

## Shipped on Intel (awaiting Rosy)

| Upstream | What Intel got |
|---|---|
| #3056 `24f4c416a` | A command such as `node -v`, `npx …` or `python` from a version manager now runs in `shell_run` as it does in Terminal. Before this, the app's sparse PATH made them "command not found". |
