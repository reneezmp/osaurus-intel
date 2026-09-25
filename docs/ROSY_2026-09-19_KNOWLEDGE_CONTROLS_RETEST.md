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
- Overall result: [ ] Pass  [ ] Fail  [x] Partial

## 1. Settings titlebar and untouched native controls

- [x] Launch Settings directly after a complete quit. Red, yellow, and green
      controls are visible, clickable, and sit on a light titlebar that blends
      with Settings instead of a large dark-grey strip. **Difference:** the
      separate light titlebar remains; upstream-style full-size chrome is still
      pending.
- [ ] Before clicking any control, inspect a normal and disabled button, switch,
      selector, menu, and numeric stepper. Every label/icon is readable; none is
      white on white or blank.
- [ ] Open General and Memory. Existing switch states and the Core Model selector
      are visible before interaction.
- [ ] Navigate between several Settings pages, open and dismiss a sheet, then
      repeat the checks.
- [x] Switch to an agent with a dark **chat** theme. Its chat becomes dark while
      the separate Settings window remains consistently readable.
- [ ] Quit completely, relaunch, and repeat the titlebar and untouched-control
      checks once.

## 2. Knowledge cards

- [ ] **Partial:** each populated collection card shows its name and summary, enabled switch,
      agent-access count/avatars where applicable, project usage where applicable,
      document/chunk status, and Re-index/Delete actions. It still lacks the
      upstream inline Edit action and categorized/uncategorized status badge.
- [ ] A collection with no agent grant says that no agents have access.
- [ ] Toggle a collection off and on before opening its details; colour and state
      are correct immediately and persist after navigation.

## 3. Knowledge details and real data

- [x] Open a populated collection. The sheet shows name, summary, enabled switch,
      Location, created/updated dates, Status, project usage where applicable,
      Agents with Access, Documents, and Delete/Edit/Re-index/Done.
- [x] Document rows show name, relative path, and category where the index has one.
      Counts agree with the collection card.
- [ ] **Failed:** toggling a custom agent's access does not visibly change the
      switch and does not establish a globally reflected grant. Fix the
      observable grant-state update before retesting persistence or runtime denial.
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

### Automated pre-Rosy gate

The current source diagnosis is that `AgentManager.updateKnowledgeSettings`
mutated its private `knowledgeGrants` sidecar and posted `.agentUpdated`, but
did not publish an observed-object change. The detail-sheet switch and card
access summary therefore could remain stale even when
`knowledge/agent-grants.json` was written. The implementation now has a
focused automated guard,
`IntelAgentRuntimeLaneTests.knowledgeGrantPublishesPersistsAndRevokesRuntimeAccess`,
covering publication, sidecar writes, capability revision, positive direct
dispatch, and revocation denial. The older
`IntelAgentRuntimeLaneTests.dispatchRejectsWebSearchAndKnowledgeWithoutTheirGrants`
still covers denial with no grant.

The card parity repair is also implemented in source: each card now exposes an
inline Edit action and asynchronously derives a categorized/uncategorized badge
from the Intel Knowledge index. These remain unchecked above until the same
x86_64 candidate is inspected on Rosy.

Before checking any box above, complete the remaining focused regression lane
covering:

- sidecar persistence across the manager's reload/relaunch boundary;
- allowed Knowledge search from a fresh chat and a restored chat whose
  `ChatSessionData.agentId` is rehydrated; and
- denial after revocation in both fresh and restored chats.

Keep these Rosy checks pending until that lane passes and the same behavior is
confirmed in the signed x86_64 candidate. Automated success is not manual
acceptance.

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

- Agents with Access switches do not change state when clicked.
- Knowledge cards still lack inline Edit and categorized/uncategorized status.

### Unexpected differences from upstream

- Settings still uses a separate light native titlebar instead of the chat
  window's full-size integrated chrome.
