//
//  ConfigHarnessSections.swift
//  osaurus
//
//  Declarative shape for an agent's Claude Code options (`claude_code` on
//  `agents[]` and `default_agent`). Intel has no harness runtime registry
//  (`W-harness-runtimes`), so upstream's `harness_runtimes` section and the
//  `runtime:` key are not part of the Intel schema.
//

import Foundation

/// Claude Code options for an agent.
/// Only provided keys change.
public struct AgentClaudeCodeEntry: Codable, Equatable, Sendable {
    /// `--effort`: `low` … `max`, or `default` for the CLI's own default.
    public var effort: String?
    /// `agent` | `text_only`.
    public var mode: String?
    public var allowWrites: Bool?
    public var allowShell: Bool?
    public var allowOsaurusTools: Bool?
    /// Default agent only: the Osaurus config tools are the Orchestrator's.
    public var allowOsaurusConfigWrites: Bool?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case effort, mode
        case allowWrites = "allow_writes"
        case allowShell = "allow_shell"
        case allowOsaurusTools = "allow_osaurus_tools"
        case allowOsaurusConfigWrites = "allow_osaurus_config_writes"
    }
}

enum ConfigHarness {
    static let modeKeys = ["agent", "text_only"]
    /// `claude_code.effort` value that clears the override.
    static let defaultEffortKey = "default"
    static let effortKeys = [defaultEffortKey] + ClaudeCodeEffort.allCases.map(\.rawValue)

    /// `.some(nil)` clears the override; nil is an unknown value.
    static func effort(forKey raw: String) -> ClaudeCodeEffort?? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty || key == defaultEffortKey { return .some(nil) }
        return ClaudeCodeEffort(rawValue: key).map { .some($0) }
    }

    static func mode(forKey raw: String) -> ClaudeCodeMode? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "agent": return .agent
        case "text_only": return .textOnly
        default: return nil
        }
    }

    static func key(for mode: ClaudeCodeMode) -> String {
        switch mode {
        case .agent: return "agent"
        case .textOnly: return "text_only"
        }
    }

    static func export(_ config: ClaudeCodeAgentConfig, includeConfigWrites: Bool) -> AgentClaudeCodeEntry {
        var entry = AgentClaudeCodeEntry()
        entry.effort = config.resolvedEffort?.rawValue ?? defaultEffortKey
        entry.mode = key(for: config.mode)
        entry.allowWrites = config.allowWrites
        entry.allowShell = config.allowShell
        entry.allowOsaurusTools = config.allowOsaurusTools
        if includeConfigWrites { entry.allowOsaurusConfigWrites = config.allowOsaurusConfigWrites }
        return entry
    }

    static func patch(_ config: inout ClaudeCodeAgentConfig, from entry: AgentClaudeCodeEntry) {
        if let raw = entry.effort, let effort = effort(forKey: raw) { config.effort = effort?.rawValue }
        if let raw = entry.mode, let mode = mode(forKey: raw) { config.mode = mode }
        if let v = entry.allowWrites { config.allowWrites = v }
        if let v = entry.allowShell { config.allowShell = v }
        if let v = entry.allowOsaurusTools { config.allowOsaurusTools = v }
        if let v = entry.allowOsaurusConfigWrites { config.allowOsaurusConfigWrites = v }
    }

    /// Plan lines for a `claude_code` block against the stored options.
    static func changes(
        _ entry: AgentClaudeCodeEntry, current: ClaudeCodeAgentConfig, prefix: String
    ) -> [String] {
        var desired = current
        patch(&desired, from: entry)
        var out: [String] = []
        if desired.resolvedEffort != current.resolvedEffort {
            let old = current.resolvedEffort?.rawValue ?? defaultEffortKey
            let new = desired.resolvedEffort?.rawValue ?? defaultEffortKey
            out.append("\(prefix).effort: \(old) -> \(new)")
        }
        if desired.mode != current.mode {
            out.append("\(prefix).mode: \(key(for: current.mode)) -> \(key(for: desired.mode))")
        }
        func flag(_ name: String, _ old: Bool, _ new: Bool) {
            if old != new { out.append("\(prefix).\(name): \(old) -> \(new)") }
        }
        flag("allow_writes", current.allowWrites, desired.allowWrites)
        flag("allow_shell", current.allowShell, desired.allowShell)
        flag("allow_osaurus_tools", current.allowOsaurusTools, desired.allowOsaurusTools)
        flag(
            "allow_osaurus_config_writes", current.allowOsaurusConfigWrites,
            desired.allowOsaurusConfigWrites)
        return out
    }

    /// Risk lines for switches a `claude_code` block newly turns on.
    static func risks(
        _ entry: AgentClaudeCodeEntry, current: ClaudeCodeAgentConfig, agent: String
    ) -> [String] {
        var out: [String] = []
        if entry.allowShell == true, !current.allowShell {
            out.append(ConfigRisk.claudeCodeShell(agent))
        }
        if entry.allowOsaurusConfigWrites == true, !current.allowOsaurusConfigWrites {
            out.append(ConfigRisk.claudeCodeConfigWrites(agent))
        }
        return out
    }
}
