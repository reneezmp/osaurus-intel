# Rosy Build `944887838` Retest Checklist

Use this checklist for the exact candidate built after Rosy disproved
`f38bfecf1`. It covers the repaired Ventura controls, Knowledge form, and
message chrome. Keep the broader post-QA checklist for the other feature groups.

## Candidate

- Commit: `944887838` (`Repair Ventura settings rendering`)
- App: `build/rosy-deploy/Build/Products/Debug/osaurus.app`
- Architecture: thin `x86_64`
- Minimum system: macOS 13.0
- Data root: canonical `~/.osaurus`
- M4 validation: 983 tests in 149 suites passed
- Signature: strict deep verification passed

Record the Rosy result here:

- Date/time:
- macOS version:
- Tester:
- Copied app hash or commit confirmation:
- Overall result: [ ] Pass  [ ] Fail  [ ] Partial

## Preflight

- ✅ Quit every Osaurus process and replace the previous app with this candidate.
- ✅ Confirm the candidate commit/build identifier is `944887838`.
- ✅ Confirm Rosy is running macOS Ventura and screen sharing is stopped.
- ✅ Launch Settings directly from a fresh app launch before opening a sheet.

## Settings window chrome

- ⚠️ Red, yellow, and green controls are visible immediately and each action works. --> Yes, it appears normally on the chat window, but on the settings window it appears in a dark bar
- ❌ Repeat after selecting a dark agent/chat theme; Settings controls remain readable. --> When changing to an agent that uses a dark theme, it changes only the chat window theme. The settings remains the same.
- ✅ Open and dismiss Add Knowledge Collection; the traffic lights neither disappear nor change from coloured to grey merely because the sheet is presented.
- ✅ Quit completely and repeat the three checks after relaunch. --> same results

## Text and native controls

- ✅ Focus Search Settings, a standard text field, a numeric field, and a multiline editor. Each shows a visible caret, readable text/placeholder, selection, and
      focus treatment before and after typing.
- ⚠️ Inspect one untouched toggle, selector, menu, normal button, primary button, and disabled button. No foreground is white on a white background. --> I opened the details of a knowledge base and the buttons are still not displaying properly
- ⚠️ Repeat after navigation, theme changes, and relaunch. --> The theme problem stated below still happens

## Add Knowledge Collection parity

- ✅ The sheet shows labelled Name, Summary, Folder, Include, and Exclude fields, format/help text, Choose, Cancel, and Add.
- ✅ Create a temporary collection with an Include glob and an Exclude glob; confirm only matching non-excluded files are indexed.
- ✅ Reopen or inspect the collection after relaunch and confirm the filters persist.
- ✅ Delete the temporary collection after the check.

⚠️ I realised the detail page of a knowledge base is very different from upstream's! THe "penhoras" screenshot is ours, the "Modelos Gabinete" screenshot is upstream's. Theirs shows Location, Status, Agents with acces (with toggles) and Documents (with name, relative path and tag). Please check their code and lets copy it!
Their knowledge cards also shows more details (check screenshot)
Also, there's no button to edit the KB

## Completed-message chrome

- ✅ Send a fresh ordinary request. The completed assistant message shows its actions menu plus TTFT, tok/s, and total generated tokens.
- ✅ Send a tool-using request. The final assistant message shows the same metrics and one actions row; intermediate tool turns do not duplicate the footer.
- ✅ Reopen both chats and confirm the available metrics remain visible. Historical responses created before metric capture may remain blank and are not reconstructable.
- ✅ Repeat after a theme change and full relaunch.

## Evidence

- ✅ Save one screenshot of Settings before any sheet is opened.
- ✅ Save one screenshot with the complete Knowledge form.
- ✅ Save one screenshot of a fresh completed response showing all three metrics.
- ✅ Record every failure against the exact candidate commit; do not promote the Ventura parity row from Partial from automated evidence alone.

## Result notes

### Failures

- Reported above.

### Unexpected differences from upstream

- Reported above

### Final decision

- [ ] Accept this repaired group on Rosy.
- ⚠️ Keep the group Partial and return the failures to the repair log. --> we're almost there!
