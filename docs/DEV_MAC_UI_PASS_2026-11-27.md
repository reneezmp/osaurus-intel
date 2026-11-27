# Dev-Mac UI pass, build 70 code (2026-11-27)

First screen-driven pass on the build Mac (macOS 27, x86_64 under Rosetta) with
a `com.dinoki.osaurus.intel-dev` build of `intel-fork` at `4886f35ed`, launched
by `scripts/test/run_dev_app.sh` (temp data root, keychain and Sparkle off) and
chatting with `scripts/test/mock_provider.py` (no real provider, nothing
billed). Not a substitute for Rosy: no Ventura, no real providers.

Safety: postflight showed identity `mdat` unchanged and no file under
`~/.osaurus` changed; the temp root, dev defaults and caches were deleted.

## Passed

- Local server listens on `127.0.0.1` only. `/sessions`, `/agents`,
  `/mcp/tools`: 200 without `Origin`; 403 with a web `Origin`, a foreign
  `Host` or `Sec-Fetch-Site: cross-site`, with no `Access-Control-Allow-Origin`.
- `/admin/config/export` 200 local / 403 web; `/admin/import/plan` 415 without
  JSON content type; `/admin/config/apply` 409 with no chat window.
- "Require an access key for local apps": default off; on gives 401 without a
  key; off restores 200. Expose to Network off.
- Custom local provider added; chat streams; title and follow-up generated; no
  Router fields sent to it.
- `osaurus_config`: review window with a clear diff; Cancel applies nothing and
  ends the run; Apply changed the delegation budget.
- Stop keeps the partial reply with no error; a mid-stream error appears below
  the text; a length stop shows the explanation; none re-sent. Announce-only
  turn is nudged once more with the system notice.
- Settings search finds "pairing", "Browser Use", "Codex", "access key".
- Agent Templates: review sheet flags the sandbox risk and needs the checkbox;
  creates the agent.
- Delete all data: removed only that agent's one chat; five other chats and the
  agent stayed.
- Sandbox self-test: exec, workspace read/write, outside writes blocked,
  network blocked.

## Findings (fixed in code 2026-11-27; see "Fixes")

1. **Sandbox page stuck "Unavailable".** `SandboxManager.State.availability`
   starts as `unavailable("Intel: host sandbox not enabled")` and nothing calls
   `refreshAvailability()` at launch or from `IntelSandboxView`, so the page (and
   the chat chip / agent tab that read it) only work after a sandbox-enabled
   agent has chatted. Fix: refresh at launch (upstream does) and on the page's
   appear.
2. **Sandbox listed under "Not Available on This Mac"** in the Settings sidebar
   (`ManagementSection.unavailable: [.models, .sandbox]`). Move `.sandbox` to a
   normal section.
3. **New chats default to Claude Code** when the CLI is signed in (new
   Orchestrator chats and new template agents). A test message ran the real
   Claude Code CLI on the owner's subscription for a few seconds before Stop (no
   session file left). Harness stage 4a/5 replaces this path; until then,
   consider not auto-selecting a Claude Code model as the default.
4. **Two data-delete cards** on an agent's General tab: the older "Agent Data →
   Delete chats and memory" and the new "Delete All Data" (#2355 port). Keep one.
5. **Claude Code sheet title unreadable** (Cloud Models → Claude Code →
   Configure): the title is near-white on a white sheet.
6. **Settings search misses** the "Require an access key for local apps" row.

## Not tested here

Denying a tool batch (needs a working folder dialog), delegation/`spawn_agent`
(needs an admitted model), Bundles, Computer Use (not enabled), every real
provider, and everything Ventura-specific.

## Fixes (2026-11-27)

Merged into `intel-fork` as `fc13e6034`..`a21f4e639`. Full suite on
`2fc5c7362`: 6856 tests passed (6 known issues); the last commit
(`a21f4e639`) ran the related suites only (215 tests passed). **On-screen
retest (same day, dev app on `ba546ae9a`):** all six passed. Auto-start
after a relaunch was not checked here (the launcher deletes the data root).
Postflight clean (`mdat` unchanged, nothing changed under `~/.osaurus`).

1. Availability is resolved at launch and when the Sandbox page appears. As
   upstream, a set-up sandbox with auto-start on is started again at launch;
   no tool is registered for an agent that has not opted in, and the page
   itself starts nothing. Side effect (upstream's own line): finishing
   onboarding now writes the default `sandbox.json`.
2. Sandbox sits under Developer Tools, a collapsible sidebar section. Only
   Local Models stays under "Not Available on This Mac".
3. Claude Code is never the automatic default
   (`Array.automaticDefault`). With no other chat model the chip says
   "Select Model" and Send opens the picker, keeping the text; voice,
   schedules, watchers and queued sends show "Choose a model…" instead of
   using the subscription. Saved selections are untouched.
4. One "Delete All Data" card (upstream's). The removed Intel card deleted
   nothing the kept one misses.
5. The Claude Code sheet paints the theme background.
6. Search finds the access-key switch and opens Server → Settings →
   Connection.

### What the retest showed

- 1: fresh app, Sandbox page reads "Not set up" with Start Sandbox; the
  template agent's chat shows the Sandbox chip.
- 2: only Local Models is under "Not Available on This Mac".
- 3: Claude Code only: "Select Model", Send opens the picker and keeps the
  text. After adding the fake provider, the chat, a new tab and a new template
  agent use `mock-model`.
- 4: the template agent's General tab ends with one "Delete All Data" card
  (button not pressed this time).
- 5: the Claude Code sheet title is readable on the System (dark) and Light
  themes.
- 6: both searches open Server → Settings → Connection with the row lit, also
  from the Overview tab.
- Tool limit: an agent card in Settings → Agents is a menu control, so the
  background computer-use tools can't open it (and the sidebar gear needs a
  hover): the owner clicked it.
