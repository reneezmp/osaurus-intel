//
//  IntelPluginExecution.swift
//  OsaurusCore — Intel fork
//
//  What is left of Intel's own plugin host. Until `W-plugin-reliability`
//  stage 2e this file held a slim dylib loader (`IntelPluginLoader`,
//  `IntelLoadedPlugin`, `IntelPluginTool`), its own copy of the plugin ABI
//  structs and Intel's config / log callbacks. Stages 2a–2d moved the host
//  callbacks onto upstream's `PluginHostContext`; stage 2e moved the rest:
//  plugins load as upstream's `ExternalPlugin` (`Models/Plugin/
//  ExternalPlugin.swift`, which also carries the ABI mirror), their tools
//  are upstream's `ExternalTool`, and `PluginHostContext.buildHostAPI()` is
//  upstream's table (`IntelPluginHostContext.swift`).
//
//  Intel-only, still here:
//  - `IntelPluginConfigMigration`: plugin config lived in a plaintext file
//    until 2026-10-10; this moves any values left in it into the Keychain;
//  - `intelPluginConfigGet` / `intelPluginConfigSet`: the Plugins tab's
//    global values (the Default agent's Keychain namespace), for Intel's
//    config sheet until upstream's `PluginConfigView` replaces it.
//

#if OSAURUS_INTEL

import Foundation
import os

private let intelPluginLog = Logger(subsystem: "com.osaurus.intel", category: "plugin-host")

// MARK: - Plugins tab values

// Explicit-plugin config access (the settings UI / PluginManager — not the
// plugin's own `config_get`): the Plugins tab's global defaults, i.e. the
// Default agent's namespace, the same place upstream's secrets sheet writes.
func intelPluginConfigGet(pluginId: String, key: String) -> String? {
    ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: Agent.defaultId)
}

func intelPluginConfigSet(pluginId: String, key: String, value: String) {
    if value.isEmpty {
        ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: Agent.defaultId)
    } else {
        ToolSecretsKeychain.saveSecret(value, id: key, for: pluginId, agentId: Agent.defaultId)
    }
}

// MARK: - Legacy config file migration

enum IntelPluginConfigMigration {
    static let separator = "\u{1}"

    static func legacyFileURL() -> URL {
        OsaurusPaths.root()
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent(".intel-plugin-config.json")
    }

    /// Move every `pluginId<U+0001>key` value from the legacy plaintext file
    /// into the Default agent's Keychain namespace (where the Plugins tab
    /// writes). The file is deleted only after every value reads back from
    /// the Keychain, so an interrupted or refused write never loses one;
    /// it stays for the next launch otherwise. Returns how many moved.
    @discardableResult
    static func runIfNeeded() -> Int {
        let url = legacyFileURL()
        guard let data = try? Data(contentsOf: url) else { return 0 }
        guard let stored = try? JSONDecoder().decode([String: String].self, from: data) else {
            intelPluginLog.error("plugin config file unreadable; left in place")
            return 0
        }
        var moved = 0
        var allMoved = true
        for (scopedKey, value) in stored {
            let parts = scopedKey.components(separatedBy: separator)
            // `_shared` held values set outside any plugin call: no owner.
            guard parts.count == 2, !parts[0].isEmpty, parts[0] != "_shared", !parts[1].isEmpty else { continue }
            let (pluginId, key) = (parts[0], parts[1])
            if ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: Agent.defaultId) == value {
                moved += 1
                continue
            }
            ToolSecretsKeychain.saveSecret(value, id: key, for: pluginId, agentId: Agent.defaultId)
            if ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: Agent.defaultId) == value {
                moved += 1
            } else {
                allMoved = false
            }
        }
        if allMoved {
            try? FileManager.default.removeItem(at: url)
        } else {
            intelPluginLog.error("plugin config: some values could not be stored in the Keychain; file kept")
        }
        return moved
    }
}

#endif
