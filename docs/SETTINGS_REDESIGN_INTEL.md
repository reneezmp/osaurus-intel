# Settings redesign on Intel (upstream #2950)

Backlog id: `W-settings-ux-2950` in [`INTEL_MISSING_FEATURES_BACKLOG.md`](INTEL_MISSING_FEATURES_BACKLOG.md).
Audit: [`UPSTREAM_AUDIT_2026-09-30.md`](UPSTREAM_AUDIT_2026-09-30.md#2950--settings-redesign-staged-port-w-settings-ux-2950).
Rosy checklist: [`ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`](ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md#settings-redesign).

Upstream #2950 (`64b0d6a4b`) moved every Management tab to a macOS System
Settings–style grouped form. Intel's Settings were an older layout and every
touched file diverges, so the port is by hand, in five steps:

1. Kit + header restyle — **done 2026-09-30**
2. General / Conversation split, Advanced → Data & Storage, search anchors — **done 2026-09-30**
3. Tools & MCP rename (Services / All Tools / Plugins) and the MCP directory
4. Voice tabs (Chat Voice, Transcription) on top of the Intel voice port
5. Providers, Themes, slash-command editor sheet (the CLI card already moved in step 2)

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

## Step 2 — General / Conversation split (2026-09-30)

- **General** (`ConfigurationView`, rewritten on `SettingsPage`): General
  (hotkey, login, dock, beta), Core Model, Notifications (show toasts,
  position, test toast), Advanced (toast timeout, max visible toasts, max
  concurrent tasks, **Data & Storage** = `StorageSettingsView(embedded: true)`),
  Reset (Factory Reset). No Save button any more: edits auto-save ~0.6 s after
  the last change (upstream's debounced save), flushed when leaving the tab.
- **Conversation** (`ChatSettingsView`, new tab `ManagementTab.chat`, Intel's
  own file): Appearance (spell check), Behavior (chat titles, Core Model link,
  agent-description filler, clipboard, ⌘N, Disable Tools, Enable Memory),
  Greetings (AI greetings + personality), Folder Tool Permissions, Advanced
  (System Prompt / Temperature / Max Tokens as **Orchestrator fallbacks**,
  Context Length, Top P, Max Tool Attempts). Same auto-save; it writes only
  its own `ChatConfiguration` fields (`ChatSettingsView.apply`).
- **Storage tab** left the sidebar. `ManagementTab.storage` still exists and
  routes to General; What's New "open storage" lands on General and the
  `storage.encryption` landing opens Advanced.
- **Command Line Tool** → Developer Tools → Server → Overview
  (`CommandLineToolSection`, upstream file). Its icon is `terminal`:
  `apple.terminal` is macOS 14+ and the SF Symbol guard caught it.
- **Dropped because nothing on Intel reads them:** the Work generation
  sliders (`workTemperature`, `workMaxTokens`, `workTopPOverride`,
  `workMaxIterations`: only upstream's excluded local agent loop used them),
  the Capability Search picker (`preflightSearchMode`: preflight search is
  not compiled), the "Voice (Advanced)" status card (the Voice tab shows the
  same status), the "Server settings moved" search card, the Apple-Silicon-
  only models-directory placeholder, and General's in-page search filter
  (the sidebar search replaces the page with global results). Stored values
  are kept.
- **Kept although upstream moved them:** Disable Tools and Enable Memory
  (upstream: Agents / Memory; Intel's Memory tab has no off switch), Folder
  Tool Permissions (upstream: Tools & MCP — step 3), Context Length
  (upstream: Server → Cache, hidden on Intel), System Prompt / Temperature /
  Max Tokens (upstream: Orchestrator; on Intel they are the Orchestrator's
  inherited values, `AgentManager.effective*`), notification position /
  timeout / stack size (upstream hid them).
- **Not on Intel yet** (upstream Conversation switches): smooth streaming,
  group thinking & tool activity, expand thinking while streaming,
  compaction model, suggest follow-ups (`W-chat-ux`); keep Mac awake while
  agents run (`W-ui-misc`). No Legal links: upstream's terms cover upstream's
  service.
- ⌘N default stays **off** on Intel (upstream's `@AppStorage` default is on);
  existing users keep their value either way.
- Primitives gained an optional explicit `anchorId` (SettingsToggle, fields,
  slider, stepper, subsection): controls inside `SettingsAdvancedDisclosure`
  have no section title for the automatic anchor. `SettingsSearchIndexTests`
  now checks General and Conversation entries land on a control and that
  Advanced entries are in the page's `advancedAnchorIds`.
