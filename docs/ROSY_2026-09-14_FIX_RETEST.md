# Rosy Post-QA Fix Retest

Run this checklist on Rosy (Intel, macOS Ventura) against the build produced after
the 2026-09-13 acceptance pass. These checks target the defects repaired from that
pass; the full acceptance checklist remains the final release gate.

## Preflight

- Candidate: `build/rosy-deploy/Build/Products/Debug/osaurus.app`
- Verified on M4 before transfer: x86_64, macOS 13.0 minimum, canonical data
  enabled, signed by `Osaurus Intel Code Signing`; 983 tests / 149 suites pass
  serially against an isolated test root.
- [ ] Record the app commit/build identifier and copy the pre-test agent inventory.
- [ ] Quit every older Osaurus build before opening this one.
- [ ] Launch with Rosy's existing `~/.osaurus`; no agent or chat should be reset.

## Native Ventura controls and message chrome

Rosy result from the first repair candidate (`f38bfecf1`): **failed**. The chat
window rendered its controls, but Settings kept clickable traffic-light hit
regions with invisible images. Settings text editors still hid the caret and
several untouched native controls remained white on white. Presenting the
Knowledge sheet changed the window state enough to reveal grey traffic lights,
which isolates the defect to Settings window appearance/titlebar composition,
not missing standard buttons. The Knowledge form itself worked but was missing
upstream's labels, help, and include/exclude filters. Assistant actions returned,
but the metrics row did not consistently expose TTFT, tok/s, and token count.

The next candidate uses an ordinary AppKit titlebar for Settings, pins its native
controls to Aqua independently of the active agent chat theme, reapplies field
editor text/caret rendering on focus, restores the full local-folder Knowledge
form including persisted globs, and renders statistics when a restored turn has
only its persisted token count. The attached Rosy screenshots are the acceptance
evidence for this correction; none of the items below are promoted until Rosy
passes them.

For this group's second candidate, use the smaller evidence checklist in
[`ROSY_2026-09-19_VENTURA_RETEST.md`](ROSY_2026-09-19_VENTURA_RETEST.md).

- [ ] With screen sharing stopped, both Settings and chat show clickable red,
      yellow, and green window controls.
- [ ] Repeat after changing themes and after a complete relaunch.
- [ ] Every text field and editor shows an insertion caret, focus, selection, and
      readable placeholder text.
- [ ] Open Add Knowledge Collection. Its labels, fields, folder button, Cancel,
      and Add remain readable in normal, hover, pressed, focused, and disabled states.
- [ ] Check Memory controls and a representative menu, selector, toggle, and disabled
      button elsewhere; no white-on-white control remains.
- [ ] A completed assistant message shows its actions menu and available message
      statistics/details. Confirm the controls survive theme changes and relaunch.

## Agent model, Claude Code, data, and avatar

- [ ] In a fresh chat, change only the chat model. The Agent Settings model must
      remain unchanged after the next turn, navigation, and relaunch.
- [ ] Change the model in Agent Settings; a new chat must inherit that setting.
- [ ] General -> Configure always exposes the Claude Code section clearly.
- [ ] Select a Claude Code model and verify Agent/Text only, Allow file changes,
      Allow shell commands, and the explanatory unavailable MCP row.
- [ ] Exercise Claude Code with each file/shell permission off and on.
- [ ] On a disposable custom agent, find Agent Data -> Delete Data. Confirm it
      deletes chats, pinned facts, and episode summaries while keeping the agent.
- [ ] Upload and select a custom avatar. It updates the Agent Settings header and
      chat immediately, survives relaunch, and clears correctly to the monogram.

## Ability and tool enforcement

- [ ] In an already-open chat, remove an assigned tool. On the next turn it is no
      longer offered, and a stale call is rejected without executing.
- [ ] Repeat once with Auto-discover on and once with Manual selection.
- [ ] Re-enable the tool and confirm it returns on the next turn.
- [ ] Toggle Self-scheduling off. `schedule_next_run`, `cancel_next_run`, and
      `notify` disappear and stale calls are rejected.
- [ ] Toggle Self-scheduling on. The tools return and the Automation page exposes
      the configured bounds.
- [ ] Intel-unavailable Database, native subagents, and Sandbox abilities remain
      visibly explanatory and expose no working-looking controls.

## Memory distillation

- [ ] Configure the Rosy-routable `osaurus/qwen-3-8-max` model and run distillation.
      It must not report malformed response data.
- [ ] Quit and relaunch before provider discovery finishes; distillation must not
      skip with `no_model:configured_unservable`.
- [ ] Confirm a valid Qwen response containing text content parts is accepted.
- [ ] Confirm a deliberately malformed/non-text response still fails with a useful,
      redacted, bounded diagnostic.
- [ ] After successful distillation, Agent Memory shows pinned fact text, tags, use
      counts, scores, and compact episode summaries/empty states.
- [ ] Turn Memory off and confirm no recall or saving; turn it on and confirm both.

## Schedules and watchers

- [ ] Create a temporary schedule and open it from its card.
- [ ] Edit, pause, resume, Run Now, relaunch, and delete it; the next-run banner
      updates after each operation.
- [ ] Create a watcher and confirm every responsiveness option is readable before
      selection.
- [ ] Assign a temporary folder, relaunch, and trigger the watcher with a new file.
- [ ] The generated chat shows the assigned folder, the agent can list/read it, and
      an assistant response completes rather than leaving only the user message.
- [ ] Pause, resume, edit, relaunch, and delete the watcher.

## Orchestrator

- [ ] The built-in Orchestrator uses the upstream green mascot in Settings and chat.
- [ ] With the editable prompt empty, a fresh Orchestrator chat still receives the
      built-in role that configures Osaurus and delegates bounded work.
- [ ] The Orchestrator receives `orchestrator_config` and the delegation tool; custom
      agents do not receive either.
- [ ] Admit one custom agent and one cloud model, then delegate one small task to each.
- [ ] Missing, removed, unavailable, denied, and malformed targets fail closed.
- [ ] Ask pauses; Deny blocks; Always Allow is scoped to the launcher/target pair.
- [ ] A child is fresh, standalone, one-turn, tool-free, one-at-a-time, cancellable,
      and bounded by input, output, token, and timeout limits.
- [ ] The result is bounded inline text with no durable child chat, file artifact,
      background continuation, or nested spawn.
- [ ] Remove an admitted target, relaunch, and confirm a fresh chat cannot use it.

## Postflight

- [ ] Rapidly switch agents, tabs, and subtabs; no model, theme, avatar, ability, or
      content state leaks.
- [ ] Smoke-test ordinary chat, Codex, Claude Code, Knowledge, Projects, working
      folders, project memory, Web Search, Automation, Memory, and Orchestrator.
- [ ] Quit completely and reopen for a final persistence pass.
- [ ] Compare agent inventory/configuration with preflight and explain every change.
