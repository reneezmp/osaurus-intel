# Rosy Ventura Window and Message Retest

Use this short list for the candidate built after Rosy disproved `f38bfecf1`.
It covers only the first failed group; keep the broader post-QA checklist for
the remaining repaired features.

## Preflight

- [ ] Quit every Osaurus process, replace the app, and record the candidate commit.
- [ ] Confirm Rosy is running macOS Ventura and screen sharing is stopped.
- [ ] Launch Settings directly from a fresh app launch before opening a sheet.

## Settings window chrome

- [ ] Red, yellow, and green controls are visible immediately and each action works.
- [ ] Repeat after selecting a dark agent/chat theme; Settings controls remain readable.
- [ ] Open and dismiss Add Knowledge Collection; the traffic lights neither disappear
      nor change from coloured to grey merely because the sheet is presented.
- [ ] Quit completely and repeat the three checks after relaunch.

## Text and native controls

- [ ] Focus Search Settings, a standard text field, a numeric field, and a multiline
      editor. Each shows a visible caret, readable text/placeholder, selection, and
      focus treatment before and after typing.
- [ ] Inspect one untouched toggle, selector, menu, normal button, primary button,
      and disabled button. No foreground is white on a white background.
- [ ] Repeat after navigation, theme changes, and relaunch.

## Add Knowledge Collection parity

- [ ] The sheet shows labelled Name, Summary, Folder, Include, and Exclude fields,
      format/help text, Choose, Cancel, and Add.
- [ ] Create a temporary collection with an Include glob and an Exclude glob; confirm
      only matching non-excluded files are indexed.
- [ ] Reopen or inspect the collection after relaunch and confirm the filters persist.
- [ ] Delete the temporary collection after the check.

## Completed-message chrome

- [ ] Send a fresh ordinary request. The completed assistant message shows its actions
      menu plus TTFT, tok/s, and total generated tokens.
- [ ] Send a tool-using request. The final assistant message shows the same metrics and
      one actions row; intermediate tool turns do not duplicate the footer.
- [ ] Reopen both chats and confirm the available metrics remain visible. Historical
      responses created before metric capture may remain blank and are not reconstructable.
- [ ] Repeat after a theme change and full relaunch.

## Evidence

- [ ] Save one screenshot of Settings before any sheet is opened.
- [ ] Save one screenshot with the complete Knowledge form.
- [ ] Save one screenshot of a fresh completed response showing all three metrics.
- [ ] Record every failure against the exact candidate commit; do not promote the
      Ventura parity row from Partial from automated evidence alone.
