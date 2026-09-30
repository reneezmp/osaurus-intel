# Settings redesign on Intel (upstream #2950)

Backlog id: `W-settings-ux-2950` in [`INTEL_MISSING_FEATURES_BACKLOG.md`](INTEL_MISSING_FEATURES_BACKLOG.md).
Audit: [`UPSTREAM_AUDIT_2026-09-30.md`](UPSTREAM_AUDIT_2026-09-30.md#2950--settings-redesign-staged-port-w-settings-ux-2950).
Rosy checklist: [`ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`](ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md#settings-redesign).

Upstream #2950 (`64b0d6a4b`) moved every Management tab to a macOS System
Settings–style grouped form. Intel's Settings were an older layout and every
touched file diverges, so the port is by hand, in five steps:

1. Kit + header restyle — **done 2026-09-30**
2. General / Conversation split, Advanced → Data & Storage, search anchors
3. Tools & MCP rename (Services / All Tools / Plugins) and the MCP directory
4. Voice tabs (Chat Voice, Transcription) on top of the Intel voice port
5. Providers, Themes, slash-command editor sheet, CLI card → Developer Tools

## Step 1 — kit and header (2026-09-30)

- `Views/Settings/Shared/SettingsKit.swift` is upstream's file with Intel
  changes listed in its header:
  - **`SettingsGroup` uses `_VariadicView`**, not `Group(subviews:)`
    (macOS 15). `_VariadicView.Tree` + `_VariadicView_MultiViewRoot` has
    resolved a view builder into its children since macOS 10.15. Children
    that an `if` leaves out produce no row and no divider.
  - Single-value `onChange`.
  - `SettingsPickerRow(.segmented)` renders `ThemedSegmentedPicker` (native
    segmented pickers are banned by `IntelVenturaControlGuardTests`).
  - Colours come from `ThemeManager.shared`, like Intel's other settings
    primitives. `@Environment(\.theme)` defaults to the **light** theme
    wherever a sheet or panel does not inject it, which would put light rows
    on a dark page.
  - `SettingsRow` omits an empty description (an empty `Text` still takes a
    line and pushed the title above the trailing control; upstream has the
    same bug).
- `SettingsPrimitives.swift`: `SettingsSection` is now a sentence-case title
  above one `SettingsGroup` (the icon argument is kept but not drawn; an
  optional `anchorId` was added). Intel's automatic search anchors still work:
  the section title is injected into the group's content
  (`settingsSectionTitle`). `SettingsSubsection` is a plain semibold label.
  `SettingsToggle` wraps `SettingsRow` and keeps `ThemedSwitchToggleStyle`.
  **Consequence:** every direct child of a `SettingsSection` is now a row with
  a hairline between rows. Pages whose sections hold several loose views get
  dividers between them until their step rebuilds them.
- `ManagerHeader*`: 22 pt semibold title, 13 pt subtitle, same background as
  the page (no header band), `managerHeaderEntrance(hasAppeared:)`, and header
  buttons grey out under `.disabled(...)`. The stacked-layout and tab-subset
  changes to `HeaderTabsRow` arrive with step 3 (Intel's tools sub-tabs are
  still the old set).
- **Verifying layouts without launching the app:** `ImageRenderer` in a
  throwaway swift-testing test renders kit components to PNG (inject
  `.environment(\.theme, ThemeManager.shared.currentTheme)`). It does **not**
  draw `ScrollView` contents or views still at opacity 0 before `onAppear`,
  so whole pages come out blank below the header. `ConfigurationView` needs
  an `UpdaterViewModel` environment object; do not create one in tests
  (Sparkle). Delete such scratch tests before committing.
