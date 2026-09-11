# Agent Settings Rosy Retest

Before running automated tests or installing the candidate build, complete the
preflight and postflight in [`TEST_STORAGE_SAFETY.md`](TEST_STORAGE_SAFETY.md).
Record hashes of the live configuration and an inventory of the agents folder;
any unexplained difference fails the handoff even if the test suite is green.

Use a copy of the existing Rosy data directory. Keep at least two established
agents with different models, avatars, themes, tools, memory, and Knowledge
assignments. Relaunch where requested: a same-session result does not prove
persistence or migration.

Record the app build commit and macOS version before starting. A failed item
must include the agent, whether the chat was new or restored, and the visible
result.

## 1. Existing-agent migration and model routing

- Launch with existing data. Confirm every agent shows its stored model rather
  than a shared Claude Code fallback.
- Start a new chat from each established agent and confirm its stored model is
  selected and receives the request.
- Change one agent's model, start a new chat, and confirm the new model is used.
- Use **Reset to default**, start another chat, and confirm the active default
  model is inherited.
- Relaunch and repeat the display and new-chat checks.

## 2. General and shared controls

- Type in every text-field style used by Settings. Confirm a visible insertion
  caret, focus ring, selection, and hover state.
- Inspect toggles before touching them, after changing them, after navigating
  away, and after relaunch. Confirm the on/off colour always matches the value.
- Confirm buttons have visible labels in normal, hover, pressed, and disabled
  states, including Database-related controls.
- For Claude Code, switch between **Agent** and **Text only**. Exercise file
  changes and shell commands with each permission disabled and enabled.
- Confirm unavailable Osaurus MCP configuration is explanatory and has no live
  switch.
- On a disposable agent, use **Delete Data**. Confirm chats and memory disappear
  while the agent remains.

## 3. Appearance

- Upload a custom avatar once. Confirm it appears immediately, becomes selected,
  updates the header/chat avatar, and survives relaunch.
- Remove it. Confirm the letter fallback appears and the previous mascot is not
  falsely highlighted.
- Assign distinct themes to two agents. Open and alternate between fresh chats;
  confirm each theme follows its agent and does not leak.
- Recheck greeting, empty-state message, action bar, and mascot selection.

## 4. Ability enforcement

- Disable **Tools**, open a fresh chat, and ask for Kagi search and fetch. Both
  must be absent. Re-enable Tools and confirm assigned calls return.
- In an already-open chat, remove one assigned tool. On the next turn it must be
  absent from the offered schema and must not execute.
- Disable **Memory** and confirm no memory context is injected or saved; re-enable
  it and confirm normal behavior returns.
- Disable **Knowledge** and confirm assigned collections remain selected but are
  unavailable to the chat. Re-enable it and confirm the agent can search those
  collections.
- Disable and enable **Web Search** and **Self-scheduling**. Confirm the relevant
  tools disappear and return in both new and restored chats.
- Relaunch and verify all values persist.

## 5. Insights

- Clear Insights, send one ordinary Intel chat request, and confirm a Chat UI
  entry appears with the correct model, duration, request body, output, token
  counts, and completion state.
- Run a tool-using request. Confirm the entry includes the offered request and
  executed tool records.
- Trigger a harmless provider error. Confirm a failed Insights entry appears
  with the provider error rather than an empty screen.

The newer upstream message action rows and per-message diagnostic controls are
tracked with the later chat-interface revamp; this pass verifies the existing
Intel chat UI and the Insights data source.

## 6. Connections

- Toggle Bonjour. Confirm the control changes immediately, persists after
  navigation and relaunch, and the explanatory status matches it.
- If a second local device is available, confirm the `_osaurus._tcp` service
  appears while enabled and disappears after disabling it.
- Confirm Relay, workspace sharing, remote grants, and Channels remain clearly
  dependency-blocked and expose no dead actions.

## 7. Automation

- Create a temporary schedule. Edit, pause, resume, run now, and delete it from
  Agent Settings. Confirm the next-run banner updates after each operation.
- Create a watcher and choose a temporary folder. Confirm every monitoring-mode
  option is readable.
- Add a file. Confirm the run starts and its chat receives the watched folder as
  the working folder.
- Pause, resume, relaunch, and delete the watcher. Confirm each state persists.

## 8. Memory and Database dependency state

- Open recent chats and create a new chat from the current agent.
- Search known pinned facts belonging to the agent. Confirm results, tags, use
  counts, and scores render.
- Confirm existing episode summaries render compactly; an empty agent gets a
  compact empty state rather than a tall blank panel.
- Visit Database Overview, Tables, Saved Views, and History. Confirm each page
  states the Intel backend dependency and offers no import, export, mutation,
  or destructive control that cannot work.

## 9. Regression and relaunch

- With screen sharing and screen recording stopped, open both Settings and chat
  windows. Confirm the native red, yellow, and green window controls are visible,
  retain their system colours, and remain clickable before and after switching
  agent themes. macOS places its screen-sharing indicator over this area, so a
  screenshot captured while sharing cannot prove whether the controls are present.
- Resize Settings from compact width to full screen. Confirm both navigation
  rows, selected pills, hover states, controls, and cards remain legible.
- Switch rapidly among agents and tabs; confirm no model, theme, avatar, or
  ability state leaks.
- Smoke-test ordinary chat, Codex, Claude Code, Knowledge, Projects, working
  folders, project memory, and native Web Search.
- Quit and reopen for one final migration and persistence pass.
