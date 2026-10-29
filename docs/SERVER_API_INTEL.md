# Local API server on Intel (`W-server-api`)

Started 2026-10-29. Renée moved this item ahead of `W-identity-mobile`
because the paired phone runs entirely through the server: it signs in with
an owner access key checked by the server's access-key gate, then calls the
agent, session and run routes inside the encrypted secure channel.

## Where Intel started

- **Server:** Intel's `HTTPHandler.swift` (834 lines) is its own file. It
  also holds the OpenAI wire types (`ChatMessage`, `ChatCompletionRequest`
  …), which upstream keeps in `Models/API/OpenAIAPI.swift` (excluded,
  `COV-intel-own`). Upstream's handler is 18,255 lines.
- **Routes:** Intel serves `/`, `/health`, `/models`, `/mcp` and
  `/chat/completions`. The last one is a DeepSeek-only proxy that reads
  `DEEPSEEK_API_KEY` from the process environment. Upstream serves about
  90 routes (see the table below).
- **No access check.** `APIKeyValidator` exists but nothing calls it.
- **Loopback only.** `AppDelegate` always binds `127.0.0.1` and ignores
  Settings › Server › "Expose to network", so the missing check was not
  reachable from the LAN. Keep it that way until the gate (stage 1) is in.
- **Crash on tampered keys:** `recoverAddress` used
  `P256K.Recovery.PublicKey`, which `fatalError`s on an unrecoverable
  signature (#131). Intel's range checks narrowed it but did not close it,
  and `AccessKeyValidatorTests` was excluded because it crashed the test
  process. Upstream calls libsecp256k1's C API directly. This had to be
  fixed before the gate verifies keys from callers (stage 0).
- **Upstream files involved:**
  - Excluded: upstream `ServerController.swift`, `HTTPLoopHelpers`,
    `HTTPProtocolErrors`, `HTTPRequestParse`, `HostAPIBridgeServer`,
    `RelayTunnelManager`, `BonjourAdvertiser`, `BonjourBrowser`.
  - Absent: `HTTPCallerContext`, `LocalNetworkAddress`,
    `LocalAPIKeyPolicy`, `ImageAPI`, `AgentRunUsage`.
  - Upstream server tests Intel excluded: `CORSHandlerTests`,
    `HTTPAuthGateTests`, `MCPHTTPHandlerTests`, `HTTPBodySizeLimitTests`,
    `AccessKeyValidatorTests`.

## Upstream route inventory and owner

| Routes | Stage / owner |
|---|---|
| Access-key gate, loopback trust, CORS, body limits, caller context, request logging, protocol errors, `/health` | 1 |
| `/models`, `/tags`, `/show`, `/chat/completions`, `/completions`, `/responses`, `/messages`, `/chat`, `/generate`, `/embeddings` (`/embed`), `/audio/transcriptions` | 2 |
| `/mcp/health`, `/mcp/tools`, `/mcp/call`, external-caller tool policy (`ExternalMCPToolPolicy`) | 3 |
| `/agents` (list, get, create, patch, delete, tools, tools preset, avatar, model), `/agents/{id}/run`, `/agents/{id}/dispatch`, `/tasks/*`, `/runs/{id}/events`, `/runs/{id}/stop`, `/approvals*`, `/config/approvals*`, `/secrets/prompts*`, `/memory/ingest` | 4 |
| `/sessions*`, `/projects`, `/artifacts/*`, `/models/picker`, `/models/options`, `/models/favorites`, `/credits/balance` | 5 |
| `/images/*`, `/images/jobs/*/events`, `/videos/*` (Intel's coordinator is in, `MEDIA_GENERATION_INTEL.md`) | 6 |
| `/admin/cache-stats`, `/admin/generation-settings`; Server tab endpoint list and "Expose to network" | 7 |
| `/admin/config/*` | `W-declarative-config` |
| `/admin/import/*` | `W-osaurus-bundles` |
| `/pair*`, `/secure/*`, `/pair-invite`, phone runs | `W-identity-mobile` |
| `/workspace-agents/*`, `/workspaces/*`, `/channels/*` | deferred (workspaces, channels) |
| `/privacy/reviews*` | `W-privacy-filter` |
| `/computer-use/prompts*` | `W-computer-use` |
| `/plugins/*` | `W-plugin-reliability` |
| `/systemone*` | check when reached (upstream on-device model) |

## Stages

0. **Crash fix.** Upstream's `recoverAddress` on the raw libsecp256k1 API;
   enable `AccessKeyValidatorTests`.
1. **Gate and plumbing.** Port onto Intel's handler, not upstream's
   18k-line file:
   - upstream's access-key gate and public paths, loopback trust and the
     #3178 local access key (app token, browser-origin refusal);
   - CORS, body-size limits and protocol errors;
   - `HTTPCallerContext` task locals;
   - Insights request logging;
   - enable `HTTPAuthGateTests`, `CORSHandlerTests` and
     `HTTPBodySizeLimitTests`, adapted where they reach routes a later
     stage adds.
2. **Inference on Intel's engine.** `/chat/completions` and friends run
   through `ChatEngine` (`CloudChatEngine`) for any configured model,
   replacing the DeepSeek proxy. `/embeddings` uses Intel's local embedder.
3. **MCP over HTTP.** This fixes `osaurus mcp`, which proxies to
   `/mcp/tools` and `/mcp/call`.
4. **Agents, runs, tasks and prompts.**
5. **Sessions and the owner model picker.**
6. **Media routes.**
7. **Admin bits, Server tab and network exposure.** Honour "Expose to
   network" only once stages 0–1 are in.

Each stage: gate run, Rosy section, row note in the backlog.

## Progress

- **Stage 0 (2026-10-29):**
  - `recoverAddress` is upstream's: the recovery byte is checked (EIP-191
    27–30 or raw 0–3), then libsecp256k1's own parse, recover and serialize
    calls, each checked, so a bad signature throws. This needs the
    `libsecp256k1` product, added to the package.
  - `APIKeyValidator` and `AccessKeyValidationResult` are upstream's:
    multi-agent audiences, `.valid(issuer:audience:keyNonce:)` and
    `isMasterScoped`.
  - `AccessKeyValidatorTests` is enabled; `CryptoHelpersTests` and
    `AccessKeyIntegrationTests` are at upstream. 72 tests pass.
- **Stage 1 (2026-10-29): gate and plumbing.** Upstream's request intake
  sits in front of Intel's routes, in `HTTPHandler.swift`:
  - **Limits:** header count and size limits (431); Content-Length and
    streamed body limits (413), with the tighter pairing limit on `/pair*`
    and `/secure/session`.
  - **Origin checks:** CORS (loopback `*`, else Allowed Origins, an
    explicit list on protected routes) and OPTIONS preflight. The #3178
    `LocalAPIKeyPolicy` refuses unlisted browser origins and accepts the
    per-launch app token over physical loopback.
  - **Access-key gate:**
    - public paths; loopback trust, withdrawn for relay-origin traffic and
      local agent-scoped keys;
    - Bearer validation with audience and key nonce;
    - agent-scope confinement: legacy-key route policy, the peer-inference
      gate (off: owner inference sharing is part of workspaces) and the
      `X-Osaurus-Agent-Id` check;
    - opportunistic loopback validation.
  - **Request context:** `HTTPCallerContext` bound around request tasks.
  - **Insights rows:** these carry the access-key attribution, and gate
    replies close the connection.
  - **Routing:** unknown routes now answer 404. The old Intel router
    answered every path 200 "ok".
  - **Validator rebuilds:**
    - `APIKeyValidatorEpoch` is bumped by key, revocation and whitelist
      changes and by the agent list.
    - `AgentIdentityRegistry` mirrors agent addresses from Intel's
      `AgentManager`.
    - `OsaurusServer` rebuilds its cached validator when the epoch moves,
      accepting every agent's audience.
    - Intel keeps the v1 `agentIndex` config; upstream's `AgentKeyPath`
      comes with `W-identity-mobile`.
  - **Not in yet:** upstream's plugin, channel and harness exemptions
    (`/plugins/*`, `/channels/*`, harness tokens), the secure-channel rewrite
    and its owner-channel 426, and the workspace-minted key index.
  - **Tests:** `HTTPAuthGateTests` (Intel copy of upstream's: 20 run,
    8 disabled until stages 2–5, the workspace / credits / tasks / harness
    cases left out) and `HTTPBodySizeLimitTests` are enabled.
    `CORSHandlerTests` waits for stage 2 (`/api/tags`).
  - **Server still loopback-only:** `AppDelegate` binds `127.0.0.1` until
    stage 7.
- **Stage 2a (2026-10-29): model routes.**
  - **Routes:** `/models`, `/tags` (Ollama) and `/show` (Ollama), at upstream.
  - **Model types:** `OpenAIModel`, `ModelsResponse`, `ModelPermission`
    and the API `ModelDetails` replace Intel's two-field stub.
  - **What's listed:** the remote models the owner exposed in the new
    Server › Models tab. That is upstream's `ServerModelsTabContent` and
    `ModelExposureStore`, with remote models hidden by default. Intel has
    no local models, so the Local Models card says they need Apple silicon.
    `/models` no longer lists Intel's two hard-coded DeepSeek ids.
  - **Peers:** they get an empty catalog while inference sharing is off.
  - **`/show`:** answers 404 for `foundation`, else answers from
    `ModelInfo`.
  - **Intel's `RemoteProviderManager`:** gained upstream's
    `getOpenAIModels`, a `cachedAvailableModels` and the
    `_testInstallConnectedProvider` / `_testRemoveProviders` hooks
    (in memory only).
  - **Tests:** `CORSHandlerTests` and `ModelExposureStoreTests` are
    enabled, plus three gate tests that waited for `/api/tags` and the
    peer catalog.

