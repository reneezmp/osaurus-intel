# Native Apple app tools on Intel (B6)

Upstream `348bc70cb` (and follow-ups, as of `upstream/main` 2026-09-29) adds
built-in tool families for nine Apple apps. Intel ports them in three
releases so each app gets its own Ventura permission check before it ships.

**Decisions (Renée, 2026-09-29):**

- **Staged.** Release 1: Calendar, Reminders, Contacts, Notes, Shortcuts.
  Release 2: Mail, Maps & Location, Music. Release 3: Messages.
- **Approvals:** reads run automatically, changes ask. Deletes
  (`calendar_delete_event`, `reminders_delete`) ask **every call**; Always
  Allow is not offered and cannot be set for them.
- **Old plugins:** migrate to native. Agents that used an installed
  `osaurus.<app>` plugin get the app switched on; the plugin is superseded.

## Release 1 — shipped 2026-09-29 (awaiting Rosy)

### Where things live

| Piece | File |
|---|---|
| Upstream tool families (Calendar, Reminders, Contacts, Notes, Shortcuts) | `AppleApps/<App>/`, `AppleApps/Support/` |
| Which apps ship on Intel | `AppleApp.availableOnIntel` (`AppleApps/AppleApp.swift`) |
| Catalog (only shipped apps) | `AppleApps/AppleAppToolCatalog.swift` |
| AppleScript runner (Notes) | `AppleScript/Exec/AppleScriptExecutor.swift`, `AppleScriptLanguage.swift`, `AppleScript/Policy/AppleScriptAccessibility.swift` |
| Per-agent switch | `AgentSettings.enabledAppleApps`; `AgentManager.effectiveAppleApps` / `updateEnabledAppleApps` (IntelManagerConformers) |
| Registration + dispatch gate | `ToolRegistry.registerAppleAppTools`, `runtimeCapabilityDenial` (IntelStubConformers) |
| Prompt gate + guidance | `SystemPromptComposer.composeChatContext` (IntelDataConformers), `AppleApps/IntelAppleAppsGuidance.swift` |
| Per-call approval | `PerCallApprovalTool` (`Models/Tool/ToolPermissionPolicy.swift`), `ToolRegistry.requiresApprovalEveryCall`, `ToolPermissionView.allowsAlwaysAllow` |
| Plugin migration | `AppleApps/AppleAppsPluginMigration.swift`, `PluginManager.supersededPluginIds` / `installedSupersededAppleAppPluginIds`, launch hook in `AppDelegate` |
| UI | `IntelAppleAppsAbilitySection` in `Views/Agent/AgentsView.swift` (Agents › Overview › Apple Apps) |
| Tests | `Tests/AppleApps/*` (upstream fake-service suites + `IntelAppleAppsTests`) |

### How the gate works

- All shipped Apple tools are **registered globally** as built-ins (so the
  Tools settings list shows their Ask/Auto policies). They never enter the
  Tools-tab allowlist: the agent's per-app switch is the grant, like the
  Knowledge and Database abilities.
- **Prompt:** tools of apps the agent has not switched on are filtered out;
  switched-on apps' tools are added even to a seeded manual allowlist.
- **Dispatch:** `runtimeCapabilityDenial` refuses an Apple tool unless there
  is an agent context, the agent's switch for that app is on (and the app is
  shipped on Intel), and the agent's tools are not disabled. The built-in
  agent never gets Apple apps.
- Apps stored in `enabledAppleApps` but not shipped yet (for example an
  agent imported from upstream with Mail on) are **kept but ignored** until
  their release.

### Intel adaptations (differences from upstream)

- **EventKit on Ventura:** `CalendarService`/`RemindersService.requireAccess`
  accept `.authorized` (macOS 13's equivalent of macOS 14's `.fullAccess`);
  requests go through `requestAccessCompat`.
- **No `get_current_time` tool on Intel.** The guidance tells the model to
  resolve dates against a `## Current local time` line (ISO 8601 with
  offset, weekday, zone) that rides the per-turn prefix, so the stable
  prompt stays cacheable.
- **No pre-dispatch schema validator** (upstream `SchemaValidator` is not
  compiled on Intel): closed-schema rejection of unknown keys does not
  happen; the tools' own argument parsing still returns `invalid_args`.
- **No registry-level permission pre-check** (upstream NSError code 7):
  services report `permission_denied` themselves, with the System Settings
  pane in the envelope.
- **Per-call approval** was ported for these deletes: `policyInfo` clamps a
  `PerCallApprovalTool`'s effective policy to Ask (Deny still wins),
  `setPolicy(.auto, …)` is refused, and the approval card hides Always Allow.
- **Migration markers are per app** (`apple-apps.json`: `migratedApps`,
  `noticeShownApps`) instead of upstream's two booleans, so Release 2/3 sweep
  their own plugins on first launch without re-running Release 1.
- **Only shipped apps' plugins are superseded.** `osaurus.mail`,
  `.messages`, `.maps`, `.music` keep loading (and keep their tool names)
  until their release; the migration ignores their legacy names.
- The sweep waits for `StorageMigrationCoordinator` before reading agents,
  and verifies each save by re-reading the agent file
  (`AgentManager.loadPersisted`), because Intel `persist` swallows errors.
- The permission section of the UI shows missing access only for
  Calendar, Reminders and Contacts. Notes uses Automation, which has no
  silent probe; macOS asks the first time the agent uses Notes. Shortcuts
  needs no permission.
- The app already carries the entitlements and usage strings these need
  (`App/osaurus/osaurus.entitlements`, `Info.plist`): Apple Events,
  address book, calendars (+ Reminders string).

### Privacy

Every Intel model is remote, so anything a tool reads (event titles,
contact details, note text) goes to the agent's cloud provider. The UI
section says so.

## Release 2 — Mail, Maps & Location, Music (planned)

- Copy `AppleApps/Mail`, `Maps`, `Music` from upstream; add them to
  `availableOnIntel` and the catalog; restore their permissions in
  `AppleApp.systemPermissions` (Music automation, Mail automation,
  Location).
- Mail's send path needs `ArgumentAwarePerCallApprovalTool` (a draft can be
  pre-approved; `send: true` must ask every time). Port that protocol and
  check it in `ToolRegistry.requiresApprovalEveryCall(name, argumentsJSON:)`.
- Bring back the Maps/Location test suites removed from
  `AppleToolExecutionTests.swift` and the Mail/Music script tests.
- Check `CLLocationManager` authorization on Ventura and MapKit APIs
  newer than macOS 13.
- Guidance: re-add the Mail line from upstream.

## Release 3 — Messages (planned)

- Reading needs Full Disk Access (`chat.db`); sending needs Automation for
  Messages. `messages_send` is a per-call tool.
- Bring back `MessagesChatDBFixtureTests` and the Messages helper suite.
- Guidance: re-add the Messages line from upstream.

## Rosy checklist

See "Native Apple apps, Release 1" in
[`ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`](ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md).
