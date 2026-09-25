# Rosy Knowledge parity retest — 2026-09-21

This focused pass validates the Knowledge grant-observability and collection-card
repairs implemented after Rosy's partial 2026-09-19 result. It does not reopen
unrelated acceptance sections.

## Candidate

Original candidate (runtime failed):

- Source base: `8f3dbfdd` (`intel-fork`) plus the pending Knowledge parity patch
- Version: `1.0.37` (`38`)
- App: `build/rosy-deploy/Build/Products/Debug/osaurus.app`
- Transfer archive: `build/rosy-deploy/Osaurus-Intel-Knowledge-2026-09-21.zip`
- Archive SHA-256: `dbcad8a5daa401b362e0392b2940e5ee3cdcc4982bde0606a6c93c8b91722a69`
- Architecture: thin `x86_64`
- Minimum system: macOS 13.0
- Data root: canonical `~/.osaurus`
- Signing: stable self-signed `Osaurus Intel Code Signing`; first-open
  Gatekeeper acceptance remains a Rosy manual check
- Automated gate: 9 tests in `IntelAgentRuntimeLaneTests` passed with isolated storage
- Explicit package gate: `swift build --package-path Packages/OsaurusCore --arch x86_64` passed

Replacement runtime candidate:

- Version: `1.0.38` (`39`)
- Transfer archive: `build/rosy-deploy/Osaurus-Intel-Knowledge-Runtime-2026-09-22.zip`
- Archive SHA-256: `a72a79cfdee9c376911fae419d85b420b1e5938527f59ac7f035446161186f14`
- Architecture: thin `x86_64`; minimum macOS 13.0; canonical `~/.osaurus`
- Focused gate: 9 tests in `IntelAgentRuntimeLaneTests` passed, including
  Knowledge schema offer and removal for a seeded manual agent

Record on Rosy:

- Date/time: 2026-09-22 (in progress)
- macOS version:
- Tester: Renée
- Overall result: [ ] Pass  [x] Fail  [ ] Partial — replacement candidate
  passed runtime, card-parity, and persistence checks, but card deletion
  bypassed confirmation

## 0. Safety and launch

- ✅ Back up Rosy's `~/.osaurus` before replacing the app.
- ✅ Quit the previous Osaurus completely.
- ✅ Copy the app from the zip into `/Applications`; do not transfer the raw
      `.app` through iCloud because that can damage bundle symlinks.
- ✅ Original candidate SHA-256 was
      `dbcad8a5daa401b362e0392b2940e5ee3cdcc4982bde0606a6c93c8b91722a69`.
- [ ] Confirm the replacement zip SHA-256 is
      `a72a79cfdee9c376911fae419d85b420b1e5938527f59ac7f035446161186f14`.
- ✅ If Gatekeeper blocks the first launch, right-click the app and choose
      **Open**, then confirm the launch. Record any different behavior below.
- ✅ Launch the candidate and confirm existing agents and Knowledge collections
      are present.
- ✅ Confirm the log reports the canonical Intel data root (`~/.osaurus`).

## 1. Agents with Access — visible state

Use one existing populated collection and one disposable custom agent.

- ✅ Open Settings → Knowledge → the collection's Details sheet.
- ✅ Note the agent's initial access state before changing it.
- ✅ Toggle access on. The switch changes immediately and stays changed without closing the sheet.
- ✅ Close Details. The collection card immediately shows the correct agent access count/avatar.
- ✅ Reopen Details. The switch still shows access on.
- ✅ Toggle access off. The switch and card summary update immediately again.

## 2. Persistence across relaunch

- ✅ Turn the disposable agent's access on.
- ✅ Quit Osaurus completely and relaunch it.
- ✅ Reopen the collection. The access switch remains on.
- ✅ Confirm the collection card still includes the agent in its access summary.
- ✅ Turn access off, quit completely, and relaunch again.
- ✅ Confirm both the switch and card remain off/absent.

## 3. Runtime enforcement

- ✅ Grant the collection to the disposable agent.
- ✅ Start a fresh chat with that agent and ask it to browse or search the collection for a known harmless fact. It can access the collection.
- ✅ Restore an existing chat belonging to that agent and repeat the search.  It can access the collection there too.
- ✅ While one chat remains open, revoke the collection in Settings.
- ✅ On the next turn in the already-open chat, ask for the same Knowledge search. Access is denied; stale chat state must not retain the grant.
- ✅ Start another fresh chat and confirm access is also denied.
- ✅ Re-grant access and confirm a subsequent turn can search again.

## 4. Collection-card parity

- ✅ Every populated collection card shows an inline **Edit** action.
- ✅ Press Edit, change only the summary, save, and confirm the card updates.
- ✅ Reopen Edit and restore the original summary.
- ✅ A fully categorized collection shows **All categorized**.
- ✅ A collection containing uncategorized indexed documents shows the correct singular/plural uncategorized count.
- ✅ After Re-index finishes, the category badge refreshes without relaunching.

## 5. Regression guard

- ✅ Details, Re-index, enable/disable, and Delete controls remain visible.
- ❌ Delete still asks for confirmation; cancel it. Do not delete real data.
  The rubbish-bin icon on a Knowledge card deleted the collection immediately.
- ✅ Project usage, document/chunk counts, indexed document rows, and category labels still render correctly.
- ✅ Add Knowledge Collection still shows the complete labelled form.
- ✅ No unrelated agent grant or project assignment changed.

## Evidence and decision

- [ ] Screenshot the access switch immediately after changing it.
- [ ] Screenshot the corresponding card access summary.
- ✅ Screenshot one categorized or uncategorized badge and the inline Edit action.
- [ ] Record any failure below with the exact agent, collection, fresh/restored
      chat state, action, visible result, and whether a full relaunch changed it.

### Failures

- **2026-09-22 — Runtime tool offering failed on original candidate `1.0.37`
  build `38`; repaired and passed on replacement `1.0.38` build `39`.** Both Moony01 and
  Sunny01 had tools enabled and an enabled Knowledge grant, but fresh chats did
  not receive `list_knowledge`, `read_knowledge`, or `search_knowledge`. The
  agents explicitly enumerated only folder/file, shell, memory, search, and
  code-execution capabilities and said no dedicated Knowledge tool existed.
  Screenshots supplied by Renée confirm the failure is schema absence rather
  than model refusal.
- Root cause: `composeChatContext` correctly established a non-empty Knowledge
  scope, then the agent's previously seeded discretionary tool allowlist
  filtered all three Knowledge schemas back out. Dispatch applied the same
  allowlist before checking the independent Knowledge grant.
- The replacement made the Knowledge grant/project scope authoritative for
  offering and executing the three tools while continuing to remove them on
  revocation. Fresh chat, restored chat, open-chat revocation, new-chat denial,
  and re-grant all passed on Rosy.
- **2026-09-22 — Knowledge card deletion bypasses confirmation.** The detail
  sheet's Delete button uses a confirmation dialog, but the card rubbish-bin
  button calls `deleteCollection` directly. Rosy deleted the collection on the
  first click. The card action must share the confirmation path before another
  candidate is accepted.
- **2026-09-22 — inactive Settings rendering.** While another Osaurus window
  is key, native buttons, toggles, and some text in Settings wash out to white
  against the light paper theme. The same screenshot also confirms the native
  Settings titlebar remains a conspicuous white band rather than chat's unified
  full-size chrome.
