# Paired phone, Secure Channel and relay on Intel (`W-identity-mobile`)

Started 2026-11-02, after `W-server-api` (`SERVER_API_INTEL.md`) put the
access-key gate and every route the phone calls in place. The protocol is
upstream's `docs/MOBILE_PROTOCOL.md` (read it at `bce907045`); section
numbers below (§) are that document's.

Renée has the Osaurus iPhone app, so each stage's Rosy steps pair the real
phone and use the feature from it, not only protocol tests.

## Where Intel starts

- **Server side is ready:**
  - the access-key gate, with master and agent-scoped keys;
  - the owner model (loopback or a master key);
  - every phone route: agents, runs, tasks, approvals, sessions, picker,
    media.
  - "Expose to Network" is honoured (stage 7), so the phone can reach the
    Mac on the LAN.
- **No pairing and no Secure Channel.** `requestIsSecureChannel` is always
  false, so a remote owner key gets `426 secure_channel_required` on every
  owner route, and the phone-only fields (`osaurus_run_id`,
  `osaurus_session_id`, `osaurus_job_id`, `osaurus_voice_call`) are
  ignored.
- **Identity:**
  - Intel has upstream's identity layer for the master key, agent keys
    (v1 `agentIndex`), access keys, revocation and the whitelist.
  - Intel's `MasterKey` reads the key without user interaction (no access
    control on the item). Upstream's Secure Channel handshake relies on
    that: `interactionNotAllowed`, signed per session.
  - **Missing:** upstream's device-scoped v2 agent keys (`AgentKeyPath`,
    86 lines of `AgentKey`) and its shared keychain group with an iCloud
    copy (`OsaurusKeychainGroup`, about 200 lines of `MasterKey`). The
    phone pins whatever address an agent has, so v1 addresses work for
    pairing.
- **Relay:** `RelayTunnelManager` is an Intel stub
  (`IntelAgentConformers.swift`). The Server tab's Relays section shows
  switches that do nothing.
- **Upstream files (26, about 6.8k lines, classifier `W-identity-mobile`):**
  - pairing: `PairingSPAKE2`, `PairingKeyEnvelope`,
    `PairingChallengeStore`, `PairingRateLimiter`, `PairingCode`,
    `MobilePairingService`, `MobileConnectIdentity`, `MobileConnectLog`,
    `MobileConnectAdvertiser`, `OsaurusConnectView`, `IncomingPairCoordinator`,
    `PairingDeepLinkRouter`;
  - Secure Channel: `SecureChannel`, `SecureSessionStore`,
    `SecureChannelResponseEncryptor`, `SecureChannelClient`;
  - phone features: `DetachedPhoneRuns`, `PhoneChatHandoff`,
    `VoiceCallReplies`;
  - relay and discovery: `RelayTunnelManager`, `BonjourBrowser`;
  - other: `OwnerDeviceAccessHost` (§5.1 owner redeem), `OsaurusIDService`,
    `OsaurusIDSessionStore`, `OsaurusIDSection`, `OsaurusKeychainGroup`.

## Stages

1. **Pairing on the LAN (§11).**
   - Settings → Mobile (`OsaurusConnectView`) with a 6-digit code and the
     paired phone.
   - `MobilePairingService` and `PairingCode`; SPAKE2 v2 and the v1 HPKE
     envelope; the rate limiter; the connect identity.
   - Bonjour `_osaurus-mobile._tcp` while exposed.
   - Routes: `/pair/hello`, `/pair/code`, `/pair/confirm`, `/pair/unpair`;
     `address` / `relay_url` on `GET /agents`.
   - "Keep Mac Awake for Paired iPhone".
2. **Secure Channel (§6.2).**
   - `/secure/session` (signed with the agent key, or the connect
     identity) and `/secure/call`: decrypt, rewrite into the inner
     request, encrypt buffered and streamed responses.
   - `requestIsSecureChannel` becomes real, so the stage 4–6 owner routes
     open to the phone.
3. **Phone runs and chats.** Split in three (2026-11-03): Intel lacks most
   of the chat hooks continuing a Mac chat needs (`appendHostedTurns`, the
   held send, `ChatHistoryWriter.turns`, `InjectedContextSpans`), so runs
   go first.
   - **3a, phone runs:** detached runs (`osaurus_run_id`,
     `/runs/{id}/events`, `/runs/{id}/stop`), voice-call turns
     (`VoiceCallReplies`, #3106), the phone's model options, #3152.
     `hasRemoteReviewer` was bound in stage 2; #3207 came with
     `W-server-api`.
   - **3b, continuing Mac chats:** `osaurus_session_id` and
     `osaurus_create_session`, the rest of `RemoteSessionContinuation`
     (history, append, the phone's own chats, the held send),
     `PhoneChatHandoff` and its Settings → Mobile switch, #3070, the chat
     part of #3135.
   - **3c, phone image jobs:** `osaurus_job_id`,
     `/images/jobs/{id}/events`, `osaurus_session_id` on image requests
     (image exchanges written into the chat).
4. **Reach From Anywhere (§6.1, §11.6).** The real `RelayTunnelManager`
   behind the Relays section and Settings → Mobile.
5. **Peers and other devices.**
   - `/pair` and `/pair/challenge` (agent pairing between Macs),
     `BonjourBrowser` and `SecureChannelClient` (this Mac as a client of
     another's agent), `/pair-invite`.
   - `OwnerDeviceAccessHost` (§5.1).
   - Check each against `RemoteAgentManager` (an Intel stub) and the
     deferred workspaces before porting.
6. **Osaurus ID** (`OsaurusIDService`, `OsaurusIDSessionStore`, the
   Identity section), replacing the API client's `idSessionToken` stubs.
7. **Identity drift:** `AgentKeyPath` v2 and `OsaurusKeychainGroup`. A
   keychain access group needs a real Apple team ID in the signature, which
   Intel's self-signed builds may not have; check before porting.

Each stage: gate run, Rosy section (pairing the real phone), row note in
the backlog.

## Progress

- **Plan (2026-11-02).**
- **Stage 1 (2026-11-02): pairing on the LAN.**
  - **Ported from upstream** (Intel edits are listed under "Intel
    differences" and "Tests" below):
    - `PairingSPAKE2`, `PairingChallengeStore`, `PairingRateLimiter`;
    - `PairingCode`, `MobileConnectIdentity`, `MobilePairingService`;
    - `MobileConnectAdvertiser`, `OsaurusConnectView`, `MobileConnectLog`;
    - `PairingKeyEnvelope`.
  - **Routes** (`IntelHTTPPairing.swift`): upstream's `/pair/hello`,
    `/pair/code`, `/pair/confirm` and `/pair/unpair`. The gate already
    listed them as public paths with the pairing body limit (stage 1 of
    `W-server-api`).
  - **Wiring:**
    - Settings → **Mobile** (`ManagementTab.connect`, after Credits, as
      upstream).
    - `MobilePairingService.shared` starts at launch (keep-awake, key
      expiry).
    - `_osaurus-mobile._tcp` is advertised with the agents while "Expose
      to Network" is on (`IntelNetworkExposure.syncBonjour`).
    - The owner's `GET /agents` lists the connect identity under the
      built-in agent while no custom agent has an address.
  - **Intel differences:**
    - **v1 pairing is macOS 14+.** It seals the key with CryptoKit's HPKE,
      which needs macOS 14. On Ventura a v1 request answers `400` and the
      phone uses v2 (SPAKE2: secp256k1 plus ChaCha20-Poly1305), which the
      current iPhone app sends. The HPKE members of `PairingKeyEnvelope`
      are `@available(macOS 14)`.
    - **No relay yet:**
      - The pairing payload carries no relay URLs
        (`RelayTunnelManager.isAvailableOnIntel` is false until stage 4).
      - Settings → Mobile hides "Reach From Anywhere" and its status.
      - The stub gained upstream's `publicURL(forAddress:)` and the
        `servedElsewhere` status, now handled in the Server tab, the agent
        page and the share sheet.
    - "Continue Phone Chats on This Mac" is hidden until
      `PhoneChatHandoff` (stage 3); it keeps upstream's defaults key.
    - **Logs:** `MobileConnectLog` always writes to
      `~/Library/Logs/Osaurus/mobile-connect.log`. Intel ships
      Debug-configuration builds (`build_rosy.sh`, `cut_intel_release.sh`),
      and upstream's Debug path is inside the build Mac's checkout.
      Upstream's `ConsoleLogFile` (a checkout-relative debug console copy)
      is left out for the same reason.
    - `ServerController` stub: `ensureRunning()` and `notRunningReason()`
      (the server always runs). "Turn on network access" on the Mobile page
      goes through the stub's restart.
    - `BonjourAdvertiser` (Intel's) gained upstream's
      `maxInstanceNameBytes` and `truncateUTF8`.
    - `onChange` uses the one-argument form (macOS 13).
    - **Agent-list sink hops to the main run loop.** Upstream's
      `AgentManager` is main-actor bound; Intel's publishes from any thread.
      Upstream's main-actor sink then trapped the process (first full gate,
      2026-11-02, inside `IntelKnowledgeWriteTests`). The app could have hit
      it too. `MobilePairingService.init` adds `.receive(on: RunLoop.main)`,
      like Intel's other `$agents` subscribers. Regression test:
      `agentChangesOffTheMainThreadDoNotTrap`.
  - **Until stage 2** the phone pairs but can't chat. Every owner route
    from a remote master key still answers `426 secure_channel_required`.
  - **Tests:**
    - Upstream's `MobilePairingTests` and `PairingSPAKE2Tests`. The
      connect-identity collision case checks v1 agent keys only;
      `AgentKeyPath` v2 is stage 7.
    - New `IntelHTTPPairingTests`: a simulated phone runs v2 over HTTP and
      opens the payload; wrong code, spent code, bad bodies, `/pair/hello`,
      unpair refusal.
    - Every route test pairs from 127.0.0.1 and shares
      `PairingRateLimiter.shared` (5 tries a minute, 30 seconds of
      cooldown after a wrong code). The fixture clears it through an Intel
      test seam, `resetForTesting()`. Without that, the v2 test's last
      wrong-code try left the next tests answering `429`.
    - `PairingHardeningTests` waits for stages 4–5 (relay URLs, the
      Mac-to-Mac `/pair` challenge).
  - **Validation (2026-11-02):**
    - Interim gate (CLT 27.0 SDK, native build, kept awake): 4,210 tests in
      521 suites. The only failure is the known avatar-cache test.
    - The x86_64 build with tests compiles.
    - Classifiers: `W-identity-mobile` 16 files left, UNASSIGNED 0.
      Guide check clean.
    - The temp root was removed. Nothing was written to `~/.osaurus` or
      `~/.codex`. The keychain identity mdat is unchanged.
    - The first two full runs stopped early: the agent-list sink trap
      (above) and the test-limiter cooldown. Both are fixed.
    - Rosy: pairing the real iPhone is in the Rosy retest checklist
      ("Paired iPhone: pairing").
- **Stage 2 (2026-11-03): Secure Channel.**
  - **Ported from upstream:** `SecureChannel`, `SecureSessionStore`,
    `SecureChannelResponseEncryptor`, and `CryptoHelpers` whole (Intel's
    copy lacked `signSecureChannelPayload` and three other signing helpers).
    `SecureChannelClient` came in early: the end-to-end tests decode with
    it. Nothing in the app calls it until stage 5.
  - **Routes** (`IntelHTTPSecureChannel.swift`):
    - `POST /secure/session`, with upstream's own rate limiter (30 a
      minute).
    - The `/secure/call` decrypt step. `channelRead` runs it before the
      access gate, so the inner Bearer goes through the validator and
      scope checks unchanged.
  - **Router** (`HTTPHandler`):
    - Requests carry `isSecureChannel` and the pinned address.
      `requestIsSecureChannel` is real now, so the stage 4–6 owner routes
      open to the paired phone.
    - Preflight and the browser-origin check read the outer request
      (upstream).
    - The access key's attribution says `secureChannel`.
    - `logRequest` keeps only the sizes of sealed bodies.
    - The server pipeline gained the encryptor between the HTTP codec and
      the handler.
  - **Intel differences:**
    - The handshake signs with `AgentKey.derive(masterKey:index:)`: Intel
      agents have a v1 `agentIndex`, and upstream's `agentKeyPath` is
      stage 7.
    - Intel's `MasterKey` read never prompts, so upstream's
      `interactionNotAllowed` context is kept as is.
  - **Remote reviewer:** `IntelHTTPAgentRun`'s remote-reviewer flag already
    read `requestIsSecureChannel`. Runs from the paired phone now send
    their approval cards to `/approvals`.
  - **Still stage 3:** the phone-only run fields (`osaurus_run_id`,
    `osaurus_session_id`, `osaurus_job_id`, `osaurus_voice_call`) are
    still ignored. A phone chat streams in one piece and can't be resumed
    after the app goes to the background.
  - **Tests:**
    - Upstream's `SecureChannelTests` and `SecureChannelVectorsTests`, with
      the vector fixture (`Tests/Identity/Fixtures`, a test resource as
      upstream).
    - `SecureChannelE2ETests`, minus the n8n channel case (channels are
      deferred) and the two `osaurus_privacy` cases (`W-privacy-filter`).
      Upstream's `MockChatEngine` is excluded on Intel, so a small streaming
      engine stands in.
    - Two Intel cases: the handshake route's refusals (bad body, wrong
      version, unknown address → 404), and a relay-origin owner read of
      `/sessions` reaching the route through the channel.

  - **Validation (2026-11-03):**
    - Interim gate (kept awake): 4,247 tests in 525 suites. The only
      failure is the known avatar-cache test.
    - The x86_64 build with tests compiles.
    - Classifiers: `W-identity-mobile` 12 files left, UNASSIGNED 0. Guide
      check clean.
    - The temp root was removed. Nothing was written to `~/.osaurus` or
      `~/.codex`. The keychain identity mdat is unchanged.
    - Rosy: "Paired iPhone: Secure Channel" in the Rosy retest checklist.
- **Stage 3a (2026-11-03): phone runs.**
  - **Ported from upstream:** `DetachedPhoneRuns` and `VoiceCallReplies`
    verbatim, with their tests.
  - **Request fields:** `ChatCompletionRequest` decodes `osaurus_run_id`,
    `osaurus_voice_call`, `osaurus_session_id` and `osaurus_create_session`
    in a second container and never encodes them (upstream), so they can't
    reach a provider. Intel's request was synthesized-`Codable`; it now has
    a hand-written decoder with the same keys. `osaurus_privacy` waits for
    `W-privacy-filter`.
  - **Run route** (`IntelHTTPAgentRun`):
    - For the paired phone (master key inside the channel), a run named
      with `osaurus_run_id` is registered in `DetachedPhoneRuns`. The same
      id while it is live follows the running one.
    - Its SSE writer records every frame (`SSEResponseWriter.recorder`,
      now in Intel's writer in `IntelHTTPInference.swift`). The end of the
      stream finishes the run.
    - Closing the connection no longer cancels it; `/runs/{id}/stop` does.
    - `/runs/{id}/events?after=N` replays the frames after N, then follows
      live; `410 run_gone` past the end or over the 16 MB replay budget.
    - Voice-call turns get the spoken-reply note on the last user message.
    - The phone's runs use `ModelOptionsStore` options for the model (the
      picker's Thinking / Reasoning Effort).
  - **Intel differences:**
    - Intel's routes write through `stateRef.contextBox`, which is cleared
      when the connection closes, and would drop every frame after the
      phone left. A detached run falls back to the context it started on,
      as upstream writes to it: the recorder still gets the frames and the
      writes fail harmlessly. Keepalive pings go to a live connection only.
    - No `LocalReasoningCapability.resolveForDispatch` before loading the
      options: Intel has no local reasoning models.
    - Intel's `runRequestTask` never cancelled on close (the run route did
      it itself), so upstream's `outlivesConnection` flag isn't needed.
  - **Fix found on the way:** the stage 2 `/secure/call` error replies sent
    the CORS headers twice (`sendResponse` already adds them).
  - **Tests:** upstream's `DetachedPhoneRunsTests` and
    `VoiceCallRepliesTests`; new `IntelPhoneRunTests` over a real channel:
    a run survives its connection closing and is replayed, `after` past the
    end is `410`, Stop ends it (and says `finished` the second time), a
    voice-call turn carries the note, a loopback script's run id doesn't
    detach, and the phone's fields are decoded but never encoded.

  - **Validation (2026-11-03):**
    - Interim gate (kept awake): 4,269 tests in 528 suites. The only
      failure is the known avatar-cache test.
    - The x86_64 build with tests compiles.
    - Classifiers: `W-identity-mobile` 10 files left, UNASSIGNED 0. Guide
      check clean.
    - The temp root was removed. Nothing was written to `~/.osaurus` or
      `~/.codex`. The keychain identity mdat is unchanged.
    - Rosy: "Paired iPhone: replies in the background, voice calls" in the
      Rosy retest checklist.
