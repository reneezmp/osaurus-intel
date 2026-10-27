# Upstream audit and port — 2026-10-27

**Range:** `fc75a1e06..bce907045` on `osaurus-ai/osaurus/main`, fetched
2026-10-27. **11 commits (no merges), 11 classified below.** Same verdict rule
and method as [`UPSTREAM_AUDIT_2026-10-26.md`](UPSTREAM_AUDIT_2026-10-26.md):
Incompatible only for Apple Silicon (MLX/Metal local inference) or
upstream-only artifacts; "Intel doesn't have X yet" is **Needs work** with X
named on the backlog. The next review begins at `bce907045` (exclusive).
`classify_gap.py` exits 0 and `classify_gated.py` reports nothing unassigned.

**Method note.** Test files are excluded by paths relative to `Tests/`
(`"Model/AnthropicAPITests.swift"`), so a check of `Tests/...` paths against
`Package.swift` must strip that prefix first; the first pass here marked
excluded tests as compiled.

## Classification

| # | Commit | Verdict | Intel note |
|---:|---|---|---|
| 1 | `c26332c11` #3206 | **Incompatible (MLX)** | DeepSeek-V4.1-Flash local bundles: encoder family, `chat_template_kwargs` thinking switch, allocator window, prefix-cache `cached_tokens`, dSpark admission, in-bundle vision evidence. Every compiled hunk (`ModelFamilyNames.isDSV41Family`, `ModelRuntimeEvent.cachedInputTokenCount`) only serves the vmlx runtime; hosted DeepSeek (`deepseek-flash`) keeps Intel's DSV4 profile. |
| 2 | `80cf45032` #3210 | **Split: Port + Needs work (`W-subagents`, `W-harness-runtimes`)** | Ported: `MemoryDistillateScreen` (no verbatim one-off instruction pinned, no "not specified" identity facts) at Intel's parse site; the distiller prompt's new rules; `FTSQueryTerms` function-word drop in Memory and Knowledge; the `delegated_conversations` side table, `bufferTurn(provenance:)`, "Delegating agent" label and no identity writes from delegated sessions; the expanded tool row keeps observing late live-exec entries (Intel has no subagent feed pane). Needs work: `ChatSession.memorySource` (Intel has no `SessionSource` / delegated sessions, `W-subagents`); `HarnessProcess` stderr drain (`W-harness-runtimes`). |
| 3 | `4002c7712` #3211 | **Incompatible (MLX)** | `vmlx-swift` pin. |
| 4 | `7ff316c3f` #3212 | **Incompatible (MLX)** | Streamed `cached_tokens` from the local prefix cache through upstream's typed stream writer; Intel's `HTTPHandler` is its own and has no local cache. |
| 5 | `63373cc82` | **Incompatible (upstream artifact)** | Upstream appcast 0.25.27. |
| 6 | `73b2057d4` #3213 | **Incompatible (MLX)** | `vmlx-swift` pin. |
| 7 | `037c4b880` #3214 | **Incompatible (MLX)** | `vmlx-swift` pin. |
| 8 | `bdc0ae693` #3215 | **Incompatible (MLX)** | Per-request allocator cleanup, MTP failure diagnostics. |
| 9 | `20887a4aa` #3217 | **Split: Port + Incompatible (MLX)** | Ported: `VolumeAvailableCapacityCache` and `OsaurusPaths.volumeFreeBytes` counting purgeable space (strict free read 18 GB against 1.44 TB on one Mac); on Intel this is the menu-bar panel's storage figure (`SystemMonitorService`). Incompatible: the installed local-model inventory, capacity estimates, download view and residency sizing. |
| 10 | `9c4aceaa8` #3218 | **Incompatible (MLX)** | Preparation-failure tracking, handled GPU failure reports, the vmlx disk-cache free-space provider (`VolumeAvailableCapacityCache+DiskCache`, installed from `AppDelegate`). |
| 11 | `bce907045` #3216 | **Incompatible (MLX)** | DeepSeek-V4.1 local alignment: dSpark solo lease, `DSV41ReasoningProfile` (matches local V4.1 bundle names only), `model_type` detection, local cached-token usage in `/agents/{id}/run` and Anthropic `/messages` (both upstream-only servers), Anthropic `thinking` / `top_k` forwarding in upstream's excluded `AnthropicAPI`. |

## Found while porting

- **Two more fixes hidden in SKIP-triaged commits:**
  - #1967 (evals harness overhaul) carried the loose-term fallback for pinned
    facts and episodes in `MemoryDatabase`, plus the possessive "my X"
    signal in `MemoryRelevanceGate`. Both are ported. Intel compiles the gate
    but its assembler doesn't call it.
  - #1815's knowledge half: Intel's `KnowledgeDatabase` AND-joined unquoted
    terms, so a full-sentence question had to match every word in one chunk.
    It is now upstream's quoted OR-prefix query with the low-signal filter
    and #3210's function-word drop; a query with no usable tokens falls back
    to LIKE, as upstream does.
- **#1635's I4 input caps:** Intel's distill prompt had no turn or length
  cap (80 turns, head plus tail; 2,000 characters per message). Ported with
  #3210's prompt changes.
- **End-to-end distill tests stay upstream-only:** upstream scripts the core
  model through `setDistillGenerateOverrideForTests` and
  `flushSessionAndWait`; Intel's distiller calls `CloudChatEngine` and has
  neither seam, so the two flush-driven tests in `MemoryDistillQualityTests`
  are omitted. The screen, the delegated marker and the FTS cases are covered.

## Shipped on Intel

Tests: `MemoryDistillQualityTests` (upstream's, minus the two flush-driven
tests, plus a knowledge-query case), `VolumeFreeSpaceTests` and
`VolumeAvailableCapacityCacheTests` (upstream keeps them in the excluded
`ModelDownloadServiceStorageTests`), #1967's gate and recall tests in
`MemoryTests` / `FTS5MemorySearchTests`, and #3210's updated FTS sanitizer
expectation. Package gate: 3,268 tests in 406 suites (6 known issues),
`~/.osaurus` and the identity key untouched. Rosy: "Upstream audit
2026-10-27" in `ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`.
