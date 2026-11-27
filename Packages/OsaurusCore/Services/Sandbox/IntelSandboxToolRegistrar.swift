//
//  IntelSandboxToolRegistrar.swift
//  osaurus
//
//  Intel fork: the host-sandbox counterpart of upstream Classic's
//  `Services/Sandbox/SandboxToolRegistrar.swift` (W-seatbelt-sandbox stage 3).
//  Upstream's file drives the Linux VM (provisioning journeys, startup
//  failure telemetry, plugin registration) and stays excluded.
//
//  What it does here:
//  - `SandboxToolGate`: the one place that decides whether an agent has the
//    sandbox. Intel rule (owner policy): only a custom agent whose own
//    `AutonomousExecConfig.enabled` is true, on a Mac where `sandbox-exec`
//    exists. Everything else keeps today's tool surface.
//  - `SandboxToolRegistrar.registerTools(for:)`: called by the chat before a
//    send (`ChatView.prepareChatExecutionMode`) and by other surfaces; it
//    registers the tools once and starts the Seatbelt backend and the
//    agent's home on first use.
//

import Foundation

// MARK: - Gate

enum SandboxToolGate {
    /// The agent's sandbox settings, or nil when it has no sandbox: not a
    /// custom agent, not opted in, or this Mac cannot run `sandbox-exec`.
    static func config(for agentId: UUID) -> AutonomousExecConfig? {
        guard SandboxBackend.current == .seatbelt, SeatbeltSandbox.isSupported else { return nil }
        guard let agent = AgentManager.shared.agent(for: agentId), !agent.isBuiltIn else { return nil }
        guard let config = agent.autonomousExec, config.enabled else { return nil }
        return config
    }

    /// Whether `agentId` may see and run the sandbox tool `toolName`. Beyond
    /// the opt-in itself (stage 3), three tools have their own switch:
    /// `sandbox_process` needs `backgroundProcessEnabled`,
    /// `sandbox_plugin_register` needs `pluginCreate`, and a sandbox
    /// plugin's tools reach only an agent that installed that plugin.
    static func allows(_ toolName: String, agentId: UUID?) -> Bool {
        guard let agentId, let config = config(for: agentId) else { return false }
        switch toolName {
        case BuiltinSandboxTools.process: return config.backgroundProcessEnabled
        case BuiltinSandboxTools.pluginRegister: return config.pluginCreate
        default:
            if SandboxPluginManager.shared.isPluginTool(toolName) {
                return SandboxPluginManager.shared.agentHasTool(toolName, agentId: agentId.uuidString)
            }
            return true
        }
    }

    /// Called after an agent's settings change (editor, declarative config):
    /// an agent that no longer has the sandbox, or no longer has Background
    /// Processes, loses its running background jobs at once.
    static func enforcePolicy(afterUpdating agentId: UUID) {
        guard config(for: agentId)?.backgroundProcessEnabled != true else { return }
        let name = SandboxToolRegistrar.hostAgentName(for: agentId.uuidString)
        Task { await SandboxBackgroundJobs.shared.stopAll(agentName: name) }
    }

    static func isOptedIn(_ agentId: UUID?) -> Bool {
        guard let agentId else { return false }
        return config(for: agentId) != nil
    }

    /// True when at least one agent has the sandbox. Used to keep the
    /// sandbox tools out of global listings until someone opted in.
    static var anyAgentOptedIn: Bool {
        AgentManager.shared.agents.contains { isOptedIn($0.id) }
    }

    /// An agent that opted in on a Mac that cannot run the backend (no
    /// `sandbox-exec`): the prompt says so instead of silently dropping it.
    static func optedInButUnsupported(_ agentId: UUID) -> Bool {
        guard let agent = AgentManager.shared.agent(for: agentId), !agent.isBuiltIn,
            agent.autonomousExec?.enabled == true
        else { return false }
        return !(SandboxBackend.current == .seatbelt && SeatbeltSandbox.isSupported)
    }
}

// MARK: - Registrar

final class SandboxToolRegistrar: @unchecked Sendable {
    static let shared = SandboxToolRegistrar()

    /// Upstream's `SandboxAgentProvisioner.linuxName(for:)`: the agent's
    /// folder under `/workspace/agents/` (lowercased id; letters, digits and
    /// dashes only).
    static func hostAgentName(for agentId: String) -> String {
        let name =
            agentId
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return name.isEmpty ? "agent" : name
    }

    /// Seeded once into a new agent's `SOUL.md` (never overwritten).
    static let soulSeedBody = """
        # SOUL

        This file is your space to record stable preferences and patterns you
        learn about working with the user. It persists across sessions, and you
        can edit it freely with sandbox_write_file. Edits apply on the next
        session.
        """

    /// Call once at app launch (upstream `start()`): resolve availability, so
    /// the Sandbox page, the chat chip and the agent editor don't read
    /// "Unavailable" until a sandbox-enabled agent has chatted.
    func start() {
        Task {
            await refreshAtLaunch()
            await autoStartIfConfigured()
        }
    }

    /// Availability, then the status the saved setup implies. Also run when
    /// the Sandbox page appears, so it starts nothing, registers no tool and
    /// only reads `sandbox.json`.
    func refreshAtLaunch(manager: SandboxManager = .shared) async {
        guard await manager.refreshAvailability().isAvailable else { return }
        _ = await manager.refreshStatus()
    }

    /// Upstream `autoStartContainerIfConfigured`: a sandbox the user already
    /// set up, with auto-start on, is running again after a relaunch. Tools
    /// still register only for opted-in agents.
    func autoStartIfConfigured(
        manager: SandboxManager = .shared,
        config: SandboxConfiguration = SandboxConfigurationStore.load()
    ) async {
        guard config.autoStart, config.setupComplete,
            await manager.refreshAvailability().isAvailable
        else { return }
        do {
            try await manager.startContainer()
        } catch {
            debugLog("[Sandbox] Auto-start during launch failed: \(error.localizedDescription)")
        }
    }

    /// Make the sandbox ready for `agentId`: register the tools (idempotent)
    /// and, on first use, start the backend and create the agent's home.
    /// Does nothing for an agent that has not opted in.
    func registerTools(for agentId: UUID) async {
        guard SandboxToolGate.isOptedIn(agentId) else { return }
        await MainActor.run { BuiltinSandboxTools.register() }
        // The agent's installed sandbox plugins (stage 4): their tools come
        // back after a relaunch the first time the agent uses the sandbox.
        SandboxPluginManager.shared.registerTools(for: agentId.uuidString)
        do {
            try await SandboxManager.shared.startContainer()
            try await SandboxManager.shared.bootstrapAgent(
                agentName: Self.hostAgentName(for: agentId.uuidString),
                agentId: agentId,
                soulSeedBody: Self.soulSeedBody
            )
        } catch {
            // The tools report the failure themselves when called; the
            // registration itself must never block a send.
        }
    }

    /// FloatingInputCard's sandbox chip calls this on "Retry". The host
    /// backend keeps no startup-failure state.
    func resetStartupFailures(for agentId: UUID? = nil) {}
}
