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

## In-place document editing

Working folder with a Word file, a spreadsheet, a slide deck and a PDF
(make them with the agent if needed). All **(paid)**.

- [ ] "In plan.docx, change Q3 to Q4 everywhere": the file keeps its fonts,
      headings and images; only the text changed. Undo the file change: the
      original returns.
- [ ] "Show me the structure of budget.xlsx" then "set B2 to 1200 and B3 to
      =B2*1.1": the workbook opens in Numbers/Excel with the new value and a
      working formula.
- [ ] "Make a 3-slide deck about pantry planning as deck.pptx": it opens in
      Keynote/PowerPoint with 3 slides. Then "change slide 2's title to
      Shopping": only that title changes.
- [ ] PDF: "delete page 2 of report.pdf" and "rotate page 1": correct in
      Preview.
- [ ] **PDF form (important on Ventura):** a PDF with text fields, a checkbox
      and a **radio group** — "fill the form: Name Ada, Agree yes, Plan Pro":
      open it in Preview and check the **radio button** shows Pro selected
      (macOS 27's PDFKit loses it; Ventura's may not). Note the result.
- [ ] Ask for a preview first ("dry run"): nothing changes until confirmed.

## Voice

Manual: [`VOICE_INTEL.md`](VOICE_INTEL.md). Use headphones for the speech
checks. Items marked **(paid)** use the chat model.

**First, the unknown (please record the answer):**

- [ ] Voice → Recognition: allow Speech Recognition when macOS asks. Note
      which languages show **"On this Mac"** (at least English and German).
      If none do, note it: voice then needs *Use Apple's servers when needed*
      and VAD Mode stays unavailable — both are expected in that case.

Setup and settings:

- [ ] The sidebar lists **Voice** under General (after Settings), and it opens.
- [ ] Setup tab: Microphone → Grant, Speech Recognition → Allow; both tick.
      Tap the big mic, say a sentence: the text appears live. The footer says
      "All processing happens on your Mac" (or, with Apple's servers on,
      "Speech is sent to Apple for recognition").
- [ ] Recognition tab: switch the language to German, speak German, then back.
      Turning *Use Apple's servers when needed* on/off changes the status line.
- [ ] Audio Input: pick another microphone (or System Audio with Screen
      Recording allowed); dictation still works.

Chat microphone:

- [ ] In a chat, tap the mic, speak, pause: the countdown appears and the
      message sends by itself **(paid)**. Manual stop mode: it waits for Stop.
- [ ] Deny microphone access once (System Settings) and tap the mic: the
      "microphone access" alert explains how to fix it; re-allow and it works.

Transcription Mode (dictate anywhere):

- [ ] Speech To Text tab: turn on Transcription Mode, set a hotkey, allow
      Accessibility when asked. In TextEdit press the hotkey, speak, pause: the
      text is pasted into TextEdit. Esc cancels without pasting.
- [ ] *Clean Up Transcription* is **off** by default. Turn it on and dictate
      "uh I I went to the store" **(paid)**: the pasted text is tidied. Turn it
      off again.

VAD Mode (wake word):

- [ ] VAD Mode tab: enable it for one agent. Close **all** chat windows, say
      "Hey <agent name>, …": that agent's chat opens and listens. Opening a
      chat window yourself pauses listening; closing the last one resumes it.
- [ ] With Apple's servers as the only option for the language, VAD Mode
      refuses to start and says why.

Speaking:

- [ ] Voice → Text To Speech: engine *On This Mac (System Voices)*, voice
      *Automatic*; Preview plays. Change voice and speed; Preview follows.
- [ ] Speaker button on a German reply and on an English reply: Automatic picks
      a matching voice for each. Tap again to stop.
- [ ] Agent → Configure → Voice: turn on Auto Speak and pick a voice; the next
      reply is read in that voice **(paid)**.
- [ ] Agent → Abilities → Output → **Speak Tool** on, then "read your answer
      aloud" **(paid)**: the `speak` call shows a spinner while it plays and a
      check after. With the switch off the agent has no speak tool.
- [ ] Optional, if you run a TTS server (e.g. openai-edge-tts in Docker):
      engine *OpenAI-Compatible Server*, Test Connection → Connected, Preview
      plays.
- [ ] Quit Osaurus while something is playing or the mic is on: it quits
      cleanly and the mic indicator goes off.

## Automatic tool discovery

Manual: [`TOOL_DISCOVERY_INTEL.md`](TOOL_DISCOVERY_INTEL.md). Needs at least
one plugin (osaurus-tools) or MCP provider connected. All **(paid)**.

- [ ] Agent → Tools: **Auto-discover relevant capabilities** on. Ask something
      a plugin/MCP tool answers (e.g. "what's the weather in Lisbon?" with a
      weather tool): the chat shows a `capabilities` call, then the real tool
      call, then the answer — in one turn.
- [ ] Ask "what tools can you load?": it answers from its Enabled capabilities
      list (or a bare `capabilities` call) without inventing names.
- [ ] Next message in the same chat uses that tool again without another
      `capabilities` call (it stayed loaded).
- [ ] Turn a tool off in that agent's Tools list, then ask for it in a new
      chat: it is not loaded, and the agent says it isn't enabled.
- [ ] Switch the agent to Manual (Auto-discover off): the enabled tools are
      used directly, no `capabilities` call.
- [ ] The Orchestrator (built-in agent) behaves as before.
- [ ] Skills: Skills tab → create a skill ("Always answer in haiku"). In chat
      type `/` — the skill is listed; pick it and send: the reply follows it.
      With Auto on, ask for something the skill covers: the agent may load
      `skill/<name>` and follow it.

## Knowledge writing

Manual: [`KNOWLEDGE_WRITE_INTEL.md`](KNOWLEDGE_WRITE_INTEL.md). Use a test
collection folder (a copy, not your real notes) granted to a custom agent.
Items marked **(paid)** use the chat model.

- [ ] "Add a document how-to-bake.md with a short recipe" **(paid)**: the
      approval card lists the path as a new document with a diff (not raw JSON)
      and is wide enough to read. Allow: the file appears in the folder and the
      agent can find it with a search.
- [ ] "In how-to-bake.md change 200°C to 180°C" **(paid)**: it uses
      `edit_knowledge`; the card shows a one-line diff; only that line changes.
- [ ] Deny a write on the card: nothing changes and the agent says so.
- [ ] "Delete how-to-bake.md" **(paid)**: the card appears and has **no**
      Always Allow; after allowing, the file is gone.
- [ ] Knowledge → a **History** tab has appeared, listing those runs. Revert the
      edit: the file returns to 200°C. Revert the delete: the file is back.
- [ ] Edit a file by hand after an agent wrote it, then try to revert that
      agent write: it refuses and says the document changed.
- [ ] Folder watcher: edit or add a markdown file in the collection folder with
      another app; within ~10 s a search finds the new text (no Re-index click).
- [ ] An agent without a grant to the collection cannot write to it.
- [ ] Relaunch: History is still there.
- [ ] Tickets: ask the agent to "flag pantry.md as out of date: prices changed"
      **(paid)**. Knowledge shows it under **Curation**. **Fix in a chat** opens
      a chat with the briefing filled in; send it and approve the edit. Then
      **Dismiss** another ticket: it disappears.
- [ ] Clickable paths: ask "which document covers soup?" **(paid)**; a path in
      the reply (like `Recipes/soup.md`) is underlined. Click opens it;
      right-click shows Open / Open With / Show in Finder / Copy Path.
- [ ] Git (only if you have a collection folder that is a git repo): its card
      shows a **git** label and **Sync**. Sync reports "up to date" or what
      changed; with no network it says it needs attention instead of hanging.
- [ ] Types: a collection with subfolders (e.g. `recipes/`, `notes/`) — ask
      the agent to list documents of type `recipes` **(paid)**; files without a
      frontmatter `type` in that folder are included.
- [ ] Upgrade: your existing collections still search normally after updating
      (the index upgrades in place; no rebuild needed).

## Upstream batch 2026-09-30

Audit: [`UPSTREAM_AUDIT_2026-09-30.md`](UPSTREAM_AUDIT_2026-09-30.md). Items
that talk to the model are **(paid)**.

- [ ] Settings › Orchestrator with at least one custom agent on a cloud model
      but **none** allowed: a warning says none of your agents is allowed and
      shows **Add all agents**. Click it: every listed agent's switch turns on.
      The warning says their models must still be admitted (the button does not
      admit models). Put your switches back afterwards.
- [ ] Search Settings for "add all agents": the result opens Orchestrator.
- [ ] **(paid)** Ask the Orchestrator "where do I turn off memory?": it quotes
      the Memory setting's path (it used to find nothing for that wording).
- [ ] **(paid)** Ask the Orchestrator to "remove every agent from delegation":
      the review card shows a red **High risk** line above the changes. Press
      **Cancel**; nothing changes.
- [ ] Open a custom agent's chat, then open a **new chat window** (menu bar or
      global hotkey): it opens on the Orchestrator, not on that custom agent.
- [ ] **(paid)** Ask the Orchestrator "make new chats open with <one of your
      agents>": the review card shows `new_chat_agent`. Apply, open a new chat
      window: it opens on that agent. Then ask it to open new chats on the
      Orchestrator again, and check a new window does.
- [ ] **(paid, only if Claude Code is set up)** A Claude Code reply that ends
      with a long paragraph shows the whole ending (the last output is no
      longer cut off when the process exits).

## Settings redesign

Manual: [`SETTINGS_REDESIGN_INTEL.md`](SETTINGS_REDESIGN_INTEL.md). Check on
Ventura in **both** light and dark themes, with the window active and inactive.

### Step 1 — grouped layout and header

- [ ] Every Settings page header: a smaller, non-rounded title with no
      separate coloured band behind it; it fades in when you open the page.
- [ ] Settings › Voice, Orchestrator, Web Search, a cloud provider's edit
      sheet: each section has a plain title **above** one rounded box, and
      the rows inside are separated by thin lines. No row text is cut off or
      overlaps its switch.
- [ ] Switches in those boxes are visible and clickable in dark mode and
      while the window is inactive.
- [ ] A switch row without a description has its title vertically centred
      with the switch.
- [ ] Header buttons that are unavailable look greyed out (for example a
      Save button with nothing to save, where a page has one).
- [ ] Search Settings for a switch inside a section (e.g. "voice input"):
      the page scrolls to it and it glows as before.

### Step 2 — General and Conversation

- [ ] The sidebar's first group reads General, **Conversation**, Voice, …;
      **Storage** is gone from it.
- [ ] General: sections General, Core Model, Notifications, a collapsed
      **Advanced** row, then Reset. There is no Save button.
- [ ] Change the global hotkey, then switch tabs and come back: it kept the
      new value, and the hotkey works. Same for Start at Login (check System
      Settings › Login Items) and the Core Model.
- [ ] Notifications: turn toasts off and on; change Toast Position; **Test
      Toast** shows a toast in the new position. Open Advanced: Default
      Timeout, Max Visible Toasts and Max Concurrent Tasks are there and take
      effect.
- [ ] Advanced › Data & Storage shows the encryption status and the backup /
      rotate actions (what the old Storage tab showed). Export a plaintext
      backup to a throwaway folder: it works as before.
- [ ] Conversation: Appearance, Behavior, Greetings, Folder Tool Permissions,
      Advanced. Every switch keeps its value after leaving and reopening the
      tab and after relaunch (compare with what General used to show).
- [ ] **(paid)** Turn **Disable Tools** on: a new chat with a folder offers
      no tools. Turn it off again.
- [ ] Greetings: the personality editor appears only while AI-Generated
      Greetings is on.
- [ ] Folder Tool Permissions: set Run Shell Commands to Deny, run a shell
      request in a folder chat **(paid)**: it is refused. Reset All to
      Default puts it back to Ask.
- [ ] Conversation › Advanced › System Prompt: with the Orchestrator's own
      prompt empty (Orchestrator › Restore Defaults), text typed here changes
      how the Orchestrator answers **(paid)**.
- [ ] Developer Tools › Server › Overview has the **Command Line Tool** card
      with a terminal icon; Install CLI reports where it installed.
- [ ] Search Settings for "temperature", "toast timeout", "backup",
      "command line": each opens the right page, expands Advanced where
      needed, scrolls to the control and it glows.
- [ ] What's New "Storage" action (if a release note shows one) opens General
      with Advanced expanded at Data & Storage.

### Step 4 — Voice tabs

- [ ] Voice tabs read Setup, **Chat Voice**, **Transcription**, Text To
      Speech, **Wake Word**, Recognition.
- [ ] Chat Voice: the switch turns the chat microphone button on and off;
      **Open Transcription** jumps to the Transcription tab.
- [ ] Transcription: Transcription Mode switch, its hotkey, and Stop Behavior
      & Cleanup (cleanup, stop mode, pause, confirmation delay, silence
      timeout). With cleanup on, the text says each transcript goes to the
      Core Model's provider. The Stop Mode picker is readable on Ventura.
- [ ] Before speech access is granted, the Transcription and Wake Word tabs
      list "Speech Recognition Allowed" and a language step (not "Speech
      Model Downloaded"); clicking them asks for access / opens Recognition.
- [ ] Text To Speech: with speech on and system voices, the Voice card shows;
      **Advanced** holds the Engine menu; choosing OpenAI-Compatible Server
      shows the server fields there, and speech still plays after switching
      back.
- [ ] Wake Word: the switch, agent list, Custom Phrase and sensitivity work
      as before VAD Mode was renamed.
- [ ] Search Settings for "wake word", "stop mode", "voice input", "tts
      engine": each opens the right Voice tab.

### Step 5 — Commands editor

- [ ] Capabilities › Commands › **New Command**: a real editor opens (icon
      grid, name, description, template), not an "Apple Silicon only" panel.
      Save a command, then use it in a chat by typing `/` and its name
      **(paid)**.
- [ ] Edit that command: **Save** stays disabled until you change something;
      the change shows in the list and in chat.

### Step 3 — Tools & MCP

- [ ] Capabilities shows **Tools & MCP** (not Tools); it opens on **Services**.
      The tabs are Services, All Tools, Plugins. An **Add Service** button sits
      in the header on Services.
- [ ] Services: your MCP services as before, with "N connected · N tools"
      beside the title; below them a **Directory** list. Search it for
      "github"; click a service: the add sheet opens straight on its setup.
      **Custom Server** opens the custom editor.
- [ ] All Tools: **Auto-Allow All Tool Calls** at the top. Turning it on asks
      for confirmation first. Below: filter menus, service cards, plugin
      cards, and a Built-in list that now includes Knowledge, Database,
      Apple apps and Orchestrator tools. Switching a tool off or changing
      Auto/Ask/Block updates just that row. Advanced diagnostics at the bottom
      exports a report file.
- [ ] **(paid)** With Auto-Allow on, a tool set to Ask runs without the card.
      Asking the agent to delete a Knowledge document **still** shows the
      card. Turn Auto-Allow off again.
- [ ] Plugins: your native plugins with Installed / Browse, update, settings
      (gear) and uninstall, without a second page title. The Plugins sidebar
      tab still works.
- [ ] **(paid)** In a chat, collapsed tool rows read "Reading a file" /
      "Read a file" (not `file_read`); expanding one shows the raw name. A
      failed call reads in the past tense as failed.
- [ ] Search Settings for "auto-allow", "add service", "mcp directory":
      each opens the right Tools & MCP sub-tab.

## Chat tabs (`W-chat-tabs`)

Manual: [`CHAT_TABS_INTEL.md`](CHAT_TABS_INTEL.md). Start from a build with a
few saved chats under two agents.

- [ ] The toolbar reads: sidebar button, agent pill, tabs, "+", Settings
      gear. With the sidebar open, the pill and tabs start at the chat
      column's left edge; hiding the sidebar slides them left. Dragging the
      sidebar wider moves them when you let go.
- [ ] Resize the window fast, narrow and wide: the tabs never draw over the
      sidebar or the gear; with many tabs a "N ▾" menu appears and lists the
      rest.
- [ ] "+" or ⌘T opens a new blank tab. Sidebar **New Chat** on a blank tab
      stays in it; on a conversation it opens a new tab.
- [ ] Click a sidebar chat: it opens in the current tab. Right-click it ›
      **Open in New Tab**: it opens in a new tab (or reuses a blank one).
      Clicking a chat that is already in another tab jumps to that tab.
- [ ] **(paid)** Send a long request, switch to another tab while it
      replies, come back: the reply kept going, and the tab's avatar showed
      a spinning ring meanwhile.
- [ ] **(paid)** Close a tab while it is still replying (×), then reopen
      that chat from the sidebar before it finishes: the reply is still
      streaming in, not frozen, and the final text is saved once.
- [ ] Pick another agent in the pill: the strip shows only that agent's
      tabs (or one blank tab). Pick the first agent again: its tabs are back
      and the blank tab you left is gone.
- [ ] ⌃Tab / ⌃⇧Tab and ⇧⌘] / ⇧⌘[ cycle through this agent's tabs only.
- [ ] Drag a tab left and right: it reorders, the others slide over.
- [ ] ⌘W closes the active tab; on the last conversation it leaves a blank
      chat; on a lone blank tab it closes the window. ⇧⌘T brings closed
      tabs back in their old place.
- [ ] Right-click a tab: Rename (the tab and sidebar update), Pin, Move to
      Project (a folder glyph appears on the tab; clicking it opens the
      project page), Export…, Archive, Delete (asks first; the tab closes),
      Close Tab, Open in New Window.
- [ ] Each tab remembers where you were reading: scroll halfway up in a
      long chat, switch tabs, come back — same place, and the text doesn't
      visibly re-wrap. A tab left at the bottom is still at the bottom.
- [ ] Open 7+ saved chats as tabs, then click the oldest: its transcript
      shows straight away (it was put to sleep to save memory).
- [ ] Rename or pin a chat in the sidebar while it is open in a background
      tab: after switching to that tab and sending, the new name/pin stays.
- [ ] Quit with several tabs open (two agents), relaunch, open chat: the
      tabs are back and the window shows the chat you were reading. Menu
      bar **Ask AI** with no window open: the tabs come back too, but you
      land in a new blank chat.
- [ ] Menu bar **Ask AI** with the window open: a new tab (or the blank one)
      opens instead of only focusing the window.
- [ ] First launch after updating from a pre-tabs build: the chat you last
      had open comes back once.
- [ ] Ventura: the tab chips, × buttons, the "+" and the overflow menu all
      render (no blank squares); right-clicking a tab shows the chat menu,
      not the toolbar's "Icon and Text" menu.

## Chat window layout (navigator + inspector)

Manual: [`CHAT_WINDOW_LAYOUT_INTEL.md`](CHAT_WINDOW_LAYOUT_INTEL.md). This
changes the chat window's look; the "Chat tabs" section above still applies,
except that agents are now picked in the sidebar, not a toolbar pill.

- [ ] Toolbar: sidebar button, tabs, then a right-panel button and a pin.
      No agent pill, no Settings gear in the toolbar.
- [ ] Left sidebar has **Agents | Projects** at the top, a count with a "+"
      (New Agent / New Project), a search field, and **Settings** at the
      bottom (opens Settings).
- [ ] Agents: one row per agent, the current one highlighted. Clicking an
      agent shows its tabs (same rules as the tabs checklist). Hover a row:
      a "+" starts a new chat with that agent in a new tab. Right-click: New
      Chat, Open Settings.
- [ ] **(paid)** While an agent replies (in any tab, or a schedule/watcher
      run), its row shows the spinning ring and "Working…"; hover shows a
      Stop button that stops it.
- [ ] Drag a custom agent row up or down: the order sticks after relaunch.
      The Orchestrator/Default stays first. On first launch of this build,
      agents you never reordered appear alphabetically.
- [ ] "+" on Agents opens Settings › Agents with the Create Agent sheet
      already open. Create an agent: its row shows a "New" pill until you
      click it.
- [ ] Projects: project rows; "+" creates a project and opens its page;
      clicking a row opens the project page; right-click: Rename, Edit
      Instructions, Delete (asks first, keeps the chats).
- [ ] Right-panel button opens **History** on the right: the current agent's
      chats, with "N chats", search, a filter button (origin, projects,
      plugins, others, archived), New Chat and Import. Clicking a chat opens
      it in the current tab; the panel stays open. Right-click a chat: Open
      in New Tab / New Window, Rename, Pin, Move to Project, Export,
      Archive, Delete. ⌘/⇧-click selects several.
- [ ] Search finds chats by words inside their messages, not just titles.
- [ ] For the Default agent, History lists every chat (as the old sidebar
      did), including old ones saved without an agent.
- [ ] Switching agents changes History to that agent's chats and clears
      its filters.
- [ ] Drag the inner edges of both side panels: they resize, the cursor
      shows left-right arrows, and the widths are kept after relaunch.
- [ ] Narrow the window with both panels open: the left sidebar steps
      aside; the sidebar button then brings it back by closing History.
      The tabs never run under either panel.
- [ ] Pin Window: the chat window stays above other apps' windows; click
      again to unpin.
- [ ] ⌘N in the chat window opens a new tab (staying in the current
      project); on the project page ⌘N keeps its menu meaning.
- [ ] ⌘B still toggles the left sidebar.
- [ ] Ventura: the lens bars, rows, search fields, filter popover and resize
      seams render and respond; no blank squares or clipped corners.
- [ ] Open a project from Projects: the middle shows the project's name,
      "N chats", New Chat and Add Chats, and its chats (search, right-click
      menu as in History). The right panel shows **Project Settings**:
      instructions (saved as you type), knowledge collections, working
      folder, shared memory, default agent. The toolbar's right-panel button
      now reads "Hide project settings"; Pin is hidden.
- [ ] Edit the instructions of project A, click project B in the sidebar,
      come back to A: A's text is intact and B's is its own (the old
      "instructions moved between projects" bug stays fixed).
- [ ] New Chat on a project page starts a chat in that project (its folder
      and default agent apply). Add Chats moves existing chats in.
- [ ] The project's "…" menu renames and deletes (delete asks and keeps
      the chats).
- [ ] **(paid)** With a chat window open, let a schedule or watcher run
      (Run Now works): a tab for it appears under its agent without taking
      focus; that agent's sidebar row shows the working ring. Click the
      agent: the run's tab is there, streaming.
- [ ] **(paid)** Close the run's tab while it runs: it keeps running (ring
      stays, menu-bar card updates). Reopen it from History: the reply is
      still streaming in. After it finishes, closing its tab is just
      closing a chat.
- [ ] **(paid)** The menu-bar card's run row (or a notification's View)
      jumps to the run's tab instead of opening another window.
- [ ] Delete a running scheduled chat from its tab's right-click menu: the
      run stops and the chat is gone.
- [ ] First chat window after updating: a three-step tour spotlights the
      sidebar's Agents | Projects bar, the tabs, then the right-panel button.
      Next / Back / Done work; Esc skips; it never comes back on its own.
      It waits if a dialog is open.
- [ ] Help ▸ **Chat Layout Tour** replays it.
- [ ] A new chat window opens filling the screen under the pointer; resize
      it, close it, open another: the new one uses your size. A second
      window cascades and stays on screen.
- [ ] Full screen (green button): the toolbar is replaced by a themed row
      with the sidebar button, tabs and the right-panel/pin buttons; no grey
      system strip. Leaving full screen brings the normal toolbar back.


## Per-chat file history (`W-file-history`)

Manual: [`FILE_HISTORY_INTEL.md`](FILE_HISTORY_INTEL.md). Use a throwaway
working folder (a copy, not real work). Items marked **(paid)** need a model
call.

- [ ] **(paid)** In a chat with a working folder, ask the agent to create a
      file, edit it, and copy it. The right-panel button shows a count; open
      the panel: **File Changes | History**, File Changes lists three
      entries under your message ("Write file", "Edit file", "Copy file").
- [ ] Expand an entry, then a file: the diff shows added/removed lines with
      the changed words highlighted. "Open before / Open after" open the
      versions in their default app. For a .docx or .xlsx the diff says
      "Showing changed paragraphs/cells".
- [ ] **Files** chip: one row per file with Created/Modified/Deleted; hover
      shows Reveal in Finder and Revert File.
- [ ] Revert one entry: the file goes back, the entry reads "Reverted", a
      toast offers **Undo**; Undo puts the change back.
- [ ] Revert All: a dialog lists every file with what will happen ("back to
      before this chat", "will be deleted"); confirm, and the folder matches
      how it was before the chat. Folders the chat created are removed too.
- [ ] Edit one of the agent's files yourself (TextEdit), then Revert All:
      the dialog flags it "edited since" and offers Skip Edited Files /
      Overwrite Edited Files. Skip leaves your edit; Overwrite replaces it
      and can still be undone.
- [ ] Roll Back to Before This (on an older entry) undoes it and everything
      after it.
- [ ] **(paid)** Ask for a shell command that moves or deletes a file
      (`mv a.txt b.txt`, `rm`): after approving shell, the tool row shows
      "N files changed"; clicking it opens File Changes on that entry, which
      shows the rename. Revert brings the file back.
- [ ] **(paid)** Under the agent's reply: "N files changed · View changes"
      opens File Changes on the first change of that reply.
- [ ] **(paid)** Ask the agent "undo your last change" / "what files did you
      change?": it uses `file_undo` / `file_operation_history`, and the panel
      updates (the undo appears as its own revertible entry).
- [ ] History rows: chats that changed files show a small ±N badge; click it
      to open that chat with File Changes.
- [ ] Quit and relaunch: File Changes for an old chat still lists its
      entries, and reverting still works.
- [ ] Delete a chat that changed files: its history is gone (Settings shows
      less used space after a moment).
- [ ] Settings ▸ General ▸ Advanced ▸ Data & Storage ▸ **File History**:
      Keep File History (until the chat is deleted / 90 / 30 days) and a
      size limit with "Currently using …". Searching Settings for "file
      history" lands there.
- [ ] A chat with no file changes: File Changes says "No file changes".
- [ ] Ventura: the lens bar, chips, rows, diffs, the confirmation dialog's
      file list and the toast render and respond; no clipped text.
- [ ] The first-run layout tour's third stop now reads "Past chats and file
      changes" (Help ▸ Chat Layout Tour to replay).
- [ ] **(paid)** Diff cards: when the agent writes or edits a file, a
      collapsed card appears under the tool row (file name, +N −M). Click it
      to expand the coloured, syntax-highlighted diff; copy works.
- [ ] **(paid)** While the agent is still writing a longer file, the card
      grows as the content streams, then settles into the real diff.
- [ ] **(paid)** On a card: Revert puts the file back (card shows
      "Reverted", button becomes Undo); Undo restores the change; View
      change opens File Changes on that write.
- [ ] **(paid)** Ask the agent to "preview" a change with `dry_run`: the
      file on disk does not change (before this build Intel wrote text
      files even on a dry run).
- [ ] Ventura: cards expand/collapse without overlapping the next row;
      long lines wrap; dark and light themes both readable.

## Cross-block chat selection

Manual: [`CROSS_SELECTION_INTEL.md`](CROSS_SELECTION_INTEL.md). Use any
chat with a long reply that has paragraphs, a list, a code block and a
table.

- [ ] Drag from the middle of one paragraph down into the next paragraph,
      the code block and the table: the blue highlight follows across all
      of them (it used to stop at the end of the first block).
- [ ] Drag upwards works the same way; dragging back shrinks the highlight.
- [ ] Drag past the bottom (or top) edge of the chat: it scrolls and the
      selection keeps growing; it never scrolls past the last message.
- [ ] ⌘C, then paste into TextEdit: the whole selection, blocks on separate
      lines. Right-click ▸ Copy and Edit ▸ Copy do the same.
- [ ] Scroll the start of a long selection off-screen, then ⌘C: still the
      full text.
- [ ] Single click elsewhere clears the highlight. Double-click selects a
      word, triple-click a paragraph, as before.
- [ ] Links still open on click; the cursor is a pointing hand over links
      and an I-beam over text.
- [ ] Select in one chat window, switch to another and press ⌘C: nothing
      from the first window is copied.
- [ ] Ventura: the highlight is visible in light and dark themes and in a
      custom theme; text stays readable on top of it.

## Upstream batch 2026-10-01

Manual: [`UPSTREAM_AUDIT_2026-10-01.md`](UPSTREAM_AUDIT_2026-10-01.md).

- [ ] **(paid)** Under a finished reply there is no stats line any more.
      Click "…" ▸ **Inspect response**: a submenu lists Worked for, TTFT,
      tok/s and tokens, then "Open request and response log" (opens
      Insights).
- [ ] Code block: click Copy twice quickly — the checkmark stays for about
      two seconds after the second click; a "Code copied to clipboard" toast
      appears; the cursor is a pointing hand over the button.
- [ ] System Settings ▸ Appearance ▸ Show scroll bars: **Always**. In a long
      chat, copy a code block and scroll: the messages don't shift sideways
      or rewrap. Set it back afterwards.
- [ ] Drag the sidebar's edge wider and narrower: the tabs follow the edge
      during the drag (not only on release). Open the right panel, then open
      a new tab (⌘T): the tabs still stop at the panel's edge.
- [ ] **(paid)** An agent with Notes on: "list my Notes folders" and "make a
      note in folder X" work (no −1708 error).

## Context budget indicator

Manual: [`CONTEXT_BUDGET_INTEL.md`](CONTEXT_BUDGET_INTEL.md).

- [ ] In a chat with some history, a small ring sits in the composer's
      button bar to the left of Send (the old "~N / M tokens" text at the
      right of the model row is gone). Typing makes it fill a little.
- [ ] Hover the ring: the popover opens after a moment; moving into it
      keeps it open; leaving closes it. Click the ring: it stays open until
      you click outside or click the ring again.
- [ ] Popover: "CONTEXT BUDGET" with an "N% used" pill, "~N tokens used",
      "N remaining of M usable", and "Your context limit 128k · usable
      budget 85%" for a cloud model (or "Model maximum" when the model's own
      limit is known). Then Usable budget bar, Composition bar, Sources
      (System Prompt expands with a click, Memory, Tools), Messages.
- [ ] **(paid)** In a long chat, the popover offers "Compact conversation";
      clicking it shows "Summarizing older messages…" and the ring drops
      afterwards.
- [ ] "Open Context Length" at the bottom opens Settings › Conversation with
      Context Length highlighted. Set it very low (e.g. 4096): the ring turns
      amber/red, and Send still works.
- [ ] Ventura, light and dark: the ring track is visible, the popover isn't
      clipped, and it scrolls when System Prompt is expanded.

## Insights activity log (`W-insights-sync`)

Manual: [`INSIGHTS_INTEL.md`](INSIGHTS_INTEL.md).

- [ ] **(paid)** Send a chat message, then open Insights. The new layout
      shows four tiles (Events, Left this Mac, Failed, Privacy-filtered), a
      local/cloud bar, search + time range + Filter, scope tabs (All, Models,
      …, System) and the row under "Today".
- [ ] Click the row. At a wide window it opens beside the list (inspector);
      narrow the window and it replaces the list with a Back button. Up/Down
      arrows move between rows; Escape closes the inspector.
- [ ] Overview names the provider ("Model request sent to DeepSeek —
      completed"), "Where it went" shows the host and endpoint. Raw ›
      Request has a **Server** view with the exact JSON that was sent; Raw ›
      Response › Server shows the raw `data:` stream.
- [ ] Quit and relaunch: the rows are still there (before, Insights was
      empty after a relaunch).
- [ ] In the chat, the reply's "…" › Inspect response › Open request and
      response log opens Insights **on that reply's row**. For a reply from
      before this build, an "Insights Unavailable" alert appears instead.
- [ ] Use a provider with a wrong API key (or a bad model id): the failed
      request appears as a red row with the provider's error message.
- [ ] "…" › Verify Integrity: a green "chain intact" banner. Export: the
      sheet's checkboxes and buttons are visible (Ventura); export JSONL and
      Markdown to Desktop and open them.
- [ ] Settings › General › Advanced › Data & Storage: an "Activity Log" card
      under File History. Turn **Store Prompts and Responses** off, send a
      message: the new row's Prompt tab says the prompt wasn't stored
      (Data & Storage › …); turn it back on.
- [ ] Settings search "activity log" finds Keep Activity History.
- [ ] Credits › Activity (Osaurus Router): a request row's "Insights" link
      opens its row, or shows "no longer available".
- [ ] Ventura, light and dark: tiles, scope tabs, the Filter popover's
      menus and checkbox, and the "…" menu all render.
- [ ] **(paid)** Rows from other sources, each in the right scope tab:
      - an agent web search: Web, "Web search sent to …", query and hits;
      - a page fetch: Web, the page's host;
      - an MCP tool call: Tools;
      - opening Credits: System/Router rows such as "Credits";
      - Read aloud: Audio & Media, "Speech synthesized on this Mac" for a
        system voice;
      - dictation: Audio & Media, transcription;
      - a new chat's title: Models, "Chat title", source System.
- [ ] Inspect response on a reply whose chat also generated a title still
      opens the **reply**, not the title row.


## Chat UX batch (`W-chat-ux`)

Manual: [`CHAT_UX_INTEL.md`](CHAT_UX_INTEL.md).

- [ ] **(paid)** After sending two messages, press ↑ in an empty composer:
      the last message comes back; ↑ again gives the one before; ↓ walks
      forward and finally restores what you had typed. In a multi-line
      draft, ↑ moves the caret normally until the first line.
- [ ] Type `@` with a work folder set: its files and folders list (folders
      first). Arrow + Return on a folder drills in (`@…/`); on a file it
      inserts the path. Escape removes just the `@…` token. `@~/` browses
      home. Escape with the menu open doesn't close the window.
- [ ] A Chinese/Japanese input method in a search field (e.g. Insights
      search): the placeholder disappears as soon as composition starts.
- [ ] **(paid)** After a reply finishes, a "Follow up" list with up to four
      questions appears under it (a few seconds later). Clicking one sends
      it; the list disappears while the new reply streams. Turning off
      Settings › Conversation › Suggest Follow-Up Questions stops them.
- [ ] **(paid)** In a long chat, compact it (context ring popover ›
      Compact conversation, or `/compact`). A divider "Older messages
      summarized — ~… tokens reclaimed" appears below the last summarized
      message. Clicking it opens the summary text; clicking again closes
      it. Hovering shows which model summarized. Light and dark themes.
- [ ] Settings › Conversation › Advanced › **Compaction Model**: pick a
      model, then the popover's helper names it; the ✕ button returns to
      "Use the current chat model (default)". Search "compaction" in
      Settings and land on it. Relaunch keeps the choice.
- [ ] **(paid)** With a Compaction Model set, compact: the run uses that
      model (Insights row `/internal/compaction` shows it).
- [ ] **(paid)** Ask an agent something that needs several tool calls (e.g.
      "read three files in this folder and compare them"). While it works,
      a "Working" row shimmers; afterwards it reads "Worked" with step
      circles and "+N steps". Click it: the thinking and tool rows appear,
      each still expandable; Expand All / Collapse All work. Speed/TTFT
      stats show once, under the final answer.
- [ ] **(paid)** A long reply types out at an even pace instead of in
      jumps; Stop during it stops right away (no extra typing). Settings ›
      Conversation › Appearance › Smooth Streaming off: text appears in
      the provider's chunks again. A reply with a tool call shows the text
      before the tool card first.
- [ ] Settings › Conversation › Appearance › Group Thinking & Tool
      Activity off: the same chat shows every step separately, without
      reopening it. Back on: grouped again.
- [ ] **(paid)** Settings › Conversation › Advanced › Expand Thinking While
      Streaming on, with a reasoning model (DeepSeek Reasoner): the thinking
      opens while it streams and closes when the answer starts. Collapsing
      it by hand mid-stream keeps it closed.
- [ ] Type `/screenshot` in a chat. First time: macOS asks for Screen
      Recording (or a toast says to grant it in Privacy & Security; grant,
      relaunch if macOS asks, retry). A card with the screenshot appears;
      clicking it opens the image. Quit and reopen the chat: the card is
      still there. Delete the chat: `~/.osaurus-intel/artifacts/<chat id>`
      is gone.
- [ ] History pane › Import: a guide lists ChatGPT, Claude, Grok, Gemini
      and Open WebUI; each row opens to its export steps, and the ↗ button
      opens the provider's export page in the browser. Choose File… opens
      the picker. Tick "Don't show this again", import again: the picker
      opens directly. Checkbox looks themed (not the grey system box).
- [ ] **(paid)** Ask for "the complexity as $$O(n \log n)$$ and then just
      $$O(n)$$": both render as math, not with `$$` showing. Prose that
      mentions prices ($5 and $10) stays plain text.
- [ ] **(paid)** Agent with self-scheduling on: Next Run › Run now. A new
      chat "Self-scheduled run — <date>" opens; the first message shows the
      instructions only, with "Self-scheduled" and a time chip above it
      (hover: who scheduled it). Hovering the message offers Copy and Delete
      but no Edit. A second wake makes another new chat.
- [ ] **(paid)** A watcher run's chat: the first message shows only the
      watcher's instructions with a "Watcher run" chip (hover: First pass /
      Follow-up pass); no Edit button.
- [ ] Delete a response that is above the divider: the confirmation adds
      "This response is part of a conversation summary…". After deleting,
      the divider disappears (the summary no longer applies).

## Model picker (`W-model-picker-2947`)

Manual: [`MODEL_PICKER_INTEL.md`](MODEL_PICKER_INTEL.md).

- [ ] Click the model pill: a card opens above it with Provider, Model and
      (for models with options) Model options columns. Click another
      provider: its models show, the current model stays selected until you
      pick one. Picking a model updates the pill. Escape closes the card.
- [ ] Keyboard: open with `/model` or click, then ↑↓ move, ←→ switch columns,
      Return picks; the focused row shows a thin underline.
- [ ] A reasoning model (DeepSeek Reasoner / GPT-6 Astra): the pill reads
      "name · Medium"; Model options has Thinking and Reasoning Effort.
      Changing effort updates the pill; "Reset to default" appears after a
      change. The old Thinking and Options chips are gone.
- [ ] Osaurus Cloud provider: rows have stars; starring keeps a model in
      the list after switching away. First connection to Osaurus Cloud
      stars DeepSeek V4.1 Flash, Claude Opus 5.5 and GPT-6 Astra (only if
      you had no favourites).
- [ ] "More models" under Osaurus Cloud opens the Cloud browser: search,
      Category (All / Text-to-text / Image-to-text) and Context filters,
      stars, Manage Credits. Choosing a model selects it and closes it.
      ↑↓ highlight and Return pick when not typing in search.
- [ ] Light and dark themes; narrow window (the card shrinks its columns).
- [ ] Type `/` and `@`: the menus float above the composer (the chat and
      the selector row don't jump), with a "Commands" / "Files" heading and
      key hints. Voice input card uses the same card style.
- [ ] Context ring: hovering shows the budget card (after a short pause);
      clicking pins it; moving into it keeps it open. "Open Context Length"
      opens Settings at Context Length. Compact from the card: progress,
      then "Compacted — ~… tokens reclaimed".

## Upstream audit 2026-10-07

Manual: [`UPSTREAM_AUDIT_2026-10-07.md`](UPSTREAM_AUDIT_2026-10-07.md).

- [ ] Chat tabs: one rounded track with equal-width tabs, the active one in
      an accent pill; hovering a tab shows its close button on the left.
      With a single tab, no track or pill: it reads like a window title.
- [ ] A long chat (50+ messages) scrolls and streams without stutters;
      a new reply keeps the view pinned to the bottom; editing or deleting
      an earlier message doesn't jump the scroll position.
- [ ] Agent avatars look sharp in the chat headers, tabs and theme editor.
- [ ] Quit and relaunch Osaurus Intel quickly: Settings › Server (or any
      local API client) still works after relaunch (the port is retried).
      Open tabs come back after quit and relaunch.
- [ ] `/compact` while a reply streams says to wait; on a short chat it
      says there's nothing to compact.
- [ ] With a working folder, ask an agent to read a filled-in tax form or
      other flattened PDF form: each label and its value come back on one
      line, under `--- Page N of M ---` markers. Ask for "page 2 only": the
      reply covers just that page. A table in a PDF still reads row by row.
- [ ] Search the folder for a value from that form: the hit names the PDF
      and page and shows the label beside the value.
- [ ] Settings › Services: the directory has category chips and the new
      connectors (Dropbox, QuickBooks, Microsoft 365, Harvey…). HubSpot
      asks for a Client ID and Client Secret with numbered setup steps and
      a redirect URI to copy; signing in works after registering it.
- [ ] Connect any MCP server (e.g. one from the directory) and use one of
      its tools: read-only tools run without asking, tools that can delete
      data ask every time; a failing connector shows a plain-language
      error with a Details toggle; a long tool call shows its progress
      after the tool's title.
- [ ] With the Router on, relaunch Osaurus Intel: if upstream has a live
      announcement, a dialog appears with the yellow "From the upstream
      Osaurus project, not Osaurus Intel" banner. Links open in the browser;
      "Don't show upstream announcements" stops them for good (no dialog on
      the next relaunch). With the Router off, no dialog ever.
- [ ] In a custom agent's chat, use a plugin tool that starts a background
      task: the task runs under that agent. From a Default-agent chat, the
      same tool reports it can't start background work.

## Router billing (2026-10-08)

- [ ] With an Osaurus Cloud model, send a message and note the balance in
      Credits before and after: it drops by the turn's cost without
      reopening Credits.
- [ ] Credits › usage center: the turn appears in the charges list within a
      few seconds while it is open.
- [ ] Stop a Router reply mid-stream: within a few seconds the balance
      refreshes from the server.
- [ ] Reopen an old chat and a new one: nothing odd appears in replies, chat
      titles or summaries (no stray symbols or `billing:` text).

## Upstream audit 2026-10-08

Manual: [`UPSTREAM_AUDIT_2026-10-08.md`](UPSTREAM_AUDIT_2026-10-08.md).

- [ ] Ask an agent with tools on for "what is 17.5% of 2,340, and 2^40?":
      it uses Calculate (row "Calculated") and the answers are exact.
- [ ] A reply with a code block fenced by four backticks (with a three-
      backtick block inside) renders as one code block.
- [ ] With a text-only model selected, copy an image and press Cmd+V in
      the composer: a "Cannot attach image" toast explains why. With two
      chat windows open, Cmd+V of an image lands only in the focused one.
- [ ] Add a stdio MCP server whose command is `npx …` (Node from nvm,
      mise or asdf, not Homebrew): it starts without "command not found".
- [ ] Run /compact in a long chat on a DeepSeek model and, if you use one,
      an LM Studio / llama.cpp model: the summary appears; nothing errors
      about an unknown `thinking` field.

## File tools parity (2026-10-09)

- [ ] In a working-folder chat, ask for "the last 20 lines of" a log file:
      the agent reads just the tail.
- [ ] Ask about an Excel file with several sheets: the agent reads one
      sheet's preview and can name the others.
- [ ] Ask "what's in the src folder?": the agent lists it with `file_read`.
- [ ] Ask the agent to find every file mentioning a word in a big folder:
      results arrive in pages, and a note says if some files were skipped.
- [ ] Open a TextEdit `.rtfd` document via the agent: its text is read.

## Upstream audit 2026-10-09

Manual: [`UPSTREAM_AUDIT_2026-10-09.md`](UPSTREAM_AUDIT_2026-10-09.md).

- [ ] Settings › Plugins with several plugins installed: scrolling the grid
      is smooth, and a plugin missing a required key still shows its
      warning badge after a moment.
- [ ] View menu: Zoom In / Zoom Out / Actual Size work; Actual Size is
      greyed out at normal size, and Zoom In greys out at the largest size.
- [ ] (If you use OpenRouter) a request the provider rejects shows the
      provider's reason after "Provider returned error:", not just the
      generic line.

## App menu bar (2026-10-10)

- [ ] There is one View menu (not two). It has Toggle Sidebar, Next Agent,
      Theme ▸ and Zoom In / Zoom Out / Actual Size.
- [ ] View ▸ Theme ▸ Dark, then Light, then System: the app switches each
      time and the tick follows. Pick a custom theme there (e.g. Nord): it
      applies, and Settings › Themes shows it active. Reset to Default on
      the Themes page goes back to System.
- [ ] If you had the built-in Dark or Light theme picked before this build,
      the app still looks the same after updating.
- [ ] File ▸ Schedules / Watchers / Agents list yours. Clicking one opens the
      right Settings page; an agent opens a new chat window for it. File ▸
      New Window with Agent does the same.
- [ ] File ▸ Enable Voice Detection (⇧⌘V) turns VAD on, and the item then
      reads Disable Voice Detection; choosing it turns VAD off again.
- [ ] ⌘N starts a new chat in the current window; ⇧⌘N opens a new window.
      The switch in Settings › Chat still flips them.
- [ ] Window ▸ Models / Tools / Server open those Settings pages.
- [ ] Help ▸ Acknowledgements… opens a list of open-source packages. Help ▸
      Osaurus Help (⌘?) opens the upstream docs site. About still says
      "Osaurus (Intel)".
- [ ] Menus in German and Chinese show translated labels, including the zoom items.

## Plugin keys and load checks (2026-10-10)

- [ ] If Plugin Settings had values before this build: after updating, open
      Plugin Settings. The values are still there, and the plugin still
      works.
- [ ] Settings › Plugins: on a plugin that needs a key, "Configure"
      opens a real form (not an "Apple Silicon" placeholder). Save a key:
      the card's warning badge goes away, and Plugin Settings shows the
      same value.
- [ ] The Intel registry plugins (time, fetch, memo, hello) still install
      and run from a chat.
- [ ] Delete a test agent that used a plugin: nothing breaks, and other
      agents' plugins still work.

## Placeholder fixes (2026-10-10)

- [ ] Settings › Agents › reorder agents: a list you can drag opens (no
      "Apple Silicon" placeholder). The new order sticks after closing.
- [ ] In a chat, click an image you attached: it opens large and you can
      zoom; Esc or the close button dismisses it.
- [ ] A plugin README with an image shows the image. Hovering shows a
      download button.

## Shortcuts and Siri (2026-10-10)

- [ ] Open the Shortcuts app and search "Osaurus": "Ask Osaurus" and
      "Run Osaurus Agent" are listed (after Osaurus has been opened once).
- [ ] Run "Ask Osaurus" with a short question: the answer appears in
      Shortcuts, and a chat with that exchange shows up in Osaurus.
- [ ] Run "Run Osaurus Agent", pick one of your agents, add some input:
      Shortcuts says "Started …", and Osaurus shows a toast when the agent
      finishes.
- [ ] (If you use Siri on that Mac) "Ask Osaurus" starts the shortcut.

## Upstream audit 2026-10-10

- [ ] If you have Node (or Python) from nvm, mise, asdf or fnm: in a
      working-folder chat, ask the agent to run `node -v` (or `python -V`).
      It prints the version instead of "command not found".

## Inline terminal (2026-10-10)

- [ ] Ask an agent in a working-folder chat to run something slow, e.g.
      `for i in 1 2 3 4 5; do echo $i; sleep 1; done`. Expand the tool
      card: lines appear live in a terminal pane. When it finishes, the
      pane keeps the command, its output and the exit code.
- [ ] A failing command (`ls /nope`) shows its error output in the same
      pane.

## Tool execution boundary (2026-10-10)

- [ ] Ask an agent to run a command with huge output (e.g. `yes | head -c
      2000000`): the tool card shows the output truncated with a note, and
      the chat keeps working (no context-overflow error).
- [ ] Ask an agent to edit a file: the edit applies as before, and deleting
      text by replacing it with nothing still works.
- [ ] Ask for something that makes a tool hang (e.g. an MCP tool that
      never answers): after about 2 minutes the card says it timed out,
      and the agent carries on.

## Run progress chip (2026-10-10)

- [ ] Ask an agent to run `sleep 45` (it streams nothing): after about 30 s a
      "Still working…" chip appears above the composer, and it goes away when
      the reply continues.
- [ ] Ask it to run `sleep 150`: after 2 minutes the chip turns to "No
      response for a while…" with Stop, and Stop ends the run.

## Images reach cloud models (2026-10-10)

- [ ] With a vision model (e.g. an OpenRouter GPT/Claude/Gemini model, or
      the Router's vision models), attach a photo and ask what's in it: the
      answer describes the photo. (Before this build, images never left the
      app.)
- [ ] With a ChatGPT (Codex) model, the same works.
- [ ] With DeepSeek (text-only), attach an image and ask something: you
      still get an answer (the image is skipped and the model is told it
      couldn't be sent), and later messages in that chat keep working.
- [ ] Open an older DeepSeek chat that has an image in it and continue
      it: it still works.

## OpenAI, Anthropic and Google providers (2026-10-10)

Needs an API key for each provider you want to check (Settings ›
Providers). Before this build, these three could list models but not chat.

- [ ] **OpenAI** preset: chat with a GPT model, ask something that uses a
      tool (e.g. "what time is it in Tokyo?"), and attach an image once.
- [ ] **Anthropic** preset: same three checks with a Claude model. A
      longer chat keeps working on follow-ups.
- [ ] **Google** preset: same three checks with a Gemini model, including a
      second tool call in the same reply (e.g. "time in Tokyo and in Lima").
- [ ] With each, a chat title appears after the first exchange.

