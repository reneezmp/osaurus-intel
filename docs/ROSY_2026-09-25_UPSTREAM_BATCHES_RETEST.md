# Rosy Upstream Batches Retest — 2026-09-25

Focused manual pass for the three upstream port batches landed after public
build `1.0.55` (`56`): the quick correctness batch, the provider/chat batch,
and the smaller-fixes batch. Row-level detail is in
[`UPSTREAM_AUDIT_2026-09-25.md`](UPSTREAM_AUDIT_2026-09-25.md) and the batch
notes at the end of [`UPSTREAM_SYNC.md`](UPSTREAM_SYNC.md).

Automated gate before this pass: 1,159 tests in 178 suites (isolated root, no
live-data writes) plus an explicit x86_64 package build. Automated tests do not
cover Rosy's Ventura rendering, real providers, FSEvents, or TCC prompts, so
nothing here is accepted until checked on Rosy.

## Candidate

- Candidate: `1.0.56` build `57` (Debug, thin x86_64), built from
  `e8c5a6bd4` on 2026-09-26.
- Archive: `build/rosy-deploy/Osaurus-Intel-RC-UpstreamBatches-2026-09-26.zip`
  (58 MB), SHA-256
  `e8e39c78a7159560557d6f0a564eeea68eedcd8b45374102a8a7b212dd3745ef`.
- Round-trip checked: ZIP valid, macOS 13.0 minimum, canonical `~/.osaurus`,
  Sparkle key `bYYJJqFx…`, six framework symlinks kept, strict codesign passes
  with the stable Intel certificate requirement.
- Rosy's build number is now `57` (then `58` with the follow-up candidate).
  The next public release must use a higher `BUILD_NUMBER` (see `UPSTREAM_SYNC.md` → Public release 1.0.55).

## Before you start

- [x] Quit Osaurus. Optional safety copy: duplicate `~/.osaurus` to an
      external disk or another folder first. The Router billing ledger
      upgrades itself on first launch (it only adds two columns).
- [x] Install the candidate over `/Applications/osaurus.app` and launch it.
      If macOS asks for keychain access, choose **Always Allow**.
- [x] Existing chats, agents, projects, Memory and Credits history are all
      still there.

Items marked **(paid)** send a real provider request that may spend credits.
Items marked **(optional)** need something you may not have set up; skip them
and write "skipped" rather than forcing them.

## 1. Update checks start from launch

Before these ports, Intel only checked for updates when Settings was opened.

- [x] Quit Osaurus. In Terminal, note the last check time:
      `defaults read com.dinoki.osaurus SULastCheckTime`
      (an error just means it never checked).
- [x] Launch Osaurus and use only a chat window for a minute. Do **not**
      open Settings.
- [x] Run the same command again: the time is now recent (within the last
      couple of minutes).

## 2. Tool approval prompts (safety)

Needs a tool whose permission is **Ask** (Settings → Tools; any MCP or
plugin tool set to Ask works).

- [x] Open two chat windows. In both, quickly ask for something that uses
      the Ask tool, so both want approval at about the same time.
- [x] Only **one** approval panel is visible at a time; the second appears
      after you answer the first.
- [x] Press **Enter** once on the first panel: only that tool runs. The
      second still waits for its own answer.
- [x] Repeat, but choose **Always Allow** on the first panel: if the second
      request is for the same tool, it runs without asking again.
- [x] Press **Esc** on a panel: that tool is not run and the chat says so.

## 3. MCP tools

**(optional)** Needs a connected MCP server.

- [ ] Call an MCP tool with an integer argument of `0` or `1` (a page,
      offset, or limit): it works instead of failing with a type error.
- [ ] A tool that takes no arguments can be called without the provider
      rejecting the request.
- [ ] Tool descriptions for prefixed tools begin with
      "Exposed as `server_tool` (server name `tool`)".
- [ ] **(optional)** A tool that returns an image or audio: the chat shows
      a short note naming the media type and size, and the reply does not
      contain a wall of base64 text.

## 4. Chat windows and drafts

- [x] Open a saved chat in one window, then try to open the same chat from
      a second window: the first window comes forward; no second copy opens.
- [x] Type a message without sending, switch to another chat, then come
      back: the unsent text is still there.
- [x] Type in a blank new chat under agent A, switch to agent B, then back
      to A: the draft comes back for A only.
- [x] Open a saved chat, close all chat windows, then open chat from the
      dock or the global hotkey: that chat reopens (once). Doing it again
      with no chat closed in between gives a blank chat.
- [x] Open a project's page, then pick an agent from the toolbar (including
      the one already active): the project page closes and the chat shows.

## 5. Chat saving

- [x] **(paid)** Start a reply that takes a while. While it is still
      streaming, rename the chat in the sidebar (or pin/archive it).
- [x] After the reply finishes, quit and relaunch: the chat has the new
      name **and** the full last reply.

## 6. Schedules

- [x] **(paid)** On a schedule, press **Run Now**, then press it again
      while it is still running: the second press says it is already
      running; only one run happens.
      - Rosy: I can't actually press "Run now" because the button becomes inactive when it's runnin. A win is a win, though.
- [ ] **(paid, optional)** Create a daily schedule a couple of minutes
      ahead. After it fires once, quit and relaunch: it does not fire again
      for the same day.

## 7. Watchers

- [x] **(paid, optional)** Trigger a watcher: its chat shows your watcher
      instructions only, not "Changes were detected in the watched
      folder…" or the "If all files are already properly organized…"
      footer.
      - Rosy: Little detail: both the toast and the menu bar icon popu say "CHecking"instead of "Checking"

## 8. Memory

- [x] **(paid)** Normal distillation still works with your usual Memory
      model.
- [ ] **(paid, optional)** In Settings, set the Core Model to a model id
      no provider serves (then set it back afterwards). Trigger
      distillation: it completes using your chat model, and Memory
      diagnostics show the chat model was used.

## 9. Credits, Router and prompt caching

- [x] Credits opens without errors and old activity rows are intact
      (ledger upgrade check).
      - Rosy: Warning! The "Recent activity" box has a button all in white.
- [x] **(paid, optional)** In one chat on the Router with an OpenAI-backed
      model, send two or three messages. After the usage list refreshes,
      the Credits usage center shows a **Cached input** figure and rows
      show "N cached". If it never appears, record the model used; not
      every upstream model caches.
- [x] A DeepSeek or other non-allowlisted provider chat still works
      normally (no new request fields are sent there).

## 10. Models

- [x] **(optional, Codex sign-in)** The Codex model list includes
      `gpt-6-astra` and `gpt-5.6` variants when the catalog offers them.
- [x] **(optional)** For a GPT-6 model, the reasoning options are Low,
      Medium, High and Extra High (no Minimal).
      - Rosy: Warning! The "Thinking" does not appear anymore - but I guess it's because newer models no longer expose their reasoning
- [ ] **(paid, optional)** With an OpenAI reasoning model (o-series or
      GPT-5) as Core Model, chat titles generate without a "temperature"
      error.
      - Rosy: These models are no longer avialable

## 11. Themes

- [ ] In the theme editor, drag the colour picker: it moves smoothly and
      does not jump, even for dark or grey colours.
      - Rosy: Warning! The theme editor window has a lot of buttons with text in white, pickers that do not display text, and toggles that become almost invisible when the window is inactive.
- [ ] Type a hex value slowly (`#FF00` … `#FF0000`): the colour does not
      reset while typing, and leaving the field with an incomplete value
      restores the previous colour.
      - Rosy: Warning! The colour changes as I type it's number, is that what's supposed to happen? Also, there's no blinking indicator that text is being edited.
- [x] Set a colour with transparency (for example `#FF000080`), save,
      reopen the editor: the same colour and transparency come back.
- [x] Edit the Raw JSON, then change a control: a stale-JSON warning
      appears instead of silently losing either change.

## 12. Attachments and links

- [x] The attach picker accepts a `.md` and a `.txt` file.
      - Rosy: It also accepts PDFs.
- [x] **(paid)** Send a message with an attached document, quit and
      relaunch, reopen the chat and send a follow-up: the model can still
      see the document's text.
      - Rosy: Warning! When I send the message with the attachment, the little bubble with the attachment above the message does not display any icon, although it has the exact space for displaying an icon
- [x] Click a link in a chat reply: it opens without the app freezing.
- [x] Select text in a long reply: no freeze.

## 13. Folders

- [x] Pick a working folder with the folder chip, then right-click the
      chip: **Recent Folders** lists it (and earlier picks, up to five).
- [x] Choosing a recent folder switches to it.
- [x] Rename or move one of the listed folders in Finder, then choose it:
      a "Folder not found" message appears and it drops off the list.

## 14. Settings and windows

- [x] Settings opens fully on screen. **(optional)** With a scaled display
      (System Settings → Displays → Larger Text), both the Settings and chat
      windows fit and the composer is visible.
- [x] Creating an agent: type a name, open the model picker, click **Add
      Provider**: a "Leave without creating this agent?" warning appears;
      **Keep Editing** keeps your draft.
- [ ] Settings → General → Chat → Typing → **Check Spelling While Typing**: when on,
      misspelled words in the chat input are underlined with right-click
      suggestions; nothing is corrected automatically. Turning it off
      removes the underlines.
      - Rosy: Warning! There are buttons and text not showing in the Settings -> General window
- [x] **(paid, optional)** Ask the Orchestrator how to add a Knowledge
      collection: if it quotes a shortcut, it is **⌘,** (Settings…), never ⌘⇧M.

## 15. Regression spot checks

- [x] **(paid)** A normal DeepSeek chat, a Router chat, and one tool call
      work as before.
- [x] **(paid)** The Orchestrator can still list its admitted targets and
      delegate one bounded task.
- [ ] Deleting a chat still removes it for good (it does not come back
      after relaunch).

## Result

**2026-09-26, candidate `1.0.56` (`57`) on Rosy.** Every behavioural change in
the three batches passed where it was exercised: update check from launch, one
approval panel at a time, drafts and chat reopen, chat saving during a stream,
Run Now single-flight (the button disables while running, which is stronger
than the planned "already running" message), watcher framing, Memory
distillation, the Router ledger upgrade, **prompt caching** (Router Venice
`qwen-3-8-max` rows show "N cached"), the GPT-6 reasoning options, theme
transparency and stale-JSON warning, attachments across relaunch, links and
selection without freezes, Recent Folders, Settings fit, the Add Provider
warning, the ⌘, answer, and the regression spot checks.

Not exercised (optional or unavailable): §3 MCP tools, the daily-schedule
relaunch check, the Core Model fallback, the reasoning-title check (the old
OpenAI reasoning models are gone from Rosy's providers), and deleting a chat.

Failures, all Ventura rendering rather than behaviour:

- Settings → General: the Capability Search segmented picker was blank and
  the Tools / Memory / Clipboard / Chat Titles / Greetings checkboxes had no
  labels, so the spell-check toggle could not be tested.
- Credits → Recent activity: the **Export diagnostics** button was a blank
  white box.
- Theme editor: white button text, blank Syntax Theme and font menus, switches
  near-invisible when the window is inactive, no text caret in the hex fields.
- Sent document chips (`.txt`/`.md`) had an empty icon slot.
- GPT-6 answers showed no Thinking.

Notes that need no code change: "CHecking" in the watcher toast and menu is the
watcher's own name (rename it in Watchers). The hex field changing colour while
typing was by design (any complete 3-, 6- or 8-digit value applied), but it is
now tightened below. The attach picker also accepting PDFs is expected.

Root causes and repairs are recorded in `UPSTREAM_SYNC.md` → "Ventura
themed-control sweep". The Sparkle file found on the Desktop
(`sparkle_sig.txt`) is the **1.0.1 release signature**, not the old private key;
the `bYYJJqFx…` key stays in use.

## Follow-up retest (next candidate)

Candidate `1.0.57` (`58`), built from `5132047c8` on 2026-09-26:
`build/rosy-deploy/Osaurus-Intel-RC-VenturaControls-2026-09-26.zip` (58 MB),
SHA-256 `6a89f273ec28135bf05bae3cc6a4deda3219a782fc42f0ef9250621a2fdc27b4`.
Round-trip checked as for `57` (ZIP valid, thin x86_64, macOS 13.0, canonical
root, `bYYJJqFx…` key, six symlinks, strict codesign). Gate: 1,164 tests in 179
suites, x86_64 build, no new missing localization keys. The next public release
needs `BUILD_NUMBER` ≥ 59.

- [ ] Settings → General: Capability Search shows Off/Default/… segments with
      readable text; the five checkboxes show their labels and tick marks.
- [ ] Settings → General → Chat → Typing → **Check Spelling While Typing**
      (the §14 item that could not be tested).
- [ ] Every Settings switch stays visible (accent when on, grey track when
      off) after clicking into a chat window so Settings is inactive.
- [ ] Settings → Tools: each tool's Auto / Ask / Deny control is readable.
- [ ] Credits → Recent activity: **Export diagnostics** has a visible label.
- [ ] Theme editor: Cancel / Save / Replace Image / gradient buttons readable;
      Mode, Background and Fit segments readable; Syntax Theme and font menus
      show the current value; switches visible when the editor is inactive.
- [ ] Theme editor hex field: a caret blinks while editing. Typing `#FF0000`
      no longer flashes yellow at `#FF0`; typing `#F00` then Enter applies it.
- [ ] Send a `.txt` and a `.md` attachment: the chip shows a document icon.
- [ ] **(paid, optional)** GPT-6 via Codex without touching the reasoning
      picker: a Thinking section appears. If not, pick Medium explicitly and
      try again, and record both results.
- [ ] Spot check a few icons that were swapped for Ventura-safe symbols:
      Permissions → Accessibility, Identity keys, Agent network/sandbox rows,
      theme editor image buttons, Credits diagnostics.
- [ ] Delete a chat, relaunch: it stays deleted (carried over from §15).
