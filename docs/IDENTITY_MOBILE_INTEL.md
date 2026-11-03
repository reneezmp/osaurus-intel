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
3. **Phone runs and chats.**
   - Detached runs (`osaurus_run_id`, `/runs/{id}/events`, `/runs/{id}/stop`)
     and detached image jobs (`osaurus_job_id`, `/images/jobs/{id}/events`).
   - Continuing a Mac chat (`osaurus_session_id`, image exchanges,
     `PhoneChatHandoff`); voice-call turns (`VoiceCallReplies`).
   - The phone's model options; binding `hasRemoteReviewer` so approvals
     reach the phone.
   - The 2026-10 audit items: #3070, #3106, #3135, #3152, #3207.
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
