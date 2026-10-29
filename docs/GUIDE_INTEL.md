# In-app guide on Intel (`osaurus_help`)

Shipped 2026-10-27 (`W-ui-misc`). Upstream's Orchestrator answers questions
about Osaurus from a bundled guide (`Resources/Guide/guide-*.md`, loaded by
`Services/Guide/OsaurusGuide.swift`) through the `osaurus_help` tool. Intel
had only one topic (Knowledge) and no tool.

## Code

- `Services/Guide/OsaurusGuide.swift`: upstream's loader, verbatim (front
  matter `title` / `summary` / `order`, parsed once, sorted by order then id).
- `Tools/OsaurusHelpTool.swift`: Intel's tool. Upstream's lives in the
  excluded `ConfigurationTools.swift` beside `osaurus_inspect`. Same actions
  (`topics`, `read`, `find`), Orchestrator-only (registered in
  `registerIntelOrchestratorTools`, listed in `orchestratorOnlyToolNames`).
  `find` reuses `IntelOrchestratorConfigurationTool.findSettings` (the
  relaxed catalog pass) and returns Intel's "open with" hint.
- `IntelOrchestratorPrompt` tells the Orchestrator to use `osaurus_help` for
  questions about Osaurus and its `find` for setting locations.

## The corpus is Intel's own

The guide is what the Orchestrator says about the app, so every topic must be
true of this build. Upstream's 28 topics were checked one by one against
Intel's code and docs:

- **Left out** (feature not on Intel): Local Models, Channels,
  Automation (Computer Use / Browser / Sandbox), Workspaces, Declarative
  Configuration, and the 4,500-word Settings catalog (`find` searches Intel's
  live `SettingsSearchIndex` instead).
- **Images** (2026-10-28, `W-media-generation`): `guide-images.md`,
  "Images and Video", written from Intel facts (Osaurus Cloud and Venice,
  the chat picker, the agent switches, video recovery); Agents, Insights and
  What runs on this Intel Mac now mention it.
- **AppleScript** (2026-10-28, `W-applescript-agent`): the Agents topic
  lists Mac Automation among the abilities, and What runs on this Intel Mac
  lists it as working (on the chat's cloud model). Upstream's Automation
  topic stays left out (Computer Use, Browser Use, Sandbox).
- **Browser Use** (2026-10-28, `W-browser-use`): listed among the Agents
  abilities and as working in What runs on this Intel Mac (with the shared
  profile on macOS 13); Computer Use stays under "not in this build yet".
- **Agent page** (2026-10-28, `W-agent-detail-redesign`): the Agents topic
  describes the header (back, switcher, Share, Delete), the folder-style
  group tabs that remember their last page, the Tools counts, and the Next
  Run banner shown when Self-scheduling is on. Skills stay per agent here
  (upstream's shared skills library is `W-tools-tab-sync`).
- **New:** `guide-intel-mac.md`, "What runs on this Intel Mac": what needs
  Apple Silicon, what isn't in this build yet, and what works the same. Other
  topics point to it.
- **Rewritten from Intel facts:** Getting Started, Cloud Models and
  Providers, Agents, The Orchestrator, Skills, Plugins, Memory, Server and
  API, Voice, Themes, Privacy and Storage, Identity, Troubleshooting.
- **Upstream text with Intel edits:** Chat, Slash Commands, MCP, Schedules,
  Watchers, Agent Database, Insights. Intel's existing Knowledge topic was
  brought up to date (write tools, History, folder watcher).

Facts found while checking (all reflected in the guide):

- The Orchestrator is not read-only on Intel: with a working folder it gets
  the folder tools, plus the agent-loop tools and its enabled allowlist
  (`SystemPromptComposer.composeChatContext`). Upstream's restricts it.
- Autonomous Execution is an unavailable row on Intel (it needs the sandbox).
- Memory distillation is opt-in per agent: Settings → Memory → Diagnostics.
- Intel's local server (2026-10-29, `W-server-api` stages 0–3,
  `SERVER_API_INTEL.md`): the inference routes on the user's cloud models,
  the model list from Server › Models, and `/mcp/tools` / `/mcp/call`. The
  Server and MCP topics say so; agent runs, sessions and media come with
  later stages.
- Databases are always SQLCipher-encrypted on Intel (no opt-in toggle); no
  Privacy Filter, analytics or crash reporting.

## Checking the corpus

`python3 scripts/upstream/guide_check.py Packages/OsaurusCore Packages/OsaurusCore/Resources/Guide $(ls Packages/OsaurusCore/Resources/Guide)`
lists bold UI labels and `code` names in each topic that don't occur in the
sources Intel compiles (or the string catalog). A miss is a prompt to check
the sentence, not proof it is wrong: emphasised prose also shows up. Run it
on upstream's topics before porting a guide change, and on Intel's after
editing one. `OsaurusHelpToolTests` pins the topic set, the left-out topics,
and upstream-only phrases that must not return.

## Upstream guide changes

Upstream edits its guide often (e.g. #3171's path wording). Port a change
only after checking it against Intel; a change to a left-out topic needs no
port. Record the check in the audit as usual.
