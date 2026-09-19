# Rosy Build `5419bf4cb` Knowledge and Controls Retest

This is the focused follow-up to Renée's completed annotations in
[`ROSY_2026-09-19_VENTURA_RETEST.md`](ROSY_2026-09-19_VENTURA_RETEST.md).
Do not repeat the already-passed creation-form or message-statistics tests unless
a regression appears.

## Candidate

- Commit: `5419bf4cb` (`Finish Ventura controls and Knowledge parity`)
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
- Overall result: [ ] Pass  [ ] Fail  [ ] Partial

## 1. Settings titlebar and untouched native controls

- [ ] Launch Settings directly after a complete quit. Red, yellow, and green
      controls are visible, clickable, and sit on a light titlebar that blends
      with Settings instead of a large dark-grey strip.
- [ ] Before clicking any control, inspect a normal and disabled button, switch,
      selector, menu, and numeric stepper. Every label/icon is readable; none is
      white on white or blank.
- [ ] Open General and Memory. Existing switch states and the Core Model selector
      are visible before interaction.
- [ ] Navigate between several Settings pages, open and dismiss a sheet, then
      repeat the checks.
- [ ] Switch to an agent with a dark **chat** theme. Its chat becomes dark while
      the separate Settings window remains consistently readable.
- [ ] Quit completely, relaunch, and repeat the titlebar and untouched-control
      checks once.

## 2. Knowledge cards

- [ ] Each populated collection card shows its name and summary, enabled switch,
      agent-access count/avatars where applicable, project usage where applicable,
      document/chunk status, and Re-index/Delete actions.
- [ ] A collection with no agent grant says that no agents have access.
- [ ] Toggle a collection off and on before opening its details; colour and state
      are correct immediately and persist after navigation.

## 3. Knowledge details and real data

- [ ] Open a populated collection. The sheet shows name, summary, enabled switch,
      Location, created/updated dates, Status, project usage where applicable,
      Agents with Access, Documents, and Delete/Edit/Re-index/Done.
- [ ] Document rows show name, relative path, and category where the index has one.
      Counts agree with the collection card.
- [ ] Toggle one custom agent's access off, close the sheet, reopen it, and confirm
      the grant remains off. Confirm that agent cannot search the collection.
- [ ] Toggle access back on, reopen the sheet, and confirm the grant remains on.
      Confirm the agent can search the collection again.
- [ ] Press Edit, change the summary and one harmless index filter, save, and
      confirm the collection re-indexes and the values survive relaunch.
- [ ] Restore the original filter after the test.
- [ ] Press Re-index and confirm the sheet stays responsive while status/counts
      refresh.
- [ ] Verify Delete opens a confirmation and cancel it. Do not delete a real
      collection for this focused pass.

## 4. Regression guard

- [ ] Add Knowledge Collection still shows the complete labelled form and readable
      Cancel/Add buttons.
- [ ] A fresh completed assistant response still shows TTFT, tok/s, total tokens,
      and its actions menu.
- [ ] Existing collections, project assignments, and agent grants are unchanged
      except for the explicit test edits above.

## Evidence and decision

- [ ] Save one screenshot of the Settings titlebar and untouched controls.
- [ ] Save one screenshot of the top half of a populated Knowledge detail sheet.
- [ ] Save one screenshot of its agent-access and document sections.
- [ ] Accept the repaired group on Rosy.
- [ ] Keep it Partial and record each failure against commit `5419bf4cb`.

### Failures

- None recorded yet.

### Unexpected differences from upstream

- None recorded yet.
