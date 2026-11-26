//
//  IntelSandboxPluginManager.swift
//  osaurus
//
//  Intel fork (W-seatbelt-sandbox stage 4): sandbox plugins on the host
//  backend. Upstream's `SandboxPluginManager` (excluded in Package.swift)
//  drives the Linux VM: `apk` dependencies, root-owned seeding, a library of
//  plugins, post-start repair passes and a daemon. None of that exists
//  under Seatbelt, so this is a smaller manager with the same name and the
//  same on-disk record (`agents/<id>/sandbox-plugins/installed.json`):
//
//  - install = validate, create the plugin folder, seed the plugin's files,
//    run `setup` (the agent's own network switch decides network, default
//    off), record it, register its tools;
//  - every file operation is a confined command (`SandboxManager.exec*`),
//    never an app-side write into a folder the sandbox could have swapped
//    for a symlink (the plugin folder lives in the writable workspace);
//  - system `dependencies` (apk) are rejected with upstream's own message;
//    `daemon` and `events` are not run (no daemon supervisor on the host);
//  - a plugin's tools are visible to, and runnable by, only the agent that
//    installed it (`SandboxToolGate.allows`), and ask for approval like
//    `sandbox_exec`.
//

import Foundation

final class SandboxPluginManager: @unchecked Sendable {
    static let shared = SandboxPluginManager()

    /// Test seam: tests bind a private manager (temp store, temp workspace).
    @TaskLocal static var testing: SandboxPluginManager?
    static var current: SandboxPluginManager { testing ?? shared }

    private let lock = NSLock()
    /// agentId -> installed plugins. Loaded lazily from disk per agent.
    private var installed: [String: [InstalledSandboxPlugin]] = [:]
    private var loadedAgents: Set<String> = []
    private let storeRootOverride: URL?
    private let managerOverride: SandboxManager?

    /// Limits that keep an agent-authored plugin small and reviewable.
    static let maxFiles = 64
    static let maxTotalFileBytes = 256 * 1024
    static let maxTools = 16

    init() {
        storeRootOverride = nil
        managerOverride = nil
    }

    /// Test seam: a private store root and a manager rooted at a temp workspace.
    init(storeRoot: URL, manager: SandboxManager) {
        storeRootOverride = storeRoot
        managerOverride = manager
    }

    private var manager: SandboxManager { managerOverride ?? SandboxManager.shared }

    // MARK: - Queries

    func plugins(for agentId: String) -> [InstalledSandboxPlugin] {
        load(agentId)
        return lock.withLock { installed[agentId] ?? [] }
    }

    func plugin(id: String, for agentId: String) -> InstalledSandboxPlugin? {
        plugins(for: agentId).first { $0.id == id }
    }

    /// True when any loaded agent has a plugin that defines this tool name.
    func isPluginTool(_ name: String) -> Bool {
        lock.withLock {
            installed.values.contains { list in
                list.contains { entry in
                    (entry.plugin.tools ?? []).contains { "\(entry.plugin.id)_\($0.id)" == name }
                }
            }
        }
    }

    func agentHasTool(_ name: String, agentId: String) -> Bool {
        plugins(for: agentId).contains { entry in
            entry.status == .ready
                && (entry.plugin.tools ?? []).contains { "\(entry.plugin.id)_\($0.id)" == name }
        }
    }

    // MARK: - Validation

    /// Plugin and tool ids end up in paths, shell quoting and tool names.
    static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 40 else { return false }
        guard let first = value.unicodeScalars.first, CharacterSet.alphanumerics.contains(first), first.isASCII
        else { return false }
        return value.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }
    }

    /// Everything the host install can refuse up front. Empty = acceptable.
    static func validate(_ plugin: SandboxPlugin) -> [String] {
        var errors = plugin.validateFilePaths()
        if !isSafeIdentifier(plugin.id) {
            errors.append("Plugin name must produce an id of letters, digits, `-` or `_` (got `\(plugin.id)`)")
        }
        if let deps = plugin.dependencies, !deps.isEmpty {
            errors.append(
                "System `dependencies` require the Linux VM sandbox (macOS 26+). "
                    + "On this macOS sandbox, leave `dependencies` empty and install "
                    + "Python/Node packages via `setup` (pip/npm) instead.")
        }
        let tools = plugin.tools ?? []
        for tool in tools {
            let full = "\(plugin.id)_\(tool.id)"
            if BuiltinSandboxTools.allToolNames.contains(full) {
                errors.append("Tool name `\(full)` is reserved for a built-in sandbox tool")
            }
        }
        if tools.count > maxTools { errors.append("A plugin may define at most \(maxTools) tools") }
        var seen = Set<String>()
        for tool in tools {
            if !isSafeIdentifier(tool.id) {
                errors.append("Tool id `\(tool.id)` must use letters, digits, `-` or `_`")
            }
            if !seen.insert(tool.id).inserted { errors.append("Duplicate tool id `\(tool.id)`") }
        }
        let files = plugin.files ?? [:]
        if files.count > maxFiles { errors.append("A plugin may seed at most \(maxFiles) files") }
        var total = 0
        for (path, content) in files {
            total += content.utf8.count
            let safe = path.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0))
            }
            if !safe { errors.append("File path has unsupported characters: \(path)") }
            if path == "plugin.json" || path.hasSuffix("/") { errors.append("File path not allowed: \(path)") }
        }
        if total > maxTotalFileBytes {
            errors.append("Plugin files total \(total) bytes; the limit is \(maxTotalFileBytes)")
        }
        return errors
    }

    // MARK: - Install

    /// Install `plugin` for `agentId`. `networkEnabled` is the agent's own
    /// sandbox network switch: `setup` reaches the network only if it is on.
    func install(
        plugin: SandboxPlugin,
        for agentId: String,
        networkEnabled: Bool,
        secrets: [String: String] = [:]
    ) async throws {
        var errors = Self.validate(plugin)
        if managerOverride == nil {
            for tool in plugin.tools ?? []
            where !ToolRegistry.shared.canRegisterSandboxPluginTool(named: "\(plugin.id)_\(tool.id)") {
                errors.append("Tool name `\(plugin.id)_\(tool.id)` is already used by another tool")
            }
        }
        guard errors.isEmpty else { throw SandboxPluginError.invalidPlugin(errors.joined(separator: "; ")) }

        let agentName = SandboxToolRegistrar.hostAgentName(for: agentId)
        var record = InstalledSandboxPlugin(
            plugin: plugin, agentId: agentId, status: .installing, sourceContentHash: plugin.contentHash)
        upsert(record, for: agentId)

        do {
            try await manager.startContainer()
            try await manager.ensureAgentUser(agentName)
            let pluginDir = OsaurusPaths.inContainerPluginDir(agentName, plugin.id)
            let fresh = try await manager.execAsAgent(
                agentName, command: "rm -rf '\(sandboxShellEscape(pluginDir))'; mkdir -p '\(sandboxShellEscape(pluginDir))'")
            guard fresh.succeeded else { throw SandboxPluginError.setupFailed("mkdir failed: \(fresh.stderr)") }

            for (path, content) in (plugin.files ?? [:]).sorted(by: { $0.key < $1.key }) {
                try await writeFile(content, to: "\(pluginDir)/\(path)", agentName: agentName)
            }
            if let setup = plugin.setup, !setup.isEmpty {
                let result = try await manager.execAsAgent(
                    agentName,
                    command: setup,
                    pluginName: plugin.id,
                    env: secrets,
                    timeout: 300,
                    networkEnabled: networkEnabled,
                    streamToLogs: true,
                    logSource: plugin.id
                )
                guard result.succeeded else {
                    var detail = SecretScrubber.scrub(result.stderr, secrets: secrets)
                    if !networkEnabled, SandboxExecTool.looksLikeNetworkFailure(detail) {
                        detail += " (Network access is off for this agent; the user can turn it on in its sandbox settings.)"
                    }
                    throw SandboxPluginError.setupFailed(detail)
                }
            }
            record.status = .ready
            upsert(record, for: agentId)
            save(agentId)
            registerTools(of: plugin)
            NotificationCenter.default.post(
                name: .sandboxPluginInstalled, object: nil,
                userInfo: ["pluginId": plugin.id, "agentId": agentId])
        } catch {
            record.status = .failed
            upsert(record, for: agentId)
            save(agentId)
            throw error
        }
    }

    /// Seed one file through a confined command (content as base64 so no
    /// quoting or size trick can change the command's shape).
    private func writeFile(_ content: String, to path: String, agentName: String) async throws {
        let b64 = Data(content.utf8).base64EncodedString()
        let directory = (path as NSString).deletingLastPathComponent
        let result = try await manager.execAsAgent(
            agentName,
            command:
                "mkdir -p '\(sandboxShellEscape(directory))' && printf '%s' '\(b64)' | /usr/bin/base64 -D > '\(sandboxShellEscape(path))'"
        )
        guard result.succeeded else {
            throw SandboxPluginError.setupFailed("Could not write \(path): \(result.stderr)")
        }
    }

    // MARK: - Uninstall

    func uninstall(pluginId: String, from agentId: String) async throws {
        guard Self.isSafeIdentifier(pluginId) else { throw SandboxPluginError.notInstalled }
        load(agentId)
        let agentName = SandboxToolRegistrar.hostAgentName(for: agentId)
        if await manager.status().isRunning {
            let pluginDir = OsaurusPaths.inContainerPluginDir(agentName, pluginId)
            _ = try? await manager.execAsAgent(
                agentName, command: "rm -rf '\(sandboxShellEscape(pluginDir))'")
        }
        lock.withLock {
            installed[agentId]?.removeAll { $0.id == pluginId }
        }
        save(agentId)
        // Tools disappear from the registry once no agent has the plugin.
        let stillUsed = lock.withLock { installed.values.contains { $0.contains { $0.id == pluginId } } }
        if !stillUsed { ToolRegistry.shared.unregisterSandboxPluginTools(pluginId: pluginId) }
        NotificationCenter.default.post(
            name: .sandboxPluginUninstalled, object: nil,
            userInfo: ["pluginId": pluginId, "agentId": agentId])
    }

    /// Drop an agent's plugin record when the agent is deleted. The plugin
    /// files live in the agent's sandbox home, removed with it.
    @discardableResult
    func removeAgentState(for agentId: String) -> Bool {
        let had = lock.withLock { () -> Bool in
            let existed = installed.removeValue(forKey: agentId) != nil
            loadedAgents.remove(agentId)
            return existed
        }
        let dir = storeDirectory(for: agentId)
        let onDisk = FileManager.default.fileExists(atPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
        return had || onDisk
    }

    // MARK: - Registry

    /// Load this agent's record and register its ready plugins' tools. Called
    /// when an agent with the sandbox first composes or sends.
    func registerTools(for agentId: String) {
        for entry in plugins(for: agentId) where entry.status == .ready {
            registerTools(of: entry.plugin)
        }
    }

    private func registerTools(of plugin: SandboxPlugin) {
        guard managerOverride == nil else { return }
        ToolRegistry.shared.registerSandboxPluginTools(plugin: plugin)
    }

    // MARK: - Persistence

    private func storeDirectory(for agentId: String) -> URL {
        (storeRootOverride ?? OsaurusPaths.agents())
            .appendingPathComponent(agentId, isDirectory: true)
            .appendingPathComponent("sandbox-plugins", isDirectory: true)
    }

    private func storeFile(for agentId: String) -> URL {
        storeDirectory(for: agentId).appendingPathComponent("installed.json")
    }

    private func load(_ agentId: String) {
        let already = lock.withLock { loadedAgents.contains(agentId) }
        guard !already else { return }
        var list: [InstalledSandboxPlugin] = []
        if let data = try? Data(contentsOf: storeFile(for: agentId)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            list = (try? decoder.decode([InstalledSandboxPlugin].self, from: data)) ?? []
            // An install that never finished is not usable.
            list.removeAll { $0.status == .installing || $0.status == .uninstalling }
        }
        lock.withLock {
            if !loadedAgents.contains(agentId) {
                loadedAgents.insert(agentId)
                installed[agentId] = list
            }
        }
    }

    private func upsert(_ record: InstalledSandboxPlugin, for agentId: String) {
        load(agentId)
        lock.withLock {
            var list = installed[agentId] ?? []
            if let index = list.firstIndex(where: { $0.id == record.id }) {
                list[index] = record
            } else {
                list.append(record)
            }
            installed[agentId] = list
        }
    }

    private func save(_ agentId: String) {
        let dir = storeDirectory(for: agentId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let list = lock.withLock { installed[agentId] ?? [] }
        guard let data = try? encoder.encode(list) else { return }
        try? data.write(to: storeFile(for: agentId), options: .atomic)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let sandboxPluginInstalled = Notification.Name("SandboxPluginInstalled")
    static let sandboxPluginUninstalled = Notification.Name("SandboxPluginUninstalled")
}

// MARK: - Errors

public enum SandboxPluginError: Error, LocalizedError {
    case invalidPlugin(String)
    case dependencyInstallFailed(String)
    case setupFailed(String)
    case notInstalled

    public var errorDescription: String? {
        switch self {
        case .invalidPlugin(let msg): "Invalid plugin: \(msg)"
        case .dependencyInstallFailed(let msg): "Dependency install failed: \(msg)"
        case .setupFailed(let msg): "Setup failed: \(msg)"
        case .notInstalled: "Plugin is not installed"
        }
    }
}
