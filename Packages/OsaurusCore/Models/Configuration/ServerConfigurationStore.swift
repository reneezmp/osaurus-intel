//
//  ServerConfigurationStore.swift
//  osaurus
//
//  Persistence for ServerConfiguration
//

import Foundation

@MainActor
enum ServerConfigurationStore {
    /// When set, configuration reads/writes use this directory instead of the default path.
    static var overrideDirectory: URL?

    static func load() -> ServerConfiguration? {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            var configuration = try JSONDecoder().decode(ServerConfiguration.self, from: Data(contentsOf: url))
            if migrateLegacyImmediateIdleResidencyIfNeeded(&configuration) {
                save(configuration)
            }
            return configuration
        } catch {
            print("[Osaurus] Failed to load ServerConfiguration: \(error)")
            return nil
        }
    }

    static func save(_ configuration: ServerConfiguration) {
        let url = configurationFileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Persist off the main thread (upstream ConfigDiskWriter, a hang
            // fix). Tests read the file back immediately, so they write
            // synchronously. Intel: any test process (OSAURUS_TEST_ROOT
            // runs don't set overrideRoot).
            ConfigDiskWriter.write(
                try encoder.encode(configuration),
                to: url,
                synchronous: OsaurusPaths.overrideRoot != nil || OsaurusPaths.isTestProcess,
                onError: { print("[Osaurus] Failed to save ServerConfiguration: \($0)") }
            )
        } catch {
            print("[Osaurus] Failed to save ServerConfiguration: \(error)")
        }
    }

    static func updateAppearanceMode(_ mode: AppearanceMode) {
        var configuration = load() ?? ServerConfiguration.default
        configuration.appearanceMode = mode
        save(configuration)
    }

    static func updateFontSizeMultiplier(_ multiplier: Double) {
        var configuration = load() ?? ServerConfiguration.default
        configuration.fontSizeMultiplier = ServerConfiguration.clampedFontSizeMultiplier(multiplier)
        save(configuration)
    }

    private static func configurationFileURL() -> URL {
        if let dir = overrideDirectory {
            return dir.appendingPathComponent("server.json")
        }
        return OsaurusPaths.resolvePath(new: OsaurusPaths.serverConfigFile(), legacy: "ServerConfiguration.json")
    }

    private static func migrateLegacyImmediateIdleResidencyIfNeeded(
        _ configuration: inout ServerConfiguration
    ) -> Bool {
        let markerURL = idleResidencyWarmDefaultMigrationMarkerURL()
        guard configuration.modelIdleResidencyPolicy == .immediately,
            !FileManager.default.fileExists(atPath: markerURL.path)
        else {
            return false
        }

        configuration.modelIdleResidencyPolicy = .defaultWarm
        OsaurusPaths.ensureExistsSilent(markerURL.deletingLastPathComponent())
        try? Data().write(to: markerURL, options: [.atomic])
        return true
    }

    private static func idleResidencyWarmDefaultMigrationMarkerURL() -> URL {
        configurationFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent(".model-idle-residency-warm-default-migrated")
    }
}
