# Rosy Final Acceptance Checklist

This is the canonical end-of-roadmap acceptance pass for the Intel fork. Run it
on Rosy only after the planned feature work for the candidate release is complete.
Do not promote a feature from Partial to Working and tested from M4 compilation,
automated tests, or isolated screenshots alone.

Fill in before testing:

- Candidate commit:
- Build path or archive:
- Rosy macOS version (Ventura or Sequoia):
- Intel Mac model:
- Data-root mode:
- Screen sharing/recording state:

For every failure, record the agent, whether the chat was new or restored, the
selected setting, the visible result, and whether a full relaunch changed it.

## 0. Safety and preflight

- [ ] Back up Rosy's `~/.osaurus`.
- [ ] Record hashes of live configuration files and inventory the agents folder.
- [ ] Keep at least two established agents with different models, avatars,
      themes, tools, Memory, and Knowledge assignments.
- [ ] Keep one disposable agent for destructive tests.
- [ ] Stop screen sharing and screen recording before judging titlebar controls.
- [ ] Confirm the candidate is a signed x86_64 build with macOS 13.0 minimum.

## 1. Existing agents and model routing

- [x] Every existing agent keeps its name, description, model, avatar, order,
      theme, tools, Memory, Knowledge, and Bonjour settings.
- [x] Existing agents display their stored models rather than a shared Claude
      Code fallback.
- [x] A fresh chat from each agent selects and calls that agent's stored model.
- [x] Changing an agent model affects a fresh chat.
- [x] Reset to default restores active-model inheritance in a fresh chat.
- [x] Display and runtime routing remain correct after relaunch.
- [ ] **Regression:** changing the model from a fresh chat must not rewrite the
      agent's configured model in Settings. Rosy currently couples the two.

## 2. App-wide Ventura controls

- [ ] **Failed:** text fields accept focus/input but do not show insertion
      carets on Rosy Ventura.
- [x] Untouched toggles show the correct state and colour before interaction.
- [x] Toggle appearance remains correct after navigation and relaunch.
- [ ] **Failed:** several buttons and selectors render white labels on white
      backgrounds.
- [ ] **Failed:** the Add Knowledge Collection sheet renders its fields and
      buttons with effectively invisible labels; folder selection and creation
      still work, making this a dangerous blind workflow.
- [x] Tab and subtab hover states are visible throughout the app.
- [x] Database and watcher controls do not render blank.
- [ ] Native red/yellow/green window controls remain absent. Record screen
      sharing/recording state before assigning the cause; the current evidence
      proves the visible failure but not whether window chrome or the sharing
      indicator owns it.

## 3. Agent General and Appearance

- [x] Name, description, instructions, temperature, maximum tokens, model, and
      follow-up model save and survive relaunch.
- [x] Reset to default is present and restores model inheritance.
- [ ] **Failed:** no Claude Code control surface exposes Agent/Text mode,
      file-change permission, or shell-command permission anywhere in General
      or Agent Settings.
- [x] Unavailable Claude MCP support is explanatory and has no dead switch.
- [ ] **Failed:** no Delete Data button is visible in the Agents window for a
      disposable custom agent, so deletion cannot be tested. The compiled view
      declares the action under General → Configure, which makes this a UI
      reachability/rendering defect rather than proof that the backend is absent.
- [x] A custom avatar appears on first upload, can be selected, updates the
      header/chat, and survives relaunch.
- [x] Removing the custom avatar restores the letter fallback without leaving a
      mascot falsely selected.
- [x] Distinct agent themes apply to their chats and never leak between agents.
- [x] Mascots, greeting, empty state, action bar, and action-bar items work.
- [ ] **Regression:** selecting a custom avatar updates the main chat but leaves
      the upper Agent Settings header showing the previous avatar.

## 4. Ability and tool enforcement

- [x] Tools off removes assigned tools from fresh and restored chats; Tools on
      restores them.
- [ ] **Failed:** removing a tool from an already-open chat updates the picker,
      but the tool remains callable on the next turn. The runtime dispatch
      boundary is not enforcing the live agent allowlist on Rosy.
- [ ] **Blocked by two Memory failures:** distillation with
      `osaurus/qwen-3-8-max` first fails with “The data couldn’t be read because
      it isn’t in the correct format”; after relaunch it is skipped as
      `no_model:configured_unservable:osaurus/qwen-3-8-max`. Memory off/on
      injection and saving cannot be accepted until both paths are repaired.
- [x] Knowledge off retains collection assignments but blocks chat access;
      Knowledge on restores search.
- [ ] **Partial:** Web Search removes and restores its tools, but
      Self-scheduling has no ability toggle and agents report no scheduling
      tools, so its off/on enforcement cannot be tested.
- [x] All ability values persist after relaunch.
- [x] Tools search, All/Enabled filters, individual/provider assignment, counts,
      persistence, and allowed execution work. Runtime denial after removal is
      tracked separately above and has failed.
- [ ] **Failed:** Rosy shows no unavailable-ability explanation. The compiled
      view declares unavailable rows for Database, Computer Use, Browser Use,
      Spawn, image/video, and AppleScript, so this is a candidate UI
      reachability/rendering mismatch rather than proof those declarations are
      absent from source.

## 5. Insights

- [x] An ordinary Intel chat creates an Insights entry with the correct model,
      duration, request, output, token data, and completion state.
- [x] A tool-using request records offered and executed tools.
- [x] A harmless provider failure creates a useful failed entry.
- [x] Insights does not render as an empty page when records exist.
- [x] Missing newer per-message diagnostics are recorded as part of the later
      chat-interface revamp, not misreported as an Insights data failure.

## 6. Connections and Bonjour

- [x] Network, Remote Connections, and Agent Channels open correctly.
- [x] Bonjour changes immediately and persists through navigation and relaunch.
- [x] Its explanatory status matches the stored value.
- [x] A second device sees `_osaurus._tcp` only while Bonjour is enabled.
- [x] Relay, Shared With, remote grants, and Agent Channels show accurate
      dependency states with no dead actions.

## 7. Automation

- [ ] **Failed:** a schedule can be created and survives relaunch, but its card
      exposes no visible ellipsis/menu for edit, pause, resume, run now, or
      delete. Those actions exist in source but are unreachable on Rosy.
- [x] The next-run banner updates after schedule operations that are reachable.
- [ ] Create a watcher and select a temporary folder.
- [ ] **Failed:** monitoring-mode options remain unreadable on Ventura.
- [ ] **Failed:** adding a file triggers a watcher session and inserts the user
      request, but the session does not inherit the watched folder and produces
      no assistant response. Scheduled sessions also lose their assigned folder.
- [ ] **Failed:** watcher cards expose no visible menu for pause, resume, or
      delete, so those operations and their relaunch state cannot be accepted.

## 8. Agent Memory and Database boundary

- [x] Recent chats open and New Chat retains the current agent.
- [ ] **Blocked:** known pinned-fact text, tags, use counts, and scores cannot be
      accepted while the distillation regression prevents test data generation.
- [ ] **Blocked:** existing episode-summary rendering cannot be accepted while
      distillation is failing.
- [ ] **Blocked:** the compact no-episodes state cannot be distinguished from
      the broken distillation state until distillation works again.
- [x] Database Overview, Tables, Saved Views, and History preserve navigation.
- [x] Until the Intel backend exists, every Database page and Ability card states
      the dependency and offers no fake import/export/edit/delete controls.

## 9. Settings sidebar

- [x] Sections appear in upstream order: General, Models, Agents, Capabilities,
      Automation, Developer Tools.
- [x] Rows within each section follow upstream ordering.
- [x] Intel-unavailable Local Models, Voice, and Sandbox appear together under
      Not Available on This Mac immediately before Developer Tools.
- [x] Unavailable rows are disabled and explanatory.
- [x] Developer Tools reveal state works and persists.
- [x] Narrow, normal, and full-screen widths keep labels, counters, selection,
      scrolling, and Check for Updates usable.

## 10. Native Web Search

- [x] Web Search defaults off for existing and new agents, persists when enabled,
      and gates `web_search` plus `search_and_extract` at runtime.
- [x] A keyless built-in search returns useful results or a redacted error and
      never invokes a paid provider.
- [x] Web, news, and image categories work where supported. Image results expose
      image and thumbnail URLs as structured tool output; inline image previews
      are not part of the current search/chat rendering contract.
- [x] Offline, provider-failure, fallback, and cancellation paths keep chat
      responsive and provide a useful retry path.
- [x] Add, test, disable, re-enable, relaunch, reorder, and delete one credentialed
      provider; its secret never appears in logs, diagnostics, export, or errors.
- [x] Category preferences persist and control the actual routing order.
- [x] Add, test, relaunch, and remove a custom REST provider; bundled identifiers
      cannot be shadowed.
- [x] Extraction handles a normal article, redirect, and large page with bounded
      output; localhost/private-network targets are rejected before fetch.
- [x] An installed legacy `search-intel` plugin is ignored and cannot duplicate
      or override the native tools.
- [x] Premium Search is present only with the real Credits/Router path, defaults
      off, and never turns on merely because Router is enabled.

## 11. Orchestrator settings and bounded delegation

- [x] The Orchestrator route stays selected across Settings navigation.
- [x] Name, prompt, model, temperature, and maximum tokens persist after relaunch
      without changing custom agents.
- [x] Fresh chats use the selected model and prompt; reset restores inheritance;
      already-open chats follow the documented invalidation behavior.
- [ ] **Blocked:** the Orchestrator chat receives no orchestration/delegation
      tools, so admitted-target enforcement cannot be exercised there.
- [ ] **Blocked:** missing, removed, unavailable, denied, and malformed target
      failures cannot be exercised without a callable delegation path.
- [ ] **Blocked:** Ask, Deny, and launcher/target-scoped Always Allow cannot be
      exercised from the Orchestrator chat.
- [ ] **Blocked:** child freshness, isolation, concurrency, cancellation, and
      input/token/output/timeout bounds cannot be exercised from chat.
- [ ] **Blocked:** bounded inline return and the absence of durable sessions,
      artifacts, background work, and nested/model-owned spawn cannot be
      exercised from chat.
- [ ] **Blocked:** admitted-target removal cannot be tested against a fresh
      Orchestrator chat because that chat has no delegation tool.
- [ ] **Failed:** the built-in Orchestrator does not use upstream's standard
      green mascot; the Intel `Agent.default` omits `avatar: "green"`.
- [ ] **Failed:** completed Orchestrator messages lack the ellipsis/actions row
      and message statistics shown beneath ordinary upstream assistant messages.
- [ ] **Failed:** the Intel Orchestrator receives only the user-editable prompt.
      Upstream's substantial built-in Orchestrator instructions are compiled out
      with `DefaultAgentSystemPromptBuilder` and are not replaced in the Intel
      prompt composer.

## 12. Declarative configuration in Settings

- [ ] Export/load the supported current slice and preview it unchanged as a no-op.
- [ ] Preview a name or maximum-token change and inspect every before/after row.
- [ ] Cancel leaves configuration untouched; Apply persists through relaunch and
      does not modify personal agents.
- [ ] A plan made stale by an external setting change cannot overwrite newer data.
- [ ] One approval cannot be replayed.
- [ ] Unsupported `agents` data rejects cleanly.
- [ ] `api_key` rejects without revealing its value while valid `max_tokens` is
      accepted.

## 13. Model-callable `orchestrator_config`

- [ ] **Failed at entry:** a new built-in Orchestrator chat does not see
      `orchestrator_config`; therefore its custom-agent and unbound denial paths
      were not tested manually.
- [ ] **Blocked by missing tool exposure:** plan paths, fingerprints, and private
      value omission were not exercised.
- [ ] **Blocked by missing tool exposure:** the requesting-chat approval card was
      not exercised.
- [ ] **Blocked by missing tool exposure:** Apply/Cancel behavior was not exercised.
- [ ] **Blocked by missing tool exposure:** apply persistence was not exercised.
- [ ] **Blocked by missing tool exposure:** stale-plan rejection was not exercised.
- [ ] **Blocked by missing tool exposure:** stop/close cancellation was not exercised.
- [ ] **Blocked by missing tool exposure:** tool-policy Deny and dedicated-card
      Ask/Auto behavior were not exercised.

## 14. Later-roadmap feature acceptance

Complete the matching detailed test section when each feature lands:

- [ ] Revamped Credits and Router, including paid consent, billing failures,
      diagnostics, balance/activity, and Web Search integration.
- [ ] Global Channels transports, credentials, allowlists, reply assignment,
      proactive destinations, outbox policy, activity, and revocation.
- [ ] Browser Use feasibility/runtime, persistent isolated sessions, sign-in,
      approvals, cancellation, and Ventura support.
- [ ] Computer Use feasibility/runtime, Accessibility, optional Screen Recording,
      action approval, cancellation, and Ventura support.
- [ ] Cloud-only Media discovery, model defaults, image/video permissions, quotes,
      job recovery, cancellation semantics, and returned artifacts.
- [ ] Privacy Overview, Rules, Providers, Models, Storage, redaction review, local
      bypass rules, persistence, and destructive actions.
- [ ] Revamped chat interface and Workspaces when their deferred ports land.

### 14A. Credits, Router, and Premium Web Search

- [ ] Router defaults on for an existing install unless the user previously
      opted out; the explicit value survives relaunch.
- [ ] Turning Router off requires confirmation, removes Router models, clears
      stale balance/activity, and causes no balance, usage, catalog, inference,
      Premium Search, or extraction request.
- [ ] Turning Router on reconnects and restores its real catalog and account
      state without creating duplicate providers.
- [ ] Top-up accepts the minimum and ordinary decimal amounts; zero, negative,
      non-numeric, non-finite, and huge values cannot open Checkout.
- [ ] Checkout cancellation, browser handoff, successful return, network error,
      insufficient funds, frozen account, unauthorized identity, and rate limit
      have distinct useful states with no raw server body.
- [ ] Activity and exported diagnostics contain no prompt, response, query,
      URL, page text, key, signature, or identity secret.
- [ ] Balance, model prices, usage charges, and wallet activity use credits;
      Checkout still states the exact dollar charge before opening the browser.
- [ ] Redeem a valid code and confirm the awarded credits and refreshed balance;
      trim surrounding whitespace and reject an empty or overlong submission.
- [ ] Already-redeemed and referral-pending successes are clear; invalid code,
      403/account restriction, unauthorized identity, 429, network failure, and
      5xx states are distinct and reveal no raw server response.
- [ ] Quit and reopen after redemption; the wallet remains authoritative and no
      code or transient success/error state is persisted.
- [ ] Account details show request/input/output totals, usage cost, wallet net,
      recent usage, and transactions; refresh does not duplicate entries.
- [ ] No Insights link appears until a selected Router request can be correlated
      with a real Intel chat turn. No onboarding redemption is implied.
- [ ] Premium Search defaults off. Router on alone never enables it.
- [ ] Included search credits are used before wallet funds; wallet auto-pay is
      independently opt-in and persists.
- [ ] Premium success, empty/replayed response, 402, paid-web-disabled, 404,
      409, 429, timeout, and 5xx follow the documented native fallback path
      without duplicate billing or speculative retries.
- [ ] Settings test search and agent tools use the same route; removing the
      agent's Web Search ability still blocks both search tools.
- [ ] Hosted extraction rejects localhost and private-network targets before a
      request and never exposes billing details to the model.
- [ ] A direct article URL uses hosted contents when available, falls back
      locally once on empty/replayed/error responses, and local fallback blocks
      redirects into localhost or a private network.
- [ ] The same logical idempotency key reaches `/v1/search` or `/v1/contents`
      in both the signed JSON body and `Idempotency-Key` header; no fallback
      invents a second paid attempt.
- [ ] Included requests update the allowance display without reducing the
      wallet balance; only paid requests reduce the optimistic balance.

## 15. Final regression and postflight

- [ ] With screen sharing stopped, Settings and chat windows show clickable native
      red, yellow, and green controls before and after theme changes.
- [ ] Rapid agent/tab/subtab switching leaks no model, theme, avatar, ability, or
      content state.
- [ ] Smoke-test ordinary chat, Codex, Claude Code, Knowledge, Projects, working
      folders, project memory, Web Search, and every newly landed roadmap feature.
- [ ] Quit completely and reopen for one final migration/persistence pass.
- [ ] Compare final configuration hashes and agent inventory with preflight.
- [ ] Explain every expected difference; any unexplained mutation fails handoff.

## Evidence rule

Update `FEATURE_PARITY.md`, `UPSTREAM_SYNC.md`, and the relevant feature manual
with the exact Rosy result. A visible route, successful M4 build, or passing
automated suite does not substitute for Ventura runtime and UI evidence.
