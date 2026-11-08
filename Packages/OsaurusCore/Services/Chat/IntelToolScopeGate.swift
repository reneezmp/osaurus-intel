//
//  IntelToolScopeGate.swift
//  osaurus
//
//  Upstream's tool scope gate (`ToolRegistry.execute` with a
//  `toolExecutionScope`: #2018, #2145, #2279, #2309) for Intel's engine. A
//  call to a tool the request didn't offer is never run. Upstream answers it
//  with a `tool_not_found` envelope and the loop goes on, so the model gets
//  one correction (an identical repeat is replayed by the harness). Intel's
//  engine used to end the turn with "The provider requested a tool that was
//  not offered". The envelope says what the model can do next, without naming
//  tools the agent was not given:
//  - a folder tool with no folder attached: attach one;
//  - an Apple app tool: where its switch is;
//  - an enabled capability one load away: `capabilities` with its id;
//  - a plugin group id called as a function (#2309): load the group;
//  - anything else: the opaque refusal.
//

import Foundation

enum IntelToolScopeGate {
    /// Upstream `ToolRegistry.coreWorkspaceToolNames`.
    static let coreWorkspaceToolNames: Set<String> = [
        "file_read", "file_search", "file_write", "file_edit", "shell_run",
    ]

    @MainActor
    static func envelope(forUnofferedCall name: String, offered: [Tool]?, agentId: UUID?) -> String {
        let offeredNames = Set((offered ?? []).map(\.function.name))
        let catalog: CapabilityCatalog =
            (offeredNames.contains(CapabilitiesTool.toolName) && agentId != nil)
            ? CapabilityCatalog.build(agentId: agentId!) : .empty
        return envelope(forUnofferedCall: name, offeredNames: offeredNames, agentId: agentId, catalog: catalog)
    }

    /// Pure form (tests pass their own catalog).
    static func envelope(
        forUnofferedCall name: String,
        offeredNames: Set<String>,
        agentId: UUID?,
        catalog: CapabilityCatalog
    ) -> String {
        // Folder tools first: their only next step is user-facing (attach a
        // folder), never a loader round-trip (upstream). Intel has no
        // Autonomous execution, so that alternative is not named.
        if coreWorkspaceToolNames.contains(name) {
            return ToolErrorEnvelope(
                kind: .toolNotFound,
                reason:
                    "\(name) needs a working folder attached to THIS chat and there is none "
                    + "(this chat has no folder, or its folder was cleared). "
                    + PromptWorkingFolderTool.attachFolderSteer
                    + " An attached folder also becomes the agent's Working Folder for "
                    + "future chats and background runs. Until then, deliver file content with "
                    + "share_artifact and say why.",
                toolName: name,
                retryable: false
            ).toJSONString()
        }
        if let app = AppleApp.app(forTool: name) {
            return appleAppOffEnvelope(tool: name, app: app, agentId: agentId)
        }
        let canLoad = offeredNames.contains(CapabilitiesTool.toolName)
        if canLoad, catalog.tools.contains(where: { $0.name == name }) {
            return ToolErrorEnvelope(
                kind: .toolNotFound,
                reason:
                    "\(name) exists but is not loaded in this conversation. "
                    + "Call capabilities with ids: [\"tool/\(name)\"] to load it, "
                    + "then retry this call.",
                toolName: name,
                retryable: true
            ).toJSONString()
        }
        if canLoad, let group = groupCalledAsFunction(name, catalog: catalog) {
            return ToolErrorEnvelope(
                kind: .toolNotFound,
                reason:
                    "'\(name)' is a capability id for a plugin group, not a callable "
                    + "function. Call capabilities with {\"ids\":[\"plugin/\(group.id)\"]} to "
                    + "load it, then call one of the loaded tool names to continue.",
                toolName: name,
                retryable: true
            ).toJSONString()
        }
        return ToolErrorEnvelope(
            kind: .toolNotFound,
            reason: "\(name) is not available in this conversation.",
            toolName: name,
            retryable: false
        ).toJSONString()
    }

    /// Upstream `groupIdCallRescueEnvelope`: `plugin/<id>` or a bare group id
    /// copied into the function name. Only a group this agent may load (the
    /// catalog is already filtered to enabled, allowed tools) is named.
    static func groupCalledAsFunction(_ guessedName: String, catalog: CapabilityCatalog) -> CapabilityCatalog.Group? {
        let bare: String
        if guessedName.hasPrefix("plugin/") {
            bare = String(guessedName.dropFirst("plugin/".count))
        } else {
            guard !guessedName.contains("/") else { return nil }
            bare = guessedName
        }
        guard !bare.isEmpty else { return nil }
        let slug = CapabilityCatalog.slug(bare)
        return catalog.groups.first { ($0.id == bare || $0.id == slug) && !$0.tools.isEmpty }
    }

    /// Upstream `ToolRegistry.appleAppOffEnvelope`, with Intel's location of
    /// the switch (Agents › Abilities › Apple Apps).
    static func appleAppOffEnvelope(tool: String, app: AppleApp, agentId: UUID?) -> String {
        let message: String
        if agentId == nil {
            message =
                "'\(tool)' belongs to the built-in \(app.displayName) app and only runs inside an Osaurus agent that has \(app.displayName) enabled."
        } else if agentId == Agent.defaultId {
            message =
                "'\(tool)' belongs to the built-in \(app.displayName) app. The Default agent never uses Apple app tools; enable \(app.displayName) on a custom agent and delegate to it."
        } else {
            message =
                "'\(tool)' belongs to the built-in \(app.displayName) app, which is off for this agent. It cannot be loaded with capabilities. Ask the user to turn on \(app.displayName) under this agent's Abilities → Apple Apps, then retry."
        }
        return ToolEnvelope.failure(
            kind: .rejected, message: message, tool: tool, retryable: false,
            metadata: ["apple_app": app.rawValue]
        )
    }
}
