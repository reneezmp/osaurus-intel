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
- Rosy's build number is now `57`. The next public release must use
  `BUILD_NUMBER` 58 or higher (see `UPSTREAM_SYNC.md` → Public release 1.0.55).

## Before you start

- [ ] Quit Osaurus. Optional safety copy: duplicate `~/.osaurus` to an
      external disk or another folder first. The Router billing ledger
      upgrades itself on first launch (it only adds two columns).
- [ ] Install the candidate over `/Applications/osaurus.app` and launch it.
      If macOS asks for keychain access, choose **Always Allow**.
- [ ] Existing chats, agents, projects, Memory and Credits history are all
      still there.

Items marked **(paid)** send a real provider request that may spend credits.
Items marked **(optional)** need something you may not have set up; skip them
and write "skipped" rather than forcing them.

## 1. Update checks start from launch

Before these ports, Intel only checked for updates when Settings was opened.

- [ ] Quit Osaurus. In Terminal, note the last check time:
      `defaults read com.dinoki.osaurus SULastCheckTime`
      (an error just means it never checked).
- [ ] Launch Osaurus and use only a chat window for a minute. Do **not**
      open Settings.
- [ ] Run the same command again: the time is now recent (within the last
      couple of minutes).

## 2. Tool approval prompts (safety)

Needs a tool whose permission is **Ask** (Settings → Tools; any MCP or
plugin tool set to Ask works).

- [ ] Open two chat windows. In both, quickly ask for something that uses
      the Ask tool, so both want approval at about the same time.
- [ ] Only **one** approval panel is visible at a time; the second appears
      after you answer the first.
- [ ] Press **Enter** once on the first panel: only that tool runs. The
      second still waits for its own answer.
- [ ] Repeat, but choose **Always Allow** on the first panel: if the second
      request is for the same tool, it runs without asking again.
- [ ] Press **Esc** on a panel: that tool is not run and the chat says so.

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

- [ ] Open a saved chat in one window, then try to open the same chat from
      a second window: the first window comes forward; no second copy opens.
- [ ] Type a message without sending, switch to another chat, then come
      back: the unsent text is still there.
- [ ] Type in a blank new chat under agent A, switch to agent B, then back
      to A: the draft comes back for A only.
- [ ] Open a saved chat, close all chat windows, then open chat from the
      dock or the global hotkey: that chat reopens (once). Doing it again
      with no chat closed in between gives a blank chat.
- [ ] Open a project's page, then pick an agent from the toolbar (including
      the one already active): the project page closes and the chat shows.

## 5. Chat saving

- [ ] **(paid)** Start a reply that takes a while. While it is still
      streaming, rename the chat in the sidebar (or pin/archive it).
- [ ] After the reply finishes, quit and relaunch: the chat has the new
      name **and** the full last reply.

## 6. Schedules

- [ ] **(paid)** On a schedule, press **Run Now**, then press it again
      while it is still running: the second press says it is already
      running; only one run happens.
- [ ] **(paid, optional)** Create a daily schedule a couple of minutes
      ahead. After it fires once, quit and relaunch: it does not fire again
      for the same day.

## 7. Watchers

- [ ] **(paid, optional)** Trigger a watcher: its chat shows your watcher
      instructions only, not "Changes were detected in the watched
      folder…" or the "If all files are already properly organized…"
      footer.

## 8. Memory

- [ ] **(paid)** Normal distillation still works with your usual Memory
      model.
- [ ] **(paid, optional)** In Settings, set the Core Model to a model id
      no provider serves (then set it back afterwards). Trigger
      distillation: it completes using your chat model, and Memory
      diagnostics show the chat model was used.

## 9. Credits, Router and prompt caching

- [ ] Credits opens without errors and old activity rows are intact
      (ledger upgrade check).
- [ ] **(paid, optional)** In one chat on the Router with an OpenAI-backed
      model, send two or three messages. After the usage list refreshes,
      the Credits usage center shows a **Cached input** figure and rows
      show "N cached". If it never appears, record the model used; not
      every upstream model caches.
- [ ] A DeepSeek or other non-allowlisted provider chat still works
      normally (no new request fields are sent there).

## 10. Models

- [ ] **(optional, Codex sign-in)** The Codex model list includes
      `gpt-6-astra` and `gpt-5.6` variants when the catalog offers them.
- [ ] **(optional)** For a GPT-6 model, the reasoning options are Low,
      Medium, High and Extra High (no Minimal).
- [ ] **(paid, optional)** With an OpenAI reasoning model (o-series or
      GPT-5) as Core Model, chat titles generate without a "temperature"
      error.

## 11. Themes

- [ ] In the theme editor, drag the colour picker: it moves smoothly and
      does not jump, even for dark or grey colours.
- [ ] Type a hex value slowly (`#FF00` … `#FF0000`): the colour does not
      reset while typing, and leaving the field with an incomplete value
      restores the previous colour.
- [ ] Set a colour with transparency (for example `#FF000080`), save,
      reopen the editor: the same colour and transparency come back.
- [ ] Edit the Raw JSON, then change a control: a stale-JSON warning
      appears instead of silently losing either change.

## 12. Attachments and links

- [ ] The attach picker accepts a `.md` and a `.txt` file.
- [ ] **(paid)** Send a message with an attached document, quit and
      relaunch, reopen the chat and send a follow-up: the model can still
      see the document's text.
- [ ] Click a link in a chat reply: it opens without the app freezing.
- [ ] Select text in a long reply: no freeze.

## 13. Folders

- [ ] Pick a working folder with the folder chip, then right-click the
      chip: **Recent Folders** lists it (and earlier picks, up to five).
- [ ] Choosing a recent folder switches to it.
- [ ] Rename or move one of the listed folders in Finder, then choose it:
      a "Folder not found" message appears and it drops off the list.

## 14. Settings and windows

- [ ] Settings opens fully on screen. **(optional)** With a scaled display
      (System Settings → Displays → Larger Text), both the Settings and chat
      windows fit and the composer is visible.
- [ ] Creating an agent: type a name, open the model picker, click **Add
      Provider**: a "Leave without creating this agent?" warning appears;
      **Keep Editing** keeps your draft.
- [ ] Settings → General → Chat → Typing → **Check Spelling While Typing**: when on,
      misspelled words in the chat input are underlined with right-click
      suggestions; nothing is corrected automatically. Turning it off
      removes the underlines.
- [ ] **(paid, optional)** Ask the Orchestrator how to add a Knowledge
      collection: if it quotes a shortcut, it is **⌘,** (Settings…), never ⌘⇧M.

## 15. Regression spot checks

- [ ] **(paid)** A normal DeepSeek chat, a Router chat, and one tool call
      work as before.
- [ ] **(paid)** The Orchestrator can still list its admitted targets and
      delegate one bounded task.
- [ ] Deleting a chat still removes it for good (it does not come back
      after relaunch).

## Result

Record the date, candidate build, and any failures here (screenshots welcome).
Failed items become the next focused retest.
