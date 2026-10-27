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

- **Left out** (feature not on Intel): Local Models, Images, Channels,
  Automation (Computer Use / Browser / Sandbox), Workspaces, Declarative
  Configuration, and the 4,500-word Settings catalog (`find` searches Intel's
  live `SettingsSearchIndex` instead).
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
- Intel's local server: `/health`, `/models`, `/chat/completions` (DeepSeek
  proxy reading `DEEPSEEK_API_KEY` from the environment only), and `/mcp`
  (`MCPBridge`: demo tools `echo`, `get_time`, `os_info`). See the
  `W-server-api` row for the follow-ups.
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
