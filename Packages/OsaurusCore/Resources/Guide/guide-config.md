---
title: Declarative Configuration
summary: Describe parts of your Osaurus setup as one YAML (or JSON) document; the assistant plans the diff, you approve it, then it applies.
order: 121
---

# Declarative Configuration

Parts of Osaurus can be configured from a single YAML document that describes the desired state. The Orchestrator plans a diff against the current state, shows you exactly what would change (with any risks called out), and applies it only after you approve it. Nothing is applied without your approval.

## How you use it

- **Chat.** Ask the built-in Orchestrator to change a setting ("use this model for the research agent", "turn on web search for Planner"). It calls `osaurus_config` (`schema`, `export`, `plan`, `apply`). `plan` is a dry run that changes nothing; `apply` opens the **Review configuration changes** window in the app with the diff, the risks and a prune warning. **Apply** applies it; **Cancel** (or closing the window, or waiting too long) applies nothing. The model must not ask you to confirm in chat: the window is the confirmation.
- **From your paired iPhone.** A request that came from the phone shows the same plan there, to answer on the phone.
- **Not from the background.** A schedule, a watcher, a background run or an external caller cannot apply a change on its own: those runs are refused, because nobody is there to approve. With no chat window open, an apply is refused too and nothing changes.
- **Local HTTP.** `GET /admin/config/export`, `GET /admin/config/schema` and `POST /admin/config/plan` are read-only; `POST /admin/config/apply` still waits for your approval in the app (details below).

## Sections

The document has these sections (plus `version`):

- `memory`: persistent memory: enabled, token budget, retention days.
- `default_agent`: the built-in Orchestrator: display name, model, temperature, max tokens, persona.
- `new_chat_agent`: which agent new chats open with: `default` or a custom agent's name (`active_agent` is still accepted as an older spelling).
- `agents`: custom agents: prompt, model, sampling, and per-agent capability toggles (tools, web search, Browser Use, relay, `apple_apps`, and more). `tools` with `mode: manual` is the exact tool list. `capabilities.apple_apps` lists the built-in Apple apps the agent may use (`calendar`, `reminders`, `contacts`, `notes`, `mail`, `messages`, `maps`, `music`, `shortcuts`); the full list replaces the set and `[]` turns them all off. Specialist tools are off on a new agent: set `capabilities.calculator_enabled: true` for an agent that works with numbers, in the same apply that creates it. `task_checklist_enabled`, `clarify_enabled` and `artifacts_enabled` are on by default. `orchestrator_spawnable` is accepted but does nothing here: a new agent is never added to the Orchestrator's delegation list automatically (see Delegation).
- `tools`: global tool enablement and per-tool policies (`auto` / `ask` / `deny`). Tools that send or delete as you (`messages_send`, `calendar_delete_event`, `reminders_delete`, `delete_knowledge`) ask on every call regardless; `auto` on them is stored but has no effect, and the plan says so.
- `delegation`: which custom agents the Orchestrator may delegate to (`spawnable_agents`). See below.
- `commands`: your slash-command templates.
- `knowledge_collections`: folder-backed knowledge collections with include/exclude globs.
- `mcp_servers`: MCP servers, HTTP or stdio (`command` / `args` / `env`), with `token_ref`, `secret_header_refs` and `secret_env_refs` for credentials.
- `plugins`: installed plugin ids.
- `providers`: cloud model providers, including endpoint fields (create-only) and `api_key_ref` / `set_api_key`.
- `search_providers`: web-search providers and their fallback ranking.
- `schedules`: scheduled agent runs (interval, daily, weekly, cron).
- `watchers`: folder watchers that trigger an agent.

Not available on this Mac yet: channels, harness runtimes, local models, agent skills lists, agent templates, and sandbox network keys. A document that uses one of them is refused with a message naming the key.

## Delegation

```yaml
delegation:
  spawnable_agents: [Coder, Researcher]   # replaces the whole list
```

- `spawnable_agents` is the Orchestrator's list of allowed custom agents (Settings → Orchestrator → Delegation). It replaces the whole list, so list every agent to keep; `[]` empties it, which the plan flags as high risk. Built-in agents and the Default agent are rejected.
- Listing an agent does not make it runnable by itself: its exact model must also be admitted. Admitting a cloud model, the permission modes and the child limits are Settings-only choices; `osaurus_config` never changes them, and the apply result says how many of the listed agents are actually runnable and why not.
- The other `delegation` keys (budgets, `permission_defaults`, local text, AppleScript mode and so on) are accepted and stored, but this Mac's Orchestrator doesn't read them yet; the plan marks them "stored only".
- A new agent created by `agents` is not added to the list. List it under `delegation.spawnable_agents` in the same document (the list applies after `agents`) or add it in Settings → Orchestrator.

## Semantics

- **Merge by default.** A key absent from the document is left unchanged. An explicit `null` clears an optional override back to its default.
- **Entities match by name** (case-insensitive): agents, MCP servers, providers, schedules and watchers listed in the document are created if missing and patched if present.
- **Plan is a dry run.** Only `apply` changes anything. A planned change is not a done change; after a successful apply the tool says so and the assistant stops.
- **Prune is explicit and destructive.** It is a tool argument, never a document key. Applying with prune also deletes entries not listed in the sections the document declares; it never touches undeclared sections. A prune that would delete an agent while a surviving schedule or watcher still runs on it is refused.
- **Validation is all-or-nothing.** Any invalid key, value or reference fails the whole document with every issue listed; nothing is half-applied.
- **High-risk changes always show their risks in the approval window**: prune deletions, Browser Use grants, agent relay exposure, new MCP endpoints, stdio MCP commands, setting a tool policy to `auto`, and emptying the delegation list.
- **JSON works everywhere YAML does.** `export` and `schema` accept `format: json`, and `plan` / `apply` accept JSON in the same field.

## Secrets

Secrets never appear in a document: exports contain none, and an apply never accepts a raw key. Two ways to wire credentials:

- **Secret references.** `api_key_ref` (providers), `token_ref` and `secret_header_refs` (MCP servers) and `secret_env_refs` (stdio MCP env) accept `env:VAR_NAME` or `keychain:SERVICE/ACCOUNT`. The apply resolves the reference at that moment; the document only carries the pointer.
- **The credential sheet.** Creating a cloud provider opens the native credential sheet during the apply, and so does `set_api_key: true` on an existing provider (a one-shot request, never exported). You type the key in the sheet; dismissing it cancels that step. A run from the phone gets "finish this in Settings" instead.

## Local HTTP: /admin/config

For scripts on this Mac. All four routes answer only a caller on this Mac itself (the 127.0.0.1 / ::1 address): a request that arrives over the network, through the relay tunnel, from a paired peer or inside the Secure Channel gets 403. They go through the same access-key gate as the other local admin routes.

- `GET /admin/config/export?format=yaml|json`, `GET /admin/config/schema?format=yaml|json`: read the current document or the schema.
- `POST /admin/config/plan` with `{"yaml": "<document>", "prune": false}`: the dry-run diff.
- `POST /admin/config/apply` with the same body: shows the plan in the Review configuration changes window and waits. Only your **Apply** there applies it. With no chat window open it answers 409 (`approval_unavailable`) and applies nothing; a decline answers 403, a timeout 408. `confirm_high_risk` in the body is ignored: a caller cannot approve for you. Credentials never travel through this route.

## Not configurable declaratively

- **Settings-UI only**: server runtime (port, Expose to Network, caches), chat behavior, app shell (login item, dock icon, appearance, themes), voice, which cloud models the Orchestrator may delegate to, and macOS permission grants. The Orchestrator tells you the path with `osaurus_help` `find`.
- **Inherently interactive**: macOS permission prompts, sign-ins and pairing, hotkey capture, folder pickers, destructive resets and payment.
