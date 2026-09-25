# Rosy Settings window and Knowledge deletion retest — 2026-09-22

This focused pass follows the completed Knowledge runtime acceptance on Rosy.
Do not repeat the already-passed grant/runtime/card-parity sections unless a
regression appears here.

## Candidate

- Superseded candidate: `1.0.39` (`40`) removed the white band but hid the
  traffic lights; retain only as failure evidence
- Superseded candidate: `1.0.40` (`41`) still hid the traffic lights and
  introduced a blank Core Model picker label
- Superseded candidate: `1.0.41` (`42`) still hid Settings traffic lights,
  hid inactive chat traffic lights, and rendered Core Model as bare text
- Superseded candidate: `1.0.42` (`43`) hid AppKit's controls but placed the
  replacements below Ventura's separate titlebar frame, making both disappear
- Superseded candidate: `1.0.43` (`44`) displayed the chat controls in the
  toolbar flow at the wrong coordinates, displayed none in Settings, and let
  the button-style Core Model menu lose its selected text
- Superseded candidate: `1.0.44` (`45`) restored correctly positioned,
  active/inactive traffic lights in chat and fixed the Core Model picker, but
  Settings still displayed no traffic lights
- Superseded candidate: `1.0.45` (`46`) proved the Settings strip survives and
  remains attached after presentation, but also proved that Ventura composites
  the entire native-button plane underneath another Settings layer
- Accepted candidate: `1.0.46` (`47`)
- Archive: `build/rosy-deploy/Osaurus-Intel-Settings-Frame-Root-2026-09-22.zip`
- SHA-256: `0a4803abe815984b41121e9b533baf2c9d252a25566ef09c0a88a6eb1982958a`
- Architecture: thin `x86_64`; minimum macOS 13.0; canonical `~/.osaurus`
- Automated gate: 17 tests across the Intel Ventura-rendering and agent-runtime
  suites passed; archive extraction preserved the bundle symlinks, version,
  architecture, and canonical data-root flag

Record on Rosy:

- Date/time:
- macOS version:
- Tester: Renée
- Overall result: [x] Pass  [ ] Fail  [ ] Partial — accepted by Renée on Rosy

## 0. Install

- [ ] Back up `~/.osaurus`, quit Osaurus fully, and replace the app.
- [ ] Confirm the archive SHA-256 matches the value above.
- [ ] Launch and confirm existing agents, chats, and Knowledge collections remain.

## 1. Knowledge deletion safety

Use a disposable collection only.

- ✅ Press the rubbish-bin icon on the collection card. A themed confirmation
      appears; the collection is still present behind it.
- ✅ Press **Cancel**. The collection remains present and usable.
- ✅ Open Details and press **Delete**. The same confirmation appears.
- ✅ Cancel again; the collection remains present.
- ✅ Press either Delete entry point once more, confirm **Delete Collection**, and verify only then that the disposable collection is removed.
- ✅ Confirm the source folder and its files remain untouched.

## 2. Unified Settings chrome

- [x] Settings still has no separate white band across the top.
- [x] The close, minimize, and zoom traffic lights are visible before any click.
- [x] All three traffic lights remain clickable and perform their normal actions.
- [x] Resize and reopen Settings; content does not overlap the traffic lights.
- [x] The sidebar and page header begin below/alongside the unified titlebar
      without clipping, unexplained padding, or an inaccessible drag region.
- [x] Put Settings in front: Settings' controls are colored and chat's three
      controls remain visible in muted grey.
- [x] Put chat in front: chat's controls become colored and Settings' controls
      remain visible in muted grey.
- [x] Confirm close, minimize, and zoom work in both Settings and chat.
- [x] Close Settings with the red control, reopen it from chat, and confirm all
      three Settings controls return in the correct position.
- [x] Resize Settings, release the pointer, and confirm the controls remain
      visible after the resize lifecycle completes.

## 3. Active and inactive rendering

- [ ] With Settings key, record the appearance of Add Collection, card toggles, sidebar labels, and card actions.
- [ ] Make a chat window key while leaving Settings visible. Those controls remain readable; record any normal macOS inactive desaturation separately from white-on-white text.
- [ ] Return focus to Settings. No control requires a click to recover its color.
- [ ] Repeat with an enabled and a disabled collection toggle.
- [ ] Repeat once in a dark agent theme and once in a light agent theme.

## 4. Core Model menu

- [ ] Open Settings → General. The selected Core Model name is visible without clicking the control.
- [ ] Open the menu and select a different installed model. Its name appears immediately.
- [ ] Save Changes, close Settings, reopen it, and confirm the chosen name remains visible.
- [ ] Select **Use chat model (default)** and confirm that exact fallback label is visible.

## Evidence

- [ ] Screenshot Settings while it is inactive beside the active chat window.
- [ ] Screenshot the unified top chrome with visible traffic lights.
- [ ] Screenshot the card-triggered deletion confirmation.
- [ ] If Settings controls are still absent, capture Console lines containing
      `[Osaurus Intel][SettingsChrome]`; these now report the native close
      button's parent identity, frames, visibility, and strip attachment.

### Failures

- **2026-09-22 — traffic lights invisible on `1.0.39` build `40`.** Settings'
  unified toolbar existed but had no materialized items. On
  Rosy/Ventura AppKit collapsed that native chrome region, so the standard
  window buttons were logically installed and not hidden but were not visible.
  The next candidate must install a flexible-space item after toolbar
  attachment and verify the item exists rather than testing only
  `standardWindowButton(...).isHidden`.
- **2026-09-22 — traffic lights still invisible and Core Model label blank on
  `1.0.40` build `41`.** A flexible-space item was not equivalent to chat's
  titlebar lifecycle. Settings now uses a retained `NSToolbarDelegate` and a
  delegate-produced, non-zero-height custom item, matching chat's ownership
  contract. The broad `controlActiveState = active` override was removed, and
  the native Core Model `Picker` was replaced with a theme-owned `Menu` whose
  visible title is computed for default, available, and unavailable selections.
  Focused coverage now asserts both the real toolbar item and every selection-
  title state.
- **2026-09-22 — shared native-button rendering and menu affordance failed on
  `1.0.41` build `42`.** Settings still had no traffic lights; the inactive chat
  window also lost its traffic lights instead of showing muted grey controls.
  Core Model showed the selected text but Ventura discarded the custom
  borderless menu's border and chevron. The next candidate uses one shared
  topmost traffic-light strip for both window types, with red/yellow/green key-
  window colors, grey inactive colors, and close/minimize/zoom actions. Core
  Model now uses the standard macOS button-menu style so AppKit owns the visible
  border and disclosure indicator.
- **2026-09-22 — replacement strip hidden below the titlebar on `1.0.42` build
  `43`.** A topmost subview of the full-size content view is still below
  Ventura's separate titlebar frame. Because the candidate also hid AppKit's
  unreliable standard buttons, neither set was visible. The replacement strip
  now lives in a real `NSTitlebarAccessoryViewController`; the regression test
  explicitly requires titlebar ownership and rejects a content-view overlay.
- **2026-09-22 — accessory placement and native menu label failed on `1.0.43`
  build `44`.** Chat proved the strip itself and active/inactive palettes work,
  but AppKit placed the accessory in toolbar flow below and right of the native
  button cluster; Settings did not show it. The strip now becomes a sibling of
  the hidden native close button inside its actual titlebar superview, and its
  frame is derived from the native close button's coordinates. Core Model no
  longer uses `Picker` or `Menu`: a fully SwiftUI-owned button renders the text,
  border, and chevron and opens a SwiftUI popover of model choices.
- **2026-09-22 — Settings-only titlebar lifecycle failure on `1.0.44` build
  `45`.** Chat now places the replacement controls at the native traffic-light
  coordinates and correctly changes them between colored/key and grey/inactive
  states. The custom Core Model button/popover also renders and operates
  correctly. Settings alone still has no controls. This disproves a shared
  drawing, color, or coordinate defect: the remaining defect is ownership and
  lifecycle of the Settings titlebar hierarchy. `restoreTitlebarControls`
  attaches the strip to `standardWindowButton(.closeButton)?.superview` before
  the Settings window is ordered and keyed. Settings has no retained window
  delegate or post-key repair, and its existing-window path only calls
  `makeKeyAndOrderFront`. Ventura can replace or retire that private titlebar
  container while finalizing the hosting controller and toolbar, leaving the
  strip attached to a stale/non-visible view. The current unit test only
  inspects an off-screen window immediately after configuration, so it proves
  installation but not survival through order-front/key/titlebar finalization.
  Do not change the now-working chat strip or Core Model picker. The next work
  should add a Settings-owned lifecycle controller/delegate, repair only after
  the window becomes key and completes layout, repair again on reuse, and add a
  lifecycle test that deliberately invalidates the initial titlebar attachment.
- **2026-09-22 — lifecycle repair disproved stale attachment on `1.0.45` build
  `46`.** Rosy's `[SettingsChrome]` logs consistently reported a key and visible
  Settings window, a visible native parent, the strip attached to that same
  stable parent, and canonical frames (`closeFrame={{19, 18}, {14, 16}}`,
  `stripFrame={{19, 17}, {52, 18}}`). The parent identity also remained stable
  across key, reuse, settled, and visibility repairs. Therefore the strip was
  neither lost, misplaced, nor attached too early: Ventura composites or clips
  the complete native-button plane below another Settings layer. The next
  candidate keeps chat unchanged and moves only the Settings strip to the
  persistent frame root (`window.contentView?.superview`), converts the native
  close-button frame through window coordinates, and inserts the strip above
  both titlebar and SwiftUI content. Focused tests require frame-root ownership
  and still require recovery after deliberate strip removal.

### Acceptance

- **2026-09-22 — phase completed successfully on `1.0.46` build `47`.** Renée
  confirmed on Rosy that the Settings traffic lights are finally visible and
  correctly placed while the already-correct chat window and Core Model picker
  remain normal. The accepted compatibility rule is: chat may keep its strip
  beside the native close button, but Settings must place its replacement strip
  in the persistent window frame root, using the native close button only as a
  coordinate source. Do not collapse these two installation paths back into a
  single native-titlebar-parent implementation during future upstream syncs.
