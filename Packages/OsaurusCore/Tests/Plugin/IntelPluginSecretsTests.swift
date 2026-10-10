//
//  IntelPluginSecretsTests.swift
//  osaurusTests
//
//  W-plugin-reliability stage 1 (2026-10-10): Intel's plugin host keeps
//  config in `ToolSecretsKeychain` under upstream's resolution policy
//  (#2061), injects `_secrets` / `_context` like upstream's `ExternalTool`,
//  validates the ABI table and manifest at load, and migrates the old
//  plaintext config file. `ToolSecretsKeychain` uses its in-memory store in
//  test processes, so nothing here reaches the Keychain.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelPluginSecretsTests {
    private static func freshPluginId() -> String { "intel.tests.\(UUID().uuidString)" }

    // MARK: - Resolution policy (upstream #2061)

    @Test func resolvedSecretPrefersTheAgentThenFallsBackToDefault() {
        let pluginId = Self.freshPluginId()
        let agent = UUID()
        defer { ToolSecretsKeychain.deleteAllSecretsAllAgents(for: pluginId) }

        ToolSecretsKeychain.saveSecret("global", id: "api_key", for: pluginId, agentId: Agent.defaultId)
        #expect(ToolSecretsKeychain.resolvedSecret(id: "api_key", for: pluginId, agentId: agent) == "global")
        #expect(ToolSecretsKeychain.hasResolvedSecret(id: "api_key", for: pluginId, agentId: agent))

        ToolSecretsKeychain.saveSecret("mine", id: "api_key", for: pluginId, agentId: agent)
        #expect(ToolSecretsKeychain.resolvedSecret(id: "api_key", for: pluginId, agentId: agent) == "mine")

        ToolSecretsKeychain.deleteSecret(id: "api_key", for: pluginId, agentId: Agent.defaultId)
        #expect(ToolSecretsKeychain.resolvedSecret(id: "api_key", for: pluginId, agentId: Agent.defaultId) == nil)
        #expect(!ToolSecretsKeychain.hasResolvedSecret(id: "api_key", for: pluginId, agentId: Agent.defaultId))
    }

    @Test func requiredSecretSetOnTheDefaultAgentCountsForEveryAgent() {
        let pluginId = Self.freshPluginId()
        defer { ToolSecretsKeychain.deleteAllSecretsAllAgents(for: pluginId) }
        let specs = [PluginManifest.SecretSpec(id: "api_key", label: "API Key")]
        #expect(!ToolSecretsKeychain.hasAllRequiredSecrets(specs: specs, for: pluginId, agentId: UUID()))

        ToolSecretsKeychain.saveSecret("global", id: "api_key", for: pluginId, agentId: Agent.defaultId)
        #expect(ToolSecretsKeychain.hasAllRequiredSecrets(specs: specs, for: pluginId, agentId: UUID()))
        #expect(ToolSecretsKeychain.getMissingRequiredSecrets(specs: specs, for: pluginId, agentId: UUID()).isEmpty)
    }

    // MARK: - Host config callbacks (upstream PluginHostAPI.config*)

    @Test func hostConfigIsScopedToTheCallingAgent() {
        let pluginId = Self.freshPluginId()
        let agent = UUID()
        defer { ToolSecretsKeychain.deleteAllSecretsAllAgents(for: pluginId) }

        intelHostConfigSetValue(pluginId: pluginId, agentId: agent, key: "token", value: "abc")
        #expect(intelHostConfigGetValue(pluginId: pluginId, agentId: agent, key: "token") == "abc")
        // Another agent doesn't see it (no Default-agent value to fall back to).
        #expect(intelHostConfigGetValue(pluginId: pluginId, agentId: UUID(), key: "token") == nil)

        intelHostConfigDeleteValue(pluginId: pluginId, agentId: agent, key: "token")
        #expect(intelHostConfigGetValue(pluginId: pluginId, agentId: agent, key: "token") == nil)
    }

    @Test func hostConfigWithoutAnAgentNeverTouchesTheDefaultNamespace() {
        let pluginId = Self.freshPluginId()
        defer { ToolSecretsKeychain.deleteAllSecretsAllAgents(for: pluginId) }
        intelPluginConfigSet(pluginId: pluginId, key: "token", value: "global")

        #expect(intelHostConfigGetValue(pluginId: pluginId, agentId: nil, key: "token") == nil)
        intelHostConfigSetValue(pluginId: pluginId, agentId: nil, key: "token", value: "overwrite")
        intelHostConfigDeleteValue(pluginId: pluginId, agentId: nil, key: "token")
        #expect(intelPluginConfigGet(pluginId: pluginId, key: "token") == "global")
    }

    @Test func hostConfigRejectsOversizedValues() {
        let pluginId = Self.freshPluginId()
        let agent = UUID()
        defer { ToolSecretsKeychain.deleteAllSecretsAllAgents(for: pluginId) }
        let big = String(repeating: "x", count: intelPluginConfigValueMaxBytes + 1)
        intelHostConfigSetValue(pluginId: pluginId, agentId: agent, key: "blob", value: big)
        #expect(intelHostConfigGetValue(pluginId: pluginId, agentId: agent, key: "blob") == nil)
    }

    @Test func settingsSheetWritesTheDefaultAgentNamespace() {
        let pluginId = Self.freshPluginId()
        defer { ToolSecretsKeychain.deleteAllSecretsAllAgents(for: pluginId) }
        intelPluginConfigSet(pluginId: pluginId, key: "region", value: "eu")
        #expect(ToolSecretsKeychain.getSecret(id: "region", for: pluginId, agentId: Agent.defaultId) == "eu")
        intelPluginConfigSet(pluginId: pluginId, key: "region", value: "")
        #expect(ToolSecretsKeychain.getSecret(id: "region", for: pluginId, agentId: Agent.defaultId) == nil)
    }

    // MARK: - Payload injection (upstream ExternalTool)

    @Test func secretsAreInjectedForANamedAgentOnly() throws {
        let pluginId = Self.freshPluginId()
        let agent = UUID()
        defer { ToolSecretsKeychain.deleteAllSecretsAllAgents(for: pluginId) }
        ToolSecretsKeychain.saveSecret("global", id: "a", for: pluginId, agentId: Agent.defaultId)
        ToolSecretsKeychain.saveSecret("mine", id: "b", for: pluginId, agentId: agent)

        let injected = IntelPluginTool.injectSecrets(into: #"{"q":1}"#, pluginId: pluginId, agentId: agent)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(injected.utf8)) as? [String: Any])
        #expect(object["q"] as? Int == 1)
        #expect(object["_secrets"] as? [String: String] == ["a": "global", "b": "mine"])

        // Anonymous and Default-agent calls get nothing (upstream).
        #expect(IntelPluginTool.injectSecrets(into: #"{"q":1}"#, pluginId: pluginId, agentId: nil) == #"{"q":1}"#)
        #expect(
            IntelPluginTool.injectSecrets(into: #"{"q":1}"#, pluginId: pluginId, agentId: Agent.defaultId)
                == #"{"q":1}"#)
        // A non-object payload is passed through untouched.
        #expect(IntelPluginTool.injectSecrets(into: "[1]", pluginId: pluginId, agentId: agent) == "[1]")
    }

    @Test func folderContextCarriesTheWorkingDirectory() throws {
        let folder = URL(fileURLWithPath: "/tmp/intel-plugin-folder", isDirectory: true)
        let injected = IntelPluginTool.injectFolderContext(into: "{}", folderRoot: folder)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(injected.utf8)) as? [String: Any])
        #expect((object["_context"] as? [String: String])?["working_directory"] == folder.path)
        #expect(IntelPluginTool.injectFolderContext(into: "{}", folderRoot: nil) == "{}")
    }

    // MARK: - Load validation (upstream #2061)

    @Test func incompleteAbiTablesAreRejected() {
        let empty = osr_plugin_api(
            free_string: nil, init: nil, destroy: nil, get_manifest: nil, invoke: nil,
            version: 2, handle_route: nil, on_config_changed: nil, on_task_event: nil)
        let message = IntelPluginLoader.abiTableValidationFailure(empty)
        #expect(message?.contains("free_string, init, destroy, get_manifest, invoke") == true)
    }

    @Test func manifestIdentityAndToolIdsAreChecked() {
        func failure(_ json: String) -> String? {
            IntelPluginLoader.manifestValidationFailure(manifestJSON: json, directoryId: "time-intel")
        }
        #expect(failure(#"{"plugin_id":"time-intel","capabilities":{"tools":[{"id":"get_current_time"}]}}"#) == nil)
        #expect(failure(#"{"capabilities":{"tools":[{"id":"a"}]}}"#) == nil)
        #expect(failure(#"{"plugin_id":"other","capabilities":{"tools":[]}}"#)?.contains("installed as 'time-intel'") == true)
        #expect(failure(#"{"plugin_id":"time-intel","capabilities":{"tools":[{"id":"a"},{"id":"a"}]}}"#)?.contains("duplicate tool id 'a'") == true)
        #expect(failure(#"{"plugin_id":"time-intel","capabilities":{"tools":[{"id":"  "}]}}"#)?.contains("empty id") == true)
    }

    // MARK: - Plaintext file migration

    @Test func legacyPlaintextConfigMovesToTheKeychainAndIsDeleted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intel-plugin-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Tools", isDirectory: true), withIntermediateDirectories: true)
        OsaurusPaths.overrideRoot = root
        defer {
            OsaurusPaths.overrideRoot = nil
            try? FileManager.default.removeItem(at: root)
        }
        let pluginId = Self.freshPluginId()
        defer { ToolSecretsKeychain.deleteAllSecretsAllAgents(for: pluginId) }

        let legacy: [String: String] = [
            "\(pluginId)\u{1}api_key": "secret-value",
            "\(pluginId)\u{1}region": "eu",
            "_shared\u{1}orphan": "dropped",
        ]
        let url = IntelPluginConfigMigration.legacyFileURL()
        try JSONEncoder().encode(legacy).write(to: url)

        #expect(IntelPluginConfigMigration.runIfNeeded() == 2)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(intelPluginConfigGet(pluginId: pluginId, key: "api_key") == "secret-value")
        #expect(intelPluginConfigGet(pluginId: pluginId, key: "region") == "eu")
        // Nothing to do on the next launch.
        #expect(IntelPluginConfigMigration.runIfNeeded() == 0)
    }
}
