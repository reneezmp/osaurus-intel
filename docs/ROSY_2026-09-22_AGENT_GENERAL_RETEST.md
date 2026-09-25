# Rosy Agent General and Appearance acceptance — 2026-09-22

This focused pass promotes the first slice of the remaining main Rosy
acceptance roadmap and now accumulates the Abilities/Tools, Automation, and
Memory slices. Run it against the reviewed `1.0.50` build `51` candidate.

## Candidate

- Version: `1.0.50` (`51`)
- Archive: `build/rosy-deploy/Osaurus-Intel-Memory-2026-09-23.zip`
- SHA-256: `40609fb2cf505d6bd4b6e23c1cb1b93fd2f5a71e93840ad3f398a431e0fcc930`
- Data root: canonical `~/.osaurus`
- Overall result: [ ] Pass  [ ] Fail  [ ] Partial

## Automated gate

The cumulative source tree passes the complete **1,054-test / 159-suite** package
gate before manual QA. The enumerated Memory slice passes **74/74 tests in 12
suites**, including:

- `IntelAgentRuntimeLaneTests`: 11/11, including chat-local model isolation,
  live allowlist denial, and the Manual-mode self-scheduling master gate.
- `IntelClaudeCodeTests`: 10/10.
- `IntelAgentPresentationPersistenceTests`: 1/1 custom-avatar persistence test.
- `WebSearchToolTests`: 11/11.
- `ScheduleExecutionAnchorTests`: 3/3.
- `ExecutionContextFolderActivationTests`: 2/2.
- `IntelVenturaRenderingTests`: 8/8.
- `IntelMemoryDistillationRegressionTests`: 5/5, including managed-Router cold
  discovery, Qwen text-part decoding, non-text rejection, and bounded redacted
  diagnostics.
- `IdentityOverrideTests`: 5/5 pinned-identity deduplication and metadata tests.
- `MemoryServiceBackfillTests`: 10/10 conversational turn-pairing cases.
- Re-enabled configuration, context-assembly, model-invariant, and database
  suites, plus FTS5 recall, relevance-gate, and budget-fallback coverage.

These tests lock the manager/session boundaries and persistence behavior; they
do not replace the live-surface and Ventura rendering checks below.

## 0. Safety

- [ ] Keep one disposable custom agent for destructive/avatar checks.
- [ ] Record that agent's configured model before testing.
- [ ] Do not use the built-in Orchestrator for Delete Data or custom-avatar
      checks; built-in identities intentionally reject those mutations.

## 1. Chat-local model isolation

- [ ] Open a fresh chat for the disposable agent and note its current model.
- [ ] Change only the model in the chat-window picker.
- [ ] Open Settings → Agents → the same agent → Configure.
- [ ] Its configured Model remains unchanged; the chat override must not have
      written through to Agent Settings.
- [ ] Start another fresh chat for that agent. It inherits the configured Agent
      Settings model, not the previous conversation's override.
- [ ] Change the model from Agent Settings. A subsequent fresh chat inherits the
      new configured value.
- [ ] Use **Reset to default** in Agent Settings. A subsequent fresh chat uses
      the global default model.

## 2. Claude Code controls

- [ ] In the agent's Configure page, the **Claude Code** section is visible
      directly below Model without opening Advanced.
- [ ] Before selecting Claude Code, the section explains that its controls apply
      when a Claude Code model is selected.
- [ ] Select a Claude Code model. **Agent** and **Text only** are readable and
      selectable.
- [ ] In Agent mode, **Allow file changes** and **Allow shell commands** are
      visible, readable, and independently toggleable.
- [ ] The unavailable **Osaurus tools** row is explanatory and has no working-
      looking switch.
- [ ] Toggle both permissions, navigate away and back, then relaunch; their
      values persist.
- [ ] Optional runtime smoke test: attach a disposable folder and verify Text
      only exposes no built-in tools; Agent mode respects file/shell denial and
      opt-in.

## 3. Delete Agent Data reachability and scope

- [ ] In Configure, scroll below Advanced. **Agent Data** and **Delete Data**
      are visible for the disposable custom agent.
- [ ] Press **Delete Data**. A confirmation explicitly says chats, pinned facts,
      and episode summaries will be removed while the agent and settings stay.
- [ ] Cancel once; nothing changes.
- [ ] Create or retain one disposable chat for this agent, confirm deletion, and
      verify its chats and Memory data disappear.
- [ ] The agent itself remains present with its name, model, theme, abilities,
      permissions, and Knowledge assignments intact.
- [ ] Other agents' chats and Memory remain untouched.

## 4. Custom-avatar synchronization

- [ ] Upload a disposable image as the custom avatar.
- [ ] It immediately becomes selected and appears in the Configure avatar grid,
      upper Agent Settings header, Agents list, and chat header/sidebar without
      navigating away first.
- [ ] Replace it with a different image. Every live surface updates instead of
      retaining the first decoded image.
- [ ] Quit and relaunch. The replacement avatar persists everywhere.
- [ ] Select a mascot or monogram. The custom image disappears from every live
      surface and does not remain falsely selected.

## 5. Regression smoke

- [ ] Settings traffic lights remain visible and correctly positioned.
- [ ] The Core Model picker still renders its selected text, border, and chevron.
- [ ] An ordinary non-Claude chat still sends and receives normally.

## 6. Agent Settings — Abilities and Tools

Continue with the same disposable custom agent. Use a harmless assigned tool
whose result is easy to recognize; do not use a write-capable tool for denial
testing.

### 6.1 Live tool revocation

- [ ] With **Auto-discover relevant capabilities** selected, keep an agent chat
      open, remove the harmless tool in Settings → Agents → Abilities → Tools,
      and return to that same chat.
- [ ] On the next turn the removed tool is no longer offered. A deliberately
      stale call is rejected before execution and produces no side effect.
- [ ] Re-enable the tool. It is offered and can complete a benign call on the
      next turn without recreating the chat.
- [ ] Repeat the remove/deny/re-enable sequence with **Manual selection**.
- [ ] Navigate away and back, then quit and relaunch. The selected mode and
      assignments persist.

### 6.2 Master Tools switch

- [ ] Turn **Tools** off in Abilities. Assigned tools disappear from the already-
      open chat, a fresh chat, and a restored chat; a stale call is rejected.
- [ ] Tool assignments remain configured while the master switch is off.
- [ ] Turn **Tools** on. The configured tools return in all three chat states.
- [ ] Mounted-folder tools remain available when their folder and permission
      requirements are satisfied; the built-in Orchestrator retains only its
      explicit built-in tools. Neither exception admits unrelated tools.

### 6.3 Independent ability gates

- [ ] Web Search off removes `web_search` and `search_and_extract` from the open
      chat and rejects a stale call; on restores them.
- [ ] Knowledge access still follows its collection grants independently of the
      individual Tools-page assignments.
- [ ] Self-scheduling is visibly marked **Unavailable** in both Abilities and
      General/Scheduling, explains the missing Intel scheduler tools, and points
      to explicit schedules and folder watchers under Automation.
- [ ] Neither surface exposes a switch, schedule-mode picker, or other working-
      looking control. Legacy Ambient/Reactive/Project records do not advertise
      or execute `schedule_next_run`, `cancel_next_run`, or `notify`.

### 6.4 Truthful Intel-unavailable surfaces

- [ ] Abilities visibly explains that Database and Autonomous Execution are
      unavailable in this Intel build; neither row exposes a working-looking
      switch or action.
- [ ] The native-subagents explanation names Computer Use, Browser Use, Spawn,
      image/video, and AppleScript as unavailable and offers no dead controls.
- [ ] The Sandbox page clearly explains the unavailable runtime and points to
      the supported Claude Code folder/permission path.
- [ ] Text, icons, disabled states, and scrolling remain readable in both active
      and inactive windows.

Memory off/on is deliberately not promoted by this section. Its distillation
failure is tracked by the later dedicated Memory acceptance slice. Likewise,
the unavailable features above pass by being accurate and non-actionable—not by
pretending their missing backends exist.

## 7. Agent Settings — Automation

Use only the disposable agent and a newly created temporary folder containing
synthetic files. Existing schedules, watchers, folders, and chats are
observation-only.

### 7.1 Schedule lifecycle

- [ ] Create a temporary schedule with a harmless prompt such as “Reply with
      exactly `AUTOMATION_TEST_OK`; do not use tools or modify files.” Its card
      and the next-run banner appear immediately.
- [ ] The card exposes visible **Edit**, **Run Now**, **Pause/Resume**, and
      **Delete** buttons without relying on an ellipsis menu. Their tooltips are
      readable.
- [ ] Edit its name, prompt, frequency/time, agent, and temporary working folder;
      reopen the editor and confirm the values.
- [ ] Pause and resume it. Card state and the next-run banner update immediately.
- [ ] Run Now. The generated chat uses the chosen agent/model and folder, records
      scheduled origin, includes the request, and completes with the expected
      assistant response—not merely a persisted user turn.
- [ ] Quit and relaunch. Configuration and enabled state persist, and another
      safe Run Now completes.
- [ ] Delete the disposable schedule through its confirmation. It and its next-
      run state disappear without affecting another schedule.

### 7.2 Watcher lifecycle

- [ ] Create a watcher for a dedicated empty temporary folder with read-only
      instructions and no file-write tools.
- [ ] Every responsiveness/monitoring option is readable before and after
      selection; the chosen option and Recursive state survive editor reopen.
- [ ] The card exposes visible **Edit**, **Run Now**, **Pause/Resume**, and
      **Delete** buttons, with readable tooltips and delete confirmation.
- [ ] Add one synthetic text file. The watcher fires once after its selected
      debounce, creates a watcher-origin chat for the chosen agent, mounts the
      watched folder, can read the sentinel file, and completes an assistant
      response.
- [ ] Pause it and add another synthetic file. No automatic run occurs. Manual
      Run Now remains an explicit user action and completes once.
- [ ] Resume, edit the prompt/folder/mode, and trigger with a new synthetic file.
      The updated values—not stale ones—govern the run.
- [ ] Quit and relaunch. Folder access/bookmark, configuration, mode, and enabled
      state persist; a safe trigger still completes.
- [ ] Delete the disposable watcher through its confirmation. It does not
      reappear or trigger again.

### 7.3 Safety and postflight

- [ ] Never point the watcher at Desktop, Downloads, a real project, a synced
      folder, or any directory containing valuable files.
- [ ] Record the disposable schedule/watcher IDs and exact temporary path before
      testing. Clean up only those resolved targets—never broad globs.
- [ ] Existing automations remain byte-for-byte unchanged, and no unexplained
      synthetic agent/session/config residue remains after cleanup.
- [ ] Re-run the section 5 traffic-light/Core Model/ordinary-chat smoke checks.

## 8. Agent Settings — Memory

Continue with the disposable custom agent. Enable global Memory and explicitly
opt this agent into paid cloud distillation. Use a known-working managed Router
model—preferably `osaurus/qwen-3-8-max`—and a short chat containing distinctive,
non-sensitive facts that cannot be confused with existing memories.

### 8.1 Cold-launch model routing

- [ ] Select and save the Router-qualified distillation model, then quit Osaurus
      completely before performing any ordinary chat request with that model.
- [ ] Relaunch and use Memory's explicit **Distill pending** action first. The
      request reaches the configured provider; it is not skipped as
      `no_model:configured_unservable:osaurus/qwen-3-8-max`.
- [ ] A successful Qwen response whose `content` is an array of text parts is
      accepted. No “data couldn't be read because it isn't in the correct
      format” error appears.
- [ ] If the provider returns a malformed or non-text response, distillation
      fails visibly with a bounded, authorization-redacted diagnostic and the
      pending signals remain recoverable for a later retry.

### 8.2 Stored facts, episodes, and empty state

- [ ] End/switch the disposable chat or use **Distill pending** after its
      distinctive facts meet the novelty threshold.
- [ ] The agent's Memory page renders the resulting pinned-fact text, tags, use
      counts, and scores without blank rows or stale values.
- [ ] Episode summaries render compactly and remain readable at Rosy's normal
      and narrow window sizes.
- [ ] A different disposable agent with no episodes shows the intentional
      compact empty state, not a broken-loading or distillation-failure state.
- [ ] Navigate away and back, then quit and relaunch. Facts, episodes, metadata,
      and the correct per-agent boundary persist.

### 8.3 Enforcement and paid-operation consent

- [ ] Turn this agent's Memory ability off. Existing stored records remain
      preserved, but fresh and restored chats neither inject recalled Memory nor
      save new conversational Memory.
- [ ] Turn Memory on. Recall injection and saving resume without recreating the
      agent or losing the preserved records.
- [ ] Disable the agent's paid cloud-distillation opt-in. Ordinary chat remains
      usable, but automatic and explicit cloud distillation do not silently run;
      pending work remains recoverable.
- [ ] Re-enable the opt-in and explicitly distill. The pending work completes
      once, without duplicate facts or episodes.

### 8.4 Storage safety and postflight

- [ ] Record the disposable agent id before testing. Do not delete or rewrite
      Memory belonging to an existing personal agent.
- [ ] Confirm another agent's facts, episodes, chats, and settings remain
      unchanged throughout the test.
- [ ] Clean up only through the disposable agent's scoped **Delete Data** flow.
      The agent and its settings remain while its chats, pinned facts, and
      episodes disappear; no other namespace is affected.
- [ ] Re-run the section 5 traffic-light/Core Model/ordinary-chat smoke checks.

### 8.5 Historical-chat backfill

- [ ] In Memory → Diagnostics, **Backfill history** is visible and its
      confirmation explicitly says eligible chats will be sent through cloud
      distillation. Cancel once; no sessions or pending counts change.
- [ ] With one disposable eligible chat, start backfill. Progress reports
      sessions and buffered turns, then distillation completes and preserves the
      chat's original date in the resulting episode.
- [ ] Run backfill again. The already buffered/distilled conversation is skipped
      and no duplicate episode or pinned fact appears.
- [ ] Start a multi-session disposable backfill and cancel it. The operation
      stops between sessions/distillations, accurately reports cancellation,
      and any already-buffered work remains available to **Distill pending**.
- [ ] A non-project agent without paid-distillation consent is skipped. A chat
      inside a disposable project may backfill only into that project's shared
      namespace when personal Memory/distillation is off; it must not create
      personal agent facts or episodes.

## 9. Orchestrator and bounded delegation

Use the built-in green Orchestrator plus one disposable custom target agent. Do
not admit a personal agent or a write-capable target. The child contract is one
fresh text-only turn: no tools, files, nested spawn, durable child session,
background continuation, or autonomous work.

### 9.1 Settings and runtime identity

- [ ] Settings → Agents → Orchestrator opens the dedicated page and remains
      selected across navigation.
- [ ] Name, editable prompt, remote model, temperature, and maximum tokens save
      and survive relaunch. Restore Defaults restores inheritance without
      modifying custom agents.
- [ ] A fresh Orchestrator chat uses the saved model/generation values and always
      retains the fixed built-in orchestration role before the editable persona.
- [ ] A custom agent receives neither that fixed role nor either Orchestrator-
      only model-callable schema.

### 9.2 Target admission and bounded delegation

- [ ] Admit exactly one disposable custom agent and its available remote cloud
      model. A fresh Orchestrator chat can call the bounded delegation tool.
- [ ] With policy **Ask**, the exact Orchestrator/target pair requires one visible
      approval; approve once and receive a bounded inline text result.
- [ ] With **Deny**, no child request starts. With **Always Allow**, only that
      exact launcher/target pair bypasses the prompt and the choice persists.
- [ ] Missing, removed, built-in, self, unadmitted, malformed, or unavailable-
      model targets fail closed with actionable output and no provider request.
- [ ] Input, token, output, timeout, and one-active-child bounds are enforced.
      Cancellation and timeout cannot later surface as success.
- [ ] The child starts fresh with the target prompt and no tools. No child chat,
      artifact, filesystem mutation, background work, nested spawn, or change to
      the parent model/tool policy remains afterward.
- [ ] Remove the admitted target. A fresh Orchestrator chat can no longer select
      or execute it.

### 9.3 Declarative configuration

- [ ] Export/read the supported version-1 shape for `default_agent` and
      `delegation`; private current prompt values are not returned to the model.
- [ ] Preview a harmless disposable change. The review card shows bounded
      before/after values and no mutation occurs before explicit approval.
- [ ] Approve the exact plan once. It persists and applies atomically; replay and
      a stale plan both fail without mutation.
- [ ] Deny and cancel separate plans. Relaunch while a review is pending; the
      process-local request does not survive or mutate anything.
- [ ] Unknown domains/keys, malformed numbers, secret-shaped keys, and
      `env:`/`keychain:` references fail closed without echoing secret values.
- [ ] Local MLX, sandbox, browser/computer use, media, workspace/remote targets,
      background autonomy, child tools, and model-owned autonomous delegation
      remain explicitly unavailable and expose no working-looking controls.

## Promotion rule

Promote Agent Settings — General and Appearance from **Partial** to **Working
and tested** only when sections 1–4 pass on Rosy. Record any failure with the
agent id, whether the chat was fresh or restored, the selected/configured model,
and whether navigation or relaunch changed the result.

Promote Agent Settings — Abilities Overview and Tools from **Partial** to
**Working and tested** only when section 6 passes on Rosy, including live
revocation in both Auto and Manual modes. Record the agent id, exact tool, chat
state, selection mode, stale-call result, and relaunch outcome for any failure.

Promote Agent Settings — Automation from **Partial** only when section 7 passes
on Rosy: both complete CRUD/action lifecycles, readable watcher modes, folder
inheritance, real assistant completion, relaunch persistence, and a clean
storage-safety postflight are required. Explicitly unavailable model-callable
Self-scheduling is outside the conventional schedule/watcher promotion gate.

Promote Agent Settings — Memory from **Partial** only when section 8 passes on
Rosy: cold-launch provider routing, Qwen response decoding, stored facts,
episodes, the true empty state, Memory off/on enforcement, paid-distillation
consent, historical backfill, relaunch persistence, and scoped cleanup are all required. Record the
agent id, qualified model id, whether provider discovery had been warmed, the
distillation diagnostic, and pending-signal state for any failure.

Promote Orchestrator from **Partial** only when section 9 passes on Rosy. Record
the launcher/target ids, admitted model, policy, approval result, requested and
effective bounds, child result state, and whether any durable residue appeared
for each failure.
