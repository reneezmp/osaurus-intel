//
//  DefaultAgentConfigurationStore.swift
//  osaurus
//
//  Persistence for the built-in Orchestrator configuration.
//

import Foundation

/// JSON persistence for `DefaultAgentConfiguration` at
/// `~/.osaurus/config/default-agent.json`.
///
/// The Intel runtime reads this store from non-actor-isolated code, so its
/// small in-memory cache is protected by a lock rather than tied to the main
/// actor. Tests can direct it to an isolated directory with `overrideDirectory`.
public enum DefaultAgentConfigurationStore {
    public nonisolated(unsafe) static var overrideDirectory: URL?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: DefaultAgentConfiguration?

    public static func load() -> DefaultAgentConfiguration {
        lock.lock()
        defer { lock.unlock() }

        if let cached { return cached }

        let configuration = loadFromDisk(at: configurationFileURL())
        cached = configuration
        Agent.defaultAgentNameOverride = configuration.resolvedDisplayName
        return configuration
    }

    /// Persist an explicit Orchestrator configuration. Callers that need the
    /// live runtime to refresh should use `AgentManager`'s default-agent
    /// update method, which also invalidates active capability snapshots.
    public static func save(_ configuration: DefaultAgentConfiguration) {
        do {
            try saveChecked(configuration)
        } catch {
            print("[Osaurus] Failed to save default-agent.json: \(error)")
        }
    }

    /// Persist first, then update the cache. Declarative configuration uses
    /// this throwing variant so a failed write can never look successful just
    /// because the requested value was already placed in memory.
    public static func saveChecked(_ configuration: DefaultAgentConfiguration) throws {
        lock.lock()
        defer { lock.unlock() }

        let url = configurationFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: url, options: [.atomic])
        cached = configuration
        Agent.defaultAgentNameOverride = configuration.resolvedDisplayName
    }

    /// Read persisted bytes without consulting or changing the cache.
    public static func loadFreshFromDisk() throws -> DefaultAgentConfiguration {
        lock.lock()
        defer { lock.unlock() }
        let data = try Data(contentsOf: configurationFileURL())
        return try JSONDecoder().decode(DefaultAgentConfiguration.self, from: data)
    }

    /// Clears only the memory cache; useful after changing the isolated test
    /// storage directory. It never changes the user's persisted settings.
    public static func resetCacheForTests() {
        lock.lock()
        cached = nil
        Agent.defaultAgentNameOverride = nil
        lock.unlock()
    }

    private static func configurationFileURL() -> URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent("default-agent.json")
        }
        return OsaurusPaths.config().appendingPathComponent("default-agent.json")
    }

    private static func loadFromDisk(at url: URL) -> DefaultAgentConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .default
        }
        guard let data = try? Data(contentsOf: url),
            let configuration = try? JSONDecoder().decode(DefaultAgentConfiguration.self, from: data)
        else {
            // Do not overwrite an unreadable user file merely because the app
            // launched. The next explicit save is the user's recovery choice.
            print("[Osaurus] Failed to decode default-agent.json; using inherited defaults")
            return .default
        }
        return configuration
    }
}
