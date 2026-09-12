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

- [ ] Every existing agent keeps its name, description, model, avatar, order,
      theme, tools, Memory, Knowledge, and Bonjour settings.
- [ ] Existing agents display their stored models rather than a shared Claude
      Code fallback.
- [ ] A fresh chat from each agent selects and calls that agent's stored model.
- [ ] Changing an agent model affects a fresh chat.
- [ ] Reset to default restores active-model inheritance in a fresh chat.
- [ ] Display and runtime routing remain correct after relaunch.

## 2. App-wide Ventura controls

- [ ] Text fields show insertion carets, focus rings, selection, and hover.
- [ ] Untouched toggles show the correct state and colour before interaction.
- [ ] Toggle appearance remains correct after navigation and relaunch.
- [ ] Buttons show labels/icons in normal, hover, pressed, and disabled states.
- [ ] Menus and dropdown options are readable before selection.
- [ ] Tab and subtab hover states are visible throughout the app.
- [ ] Database and watcher controls do not render blank.

## 3. Agent General and Appearance

- [ ] Name, description, instructions, temperature, maximum tokens, model, and
      follow-up model save and survive relaunch.
- [ ] Reset to default is present and restores model inheritance.
- [ ] Claude Code exposes Agent/Text only plus file-change and shell-command
      permissions; each disabled/enabled state is enforced.
- [ ] Unavailable Claude MCP support is explanatory and has no dead switch.
- [ ] Delete Data removes chats and memory from a disposable agent but keeps the
      agent.
- [ ] A custom avatar appears on first upload, can be selected, updates the
      header/chat, and survives relaunch.
- [ ] Removing the custom avatar restores the letter fallback without leaving a
      mascot falsely selected.
- [ ] Distinct agent themes apply to their chats and never leak between agents.
- [ ] Mascots, greeting, empty state, action bar, and action-bar items work.

## 4. Ability and tool enforcement

- [ ] Tools off removes assigned tools from fresh and restored chats; Tools on
      restores them.
- [ ] Removing a tool from an already-open chat removes it on the next turn and
      stale calls cannot execute.
- [ ] Memory off prevents injection and saving; Memory on restores both.
- [ ] Knowledge off retains collection assignments but blocks chat access;
      Knowledge on restores search.
- [ ] Web Search and Self-scheduling toggles remove and restore their tools in
      fresh and restored chats.
- [ ] All ability values persist after relaunch.
- [ ] Tools search, All/Enabled filters, individual/provider assignment, counts,
      persistence, allowed execution, and removed-tool denial work.
- [ ] Unavailable abilities remain clearly marked and cannot create fake config.

## 5. Insights

- [ ] An ordinary Intel chat creates an Insights entry with the correct model,
      duration, request, output, token data, and completion state.
- [ ] A tool-using request records offered and executed tools.
- [ ] A harmless provider failure creates a useful failed entry.
- [ ] Insights does not render as an empty page when records exist.
- [ ] Missing newer per-message diagnostics are recorded as part of the later
      chat-interface revamp, not misreported as an Insights data failure.

## 6. Connections and Bonjour

- [ ] Network, Remote Connections, and Agent Channels open correctly.
- [ ] Bonjour changes immediately and persists through navigation and relaunch.
- [ ] Its explanatory status matches the stored value.
- [ ] If a second device is available, `_osaurus._tcp` appears only while enabled.
- [ ] Relay, Shared With, remote grants, and Agent Channels show accurate
      dependency states with no dead actions.

## 7. Automation

- [ ] Create, edit, pause, resume, run now, relaunch, and delete a schedule.
- [ ] The next-run banner updates after each schedule operation.
- [ ] Create a watcher and select a temporary folder.
- [ ] Every monitoring-mode option is readable.
- [ ] Adding a file triggers a run whose chat inherits the watched folder.
- [ ] Pause, resume, relaunch, and delete the watcher.

## 8. Agent Memory and Database boundary

- [ ] Recent chats open and New Chat retains the current agent.
- [ ] Known pinned facts show text, tags, use counts, and scores.
- [ ] Existing episode summaries render compactly.
- [ ] Agents without episodes receive a compact empty state.
- [ ] Database Overview, Tables, Saved Views, and History preserve navigation.
- [ ] Until the Intel backend exists, every Database page and Ability card states
      the dependency and offers no fake import/export/edit/delete controls.

## 9. Settings sidebar

- [ ] Sections appear in upstream order: General, Models, Agents, Capabilities,
      Automation, Developer Tools.
- [ ] Rows within each section follow upstream ordering.
- [ ] Intel-unavailable Local Models, Voice, and Sandbox appear together under
      Not Available on This Mac immediately before Developer Tools.
- [ ] Unavailable rows are disabled and explanatory.
- [ ] Developer Tools reveal state works and persists.
- [ ] Narrow, normal, and full-screen widths keep labels, counters, selection,
      scrolling, and Check for Updates usable.

## 10. Native Web Search

- [ ] Web Search defaults off for existing and new agents, persists when enabled,
      and gates `web_search` plus `search_and_extract` at runtime.
- [ ] A keyless built-in search returns useful results or a redacted error and
      never invokes a paid provider.
- [ ] Web, news, and image categories work where supported.
- [ ] Offline, provider-failure, fallback, and cancellation paths keep chat
      responsive and provide a useful retry path.
- [ ] Add, test, disable, re-enable, relaunch, reorder, and delete one credentialed
      provider; its secret never appears in logs, diagnostics, export, or errors.
- [ ] Category preferences persist and control the actual routing order.
- [ ] Add, test, relaunch, and remove a custom REST provider; bundled identifiers
      cannot be shadowed.
- [ ] Extraction handles a normal article, redirect, and large page with bounded
      output; localhost/private-network targets are rejected before fetch.
- [ ] An installed legacy `search-intel` plugin is ignored and cannot duplicate
      or override the native tools.
- [ ] Premium Search remains absent until Credits/Router is real.

## 11. Orchestrator settings and bounded delegation

- [ ] The Orchestrator route stays selected across Settings navigation.
- [ ] Name, prompt, model, temperature, and maximum tokens persist after relaunch
      without changing custom agents.
- [ ] Fresh chats use the selected model and prompt; reset restores inheritance;
      already-open chats follow the documented invalidation behavior.
- [ ] Only explicitly admitted custom agents and cloud models can be delegated to.
- [ ] Missing, removed, unavailable, denied, and malformed targets fail closed.
- [ ] Ask pauses, Deny prevents execution, and Always Allow is scoped to the exact
      launcher/target pair.
- [ ] The child is fresh, standalone, one-turn, tool-free, one-at-a-time,
      cancellable, and bounded by input, token, output, and timeout limits.
- [ ] The result is bounded inline text; no durable child session, filesystem
      artifact, background continuation, or nested/model-owned spawn appears.
- [ ] Removing an admitted target persists and blocks it in a fresh chat.

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

- [ ] A new built-in Orchestrator chat sees the tool; custom-agent and unbound
      contexts cannot see or execute it.
- [ ] Plan output contains changed paths and fingerprints, never current private
      prompt/configuration values.
- [ ] Apply opens the exact before/after card only in the requesting chat window.
- [ ] The card offers Apply and Cancel only; Cancel never mutates.
- [ ] Apply persists through relaunch.
- [ ] A pending plan made stale elsewhere fails without overwriting new state.
- [ ] Stopping or closing the originating chat cancels a pending review without
      mutation.
- [ ] Explicit tool-policy Deny blocks without a card; Ask/Auto still use the
      dedicated card and never expose an Always Allow shortcut.

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
