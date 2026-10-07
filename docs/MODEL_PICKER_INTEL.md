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
