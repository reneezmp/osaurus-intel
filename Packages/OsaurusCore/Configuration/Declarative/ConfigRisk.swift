//
//  ConfigRisk.swift
//  osaurus
//
//  The risk strings the planner and the apply gate share. Upstream keeps
//  this enum at the top of `ConfigPlanner.swift`; Intel keeps it in its own
//  file so the exporter and harness helpers can use it before the planner
//  lands. Channel, harness-runtime and model-deletion risks are left out:
//  Intel has none of those sections (`W-channels`, `W-harness-runtimes`,
//  no local models).
//

import Foundation

/// Shared risk strings so planner and apply gate agree exactly.
/// Server-owned gates (network exposure, proxy, memory safety, body-size
/// raises) left with the `server` section in scope reduction 2.
enum ConfigRisk {
    static func autoPolicy(_ tool: String) -> String {
        "Sets tool `\(tool)` to auto — it will run without asking."
    }
    /// A per-call approval tool (send / delete) cannot be made silent: the
    /// registry forces `ask` at execution, so the stored `auto` is inert.
    static func autoPolicyIgnoredPerCall(_ tool: String) -> String {
        "Sets tool `\(tool)` to auto, but it always asks for approval on every call (it sends or deletes as the user) — the setting is stored and has no effect."
    }
    /// Argument-aware per-call tools (`mail_compose` / `mail_reply`): `auto`
    /// covers drafts, never the `send: true` calls.
    static func autoPolicySendsStillAsk(_ tool: String) -> String {
        "Sets tool `\(tool)` to auto — drafts will run without asking; calls that send as the user still show an approval card every time."
    }
    static func computerUse(_ agent: String) -> String {
        "Gives agent `\(agent)` screen control (computer use)."
    }
    static func browserUse(_ agent: String) -> String {
        "Gives agent `\(agent)` browser automation."
    }
    /// Apple apps whose tools can act on the user's behalf outside Osaurus
    /// (send mail / iMessages, run arbitrary Shortcuts). Reads and the
    /// organiser apps stay risk-free; the model still gets a per-call
    /// approval prompt for each send.
    static let riskyAppleApps: Set<AppleApp> = [.mail, .messages, .shortcuts]
    static func appleApp(_ agent: String, _ app: AppleApp) -> String {
        switch app {
        case .mail: return "Lets agent `\(agent)` read and send email as the user (Mail)."
        case .messages: return "Lets agent `\(agent)` read and send iMessages/SMS as the user (Messages)."
        case .shortcuts: return "Lets agent `\(agent)` run the user's Shortcuts (arbitrary automations)."
        default: return "Gives agent `\(agent)` access to \(app.displayName)."
        }
    }
    /// Risk lines for the Apple apps newly turned on (present in `desired`,
    /// absent from `current`) that are in `riskyAppleApps`.
    static func appleAppRisks(_ agent: String, current: Set<AppleApp>, desired: Set<AppleApp>) -> [String] {
        AppleApp.sorted(desired.subtracting(current).intersection(riskyAppleApps)).map { appleApp(agent, $0) }
    }
    static func relayEnabled(_ agent: String) -> String {
        "Exposes agent `\(agent)` through the relay tunnel (reachable from outside this Mac)."
    }
    static func alwaysAllowSubagent(_ kind: String) -> String {
        "Sets subagent kind `\(kind)` to always_allow — its jobs run without asking."
    }
    static let applescriptAutoRun =
        "AppleScript automations auto-run with only a warning (no per-script confirmation)."
    /// `spawnable_agents` REPLACES the pool. A document that lists none
    /// while the pool has members (or custom agents exist) takes
    /// `spawn_agent` away from the Orchestrator until an agent is added
    /// back — the silent-empty-pool failure this card must name.
    static func emptiesSpawnPool(removed: Int, customAgents: Int) -> String {
        "Empties the Orchestrator's spawn pool (`spawnable_agents` replaces the whole list; "
            + "\(removed) spawnable agent\(removed == 1 ? "" : "s") removed, \(customAgents) custom "
            + "agent\(customAgents == 1 ? "" : "s") exist) — the Orchestrator loses `spawn_agent` "
            + "and cannot delegate until an agent is listed again."
    }
    static func emptiesWorkspaceSpawnPool(removed: Int) -> String {
        "Removes every teammate agent from the Orchestrator's pool (`spawnable_workspace_agents` "
            + "replaces the whole list; \(removed) removed)."
    }
    static let ramPreflightDisabled =
        "Turns off \"Check memory before delegating\" for subagent tasks."
    static func mcpEndpoint(_ name: String, _ url: String) -> String {
        "Registers external MCP endpoint for `\(name)`: \(url)"
    }
    static func mcpRetarget(_ name: String, from: String, to: String) -> String {
        "Moves MCP server `\(name)` from \(from) to \(to)."
    }
    static func stdioCommand(_ name: String, _ command: String) -> String {
        "MCP server `\(name)` will launch a local process: \(command)"
    }
    static func stdioOnHost(_ name: String) -> String {
        "MCP server `\(name)` runs its process on the HOST, outside the sandbox."
    }
    static func deleteCommand(_ name: String) -> String {
        "Deletes slash command `/\(name)` (prune)."
    }
    static func deleteKnowledgeCollection(_ name: String) -> String {
        "Deletes knowledge collection `\(name)` and its search index (prune). "
        + "Documents in the folder are not touched."
    }
    static func deleteAgent(_ name: String) -> String {
        "Deletes agent `\(name)` (prune)."
    }
    static func deleteProvider(_ name: String) -> String {
        "Removes provider `\(name)` and its stored credentials (prune)."
    }
    static func uninstallPlugin(_ id: String) -> String {
        "Uninstalls plugin `\(id)` (prune)."
    }
    static func deleteMCPServer(_ name: String) -> String {
        "Removes MCP server `\(name)` and its tools (prune)."
    }
    static func deleteSchedule(_ name: String) -> String {
        "Deletes schedule `\(name)` (prune)."
    }
    static func deleteWatcher(_ name: String) -> String {
        "Deletes watcher `\(name)` (prune)."
    }
    static func deleteSearchProvider(_ id: String) -> String {
        "Removes search provider `\(id)` and its stored key (prune)."
    }
    static func claudeCodeShell(_ agent: String) -> String {
        "Lets Claude Code run shell commands for agent `\(agent)`, unconfined on this Mac."
    }
    static func claudeCodeConfigWrites(_ agent: String) -> String {
        "Lets Claude Code change Osaurus configuration for agent `\(agent)`."
    }
}
