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
| `/agents` (list, get, create, patch, delete, tools, tools preset, avatar, model), `/agents/{id}/run`, `/agents/{id}/dispatch`, `/tasks/*`, `/runs/{id}/events`, `/runs/{id}/stop`, `/approvals*`, `/config/approvals*`, `/secrets/prompts*`, `/computer-use/prompts*` (moved from `W-computer-use` in 4d), `/memory/ingest` | 4 |
| `/sessions*`, `/projects`, `/artifacts/*`, `/models/picker`, `/models/options`, `/models/favorites`, `/credits/balance` | 5 |
| `/images/*`, `/images/jobs/*/events`, `/videos/*` (Intel's coordinator is in, `MEDIA_GENERATION_INTEL.md`) | 6 |
| `/admin/cache-stats`, `/admin/generation-settings`; Server tab endpoint list and "Expose to network" | 7 |
| `/admin/config/*` | `W-declarative-config` |
| `/admin/import/*` | `W-osaurus-bundles` |
| `/pair*`, `/secure/*`, `/pair-invite`, phone runs | `W-identity-mobile` |
| `/workspace-agents/*`, `/workspaces/*`, `/channels/*` | deferred (workspaces, channels) |
| `/privacy/reviews*` | `W-privacy-filter` |
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

- **Stage 4a (2026-10-29): agent management** (`IntelHTTPAgents.swift`,
  `Services/MobileConnect/PhoneAgentEditing.swift`).
  - **Routes**, upstream's handlers and DTOs, routed in upstream's order:
    `GET /agents`, `GET /agents/{id}` (UUID or agent address),
    `POST /agents`, `PATCH|DELETE /agents/{id}`, `PUT /agents/{id}/model`,
    `GET /agents/{id}/avatar`, `GET /agents/{id}/tools`,
    `POST /agents/{id}/tools/preset`, `PATCH /agents/{id}/tools/{name}`.
  - **Owner rules (upstream):**
    - The owner is a trusted loopback caller or a master-scoped key
      (`callerOwnsThisMac`). Everything but the two reads is owner-only
      (403 `owner_only`); built-in agents are listed and readable for the
      owner only.
    - A remote owner key needs the Secure Channel for the owner routes
      (426 `secure_channel_required`), except the plaintext `GET /agents`
      upstream keeps for one release. Intel has no Secure Channel yet
      (`W-identity-mobile`), so `requestIsSecureChannel` is always false:
      over the relay, a phone can list agents and nothing more until then.
  - **Edits** go through upstream's `PhoneAgentEditing`. Intel edits:
    - Apple apps come from the agent's own settings; there is no sandbox
      wait and no workspace check (workspaces are deferred).
    - A phone-made agent (`AgentManager.createFromPhone`) starts with every
      capability off, as upstream's does, and its skill list seeded from
      the installed skills.
    - `Agent.toolsEnabled` / `memoryEnabled` are upstream's names over
      Intel's `disableTools` / `disableMemory`.
  - **Intel differences in the replies:**
    - The Orchestrator's address is nil (no phone connect identity yet).
    - `relay_url` follows Intel's relay manager, a stub that is always
      off, so it stays null until the relay is ported.
    - `chat_quick_actions` is each agent's own Action Bar. Upstream sends
      the Orchestrator's configure-oriented defaults, which Intel's chat
      doesn't have.
    - `supports_vision` is judged from Intel's picker items: VLMs,
      image-to-video models, and remote models that aren't embedding
      models.
    - `features` is empty: upstream advertises `session_create`, which
      needs runs that can start a chat (`osaurus_create_session`, which
      comes with the phone's runs in `W-identity-mobile`).
  - **Found while testing:** over loopback with the local-key setting off,
    upstream's gate never reads a presented key, so a local agent-scoped
    key acts as the owner. That is upstream's behaviour (the
    `loopbackTrustWithdrawn` rule only applies once a key is validated);
    tests of non-owner callers must arrive through the relay header or
    turn the setting on.
  - **Tests:**
    - Upstream's `AgentToolPatchTests` and `PhoneAgentEditingTests`, verbatim.
    - New `IntelHTTPAgentRoutesTests`: upstream's two agent-metadata cases
      from `HTTPHandlerEndpointTests` (minus its remote-provider parser),
      the create / edit / retune / delete round trip, built-in refusal,
      tools, avatar, the 426 and owner-only refusals, and the `/agents`
      halves of two gate cases whose other halves wait for stage 7 and
      `W-declarative-config`.
    - Three `HTTPAuthGateTests` cases waiting for `/agents` are enabled.
- **Stage 4b (2026-10-29): background dispatch and tasks**
  (`IntelHTTPTasks.swift`).
  - **Routes**, upstream's: `POST /agents/{id}/dispatch` (202 with a
    `poll_url`), `GET /tasks/{id}`, `DELETE /tasks/{id}` (204), and
    `POST /tasks/{id}/clarify`, which answers 410 as upstream's does
    (clarifying happens in the chat window).
  - **Upstream pieces:** `DispatchTaskOwnership` (an agent-scoped key may
    only poll or cancel the tasks it started; kept in
    `workspaces/dispatch-owners.json`, so `OsaurusPaths.workspaces()` is
    in), `dispatchSessionKey` (a reattach key is scoped to the credential
    that sent it) and the task-status JSON (`PluginHostContext.taskStateDict`,
    in `Services/Plugin/IntelPluginTaskState.swift` because Intel doesn't
    compile the plugin host).
  - **External runs:** a non-loopback dispatch is an external surface, as
    upstream. `DispatchRequest.externalSurface` and
    `BackgroundTaskManager.resolvedExternalSurface` are upstream's; the
    runner binds `ChatExecutionContext.isExternalSurface` for the whole run.
  - **Intel change to the engine:** Intel asks for tool approval in
    `CloudChatEngine`, before `ToolRegistry.execute`. An external run (or
    one that denies prompts) now refuses an `.ask` tool there instead of
    showing a card and then refusing in `execute`; the tool result says it
    needs approval in the app (`ChatEngine.unapprovedReason`). Upstream
    lets the owner's paired phone review instead (`hasRemoteReviewer`);
    that comes with `/approvals` (stage 4d).
  - **Built-in agent:** a loopback dispatch may target the Orchestrator
    (upstream); Intel passes its `allowsBuiltInAgent` flag for that.
  - **Fix found by the tests:** Intel's `AgentManager.resolveAgentId`
    accepted any UUID (and looked agents up by name), so a dispatch to an
    agent that doesn't exist started a run. It is upstream's now: a UUID
    must name an agent, anything else is an agent address. `agent(byAddress:)`
    is case-insensitive, as upstream's.
  - **Not ported:** the workspace-key refusal and workspace audit records
    (workspaces are deferred).
  - **Tests:**
    - Upstream's `AgentScopePolicyTests` and `DispatchTaskOwnershipTests`
      (missed at stage 1), minus the `PeerInferenceSharing` round trip
      (stage 7) and the pair-invite suite (`W-identity-mobile`).
    - Upstream's `TaskStateDictTests`, and the three dispatch
      external-surface cases in `MCPHTTPHandlerTests`.
    - `HTTPAuthGateTests.agentScopedKey_cannotTouchForeignTasks`.
    - Intel route cases for dispatch validation, the 426 for a remote
      owner key, the task routes, session-key scoping and the engine's
      refusal text.
- **Stage 4c (2026-10-30): streamed agent runs** (`IntelHTTPAgentRun.swift`).
  - **Routes:** `POST /agents/{id}/run`, `GET /runs/{id}/events`,
    `POST /runs/{id}/stop`, routed before the agent routes as upstream.
  - **Upstream gates, in upstream's order:** 426 for a remote caller
    without the Secure Channel; the body decoded after
    `injectingEmptyModelIfMissing`; the agent from `default`, a UUID or an
    address (any UUID is accepted, as upstream's run does); the built-in
    agent for the owner only; agent-scope confinement.
  - **How the run works on Intel:** upstream drives its own loop
    (`AgentToolLoop`, not compiled on Intel). Intel's `ChatEngine` already
    runs the tool loop, so the handler builds the agent's request and
    streams the engine's output:
    - the request is upstream's `enrichWithAgentContext` on Intel's
      composer: the agent's prompt ahead of any caller system message
      (upstream's `injectSystemContent`, now in Intel's
      `SystemPromptComposer`), memory beside the last user turn, the agent's
      tools plus caller functions that don't shadow a registered tool
      (`mergeAgentContextTools`, without upstream's canonical sort);
    - model: an omitted or `"default"` model is the agent's own
      (`effectiveModel`); sampling from `resolveAgentSampling` (request
      first, then the agent);
    - tool calls run with `isExternalSurface` bound, as upstream binds it
      around its batch executor: `.ask` tools are refused (stage 4b's engine
      rule), the external deny list applies;
    - the stream: text, reasoning, and upstream's `osaurus_agent_tool`
      trace (`writeAgentToolTrace`, `AgentToolTraceDetail`,
      `AgentToolTraceTimer`). Arguments, results, labels and durations go
      to owner callers only. Intel has no `SecretArgumentScrubber` (no
      sandbox secret tools), so arguments go through unchanged;
    - a successful `complete` / `clarify` streams its summary or question
      at the end; the tool-round cap streams upstream's "Tool-loop budget
      of N iterations exhausted" notice instead of an error; other failures
      are an in-band error chunk after the 200 head;
    - `include_usage` adds the usage chunk when every model round reported
      usage.
  - **Engine changes (API runs only, chats unchanged):**
    - `ChatCompletionRequest.reportsToolStarts`: the engine yields
      `StreamingToolHint.encodeStarted` (call id, name, arguments) before
      each tool it runs, in both the Chat Completions and Codex paths. The
      existing `tool:` hint only carries a name while the call streams, so
      it can't pair with the "completed" trace.
    - `ChatCompletionRequest.maxToolRounds`: the run's limit (upstream's
      `maxToolAttempts`, default 30, capped at 120) instead of the engine's
      12. At the limit the engine throws `ChatEngine.ToolRoundLimitReached`
      (same message the chat showed before).
    - Usage is summed over the run's rounds (upstream `AgentRunUsage`,
      ported with its tests); a round with no measured usage leaves the run
      unreported. Single-round API requests report what they did before.
  - **Wait for `W-identity-mobile`** (all need the Secure Channel, so no
    caller can reach them yet): detached phone runs (`osaurus_run_id`,
    `DetachedPhoneRuns`; `/runs/{id}/*` answer owner-only 403 or 404
    `run_not_found`), the agent's host workspace folder, continuing a Mac
    chat (`osaurus_session_id`, `osaurus_create_session`, and with it the
    `session_create` feature in `GET /agents`), voice-call turns, the
    phone's model options and privacy choice, the inbound shared-run tab.
  - **Not ported:** inference admission control (Intel has none on any
    route), workspace billing and audit, harness runtimes, Router billing
    relay, `share_artifact` relay, memory-prefix replay per `session_id`
    (`SessionToolStateStore`, not compiled on Intel), upstream's fallback
    to the loaded local model (Intel has none; `effectiveModel` already
    falls back to the chat default).
  - **Tests:** upstream's `AgentRunUsageTests` and
    `AgentRunSamplingResolutionTests`; new `IntelAgentRunEngineTests`
    (started marker, round limit, usage across rounds, against an
    in-process provider fixture) and `IntelHTTPAgentRunTests` (upstream's
    built-in loopback case, the streamed trace with no in-band hints
    leaking, the round-limit notice, validation, `/runs/*`, helpers).
    Upstream's `HTTPHandlerChatStreamingTests` stays excluded: its fake
    engines throw tool calls, upstream's engine contract, not Intel's.
  - **Validation (2026-10-30):** full suite under the interim 27.0-SDK gate
    (`TEST_STORAGE_SAFETY.md`, "2026-10-30 gate crash"): 4,027 tests, all
    stage 4c suites pass; the one failure is the avatar-cache test that
    gate can't run (uncompiled asset catalog). The package and its tests
    also build for `x86_64-apple-macosx13.0`. No live `~/.osaurus` writes,
    identity keychain item unchanged.
- **Stage 4d (2026-10-30): the phone's cards** (`IntelHTTPApprovals.swift`).
  - **Routes (upstream handlers, Intel helpers):** `GET /approvals`,
    `POST /approvals/{id}` (`deny | allow_once | allow_for_run |
    always_allow`); `GET /config/approvals`, `POST /config/approvals/{id}`
    (`apply | cancel`); `GET /secrets/prompts`, `POST /secrets/prompts/{id}`
    (`{value}` or `{decision:"cancel"}`); `GET /computer-use/prompts`,
    `POST /computer-use/prompts/{id}`. All owner-only; answers need the
    Secure Channel from a remote owner (`requiresOwnerChannel`), and so do
    reads (the owner-route gate in the access check). A gone card answers
    404 (`approval_not_pending` / `prompt_not_pending`); a decision that
    doesn't fit a computer-use card answers 400 and leaves it waiting.
  - **`/computer-use/prompts` came forward** from `W-computer-use`:
    `ComputerUsePromptQueue` with its paired-phone list and answer is
    already compiled, and the route shares upstream's handler with
    `/secrets/prompts`.
  - **Remote reviewer:** `/run` binds `ChatExecutionContext.hasRemoteReviewer`
    to `authedScopeIsMaster && requestIsSecureChannel` (upstream), so it is
    always false until `W-identity-mobile`; the lists stay empty until then.
    With it set: Intel's engine lets an `.ask` tool through to the card
    (`isExternalSurface && !hasRemoteReviewer`, both tool paths and
    `unapprovedReason`), `ToolPermissionPromptService` marks the card
    `fromPairedPhone`, and the registry's external-surface refusal is
    upstream's phone wording with `requires_mac` metadata. That refusal
    lives in Intel's `ToolRegistry` in
    `Models/Chat/IntelConformers/IntelStubConformers.swift`;
    `Tools/ToolRegistry.swift` is excluded on Intel (an edit there compiles
    nothing, which the test caught).
  - **Secrets:** upstream's `RemoteSecretPromptQueue` verbatim
    (`Services/MobileConnect/`). Its caller, `sandbox_secret_set` in
    `SandboxSecretTools.swift`, is excluded with the sandbox, so nothing
    raises a secret prompt on Intel yet; it arrives with the sandbox work.
    Intel's request log records no request bodies, so the secret is never
    logged.
  - **Config plans:** Intel keeps its own `IntelConfigApprovalQueue` (the
    Orchestrator's settings; upstream's `ConfigApprovalQueue` comes with
    `W-declarative-config`). It gains upstream's `fromPairedPhone`,
    `resolveFromPairedPhone` and `pairedPhoneListJSON`; rows use upstream's
    shape, one `update` action per changed path, `prune` always false,
    warnings as `notes` with `high_risk`. `IntelConfigApprovalService`
    parks a remote-reviewer run's plan for the phone (300 s) before its
    "no mounted chat surface" fail-closed check, as upstream's tool does.
    The Mac's card only shows its own chat's plans, so a phone plan never
    appears there.
  - **Tests:** upstream's `RemoteApprovalDecisionTests`; new
    `IntelHTTPApprovalsTests` (empty lists, validation, agent-scoped key
    403, remote owner 426, a phone run's tool card / secret / config plan
    listed and answered over HTTP, Mac-raised cards never listed, the
    config service parking a phone plan, the engine and registry wording).
  - **Validation (2026-10-30):** full suite under the interim 27.0-SDK
    gate: 4,041 tests, all stage 4d suites pass; the only failure is the
    avatar-cache test that gate can't run. The package and tests build for
    `x86_64-apple-macosx13.0`. Classifiers: UNASSIGNED 0. No live
    `~/.osaurus` writes, identity keychain item unchanged.
