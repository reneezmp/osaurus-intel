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

## Private agent database (B4/B5 Release 1)

Added 2026-09-28; needs a candidate built after `5c1fa2778`. Details are in
[`AGENT_DATABASE_INTEL_PLAN.md`](AGENT_DATABASE_INTEL_PLAN.md). Use a **test
agent** (create one, for example "Librarian") so nothing important is touched.
Items marked **(paid)** send real provider requests.

Setup and switches

- [ ] Right after installing, every existing agent shows the Database ability
      **off**, even one that had it on before (one-time reset).
- [ ] Test agent → Abilities → Autonomy & Data → **Database** on: a note says
      the table layout and any rows the agent reads or writes go to its cloud
      provider. Configure → **Private Database** shows the same state.
- [ ] The built-in agent's Database tab says it has no private database, and
      its Database rows cannot be switched on.
- [ ] Test agent → Database tab: Overview / Tables / Saved Views / History
      appear. Turning the ability off shows "Give this agent its own database";
      **Enable Database** there turns it back on.

The agent at work

- [ ] **(paid)** "Create a table for books I've read: title, author, rating."
      (It may confirm the columns first.) Tables lists `books`, and Overview
      shows it.
- [ ] **(paid)** Add three books in one message: they appear in Tables without
      reopening the tab.
- [ ] **(paid)** "Which books did I rate 5?" gets the right answer.
- [ ] **(paid)** Ask it to delete one book: Tables → **Deleted** shows it. Ask
      it to restore the book: it is back under **Active**.
- [ ] **(paid)** Ask it to save a view called "Top rated": Saved Views lists
      it. Pin it and it appears on Overview.
- [ ] **(paid)** Ask it to use raw SQL to change every rating by one author.
      An **approval panel** appears: Deny leaves the data unchanged, and a
      second try with Allow changes it.
- [ ] **(paid)** With the ability **off**, ask it to list its tables: it has
      no database tools (says it can't) and nothing changes.

History and editing

- [ ] Edit a cell yourself in the Tables grid: the value saves. History →
      **Chat & manual edits** lists that edit and the agent's chat changes.
- [ ] **(paid)** Give the test agent a schedule whose instructions add a row
      (for example "Add a book titled Scheduled Test by Rosy, rating 3"), then
      press **Run Now**. History shows a **Schedule** run, and selecting it
      shows that insert.

Files: import and export (Release 2)

- [ ] In the test agent's Tables tab, **Import** (down-arrow button) a small
      `.csv`: the rows land in the selected table, and a banner reports how
      many. Dragging a `.json` or `.xlsx` file onto the Tables screen does the
      same.
- [ ] **Export** (up-arrow button) saves a CSV of every matching row, not just
      the rows on screen. Open it in Numbers or TextEdit.
- [ ] **(paid)** Choose a working folder with the chat's Folder button, put
      `books.csv` in it, and ask the agent to import it into a table: one tool
      call, and the rows appear in Tables.
- [ ] **(paid)** Ask it to export the top-rated books to `top.xlsx` in the
      working folder: the file opens in Numbers or Excel with numbers as
      numbers.
- [ ] **(paid)** Ask it to export to a file that already exists: it refuses
      unless told to overwrite.
- [ ] **(paid)** With no working folder selected, ask it to import a file: it
      asks you to pick a folder instead of failing silently.

Agent bundles (Release 3)

- [ ] Database → Overview → **Export Bundle**: choose a folder and a
      passphrase (8+ characters, typed twice). A `.osaurus-agent` file appears
      there. The passphrase fields and buttons are readable, with a blinking
      cursor.
- [ ] **Import Bundle** with a wrong passphrase: a clear "wrong passphrase"
      error, and nothing changes.
- [ ] Import it with the right passphrase: the review shows the agent's name,
      table and view counts, "Replaces your existing agent …" (because it
      still exists), and what it arrives with (for example "Database is on").
      **Discard** changes nothing.
- [ ] Delete the test agent, then import the bundle and **Activate**: the
      agent comes back with its tables, rows and saved views.
- [ ] **(optional)** Copy the bundle to another Mac (M4) and import it there:
      same result.

Deleting and persistence

- [ ] Quit and relaunch: tables, rows, saved views and History are intact.
- [ ] Overview → **Delete All Data…** asks for confirmation. After confirming,
      tables and History are empty, and the agent can create a new table.
- [ ] Delete the test agent: no error. **(optional)** Its folder
      `~/.osaurus/agents/<id>/` is gone.

Ventura rendering

- [ ] Tables grid, the Rows/Columns and Active/Deleted/All controls, all
      buttons, the Saved Views list and the History split view are readable,
      with no blank icons or white-on-white text, also after clicking into a
      chat window so Settings is inactive.

- [ ] **(optional, back up `~/.osaurus` first)** Settings → Storage → rotate
      the storage key while the test agent's database is open: rotation
      succeeds, and the Tables tab still reads the data afterwards.

## Settings search (upstream #49)

Added 2026-09-28; needs a candidate built after this commit.

- [ ] Type "spelling" in **Search Settings**: a results page lists **Check
      Spelling While Typing** under General. Click it: the General page opens,
      scrolls to that switch, and it glows briefly. The search box clears.
- [ ] Try "hotkey", "temperature", "recovery phrase", "api key", "toast": each
      lists sensible results grouped by page, and clicking one opens the right
      page.
- [ ] A nonsense word shows "No settings match …".
- [ ] While results are showing, clicking a page in the sidebar leaves search
      and shows that page.
- [ ] Results and glow read well on Ventura (no white-on-white text).

## Agent descriptions (upstream #157/#158)

- [ ] Agents → any custom agent → Configure: with an empty description, a hint
      explains why it helps. **(paid)** **Suggest from instructions** fills the
      field with a one-line purpose you can edit; it saves like typed text.
- [ ] With empty instructions, the Suggest button is disabled.
- [ ] Create a new agent: the sheet has an optional **Description** field
      (with the same Suggest button), and creating without one still works.
- [ ] Orchestrator → Delegation: allowed agents show their description, or an
      orange "No description yet" note.
- [ ] **(paid)** Ask the Orchestrator which agent suits a task that matches
      one agent's description: it picks that agent (or says none fits).

## Audit leftovers (#49, #68, #25) and Duplicate

- [ ] **(paid)** Ask the Orchestrator "where do I turn on spell check?": it
      answers with **General › Chat › Check Spelling While Typing** (and ⌘,),
      not a made-up menu.
- [ ] **(paid)** Ask the Orchestrator to change its own settings: the review
      appears **centered** with the chat dimmed behind it; Esc cancels and
      Return applies.
- [ ] Chat with a custom agent, pick a folder, right-click the folder chip:
      **Use as Default for <agent>**. Start a new chat with that agent: it
      opens in that folder. A new chat in a project with its own folder uses
      the project's folder instead.
- [ ] Agents › Configure › **Default Working Folder** shows the same folder;
      Choose… and Clear work, and "Stop Using a Default Folder" in the chip
      menu clears it.
- [ ] Agents → a card's **Duplicate**: the copy really appears (before this
      fix it said "Duplicated as …" but saved nothing).

## Context compaction (upstream #136)

- [ ] **(paid)** In a long chat, type `/compact` (or right-click the token
      counter › **Compact Conversation**): a toast says how many earlier
      messages were compacted and roughly how many tokens were freed. The
      chat on screen doesn't change, and the token counter drops.
- [ ] **(paid)** Ask about something from early in the chat: the model still
      knows the gist (from the summary).
- [ ] Quit and relaunch: the compacted chat keeps its lower token count.
- [ ] **(paid, optional)** Set Settings › General › Chat › Context Length
      low (for example 8,000), chat until the orange "This chat is getting
      long…" notice appears above the composer, and press **Compact**. Reset
      Context Length afterwards.
- [ ] A short chat (one or two exchanges) says there's nothing to compact yet.

## Rich folder formats (upstream #91)

Use a chat with a working folder (Folder button) and any tool-capable model.
All items are **(paid)**.

- [ ] "Write a short meal plan to plan.docx": a real Word file appears and
      opens in Pages/Word with headings and bullets. Same for plan.pdf.
- [ ] "Put this shopping list in list.xlsx: …": opens in Numbers/Excel with
      numbers as numbers.
- [ ] "Read report.pdf / slides.pptx / budget.xlsx and summarize": the agent
      reads the actual content (no pandoc or "I can't read binary files").
- [ ] Put a screenshot of some text (or a scanned PDF) in the folder and ask
      what it says: the text is recognized.
- [ ] "Find 'lentils' in my folder": matches inside Word/PDF files show a
      page or paragraph.
- [ ] Ask for a PowerPoint: it explains it can't make .pptx and offers a
      .docx/.pdf outline instead.
- [ ] Ask it to overwrite list.xlsx, then undo the file change: the original
      workbook comes back intact.

## Native Apple apps, Release 1

Use a **test agent** (never the built-in one) and a tool-capable model. Items
that talk to the model are **(paid)**. Use a throwaway calendar/list or
delete what you create afterwards.

- [ ] Agents › your test agent › Overview: an **Apple Apps** section lists
      Calendar, Reminders, Contacts, Notes and Shortcuts with switches that
      render on Ventura (not blank). The built-in agent shows a note instead.
- [ ] Switch on Calendar: macOS asks for Calendar access (once). If you deny
      it, the row says Osaurus doesn't have Calendar access, and **Allow
      Access…** opens the system prompt or System Settings.
- [ ] **(paid)** "What's on my calendar tomorrow?": the agent lists real
      events with the right day (no approval card for reading).
- [ ] **(paid)** "Add 'Dentist' next Tuesday at 3pm": an approval card
      appears before anything is created; after Allow, the event is in
      Calendar at the right time and the agent repeats the title and time.
- [ ] **(paid)** Ask it to delete that event: the card appears and has **no
      Always Allow** button. Ask it to delete another one: the card appears
      again.
- [ ] **(paid)** Reminders: "remind me to buy lentils tomorrow" (approval
      card), then "mark it done".
- [ ] **(paid)** Contacts: "what's my own phone number?" / look someone up.
- [ ] **(paid)** Notes: "make a note called Pantry with rice and lentils":
      macOS asks once to let Osaurus control Notes; the note appears.
- [ ] **(paid)** Shortcuts: "list my shortcuts", then run a harmless one
      (approval card first).
- [ ] Switch Calendar off and ask about your calendar again **(paid)**: the
      agent no longer has calendar tools (it says it can't, instead of
      calling one).
- [ ] Quit and relaunch: the switches keep their state.
- [ ] If you ever installed the old osaurus-tools Calendar/Reminders/
      Contacts/Notes plugins: after the first launch a toast says they're
      built in now, agents that used them already have the app switched on,
      and the toast does not come back on the next launch.

## Native Apple apps, Release 2 (Mail, Maps & Location, Music)

Same test agent. Items that talk to the model are **(paid)**. Mail sends go
to a real address, so use your own.

- [ ] Overview › Apple Apps now also lists Mail, Maps & Location and Music.
- [ ] Switch on Maps & Location: macOS asks for Location access and the app
      waits for your answer. If you already denied it, **Allow Access…**
      opens System Settings › Location Services.
- [ ] **(paid)** "Where am I?" and "How long to drive to <a nearby place>?"
      return sensible answers.
- [ ] **(paid)** "Find cafés near <a place in your city>": results are local
      (not in another state). Ventura has no strict region option, so this
      checks the Intel distance filter.
- [ ] **(paid)** Mail: "list my last 5 emails" (macOS asks once to let
      Osaurus control Mail), then "draft a reply to the newest one": an
      approval card appears, then a draft opens in Mail and nothing is sent.
- [ ] **(paid)** "Send a test email to <your address>": the card appears and
      has **no Always Allow**. Choose Always Allow on a later *draft*, then
      ask it to send one: the send still shows a card.
- [ ] **(paid)** Music: "what's playing?", "pause", "play <a playlist>"
      (macOS asks once to let Osaurus control Music; changes ask first).
- [ ] If the old osaurus-tools Mail/Maps/Music plugins were installed: one
      toast after the first launch names only the new apps; agents that
      used their tools have them switched on.

## Native Apple apps, Release 3 (Messages)

Same test agent. Items that talk to the model are **(paid)**. Send only to
yourself (your own phone number or Apple ID email).

- [ ] Overview › Apple Apps now lists all nine apps, including Messages.
- [ ] Switch on Messages without Full Disk Access: the row says Osaurus
      doesn't have Full Disk Access yet, and **Allow Access…** opens System
      Settings › Privacy & Security › Full Disk Access. Add Osaurus there
      (macOS may ask to quit and reopen it).
- [ ] **(paid)** "Show my latest conversations" and "any unread messages?"
      return real conversations (no approval card for reading).
- [ ] **(paid)** "Text <yourself>: test from Osaurus": macOS asks once to
      let Osaurus control Messages, then an approval card with **no Always
      Allow** appears; after Allow, the message arrives.
- [ ] **(paid)** Ask it to send a second message: the card appears again.
- [ ] If the old osaurus-tools Messages plugin was installed: one toast after
      the first launch names Messages; agents that used it have Messages
      switched on.

## Upstream batch 2026-09-29

Use a **custom test agent** and a tool-capable model. Items that talk to the
model are **(paid)**.

- [ ] **(paid)** New chat with **no** folder: "Write a short packing list to
      packing.md". The folder picker opens as a sheet on the chat window and
      its message is the agent's reason. Pick a throwaway folder: the chat
      continues on its own, the file appears, and the folder chip shows it.
- [ ] **(paid)** Same again but press **Cancel**: the agent says no folder
      was attached and gives the list in the chat instead (no loop of
      pickers). The Orchestrator (built-in agent) never opens the picker.
- [ ] **(paid)** With a folder: ask it to change one line of a file that
      uses tabs, phrasing the old text with spaces: the edit applies, the
      tabs stay tabs. Ask it to replace a word that appears several times:
      it either asks for more context or uses "replace all".
- [ ] **(paid)** Put a Windows-style (CRLF) text file in the folder and ask
      for line 10: the agent quotes the same line your editor shows as 10.
- [ ] Every finished reply's stats row starts with "Worked for …" (for
      example "Worked for 8.4s"); a reply with tool steps counts all of them.
      Old chats show it too after relaunch.
- [ ] Scroll up during a long reply and wait for it to finish: the view
      stays where you were reading (no jump to older messages).
- [ ] In a very long chat (100+ messages) the collapsed minimap on the right
      fits without being cut off; hovering still expands it into the list.
- [ ] Settings › Server › Advanced HTTP › Max Request Body (MB): select the
      value and type `0`, then `64`. The field shows what you typed while
      editing (it used to snap to the clamped value), and after leaving it
      shows the saved number (`64`; a lone `0` becomes `1`). Put the old
      value back afterwards.

## Agent-loop tools (todo, complete, clarify, current time)

Custom test agent with tools on and a tool-capable model; all **(paid)**.

- [ ] "Plan a three-day trip to Lisbon, step by step": a checklist appears
      above the composer and its boxes tick as the agent works; it answers
      once at the end (no loop of checklist rewrites).
- [ ] "Help me pick a laptop — ask me what you need to know first": a
      question card with option chips appears at the bottom; picking a chip
      (or typing an answer) continues the chat with that answer.
- [ ] "What's the date and time right now?": correct local date/time and
      time zone.
- [ ] Re-test `prompt_working_folder` from the "Upstream batch 2026-09-29"
      section: the picker must now actually open (the first build refused).
- [ ] Turn the agent's Tools off: none of these appear, and the agent just
      answers in text.

## Self-scheduling

Custom test agent, tools on, a tool-capable model; model items are **(paid)**
and each self-scheduled wake is another paid run.

- [ ] Agents › test agent › Overview › Autonomy & Data: **Self-scheduling**
      is a switch (not "unavailable"). Turning it on asks once for macOS
      notification permission; Configure › Scheduling then shows Ambient,
      Reactive and Project cards with Ambient selected. The built-in agent
      shows a note instead of a switch.
- [ ] Pick **Reactive** (as often as every 5 minutes). **(paid)** In a chat:
      "In 5 minutes, check the time and send me a notification with it."
      The Next Run panel at the top of the agent shows the scheduled wake.
- [ ] About 5 minutes later a new background run appears for the agent and
      a macOS notification "<agent> · …" arrives; clicking it opens the agent.
- [ ] Schedule another wake, then turn Self-scheduling **off**: the pending
      wake disappears from the Next Run panel and never runs.
- [ ] With the switch off, **(paid)** asking the agent to schedule itself: it
      says it can't (the tools aren't offered).

## Agent description filler (opt-in)

- [ ] Settings › General › Chat › **Agent Descriptions**: "Fill in missing
      agent descriptions" is **off** by default.
- [ ] With it off, create an agent with instructions but no description:
      its card says "No description" and nothing is generated.
- [ ] **(paid)** Turn it on and save: within a few seconds that agent's card
      shows a one-line purpose (the description field itself stays empty).
      The Orchestrator's delegation settings list shows the same purpose.
- [ ] Type your own description: the card shows yours. Clear it again: the
      generated purpose returns without a new request. Edit the instructions:
      **(paid)** a new purpose replaces the old one.

## Chat export

- [ ] Right-click a chat in the sidebar (and also its "…" button): **Export…**
      is back, between Change Project and Archive.
- [ ] Export as **Markdown**, **PDF** and **Zip**: each opens a save panel;
      the files open in TextEdit/Preview/Finder and contain the conversation,
      including tool calls. The zip also carries any attachments.
- [ ] On the options page, turn on timestamps and token usage: the Markdown
      shows times and "tok / tok/s" next to replies.

## file_copy

With a working folder, **(paid)**:

- [ ] "Make a copy of report.pdf called report-draft.pdf": the copy opens in
      Preview and is identical; the agent used `file_copy` (not `cp`).
- [ ] Ask it to copy another file over an existing one: it asks/uses
      overwrite; then undo the file change: the original file comes back.
