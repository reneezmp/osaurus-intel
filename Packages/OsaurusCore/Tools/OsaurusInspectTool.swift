//
//  OsaurusInspectTool.swift
//  osaurus
//
//  `osaurus_inspect`: the Orchestrator's read surface for Osaurus
//  configuration. One tool, one scope enum, three depths: `status`
//  (aggregate snapshot with suggestions), `list` (rows in a scope),
//  `describe` (one item in full). Read-only; every write goes through
//  `osaurus_config`'s planner and the user's approval.
//
//  Intel (W-subagents stage 4, upstream Classic `ConfigurationTools.swift`,
//  #2485 / #2936): same contract, action names, scope names and envelopes
//  as upstream, with these adaptations:
//   - Scopes Intel lacks answer with a teaching failure instead of rows:
//     `channels`, `workspaces`, `shared_agents` (deferred, scope-only-user)
//     and `harness_runtimes`. `models` lists the model ids of the connected
//     cloud providers (Intel has no local MLX models).
//   - Reads expose NO secrets and touch no Keychain: provider and MCP rows
//     carry no `has_api_key` / `has_token` / `has_oauth` flags (upstream
//     reads the Keychain for them), MCP URLs are reduced to scheme, host and
//     path, and stdio environments are never listed.
//   - `status` reports the Orchestrator's spawn pool as Intel defines it
//     (Gate 4: the allowed custom agents, the admitted cloud models, the
//     targets that are runnable right now) instead of upstream's stored pool.
//   - Orchestrator only, matching `osaurus_help` and `osaurus_config`.
//

import Foundation
import OsaurusRepository

// MARK: - Read-envelope hints

/// Appended to every read-tool success envelope. Small models read-loop on
/// `osaurus_inspect` and never reach `osaurus_config` (whose own responses
/// carry next-step hints), so the bridge to the write tool lives on the READ
/// results they are actually looking at. Scoped reads additionally embed the
/// declarative YAML shape for the section that writes that scope
/// (`yaml_shape`, rendered from `ConfigManifest` so it cannot drift).
enum ConfigurationReadNextStep {
    /// THE write contract, stated once.
    static let writeContract =
        "To CHANGE configuration, compose a minimal YAML with only the keys to change and "
        + "call osaurus_config {action: 'apply', yaml: ...}. Apply is the only action that "
        + "changes anything. Never end your turn asking whether to apply — CALL apply; the "
        + "native one-tap approval card is the user's confirmation. "
        + "To DELETE entries, apply the section listing only the entries to KEEP with the "
        + "tool argument prune: true — prune goes beside yaml, never inside the document. "
        + "To set or rotate a provider's API key, apply set_api_key: true (never the key "
        + "value); only when the user names where the secret lives, reference it with "
        + "api_key_ref / token_ref: env:VAR_NAME or keychain:SERVICE/ACCOUNT — never "
        + "invent a ref."

    static func hint(hasShape: Bool) -> String {
        let lead =
            hasShape
            ? "This result is read-only. Use `yaml_shape` below as the document shape — "
                + "no schema call needed. "
            : "This result is read-only. Get the document shape with osaurus_config "
                + "{action: 'schema', sections: [...]} if unsure. "
        return lead + writeContract
            + " If the user only asked a question, answer from this result in plain text."
    }

    /// Status is the one read with no single scope. Observed dead ends get
    /// explicit routes: settings sections are NOT inspect scopes (they are
    /// read via export), server/chat/app settings are Settings-UI-only, and
    /// "what is Osaurus / how does X work" questions belong to `osaurus_help`.
    static let statusHint =
        hint(hasShape: false)
        + " Settings sections (memory, default_agent, tools, delegation) "
        + "are document sections: read one with osaurus_inspect {action: 'describe', "
        + "scope: '<section>'} (or osaurus_config {action: 'export', sections: [...]}), "
        + "and change it with osaurus_config {action: 'apply', yaml: ...}. "
        + "Server runtime, chat behavior, and app settings are managed in the Settings UI, "
        + "not with these tools. "
        + "For questions about what Osaurus is or how a feature works, read the matching "
        + "osaurus_help topic instead of answering from this snapshot."

    static let shapeSemanticsHeader = """
        # Entities match by name; keys absent from the document stay unchanged.
        # ADDING an entry that is not yet listed is the normal way to create \
        or install it. DELETING is different: if asked to remove an entry \
        that is not in the current list, say so instead of applying.
        """

    static let secretScopeSemantics = """
        # Secrets never go in YAML, and reads/exports NEVER show whether a key \
        is stored — never conclude from a read that a key is missing or empty. \
        set_api_key: true opens the native key sheet during apply; api_key_ref \
        / token_ref accept env:VAR_NAME or keychain:SERVICE/ACCOUNT (the secret \
        is read during apply — you never see it). Never ask the user to paste \
        a key in chat.
        """

    /// Scopes whose entries carry credentials and therefore get the
    /// secret-handling semantics in their shape header.
    static let secretScopes: Set<String> = ["providers", "mcp", "mcp_providers"]

    /// One-line counters to observed false beliefs that survive even with
    /// the shape in view.
    static let scopeCapabilityLines: [String: String] = [
        "providers": """
            # EVERY id in the `provider` list above is a directly supported \
            provider (openrouter included) — connect one by applying a providers \
            entry with that id. Never claim a listed provider is unsupported.
            """,
        "plugins": """
            # The list above shows INSTALLED plugins only — it is NOT the \
            registry. YOU install a registry plugin from right here: apply with \
            `plugins:` listing the installed ids PLUS the new id. The registry is \
            checked at apply (an unknown id fails with a clear error), so apply \
            directly instead of trying to pre-verify. Never redirect the user to \
            the UI or another assistant for this.
            """,
    ]

    /// The agents-scope capability line: built per call because it names the
    /// user's own orchestrator-visible templates; with none there is nothing
    /// to say. Counters `writeContract`, which would otherwise steer the model
    /// into hand-writing an agent when a template covers the request.
    static func agentTemplateCapabilityLine(templateNames: [String]) -> String? {
        guard !templateNames.isEmpty else { return nil }
        let names = templateNames.joined(separator: ", ")
        return """
            # AGENT TEMPLATES are available to you: \(names). To CREATE an agent, \
            PREFER a template over hand-writing one: osaurus_config {action: 'plan', \
            template: '<name>', overrides: {name: ..., system_prompt: ...}}, then apply. \
            A template fixes the model, tools, MCP servers, sandbox and subagents, so \
            the new agent gets exactly that set instead of inheriting everything. Call \
            osaurus_config {action: 'templates'} to read what each one is for. \
            Hand-write an agent only when no template fits, and say which you ruled \
            out. An agent the user describes as "local", "cloud", or "small"/"sub" \
            almost always names a TEMPLATE, NOT an existing agent that happens to be \
            called that.
            """
    }

    static func semanticsHeader(forScope scope: String, agentTemplateNames: [String] = []) -> String {
        var header = shapeSemanticsHeader
        if secretScopes.contains(scope) {
            header += "\n" + secretScopeSemantics
        }
        if let capability = scopeCapabilityLines[scope] {
            header += "\n" + capability
        }
        if scope == "agents", let templates = agentTemplateCapabilityLine(templateNames: agentTemplateNames) {
            header += "\n" + templates
        }
        return header
    }

    /// Declarative sections whose YAML shape a read scope embeds. Scopes
    /// without a declarative writer (skills, themes, models) keep the plain hint.
    static func shapeSections(forScope scope: String) -> Set<ConfigSectionID>? {
        switch scope {
        case "agents": return [.agents, .activeAgent]
        case "providers": return [.providers]
        case "mcp", "mcp_providers": return [.mcpServers]
        case "plugins": return [.plugins]
        case "schedules": return [.schedules]
        case "watchers": return [.watchers]
        case "knowledge": return [.knowledgeCollections]
        case "commands": return [.commands]
        case "search": return [.searchProviders]
        // Settings document sections read through `documentSectionRead`.
        case "memory": return [.memory]
        case "default_agent": return [.defaultAgent]
        case "tools": return [.tools]
        case "delegation": return [.delegation]
        default: return nil
        }
    }

    static func success(
        tool: String,
        result: [String: Any],
        scope: String? = nil,
        agentTemplateNames: [String] = []
    ) -> String {
        var result = result
        if let scope, let sections = shapeSections(forScope: scope) {
            result["yaml_shape"] =
                semanticsHeader(forScope: scope, agentTemplateNames: agentTemplateNames) + "\n"
                + ConfigManifest.renderedSchemaSections(only: sections)
            result["next_step"] = hint(hasShape: true)
        } else {
            result["next_step"] = hint(hasShape: false)
        }
        return ToolEnvelope.success(tool: tool, result: result)
    }

    /// Variant for `osaurus_inspect` status.
    static func statusSuccess(tool: String, result: [String: Any]) -> String {
        var result = result
        result["next_step"] = statusHint
        return ToolEnvelope.success(tool: tool, result: result)
    }
}

private enum PluginRepositoryDiagnosticProjection {
    static func dictionary(_ result: CentralRepositoryRefreshResult?) -> [String: Any]? {
        guard let result else { return nil }
        var dict: [String: Any] = [
            "succeeded": result.succeeded,
            "repository_url": result.repositoryURL,
            "attempted_archive_urls": result.attemptedArchiveURLs,
            "cache_available": result.cacheAvailable,
        ]
        if let refreshedAt = result.refreshedAt {
            dict["refreshed_at"] = ISO8601DateFormatter().string(from: refreshedAt)
        }
        if let cacheUpdatedAt = result.cacheUpdatedAt {
            dict["cache_updated_at"] = ISO8601DateFormatter().string(from: cacheUpdatedAt)
        }
        if let failure = result.failure {
            var failureDict: [String: Any] = [
                "kind": failure.kind.rawValue,
                "message": failure.message,
                "user_message": failure.userMessage,
                "retryable": failure.retryable,
            ]
            if let failedURL = failure.failedArchiveURL {
                failureDict["failed_archive_url"] = failedURL
            }
            if let httpStatusCode = failure.httpStatusCode {
                failureDict["http_status_code"] = httpStatusCode
            }
            dict["failure"] = failureDict
        }
        return dict
    }
}

// MARK: - Agent payloads

/// Agent-facing capability payload for describe reads, using the keys of the
/// `osaurus_config` document (`agents[].capabilities`).
enum AgentCapabilitiesPayload {
    static func payload(for agent: Agent) -> [String: Any] {
        [
            "tools_enabled": agent.toolsEnabled,
            "memory_enabled": agent.memoryEnabled,
            "search_memory_enabled": agent.settings.searchMemoryEnabled,
            "web_search_enabled": agent.settings.webSearchEnabled,
            "db_enabled": agent.settings.dbEnabled,
            "self_scheduling_enabled": agent.settings.selfSchedulingEnabled,
            "computer_use_enabled": agent.settings.computerUseEnabled,
            "browser_use_enabled": agent.settings.browserUseEnabled,
            "image_enabled": agent.settings.imageEnabled,
            "applescript_enabled": agent.settings.appleScriptEnabled,
            "apple_apps": AppleApp.sorted(agent.settings.enabledAppleApps).map(\.rawValue),
            "speak_enabled": agent.settings.speakEnabled,
            "render_chart_enabled": agent.settings.renderChartEnabled,
            "calculator_enabled": agent.settings.calculatorEnabled,
            "task_checklist_enabled": agent.settings.taskChecklistEnabled,
            "clarify_enabled": agent.settings.clarifyEnabled,
            "artifacts_enabled": agent.settings.artifactsEnabled,
            "theme_id": agent.themeId?.uuidString ?? "",
        ]
    }
}

/// An MCP server URL reduced to what is safe to show: scheme, host, port and
/// path. Userinfo and query strings can carry tokens, so they never appear.
enum InspectURLRedaction {
    static func redacted(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return "" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? ""
    }
}

// MARK: - osaurus_inspect

/// Single read surface for Osaurus configuration. One name, one scope enum,
/// three depths: `status` (aggregate snapshot with suggestions), `list` (rows
/// in a scope), `describe` (one item in full).
public final class OsaurusInspectTool: OsaurusTool, @unchecked Sendable {
    public static let toolName = "osaurus_inspect"
    public let name = OsaurusInspectTool.toolName
    public let description =
        "Read Osaurus configuration. `action`: status (one-shot snapshot of everything — default "
        + "agent, models, providers, plugins, schedules, watchers, skills, knowledge, memory, the "
        + "Orchestrator's delegation pool — plus `suggestions`; call it first when the user asks "
        + "what's configured), list (rows in one `scope`), describe (full detail for one item; "
        + "needs `scope` + `id`; providers/mcp include runtime connected/last_error; skills, "
        + "knowledge, commands, themes also match by name). "
        + "`scope` ∈ {agents, models, providers, mcp, plugins, schedules, skills, watchers, "
        + "knowledge, themes, commands, search}. "
        + "Optional `filter` (list only): providers/mcp: enabled|disabled|connected|all; "
        + "plugins: installed|available|failed; schedules/watchers/knowledge: enabled|disabled; "
        + "skills/commands: builtin|custom|plugin. Never shows secrets."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([.string("status"), .string("list"), .string("describe")]),
                "description": .string("Read depth: whole-app snapshot, scope rows, or one item."),
            ]),
            // The enum is load-bearing for small models: prompt compaction
            // strips description prose but KEEPS enums, so this list is the
            // only scope roster a compact-schema model ever sees. It also
            // includes the settings DOCUMENT SECTIONS and the removed
            // `server`/`chat`/`app` names: those execute as a teaching
            // failure (see `unknownScopeFailure`) instead of a generic
            // schema rejection the model would loop on.
            "scope": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("agents"), .string("models"), .string("providers"),
                    .string("mcp"), .string("plugins"), .string("schedules"),
                    .string("skills"), .string("watchers"), .string("knowledge"),
                    .string("themes"), .string("commands"), .string("search"),
                    .string("mcp_servers"), .string("knowledge_collections"),
                    .string("search_providers"),
                    .string("server"), .string("chat"), .string("app"),
                    .string("memory"), .string("default_agent"),
                    .string("new_chat_agent"), .string("active_agent"), .string("tools"),
                    .string("delegation"),
                ]),
                "description": .string(
                    "Configuration scope. Required for list and describe. memory, "
                        + "default_agent, new_chat_agent (alias active_agent), tools, and delegation "
                        + "are settings document sections — list/describe returns the section's "
                        + "current values (change them with osaurus_config apply). server, chat, "
                        + "and app are Settings-UI-only."),
            ]),
            "id": .object([
                "type": .string("string"),
                "description": .string(
                    "Item id, or its exact name (case-insensitive). Required for describe."),
            ]),
            "filter": .object([
                "type": .string("string"),
                "description": .string("Scope-specific list filter. See description."),
            ]),
        ]),
        "required": .array([.string("action")]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        guard ChatExecutionContext.currentAgentId == Agent.defaultId else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "The Osaurus inspect tool is available only to the built-in Orchestrator.",
                tool: name
            )
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let actionReq = requireAction(args, allowed: ["status", "list", "describe"])
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }

        switch action {
        case "status":
            return await statusEnvelope()
        case "list":
            return await listEnvelope(args)
        case "describe":
            return await describeEnvelope(args)
        default:
            return actionReq.failureEnvelope ?? ""
        }
    }

    // MARK: action: status

    private func statusEnvelope() async -> String {
        // Skills and knowledge collections load from disk off the main actor.
        let skillCount = await SkillStore.loadAll().count
        let knowledgeCollections = await KnowledgeCollectionStore.loadAllAsync()
        let knowledgeEnabledCount = knowledgeCollections.filter { $0.isEnabled }.count
        let knowledgeTotalCount = knowledgeCollections.count

        // `PluginRepositoryService.plugins` is only filled once a view
        // refreshed it (#2039); load the installed ones from disk first.
        await PluginRepositoryService.shared.ensureInstalledPluginsLoaded()

        // The Orchestrator's delegation pool is judged against the models the
        // picker currently offers, exactly as `orchestrator_targets` is.
        await ModelPickerItemCache.shared.prewarmModelCache()

        return await MainActor.run {
            let manager = AgentManager.shared
            let activeAgentId = manager.activeAgentId
            let activeAgent = manager.agent(for: activeAgentId)
            let newChatAgentId = manager.newChatAgentId
            let newChatAgent = manager.agent(for: newChatAgentId)
            let defaultConfig = DefaultAgentConfigurationStore.load()

            let providers = RemoteProviderManager.shared.configuration.providers
            let providerConnected = providers.filter {
                RemoteProviderManager.shared.providerStates[$0.id]?.isConnected == true
            }.count
            let mcpProviders = MCPProviderManager.shared.configuration.providers
            let mcpConnected = MCPProviderManager.shared.providerStates.values
                .filter { $0.isConnected }.count

            let plugins = PluginRepositoryService.shared.plugins
            let installedPlugins = plugins.filter { $0.installedVersion != nil }
            let failedPlugins = installedPlugins.filter { $0.loadError != nil }
            let pluginRepositoryDiagnostic = PluginRepositoryDiagnosticProjection.dictionary(
                PluginRepositoryService.shared.lastRefreshResult
            )

            let schedules = ScheduleManager.shared.schedules
            let watchers = WatcherManager.shared.watchers
            let memoryConfig = MemoryConfigurationStore.load()
            let catalog = ConfigModelReference.liveCatalog()
            let providerModelCount = catalog.providers.reduce(0) { $0 + $1.models.count }

            var suggestions: [String] = []
            if providers.isEmpty {
                suggestions.append(
                    "No cloud providers connected — this Mac has no local models, so chats need one. "
                        + "Add one with osaurus_config (providers section) or Settings → Providers."
                )
            }
            if !failedPlugins.isEmpty {
                let names = failedPlugins.prefix(3).map { $0.displayName }.joined(separator: ", ")
                suggestions.append("Plugins failed to load: \(names). Check their manifest / consent state.")
            }

            // The Orchestrator's spawn pool, as Intel defines it (Gate 4): the
            // custom agents the user allowed, the cloud models they admitted,
            // and the targets runnable right now. An empty pool is the one
            // state in which `spawn_agent` is not offered at all, so the
            // status read must say so instead of letting it pass as "no
            // agents", and name the repair.
            let delegation = defaultConfig.delegation
            let customAgents = manager.agents.filter { !$0.isBuiltIn }
            let poolMembers = delegation.customAgentAllowlist.filter { id in
                customAgents.contains { $0.id == id }
            }
            let poolState: String
            if !poolMembers.isEmpty {
                poolState = "ready"
            } else if customAgents.isEmpty {
                poolState = "no_agents"
            } else {
                poolState = "empty"
            }
            let available = Set(
                ModelPickerItemCache.shared.items.compactMap { item -> String? in
                    guard case .remote = item.source, item.isLikelyChatCapable,
                        !item.id.hasPrefix("claude-code/")
                    else { return nil }
                    return item.id
                })
            let evaluation = IntelOrchestratorAdmission.evaluate(
                configuration: delegation,
                agents: manager.agents,
                effectiveModel: { manager.effectiveModel(for: $0) },
                availableModelIDs: available)
            if poolState == "empty" {
                suggestions.append(
                    "Spawn pool is EMPTY although \(customAgents.count) custom agent(s) exist — the "
                        + "Orchestrator has no spawn_agent tool. Restore delegation with "
                        + "osaurus_config apply `delegation: {spawnable_agents: [<names to allow>]}` "
                        + "(the list replaces the pool) or Settings → Orchestrator → Add all agents.")
            } else if poolState == "ready" && delegation.admittedCloudModelIDs.isEmpty {
                suggestions.append(
                    "Agents are allowed but no cloud model is admitted, so nothing can be delegated. "
                        + "Only the user can admit a model, in Settings → Orchestrator.")
            }

            let budgets = SubagentConfigurationStore.snapshot().budgets.normalized
            let snapshot: [String: Any] = [
                "spawn_pool": [
                    "state": poolState,
                    "local_agents": poolMembers.count,
                    "custom_agents_total": customAgents.count,
                    "admitted_cloud_models": delegation.admittedCloudModelIDs.count,
                    "runnable_targets": evaluation.targets.count,
                    "max_parallel_remote": budgets.maxRemoteParallelSpawns,
                ],
                "active_agent": [
                    "id": activeAgentId.uuidString,
                    "name": activeAgent?.displayName ?? "Default",
                    "is_built_in": activeAgent?.isBuiltIn ?? true,
                ],
                // The `new_chat_agent` section value: which agent NEW chats
                // open with (the Orchestrator unless applied otherwise).
                "new_chat_agent": [
                    "id": newChatAgentId.uuidString,
                    "name": newChatAgent?.displayName ?? "Default",
                    "is_built_in": newChatAgent?.isBuiltIn ?? true,
                ],
                "default_agent": [
                    "model": defaultConfig.defaultModel ?? "",
                    "system_prompt_set": !(defaultConfig.systemPrompt ?? "").isEmpty,
                ],
                "models": [
                    "cloud_models_discovered": providerModelCount
                ],
                "providers": [
                    "configured": providers.count,
                    "connected": providerConnected,
                ],
                "mcp": [
                    "configured": mcpProviders.count,
                    "connected": mcpConnected,
                ],
                "plugins": [
                    "installed": installedPlugins.count,
                    "failed": failedPlugins.count,
                    "repository": pluginRepositoryDiagnostic ?? [:],
                ],
                "schedules": [
                    "total": schedules.count,
                    "enabled": schedules.filter { $0.isEnabled }.count,
                ],
                "watchers": [
                    "total": watchers.count,
                    "enabled": watchers.filter { $0.isEnabled }.count,
                ],
                "skills": [
                    "installed": skillCount
                ],
                "knowledge": [
                    "collections": knowledgeTotalCount,
                    "enabled": knowledgeEnabledCount,
                ],
                "memory": [
                    "enabled": memoryConfig.enabled
                ],
                "suggestions": suggestions,
            ]
            return ConfigurationReadNextStep.statusSuccess(tool: name, result: snapshot)
        }
    }

    // MARK: action: list

    /// Shared `enabled | disabled | connected` filter for item rows that
    /// carry `enabled` / `connected` booleans. Unknown filters pass everything.
    private static func filterByEnabledConnected(
        _ items: [[String: Any]],
        filter: String
    ) -> [[String: Any]] {
        switch filter {
        case "enabled": return items.filter { ($0["enabled"] as? Bool) == true }
        case "disabled": return items.filter { ($0["enabled"] as? Bool) == false }
        case "connected": return items.filter { ($0["connected"] as? Bool) == true }
        default: return items
        }
    }

    /// Shared `builtin | custom | plugin` origin filter for rows that carry
    /// `built_in` / `from_plugin` booleans (skills, slash commands).
    private static func filterByOrigin(
        _ items: [[String: Any]],
        filter: String
    ) -> [[String: Any]] {
        switch filter {
        case "builtin", "built_in":
            return items.filter { ($0["built_in"] as? Bool) == true }
        case "custom":
            return items.filter {
                ($0["built_in"] as? Bool) == false && ($0["from_plugin"] as? Bool) != true
            }
        case "plugin":
            return items.filter { ($0["from_plugin"] as? Bool) == true }
        default: return items
        }
    }

    private func listEnvelope(_ args: [String: Any]) async -> String {
        // Observed dead end: models put the scope name into `filter` and omit
        // `scope`. The intent is unambiguous, so execute the intended list
        // instead of rejecting; a note names the canonical shape.
        var args = args
        var filterAsScopeNote: String?
        if args["scope"] == nil,
            let misplaced = (args["filter"] as? String)?.lowercased(),
            Self.knownReadScopes.contains(Self.canonicalScope(misplaced))
        {
            args["scope"] = misplaced
            args.removeValue(forKey: "filter")
            filterAsScopeNote =
                "`\(misplaced)` is a scope, not a filter — it was treated as "
                + "{action: 'list', scope: '\(misplaced)'}. Pass `scope` directly next time."
        }
        let envelope = await resolvedListEnvelope(args)
        if let note = filterAsScopeNote {
            return Self.addingNote(note, toSuccessEnvelope: envelope)
        }
        return envelope
    }

    /// Inject a top-level `note` into a success envelope (no-op for error
    /// envelopes or unparseable strings, which pass through untouched).
    static func addingNote(_ note: String, toSuccessEnvelope envelope: String) -> String {
        guard let data = envelope.data(using: .utf8),
            var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["ok"] as? Bool == true
        else { return envelope }
        object["note"] = note
        guard
            let out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let string = String(data: out, encoding: .utf8)
        else { return envelope }
        return string
    }

    private func resolvedListEnvelope(_ args: [String: Any]) async -> String {
        let scopeReq = requireString(args, "scope", expected: "scope name", tool: name)
        guard case .value(let rawScope) = scopeReq else { return scopeReq.failureEnvelope ?? "" }
        let filter = (args["filter"] as? String)?.lowercased() ?? ""
        let scope = Self.canonicalScope(rawScope)

        // Skills and knowledge collections load from disk off the main actor.
        switch scope {
        case "skills":
            let skills = await SkillStore.loadAll()
            let items = skills.map { skill -> [String: Any] in
                [
                    "id": skill.id.uuidString,
                    "name": skill.name,
                    "description": skill.description,
                    "category": skill.category ?? "",
                    "built_in": skill.isBuiltIn,
                    "from_plugin": skill.isFromPlugin,
                ]
            }
            return ConfigurationReadNextStep.success(
                tool: name,
                result: [
                    "scope": "skills", "filter": filter,
                    "items": Self.filterByOrigin(items, filter: filter),
                ],
                scope: "skills"
            )
        case "knowledge":
            let collections = await KnowledgeCollectionStore.loadAllAsync()
            let items = collections.map { c -> [String: Any] in
                [
                    "id": c.id.uuidString,
                    "name": c.name,
                    "summary": c.summary,
                    "folder_path": c.folderPath,
                    "enabled": c.isEnabled,
                    "git_synced": c.gitRemoteURL != nil,
                ]
            }
            return ConfigurationReadNextStep.success(
                tool: name,
                result: [
                    "scope": "knowledge", "filter": filter,
                    "items": Self.filterByEnabledConnected(items, filter: filter),
                ],
                scope: "knowledge"
            )
        default:
            break
        }

        // See `statusEnvelope`: load the installed plugins from disk (#2039).
        if scope == "plugins" {
            await PluginRepositoryService.shared.ensureInstalledPluginsLoaded()
        }

        // A document-section name (`memory`, `default_agent`, …) is read
        // here, before the entity switch, so the enum's promise holds.
        if !Self.knownReadScopes.contains(scope),
            let read = await Self.documentSectionRead(scope: scope, tool: name)
        {
            return read
        }

        return await MainActor.run {
            let payload: [String: Any]
            switch scope {
            case "agents":
                // Capability flags ride along on the list rows so the model
                // can pick the right agent without a `describe` round-trip
                // per agent. `orchestrator_allowed` is Gate 4's allowlist.
                let allowed = DefaultAgentConfigurationStore.load().delegation.customAgentAllowlist
                let agents = AgentManager.shared.agents.map { agent -> [String: Any] in
                    [
                        "id": agent.id.uuidString,
                        "name": agent.name,
                        "description": agent.description,
                        "generated_description": agent.generatedDescription ?? "",
                        "is_built_in": agent.isBuiltIn,
                        "orchestrator_allowed": allowed.contains(agent.id),
                        "tools_enabled": agent.toolsEnabled,
                        "computer_use_enabled": agent.settings.computerUseEnabled,
                        "browser_use_enabled": agent.settings.browserUseEnabled,
                        "image_enabled": agent.settings.imageEnabled,
                        "apple_apps": AppleApp.sorted(agent.settings.enabledAppleApps).map(\.rawValue),
                    ]
                }
                payload = ["scope": "agents", "items": agents]
            case "models":
                // Intel has no local models; the usable ids are the connected
                // cloud providers' (prefix/model, as config documents spell them).
                let items = ConfigModelReference.liveCatalog().providers.flatMap { provider in
                    provider.models.map { model -> [String: Any] in
                        ["id": "\(provider.prefix)/\(model)", "name": model, "provider": provider.name]
                    }
                }
                payload = [
                    "scope": "models", "filter": filter,
                    "items": items,
                    "note": "Cloud model ids of the configured providers; this Mac runs no local models.",
                ]
            case "providers":
                let providers = RemoteProviderManager.shared.configuration.providers
                let items = providers.map { p -> [String: Any] in
                    let state = RemoteProviderManager.shared.providerStates[p.id]
                    return [
                        "id": p.id.uuidString,
                        "name": p.name,
                        "provider_type": p.providerType.rawValue,
                        "enabled": p.enabled,
                        "connected": state?.isConnected ?? false,
                    ]
                }
                payload = [
                    "scope": "providers", "filter": filter,
                    "items": Self.filterByEnabledConnected(items, filter: filter),
                ]
            case "mcp", "mcp_providers":
                let providers = MCPProviderManager.shared.configuration.providers
                let items = providers.map { p -> [String: Any] in
                    let state = MCPProviderManager.shared.providerStates[p.id]
                    return [
                        "id": p.id.uuidString,
                        "name": p.name,
                        "url": InspectURLRedaction.redacted(p.url),
                        "auth": p.authType.rawValue,
                        "enabled": p.enabled,
                        "connected": state?.isConnected ?? false,
                    ]
                }
                payload = [
                    "scope": "mcp", "filter": filter,
                    "items": Self.filterByEnabledConnected(items, filter: filter),
                ]
            case "plugins":
                let plugins = PluginRepositoryService.shared.plugins
                let items = plugins.map { state -> [String: Any] in
                    [
                        "plugin_id": state.pluginId,
                        "name": state.displayName,
                        "installed": state.installedVersion != nil,
                        "has_load_error": state.loadError != nil,
                    ]
                }
                let filtered: [[String: Any]]
                switch filter {
                case "installed":
                    filtered = items.filter { ($0["installed"] as? Bool) == true }
                case "available":
                    filtered = items.filter { ($0["installed"] as? Bool) == false }
                case "failed":
                    filtered = items.filter { ($0["has_load_error"] as? Bool) == true }
                default:
                    filtered = items
                }
                payload = [
                    "scope": "plugins",
                    "filter": filter,
                    "repository": PluginRepositoryDiagnosticProjection.dictionary(
                        PluginRepositoryService.shared.lastRefreshResult
                    ) ?? [:],
                    "items": filtered,
                ]
            case "schedules":
                let schedules = ScheduleManager.shared.schedules.map { s -> [String: Any] in
                    [
                        "id": s.id.uuidString,
                        "name": s.name,
                        "enabled": s.isEnabled,
                        "frequency": s.frequency.displayDescription,
                    ]
                }
                payload = [
                    "scope": "schedules", "filter": filter,
                    "items": Self.filterByEnabledConnected(schedules, filter: filter),
                ]
            case "watchers":
                let watchers = WatcherManager.shared.watchers.map { w -> [String: Any] in
                    [
                        "id": w.id.uuidString,
                        "name": w.name,
                        "enabled": w.isEnabled,
                        "watch_path": w.watchPath ?? "",
                        "agent_id": w.agentId?.uuidString ?? "",
                        "recursive": w.recursive,
                    ]
                }
                payload = [
                    "scope": "watchers", "filter": filter,
                    "items": Self.filterByEnabledConnected(watchers, filter: filter),
                ]
            case "themes":
                let activeId = ThemeConfigurationStore.loadActiveThemeId()
                let themes = ThemeConfigurationStore.listThemes().map { theme -> [String: Any] in
                    [
                        "id": theme.metadata.id.uuidString,
                        "name": theme.metadata.name,
                        "author": theme.metadata.author,
                        "built_in": theme.isBuiltIn,
                        "active": theme.metadata.id == activeId,
                    ]
                }
                payload = ["scope": "themes", "filter": filter, "items": themes]
            case "commands":
                // Built-ins live in code, custom commands on disk — the
                // popup shows both, so the read scope must too.
                let commands = (SlashCommand.builtIns + SlashCommandStore.loadAll())
                    .map { cmd -> [String: Any] in
                        [
                            "id": cmd.id.uuidString,
                            "name": cmd.name,
                            "description": cmd.description,
                            "kind": cmd.kind.rawValue,
                            "built_in": cmd.isBuiltIn,
                            "from_plugin": cmd.pluginId != nil,
                        ]
                    }
                payload = [
                    "scope": "commands", "filter": filter,
                    "items": Self.filterByOrigin(commands, filter: filter),
                ]
            case "search":
                let manager = SearchProviderManager.shared
                let configured = manager.configuredProviderIds
                let providers = manager.rankedProviders.enumerated().map { index, entry -> [String: Any] in
                    let (provider, def) = entry
                    var row: [String: Any] = [
                        "id": def.id,
                        "name": def.name,
                        "rank": index + 1,
                        "enabled": provider.enabled,
                        "free": def.isKeyless,
                    ]
                    if !def.isKeyless {
                        row["configured"] = configured.contains(def.id)
                    }
                    return row
                }
                payload = [
                    "scope": "search", "filter": filter,
                    "items": Self.filterByEnabledConnected(providers, filter: filter),
                    "note": "Rank 1 is tried first; lower ranks are fallbacks. Use osaurus_config to modify.",
                ]
            default:
                return Self.unknownScopeFailure(scope: scope, tool: name)
            }
            return ConfigurationReadNextStep.success(
                tool: name, result: payload, scope: scope,
                agentTemplateNames: Self.visibleAgentTemplateNames(forScope: scope)
            )
        }
    }

    /// A settings DOCUMENT SECTION named as an inspect scope (`memory`,
    /// `default_agent`, `tools`, …) is answered with that section's current
    /// values — the same read `osaurus_config {action: 'export', sections:
    /// [x]}` performs — instead of a rejection. The scope enum advertises
    /// these names, so refusing them would be a self-contradicting contract.
    /// Returns nil for anything that is not a document section.
    static func documentSectionRead(scope: String, tool: String) async -> String? {
        guard let section = ConfigSectionID.parse(scope),
            !settingsUIOnlyScopes.contains(scope.lowercased())
        else { return nil }
        let document = await MainActor.run { ConfigExporter.export(sections: [section]) }
        let yaml: String
        do {
            yaml = try ConfigYAML.encode(document)
        } catch {
            return nil
        }
        return ConfigurationReadNextStep.success(
            tool: tool,
            result: [
                "scope": section.rawValue,
                "kind": "document_section",
                "format": "yaml",
                "yaml": yaml,
                "note":
                    "`\(section.rawValue)` is a configuration document section (read-only here). "
                    + "Change it with osaurus_config {action: 'apply', yaml: ...}.",
            ],
            scope: section.rawValue)
    }

    // MARK: action: describe

    private func describeEnvelope(_ args: [String: Any]) async -> String {
        let scopeReq = requireString(args, "scope", expected: "scope name", tool: name)
        guard case .value(let rawScope) = scopeReq else { return scopeReq.failureEnvelope ?? "" }
        let scope = Self.canonicalScope(rawScope)
        guard Self.knownReadScopes.contains(scope) else {
            // A document-section name reads the section; anything else keeps
            // the teaching failure so the model is not dead-ended.
            if let read = await Self.documentSectionRead(scope: scope, tool: name) { return read }
            return Self.unknownScopeFailure(scope: scope, tool: name)
        }
        // Observed dead end: describe without `id` fails generically and the
        // model gives up on the scope. Route the browse intent to list.
        if args["id"] == nil {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`describe` needs `id` (an entry's name or id). To browse the "
                    + "entries first, call {action: 'list', scope: '\(scope)'}.",
                tool: name)
        }
        let idReq = requireString(args, "id", expected: "identifier", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        return await describeItem(scope: scope, idStr: idStr)
    }
}

// MARK: - describe implementation

extension OsaurusInspectTool {

    fileprivate func describeItem(scope: String, idStr: String) async -> String {
        // Skills and knowledge collections load from disk off the main actor.
        switch scope {
        case "skills":
            let skills = await SkillStore.loadAll()
            let uuid = UUID(uuidString: idStr)
            guard
                let skill = skills.first(where: {
                    $0.id == uuid || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                })
            else {
                return Self.notFoundFailure(scope: scope, id: idStr, tool: name)
            }
            var result: [String: Any] = [
                "scope": "skills",
                "id": skill.id.uuidString,
                "name": skill.name,
                "description": skill.description,
                "version": skill.version,
                "category": skill.category ?? "",
                "keywords": skill.keywords,
                "built_in": skill.isBuiltIn,
                "from_plugin": skill.isFromPlugin,
                "reference_file_count": skill.references.count,
                "asset_file_count": skill.assets.count,
            ]
            if let pluginId = skill.pluginId { result["plugin_id"] = pluginId }
            return ConfigurationReadNextStep.success(tool: name, result: result, scope: "skills")
        case "knowledge":
            let collections = await KnowledgeCollectionStore.loadAllAsync()
            let uuid = UUID(uuidString: idStr)
            guard
                let collection = collections.first(where: {
                    $0.id == uuid || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                })
            else {
                return Self.notFoundFailure(scope: scope, id: idStr, tool: name)
            }
            return ConfigurationReadNextStep.success(
                tool: name,
                result: [
                    "scope": "knowledge",
                    "id": collection.id.uuidString,
                    "name": collection.name,
                    "summary": collection.summary,
                    "folder_path": collection.folderPath,
                    "enabled": collection.isEnabled,
                    "git_remote_url": InspectURLRedaction.redacted(collection.gitRemoteURL ?? ""),
                ],
                scope: "knowledge"
            )
        default:
            break
        }

        if scope == "plugins" {
            await PluginRepositoryService.shared.ensureInstalledPluginsLoaded()
        }

        return await MainActor.run {
            let payload: [String: Any]?
            switch scope {
            case "agents":
                let uuid = UUID(uuidString: idStr)
                if let agent = AgentManager.shared.agents.first(where: {
                    $0.id == uuid || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                }) {
                    // Key is `model` (not `default_model`) on purpose: it
                    // matches the osaurus_config document schema, so a model
                    // that reads this payload reuses the right key when it
                    // writes the change document.
                    var dict: [String: Any] = [
                        "id": agent.id.uuidString,
                        "name": agent.name,
                        "description": agent.description,
                        "generated_description": agent.generatedDescription ?? "",
                        "system_prompt": agent.systemPrompt,
                        "model": agent.defaultModel ?? "",
                        "temperature": agent.temperature ?? 0,
                        "max_tokens": agent.maxTokens ?? 0,
                        "is_built_in": agent.isBuiltIn,
                        "capabilities": AgentCapabilitiesPayload.payload(for: agent),
                    ]
                    if !agent.isBuiltIn {
                        // Delegation, both directions: whether the
                        // Orchestrator may delegate to this agent (Gate 4),
                        // and this agent's own `subagents` keys.
                        let allowed = DefaultAgentConfigurationStore.load().delegation
                            .customAgentAllowlist.contains(agent.id)
                        dict["orchestrator_allowed"] = allowed
                        dict["subagents"] = [
                            "enabled": agent.settings.spawnDelegationEnabled,
                            "agents": agent.settings.spawnableAgentIDs.compactMap { id in
                                AgentManager.shared.agent(for: id)?.name
                            },
                        ]
                        dict["needs_setup"] = SetupStateStore.shared.needsSetup(agent.id)
                    }
                    payload = dict
                } else {
                    payload = nil
                }
            case "models":
                let needle = idStr.lowercased()
                let match = ConfigModelReference.liveCatalog().providers.lazy.flatMap { provider in
                    provider.models.map { (provider, $0) }
                }.first { provider, model in
                    "\(provider.prefix)/\(model)".lowercased() == needle || model.lowercased() == needle
                }
                if let (provider, model) = match {
                    payload = [
                        "id": "\(provider.prefix)/\(model)",
                        "name": model,
                        "provider": provider.name,
                        "installed": false,
                    ]
                } else {
                    payload = nil
                }
            case "providers":
                let providerUUID = UUID(uuidString: idStr)
                if let p = RemoteProviderManager.shared.configuration.providers.first(where: {
                    $0.id == providerUUID || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                }) {
                    let state = RemoteProviderManager.shared.providerStates[p.id]
                    payload = [
                        "id": p.id.uuidString,
                        "name": p.name,
                        "provider_type": p.providerType.rawValue,
                        "host": p.host,
                        "enabled": p.enabled,
                        "auto_connect": p.autoConnect,
                        "connected": state?.isConnected ?? false,
                        "last_error": state?.lastError ?? "",
                        // Bare ids as the provider advertises them. Prepend
                        // `model_prefix` + "/" to reference one in config
                        // documents / agent model settings.
                        "model_prefix": RemoteProviderManager.pickerPrefix(for: p.name),
                        "discovered_models": state?.discoveredModels ?? [],
                    ]
                } else {
                    payload = nil
                }
            case "mcp", "mcp_providers":
                let mcpUUID = UUID(uuidString: idStr)
                if let p = MCPProviderManager.shared.configuration.providers.first(where: {
                    $0.id == mcpUUID || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                }) {
                    let state = MCPProviderManager.shared.providerStates[p.id]
                    payload = [
                        "id": p.id.uuidString,
                        "name": p.name,
                        "url": InspectURLRedaction.redacted(p.url),
                        "auth": p.authType.rawValue,
                        "transport": p.transport.rawValue,
                        "enabled": p.enabled,
                        "auto_connect": p.autoConnect,
                        "connected": state?.isConnected ?? false,
                        "requires_auth": state?.requiresAuth ?? false,
                        "last_error": state?.lastError ?? "",
                        "discovered_tools": state?.discoveredToolNames ?? [],
                    ]
                } else {
                    payload = nil
                }
            case "plugins":
                if let plugin = PluginRepositoryService.shared.plugins
                    .first(where: { $0.pluginId == idStr })
                {
                    payload = [
                        "plugin_id": plugin.pluginId,
                        "name": plugin.displayName,
                        "installed": plugin.installedVersion != nil,
                        "installed_version": plugin.installedVersion?.description ?? "",
                        "latest_version": plugin.latestVersion?.description ?? "",
                        "load_error": plugin.loadError ?? "",
                    ]
                } else {
                    payload = nil
                }
            case "schedules":
                let scheduleUUID = UUID(uuidString: idStr)
                if let s = ScheduleManager.shared.schedules.first(where: {
                    $0.id == scheduleUUID || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                }) {
                    payload = [
                        "id": s.id.uuidString,
                        "name": s.name,
                        "instructions": s.instructions,
                        "agent_id": s.agentId?.uuidString ?? "",
                        "enabled": s.isEnabled,
                        "frequency": s.frequency.displayDescription,
                    ]
                } else {
                    payload = nil
                }
            case "watchers":
                let watcherUUID = UUID(uuidString: idStr)
                if let w = WatcherManager.shared.watchers.first(where: {
                    $0.id == watcherUUID || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                }) {
                    var dict: [String: Any] = [
                        "id": w.id.uuidString,
                        "name": w.name,
                        "instructions": w.instructions,
                        "watch_path": w.watchPath ?? "",
                        "agent_id": w.agentId?.uuidString ?? "",
                        "enabled": w.isEnabled,
                        "recursive": w.recursive,
                        "responsiveness": w.responsiveness.rawValue,
                    ]
                    if let last = w.lastTriggeredAt {
                        dict["last_triggered_at"] = ISO8601DateFormatter().string(from: last)
                    }
                    payload = dict
                } else {
                    payload = nil
                }
            case "themes":
                let uuid = UUID(uuidString: idStr)
                if let theme = ThemeConfigurationStore.listThemes().first(where: {
                    $0.metadata.id == uuid
                        || $0.metadata.name.caseInsensitiveCompare(idStr) == .orderedSame
                }) {
                    payload = [
                        "id": theme.metadata.id.uuidString,
                        "name": theme.metadata.name,
                        "author": theme.metadata.author,
                        "version": theme.metadata.version,
                        "built_in": theme.isBuiltIn,
                        "dark": theme.isDark,
                        "active": theme.metadata.id == ThemeConfigurationStore.loadActiveThemeId(),
                    ]
                } else {
                    payload = nil
                }
            case "commands":
                let uuid = UUID(uuidString: idStr)
                let allCommands = SlashCommand.builtIns + SlashCommandStore.loadAll()
                if let cmd = allCommands.first(where: {
                    $0.id == uuid || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                }) {
                    var dict: [String: Any] = [
                        "id": cmd.id.uuidString,
                        "name": cmd.name,
                        "description": cmd.description,
                        "kind": cmd.kind.rawValue,
                        "built_in": cmd.isBuiltIn,
                        "from_plugin": cmd.pluginId != nil,
                    ]
                    if let template = cmd.template { dict["template"] = template }
                    payload = dict
                } else {
                    payload = nil
                }
            case "search":
                let manager = SearchProviderManager.shared
                if let entry = manager.rankedProviders.enumerated().first(where: {
                    $0.element.definition.id == idStr
                }) {
                    let (provider, def) = entry.element
                    var dict: [String: Any] = [
                        "id": def.id,
                        "name": def.name,
                        "rank": entry.offset + 1,
                        "enabled": provider.enabled,
                        "free": def.isKeyless,
                        "categories": def.supportedCategories,
                    ]
                    if !def.isKeyless {
                        dict["configured"] = manager.configuredProviderIds.contains(def.id)
                    }
                    payload = dict
                } else {
                    payload = nil
                }
            default:
                payload = nil
            }
            guard let payload else {
                return Self.notFoundFailure(scope: scope, id: idStr, tool: name)
            }
            var result = payload
            result["scope"] = scope
            return ConfigurationReadNextStep.success(
                tool: name, result: result, scope: scope,
                agentTemplateNames: Self.visibleAgentTemplateNames(forScope: scope)
            )
        }
    }

    /// Names of the agent templates the user flagged for the orchestrator,
    /// for the agents-scope read hint. Empty for every other scope, and for
    /// a user who has hidden them all.
    @MainActor
    static func visibleAgentTemplateNames(forScope scope: String) -> [String] {
        guard scope == "agents" else { return [] }
        return TemplateStore.shared.orchestratorVisible(kind: .agent).map(\.name)
    }

    private static func notFoundFailure(scope: String, id: String, tool: String) -> String {
        ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "No `\(scope)` matched `\(id)` (by id or exact name). "
                + "Use {action: \"list\", scope: \"\(scope)\"} to see what exists.",
            tool: tool
        )
    }

    /// Every read scope `list` / `describe` accept on Intel. Kept in one place
    /// so the unknown-scope failure and the describe pre-check can't drift
    /// from the switch statements.
    static let knownReadScopes: Set<String> = [
        "agents", "models", "providers", "mcp", "mcp_providers", "plugins",
        "schedules", "skills", "watchers", "knowledge", "themes", "commands",
        "search",
    ]

    /// Scopes upstream reads that this Intel build does not have (deferred
    /// features). Named so the model gets an honest answer, not a loop.
    static let unavailableOnIntelScopes: Set<String> = [
        "channels", "workspaces", "shared_agents", "harness_runtimes",
    ]

    /// Declarative entity-section ids that double as natural scope guesses.
    static func canonicalScope(_ scope: String) -> String {
        switch scope {
        case "mcp_servers": return "mcp"
        case "knowledge_collections": return "knowledge"
        case "search_providers": return "search"
        default: return scope
        }
    }

    /// Section names removed from the declarative surface. A model guessing
    /// these gets an honest "Settings UI only" answer.
    static let settingsUIOnlyScopes: Set<String> = ["server", "chat", "app"]

    /// Unknown-scope failure that TEACHES instead of just rejecting.
    static func unknownScopeFailure(scope: String, tool: String) -> String {
        let valid =
            "agents, models, providers, mcp, plugins, schedules, skills, watchers, "
            + "knowledge, themes, commands, search"
        if settingsUIOnlyScopes.contains(scope.lowercased()) {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`\(scope)` settings are managed in the Settings UI, not declaratively — "
                    + "there is nothing to read or apply here. Find the control with osaurus_help "
                    + "{action: 'find', query: '…'} and tell the user to open that path. "
                    + "Do NOT claim to have changed anything. Inspect scopes: \(valid).",
                field: "scope",
                tool: tool
            )
        }
        if unavailableOnIntelScopes.contains(scope.lowercased()) {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "`\(scope)` is not available in this Intel build, so there is nothing to read. "
                    + "Do not claim it exists. Inspect scopes: \(valid).",
                field: "scope",
                tool: tool
            )
        }
        if let section = ConfigSectionID.parse(scope) {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`\(scope)` is a configuration DOCUMENT SECTION, not an inspect scope. "
                    + "Read its current values with osaurus_config {action: 'export', "
                    + "sections: ['\(section.rawValue)']}, then change it with osaurus_config "
                    + "{action: 'apply', yaml: ...}. Inspect scopes: \(valid).",
                field: "scope",
                tool: tool
            )
        }
        return ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "Unknown scope `\(scope)`. Valid: \(valid).",
            field: "scope",
            tool: tool
        )
    }
}
