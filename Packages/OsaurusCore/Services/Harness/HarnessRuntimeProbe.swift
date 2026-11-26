//
//  HarnessRuntimeProbe.swift
//  osaurus
//
//  The Agent Runtimes "Test" button: look at the runtime the way a chat would
//  launch it, without starting a conversation. Claude Code reports its sign-in
//  with `auth status`. Pi's `get_state` round trip needs the harness process
//  and lands with it (`W-harness-runtimes` stage 3); until then a Pi runtime is
//  only checked for "found, and runnable on this Mac".
//
//  Intel differences from upstream (#3175): the `.incompatible` status and the
//  Mach-O check (`HarnessBinaryArchitecture`), because an Intel Mac has no
//  Rosetta; and every collaborator is injectable so tests never launch a real
//  external process.
//

import Foundation

public struct HarnessProbeResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Started and ready to chat.
        case ready
        /// Started, but chats will fail until the user fixes something
        /// (no model configured, signed out).
        case needsSetup
        /// Couldn't start or didn't answer.
        case failed
        /// The command exists but this Mac's CPU can't run it (an arm64-only
        /// build on an Intel Mac). Intel addition.
        case incompatible
    }

    public var status: Status
    public var message: String
    /// The executable that was actually resolved.
    public var resolvedExecutable: String?
}

/// Names of the variables Osaurus gives, or strips from, a harness process.
/// Stage 3 adds upstream's `contract(context:token:)` to this enum.
enum HarnessEnvironment {
    static let chatId = "OSAURUS_CHAT_ID"
    static let agentId = "OSAURUS_AGENT_ID"
    static let agentToken = "OSAURUS_AGENT_TOKEN"
    static let apiBase = "OSAURUS_API_BASE"
    static let workingDirectory = "OSAURUS_WORKING_DIRECTORY"
    /// Read by `osaurus mcp`; the same literal as `ClaudeCodeConfiguration`'s
    /// `--mcp-config` block and the CLI's `MCPCommand`.
    static let bridgeGrant = "OSAURUS_MCP_BRIDGE_GRANT"

    /// Inherited variables no harness should see. `CLAUDECODE` makes a nested
    /// `claude` refuse to start; the bridge grant must only ever be the one
    /// Osaurus minted for this process.
    static let alwaysRemoved: Set<String> = ["CLAUDECODE", bridgeGrant]
}

/// Resolution for one-shot control commands, using the same PATH a harness
/// chat process gets, so a Test that passes means a chat can launch.
enum HarnessControlCommand {
    struct Resolved: Sendable {
        var executable: String
        var environment: [String: String]
    }

    static func resolve(
        _ command: String,
        overlay: [String: String] = [:],
        removing: Set<String> = HarnessEnvironment.alwaysRemoved,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Resolved? {
        let entries = await LoginShellPath.shared.entries()
        return resolve(
            command,
            overlay: overlay,
            removing: removing,
            inherited: inherited,
            loginShellEntries: entries
        )
    }

    /// Synchronous core of `resolve`, with the login-shell PATH entries given.
    static func resolve(
        _ command: String,
        overlay: [String: String],
        removing: Set<String>,
        inherited: [String: String],
        loginShellEntries: [String]?
    ) -> Resolved? {
        var environment = childEnvironment(
            inherited: inherited,
            loginShellEntries: loginShellEntries,
            overlay: overlay,
            removing: removing
        )
        guard let executable = ExecutableLocator.resolve(command: command, env: environment),
            FileManager.default.isExecutableFile(atPath: executable)
        else { return nil }
        if overlay["PATH"] == nil {
            environment["PATH"] = prependingShebangSibling(of: executable, to: environment["PATH"] ?? "")
        }
        return Resolved(executable: executable, environment: environment)
    }

    /// The PATH searched for `command`, for "not found" messages.
    static func searchedPath(inherited: [String: String] = ProcessInfo.processInfo.environment) async -> String {
        let entries = await LoginShellPath.shared.entries()
        return ExecutableLocator.childPath(inherited: inherited, loginShellEntries: entries)
    }

    // Upstream keeps these two on `HarnessProcess`; they move there in stage 3.

    static func childEnvironment(
        inherited: [String: String],
        loginShellEntries: [String]?,
        overlay: [String: String],
        removing: Set<String>
    ) -> [String: String] {
        var env = inherited
        for key in removing { env[key] = nil }
        env["PATH"] = ExecutableLocator.childPath(inherited: env, loginShellEntries: loginShellEntries)
        for (key, value) in overlay { env[key] = value }
        return env
    }

    /// `#!/usr/bin/env node` scripts (npm-installed `claude`, `pi`) need their
    /// interpreter on the child's PATH, and the copy beside the script is the
    /// one the user's version manager picked.
    static func prependingShebangSibling(of executable: String, to path: String) -> String {
        guard let sibling = ExecutableLocator.envShebangSiblingDirectory(executable: executable) else { return path }
        let rest = path.split(separator: ":").map(String.init).filter { $0 != sibling }
        return ([sibling] + rest).joined(separator: ":")
    }
}

enum HarnessRuntimeProbe {
    /// Collaborators, replaceable in tests.
    struct Dependencies: Sendable {
        var resolve: @Sendable (_ command: String, _ overlay: [String: String]) async -> HarnessControlCommand.Resolved?
        var claudeCodeState: @Sendable (_ command: String, _ overlay: [String: String]) async -> ClaudeCodeSetupState
        var host: HarnessBinaryArchitecture.Host

        static let live = Dependencies(
            resolve: { command, overlay in
                await HarnessControlCommand.resolve(
                    command,
                    overlay: overlay,
                    removing: HarnessEnvironment.alwaysRemoved.union(ClaudeCodeConfiguration.removedEnvironment)
                )
            },
            claudeCodeState: { command, overlay in
                await ClaudeCodeConfiguration.setupState(command: command, overlay: overlay)
            },
            host: .current
        )
    }

    static func run(_ runtime: HarnessRuntime, dependencies: Dependencies = .live) async -> HarnessProbeResult {
        // Look at the command first; only a runnable Claude Code is asked who
        // is signed in, so an Incompatible binary is never spawned.
        guard let resolved = await dependencies.resolve(runtime.executable, runtime.environment) else {
            return HarnessProbeResult(
                status: .failed,
                message: String(format: L("Couldn't find \"%@\"."), runtime.executable),
                resolvedExecutable: nil
            )
        }
        let verdict = HarnessBinaryArchitecture.verdict(forFileAt: resolved.executable, host: dependencies.host)
        if case .incompatible(let slices) = verdict {
            return HarnessProbeResult(
                status: .incompatible,
                message: HarnessBinaryArchitecture.incompatibleMessage(
                    command: runtime.executable,
                    slices: slices,
                    host: dependencies.host
                ),
                resolvedExecutable: resolved.executable
            )
        }
        switch runtime.kind {
        case .claudeCode:
            return await probeClaudeCode(runtime, resolved: resolved, dependencies: dependencies)
        case .piRPC:
            return HarnessProbeResult(
                status: .ready,
                message: String(
                    format: L("Found at %@. Osaurus checks that it answers when a chat starts it."),
                    resolved.executable
                ),
                resolvedExecutable: resolved.executable
            )
        }
    }

    private static func probeClaudeCode(
        _ runtime: HarnessRuntime,
        resolved: HarnessControlCommand.Resolved,
        dependencies: Dependencies
    ) async -> HarnessProbeResult {
        let state = await dependencies.claudeCodeState(runtime.executable, runtime.environment)
        switch state {
        case .notInstalled:
            return HarnessProbeResult(
                status: .failed,
                message: String(format: L("Couldn't find \"%@\"."), runtime.executable),
                resolvedExecutable: nil
            )
        case .statusUnavailable(let version):
            return HarnessProbeResult(
                status: .needsSetup,
                message: String(
                    format: L("Claude Code %@ doesn't report its sign-in status. Run claude in Terminal to check it."),
                    version ?? ""
                ),
                resolvedExecutable: resolved.executable
            )
        case .signedOut:
            return HarnessProbeResult(
                status: .needsSetup,
                message: L("Claude Code isn't signed in."),
                resolvedExecutable: resolved.executable
            )
        case .signedIn(let status):
            let account = status.email ?? status.orgName
            return HarnessProbeResult(
                status: .ready,
                message: account.map { String(format: L("Signed in as %@."), $0) } ?? L("Signed in."),
                resolvedExecutable: resolved.executable
            )
        }
    }
}
