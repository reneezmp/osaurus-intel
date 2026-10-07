# Model picker on Intel (`W-model-picker-2947`)

Upstream redesigned the chat's model picker into a three-column card
(Provider | Model | Model options) with a Cloud model browser and a Credits
card (#2947, 2026-09-30), seeded Osaurus Cloud starter favourites and moved
every model option into the third column (#2958), then restyled the slash,
"@" and voice popups on the same PickerCard kit (#3017, 2026-10-05). Intel
ports upstream/main's current files, not the commits one by one. Plan:
[`UPSTREAM_AUDIT_2026-10-01.md`](UPSTREAM_AUDIT_2026-10-01.md#staged-w-model-picker-2947-2947-then-2958).

## Stage A — foundations (2026-10-06)

- Upstream verbatim: `Services/FavoriteModelsStore.swift` (#1811 + #2958
  seeding), `Views/Common/AnchoredCardPresenter.swift`,
  `Views/Common/AnchoredCardResizeTransition.swift`, the provider logo
  assets (`provider-logo-{anthropic,openai,gemini,openrouter,xai}`), and the
  `smallBodySize` typography token (`ThemeProtocol`, `ThemeTypography`, read
  with a 14 pt default from older theme JSON).
- `Views/Common/PickerCardStyle.swift`: upstream's minus SwiftUI focus on
  `PickerCardTextLink`. **Ventura keyboard rule for every picker card:** no
  `.focusable()` / `focusEffectDisabled` / `onKeyPress` (macOS 14). Cards
  keep a focus key in plain state and drive ↑↓←→ / Return / Escape from a
  window-scoped key monitor; rows only draw the `focused` underline.
- `Models/Configuration/ChatModelPickerProvider.swift`: upstream's grouping
  and ordering (active Local / Osaurus Cloud first, connections in incoming
  order, inactive built-ins last; Cloud by provider id, never by title;
  nil vs empty shortlist). The source switch covers Intel's three sources
  (Foundation, local, remote; Claude Code is a remote source).
- `Models/Configuration/CloudModelCategory.swift`: image and video categories
  never match on Intel (no media models, `W-media-generation`), so the Cloud
  browser shows only All / Text-to-text / Image-to-text.
- `ModelPickerItem.favoriteKey` (upstream). Intel's `ModelPickerItem` is
  still much older than upstream's; only what the picker needs is added.
- Starter favourites: `RemoteProviderManager.firstRunOsaurusModelSlug` and
  `seedStarterFavoritesFromOsaurusRouterCatalog()` run after Intel's Router
  catalog refresh (`connectOsaurusRouterIfPossible`). Router picker ids are
  `osaurus/<model>`; the store matches the last path component. Starters
  (upstream's product choice): `deepseek-v4-1-flash`, `claude-opus-5-5`,
  `gpt-6-astra`. A user who already has favourites is never seeded.
- Tests: upstream `AnchoredCardPlacementTests`,
  `AnchoredCardResizeTransitionTests`, `FavoriteModelsStoreStarterSeedTests`,
  `ThemeTypographyTests` (minus the two `ThemeLibraryManagementService`
  cases, `W-ui-misc`), plus Intel rewrites of `ChatModelPickerProviderTests`
  and `CloudModelCategoryTests` without upstream-only sources.

## Stage B — the column picker in the chat (2026-10-06)

- Clicking the model pill (or `/model`) opens upstream's
  `ChatModelPickerCard` in an anchored card: **Provider | Model | Model
  options**. Browsing another provider never changes the model; picking a
  model does. Osaurus Cloud lists the favourites shortlist plus the selected
  model, with a star per row; "More models" opens the Cloud browser (Cloud)
  or Models management (Local). Inactive Local / Cloud rows say "Explore".
- **Options moved into the third column** (upstream #2958): Thinking
  (On / Off, with "Reset to default" once set) and every profile option
  (e.g. Reasoning Effort). Intel's separate **Thinking** and **Options**
  chips and `ModelOptionsSelectorView` are gone, as upstream.
- The pill lost its trailing icons (eye, chevron) and shows upstream's
  "model · effort" suffix (`ModelProfileRegistry.inlineReasoningSuffixLabel`,
  profile branch only). Thinking and vision state moved to the tooltip and
  VoiceOver value.
- Writes go through upstream's semantic path (`persistThinkingOverride`,
  `ModelProfileRegistry.thinkingStoredOption`, so inverted
  `disableThinking` never flips the wrong way) and are deferred a runloop
  so the pill never resizes during the card's own update.
- Files: `Views/Model/ChatModelPickerCard.swift` (upstream, adapted),
  `Views/Model/ModelPickerOptionsControl.swift` (upstream's types, which
  upstream keeps in `ModelPickerView.swift`; Intel's picker view is its own
  rewrite).
- **Intel differences:**
  - Keyboard (Ventura rule from stage A): `PickerCardKeyMonitor` drives
    ↑↓←→ and Return inside the card's panel (`activateFocused()` maps the
    focus key to its action); Escape is the presenter's.
  - No live reasoning catalog (`ModelReasoningCapabilities`): options come
    from Intel's profiles, effort rows use the segment label as help, and
    Intel's option definitions carry no footnote text.
  - Opening the card refreshes the Router catalog through
    `connectOsaurusRouterIfPossible()` (upstream refreshes every connected
    provider and prunes external models).
  - No MTP depth row (local MLX only).
  - The legacy `ModelPickerView` stays for the agent editor, Orchestrator
    and compaction settings, as upstream keeps it there.

## Stage C — Cloud model browser (2026-10-06)

- `Views/Model/CloudModelBrowserDialog.swift` (+ `CloudCategoryTag`,
  `CloudSecondaryButtonStyle` with `ModelFavoriteButtonStyle`, verbatim):
  the whole Osaurus Cloud catalog with search, Category and Context
  filters, stars, and Manage Credits. Choosing a model selects it and
  closes the sheet.
- **Intel differences:** keyboard through `PickerCardKeyMonitor` (↑↓
  highlight, Return selects; inactive while searching); no offline monitor;
  refresh via `connectOsaurusRouterIfPossible()`; identity checked once on
  appear; no media models, so no "From …" price and no image/video
  categories; themed bordered buttons.
- **Staged — Credits card:** #2947 turned the composer's credits chip
  wallet into an anchored card. Intel's composer never had upstream's
  credits chip (`FloatingCreditsChip`, router balance with low-balance
  tiers), so the card waits for that chip (`W-model-picker-2947`
  follow-up).

- Tests: `Tests/Model/IntelChatModelPickerTests.swift` (effort suffix,
  inverted Thinking writes, option defaults, key mapping). Render-checked
  offscreen on Intel (dark theme) for both the card and the browser.
- i18n: `merge-upstream-keys.py` now scans literals line by line (a stray
  quote in a comment used to shift the pairing for the rest of the file and
  silently skip strings).

## Stage D — #3017 popup restyle (2026-10-06)

- Upstream verbatim (patch applied cleanly): `SlashCommandPopup`,
  `AtFileMenuPopup`, `VoiceInputOverlay` (PickerCard surface, single-line
  rows, heading with key hints, quiet New Command / Edit links; only custom
  commands are tagged) and `FollowUpSuggestionsBar` (one-pixel dividers,
  hidden beside the hovered row).
- The slash and "@" menus float in an overlay above the input card
  (`composerPopupOverlay`), so opening one no longer shifts the composer or
  the transcript.
- **Context budget card:** upstream's current `ContextBreakdownPopover` /
  `FloatingContextChip` in an anchored card (PickerCard chrome, hero usage,
  hover preview with pin-on-click), replacing Intel's popover. Intel keeps
  its documented differences ([`CONTEXT_BUDGET_INTEL.md`](CONTEXT_BUDGET_INTEL.md)):
  window source from the catalog or Context Length, no disk-cache section,
  the "Open Context Length" link, no pink tint. The compaction rows are now
  upstream's (running phase, "Compacted — ~N tokens reclaimed", failure with
  Retry), fed by `ChatSession.compactionState`.
  - `scrollBounceBehavior` needs macOS 13.3: `intelScrollBounceBasedOnSize()`
    applies it only there.
  - The old `PopoverCardModifier` / `popoverCard()` chrome is gone (no users).
- **Staged:**
  - #3017's lone-tab styling targets upstream's Safari-style tab track
    (#2995), which Intel's Chrome-style strip doesn't have yet; both go with
    a chat-tabs follow-up (`W-chat-tabs`).
  - The wallet card restyle waits for the composer credits chip (stage C).
- Render-checked offscreen: slash and "@" menus.

## Stage E — theme editor, search, docs (2026-10-06)

- #2947's theme editor changes (3-way merged): the **Small body** size under
  Text & Fonts and landing anchors for Border Color / Width / Opacity;
  Settings search finds all four (`themes.typography.smallBody`,
  `themes.borders.*`). Intel adaptations: single-value `onChange`, and the
  landing picks the built-in theme by `isBuiltIn` + light/dark (Intel has no
  appearance-mode built-in ids).
- Not ported: upstream's `guide-chat.md` / `guide-settings.md` text (Intel
  has no in-app guide yet, `W-ui-misc`) and the `SettingsSearchSelfFindProbe`
  test helper.

## Status

Stages A–E shipped 2026-10-06. Staged: the composer credits chip and its
wallet card (Intel never had the chip), the Safari-style tab track with the
quiet lone tab (#2995 + #3017, `W-chat-tabs`), media-model categories and
prices (`W-media-generation`), live reasoning catalog capabilities.

