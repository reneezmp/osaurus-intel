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
- **Stage 2b (2026-10-29): `/chat/completions` on Intel's engine.**
  - **Decision: keep Intel's types.** Upstream's request, message and
    response types (`OpenAIAPI.swift`) differ from the ones Intel's engine
    and providers use. Swapping them is a `W-cov-reaudit`-sized refactor,
    so routes keep Intel's types. Upstream's *wire* types are copied
    verbatim (`Models/API/IntelOpenAIWire.swift`: `Usage`, `DeltaContent`,
    `StreamChoice`, `ChatCompletionChunk`, `OpenAIError`, `DeltaToolCall`,
    `ToolChoiceOption`), so the bytes on the wire are upstream's.
  - **`ToolChoiceOption`:** now upstream's. Intel's synthesized-Codable
    enum could not decode `"tool_choice": "auto"`. The engine now forwards
    the caller's choice instead of always `"auto"`
    (`ChatEngine.wireToolChoice`; the Anthropic and Codex adapters already
    translate every form). Upstream's `ToolChoiceDecodingTests` is
    enabled; Intel's copy was stale.
  - **The route** (`IntelHTTPInference.swift`):
    - It sends the client's messages and tools to `ChatEngine(source:
      .httpAPI)` with `stopAtToolCalls`. That is one model round: proposed
      calls go back as OpenAI `tool_calls`, never run, as upstream does.
    - The engine's marker strings become typed events.
    - Streaming uses upstream's `SSEResponseWriter`: role chunk, content
      and `reasoning_content` deltas, tool calls as a start chunk plus
      1 KB argument deltas, the finish reason, `data: [DONE]`, a 15 s
      `: ping` keepalive, and an in-band error chunk after the 200 head.
      The client disconnecting cancels generation.
    - Non-streaming: upstream's `chat.completion` body.
    - `usage` only when the provider measured it (see 2c part 2).
    - Upstream's `n` / `logprobs` / `response_format` rejections (400);
      unknown model 404, other engine errors 503.
    - One Insights row for the request, plus the engine's egress row.
  - **The DeepSeek proxy is gone:** `DEEPSEEK_API_KEY`,
    `DeepSeekAPIKeyStore`, its tool loop, and its Insights test. The
    engine's env-var fallback is unchanged.
  - **Not yet:** saving API chats to history (`X-Persist`, `X-Session-Id`,
    `X-Osaurus-Agent-Id` memory attribution; with sessions, stage 5); the
    stream-delta coalescing interval; `response_format` JSON mode and
    reasoning effort passed through to the provider; the inference
    admission limit; the TTFT trace.
  - **Tests:** `IntelHTTPChatCompletionsTests` (scripted engine, real
    loopback server).
  - **Gate notes (2026-10-29):**
    - One full run hung for 10 minutes after
      `AppleToolExecutionTests.invalidArgs` started (fake calendar service;
      the process idle, no Osaurus frame on any thread). The suite passes
      alone, and the next full run passed (3,914 tests).
    - Treat a recurrence as an ordering flake to bisect, not a stage-2
      regression: nothing in that path changed.
    - **Update, same day:** it recurred once more (13:46), this time
      after `AppleScriptAppKnowledgeTests.shortcutTaskGetsShortcutsRecipe`
      started. Again, every thread was idle: the main `CFRunLoop`, a
      `JavaScriptAppleEvents` runloop thread, and a parked worker. The
      runner was awaiting a job that never ran.
    - The suites before the hang, run alone four times (797 tests), always
      passed in 5.5 s; the full gate passed at 12:44, 13:21 and 14:22
      (3,941 tests).
    - Working theory, not proven: an earlier test sends a real Apple Event
      whose reply waits on macOS (an Automation consent prompt or a
      launching app), leaving the awaiting test suspended. The gate script
      runs without a cap: use `timeout 420` and kill the helper if it
      hangs.
    - Live-file hits in the passing run were the running app's (`lsof`:
      pid 64163) chat history, memory and activity log.
- **Stage 2c, part 1 (2026-10-29): Ollama `/api/chat` and `/api/generate`**
  (`IntelHTTPOllama.swift`).
  - **Requests:** upstream's decoding. `options` map to sampling,
    earlier `thinking` stays reasoning, `images` become image parts, and
    `think` is validated. Intel's request has no thinking / effort fields,
    so `think` is not passed on.
  - **Responses:** NDJSON by default, with `thinking` frames, and arguments
    as JSON objects. The closing frame carries `done_reason` and, on
    `/api/chat`, the proposed `tool_calls`. `stream: false` returns
    upstream's single body.
  - **Same path as `/chat/completions`:** one model round, the same error
    statuses. `prompt_eval_count` / `eval_count` are absent (not measured).
- **Stage 2c, part 2 (2026-10-29): measured usage, and Anthropic `/messages`.**
  - **Measured usage.** Intel's engine parsed the provider's usage for
    Insights but never passed it on. API requests now set
    `ChatCompletionRequest.reportsUsage` (not encoded), and the engine ends
    their stream with a `StreamingUsageHint` (`\u{FFFE}usage:` marker).
    App chats never set it.
    - `/chat/completions` reports `usage` (and the `include_usage` chunk)
      only then.
    - Ollama frames carry `prompt_eval_count` / `eval_count`.
    - This supersedes 2b's "usage left out".
  - **Anthropic `/messages`** (`IntelHTTPAnthropic.swift`):
    - **Request conversion:** upstream's `AnthropicAPI.swift` is no
      longer excluded. It has four documented Intel edits in its
      conversion helpers: the validation returns Intel's request; no
      `anthropic_thinking_blocks`, `top_k` or `enable_thinking`; `Double`
      sampling values.
    - **Writer:** upstream's `AnthropicSSEResponseWriter`, minus
      provider-signed thinking blocks and the Privacy Filter error.
    - **Usage:** like upstream, the route requires measured input and
      output counts (502 / an in-band error otherwise) and holds the
      stream until the input count is known. Intel learns it at the end,
      so streamed events are written together when the round finishes.
    - **Tests:** upstream's `AnthropicAPITests` is enabled, minus three
      cases for pieces Intel lacks (listed in the file).
- **Stage 2c, part 3, and 2d embeddings (2026-10-29):**
  - **`/completions` (legacy):** upstream's `CompletionRequest` and its
    validation (prompt required, FIM `suffix` / `middle` refused).
    Upstream only ever ran it on the local MLX runtime, as a raw prompt
    outside the chat template. Intel has no local models, so it answers
    404 saying so and pointing to `/chat/completions`.
  - **`/embeddings` and Ollama `/embed`** (`IntelHTTPEmbeddings.swift`):
    upstream's contract, error bodies and Insights details, on Intel's CPU
    `StaticEmbedder`.
    - The model is `potion-base-8M` (256 dimensions), the one Intel's
      memory uses; upstream serves `potion-base-4M` (128) on MLX.
    - Model validation names Intel's ids, so a client asking for
      upstream's gets the "unsupported model" error rather than vectors
      of an unexpected size.
    - The model downloads on first use, as upstream's does.
- **Stage 2d, transcription (2026-10-29):** `/audio/transcriptions`
  (`IntelHTTPTranscription.swift`).
  - **Port:** upstream's multipart parsing, `json` / `text` /
    `verbose_json` formats and Insights details. It runs on Intel's
    `SpeechService` (Apple Speech; upstream uses Parakeet on Apple silicon).
  - **Two Intel fixes:**
    - Upstream's parser traps on a body with no boundary
      (`0 ..< (ranges.count - 1)`); Intel's returns no parts. Worth sending
      upstream.
    - The temporary file keeps the upload's extension so Apple Speech
      reads non-WAV audio.
  - **`runRequestTask`** now binds upstream's activity guard
    (`ChatExecutionContext.currentRequestSource = .httpAPI` for routes that
    log their own row), so the speech service doesn't add a second
    Insights row.
  - **Tests** stop at validation: a real file would ask for
    speech-recognition access.
- **Stage 2e (2026-10-29): `/responses`** (`IntelHTTPResponses.swift`).
  - **Wire types:** upstream's `OpenResponsesAPI.swift` is back in the
    build, trimmed to its wire types, stream events, errors and the
    `toChatCompletionRequest` projection. Intel edits there: no `strict` on
    tools, `Double` sampling values, no `reasoning_effort` /
    `response_format`.
  - **Left out** (they need upstream's typed Responses engine; the first
    attempt to compile the whole file gave 70 errors): the native
    `toResponsesInferenceRequest`, the `ResponsesGenerationResult`
    projections, and the `ChatCompletionResponse` conversion.
  - **The route:** one round through `IntelHTTPInference`.
    - The response object holds reasoning / message / function-call items
      and measured usage; a length stop is `incomplete` with
      `max_output_tokens`.
    - `previous_response_id` continuation uses upstream's
      `OpenResponsesContextStore`: 128 entries, model-bound, unknown ids
      404, per-request instructions not carried over.
    - A structured `text.format` other than `text` answers 400 rather than
      being ignored.
  - **Streaming:** the portable half of upstream's
    `OpenResponsesSSEWriter`, minus the native provider-event proxy and
    prefill progress. The lifecycle is `response.created` →
    `in_progress` → reasoning summary / output text deltas → item done
    events → function-call items → `response.completed` or `incomplete`,
    then `[DONE]`.
  - **Tests:** three new cases in `IntelHTTPChatCompletionsTests`.
- **Stage 2 complete** apart from the "Not yet" list in 2b.
- **Stage 3 (2026-10-29): MCP over HTTP** (`IntelHTTPMCP.swift`).
  - **Routes:** `GET /mcp/health`, `GET /mcp/tools`, `POST /mcp/call`,
    upstream's minus the harness-token branches (`W-harness-runtimes`).
    The `osaurus mcp` stdio proxy now has something to talk to.
  - **Removed:** Intel's `POST /mcp` (`MCPBridge`, three demo tools from
    milestone M5, not an upstream surface).
  - **External-caller policy:**
    - `ChatExecutionContext.isExternalSurface` and
      `denyUnapprovedToolPrompts`.
    - The registry's `externallyDeniedToolNames`: host mutation,
      knowledge / skill writes, agent channels, the Apple app tools, the
      folder picker.
    - `isDeniedForCurrentSurface` / `externalSurfaceDenialEnvelope`,
      `ExternalMCPToolPolicy` (verbatim) and `isGlobalEnabled`.
  - **Intel difference:** Intel asks for approval in the chat engine, before
    `ToolRegistry.execute`, so `execute` itself refuses `.ask` (and
    `.deny`) tools for external callers. That is the outcome of upstream's
    gate for a caller with no approval UI.
  - **Tests:** upstream's `MCPHTTPHandlerTests` is enabled, minus the
    harness-token, dispatch-binding (stage 4) and cache-stats (stage 7)
    cases.
  - **Guide:** the Server and MCP topics are rewritten for what the server
    serves now.

