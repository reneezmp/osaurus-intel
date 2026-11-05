//
//  IntelPluginSecretsTests.swift
//  osaurusTests
//
//  W-plugin-reliability stage 1 (2026-10-10): Intel's plugin host keeps
//  config in `ToolSecretsKeychain` under upstream's resolution policy
//  (#2061) and migrates the old plaintext config file. Since stage 2e the
//  config callbacks are upstream's (`PluginHostContext.configGet` …), tools
//  are upstream's `ExternalTool` (`_secrets` / `_context` injection) and
//  load validation is upstream's (`PluginManager`'s static checks).
//  `ToolSecretsKeychain` uses its in-memory store in test processes, so
//  nothing here reaches the Keychain.
//

import Darwin
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

    /// Runs `body` as the plugin's host callback would: its context, scoped
    /// to `agentId`.
    private func asPlugin<T>(_ pluginId: String, agentId: UUID?, _ body: (PluginHostContext) -> T) throws -> T {
        let ctx = try PluginHostContext(pluginId: pluginId)
        defer { ctx.teardown() }
        return PluginHostContext.withTLSScope(pluginId: pluginId, agentId: agentId) { body(ctx) }
    }

    @Test func hostConfigIsScopedToTheCallingAgent() throws {
        let pluginId = Self.freshPluginId()
        let agent = UUID()
        defer { ToolSecretsKeychain.deleteAllSecretsAllAgents(for: pluginId) }

        try asPlugin(pluginId, agentId: agent) { $0.configSet(key: "token", value: "abc") }
        #expect(try asPlugin(pluginId, agentId: agent) { $0.configGet(key: "token") } == "abc")
        // Another agent doesn't see it (no Default-agent value to fall back to).
        #expect(try asPlugin(pluginId, agentId: UUID()) { $0.configGet(key: "token") } == nil)

        try asPlugin(pluginId, agentId: agent) { $0.configDelete(key: "token") }
        #expect(try asPlugin(pluginId, agentId: agent) { $0.configGet(key: "token") } == nil)
    }

    /// Upstream: a call with no agent, or as the Default agent, is anonymous;
    /// it reads nothing and writes nothing. (Intel's own callback, before
    /// stage 2e, read and wrote the Default agent's namespace for a
    /// Default-agent chat.)
    @Test func hostConfigWithoutANamedAgentNeverTouchesTheDefaultNamespace() throws {
        let pluginId = Self.freshPluginId()
        defer { ToolSecretsKeychain.deleteAllSecretsAllAgents(for: pluginId) }
        intelPluginConfigSet(pluginId: pluginId, key: "token", value: "global")

        for agentId in [nil, Agent.defaultId] {
            #expect(try asPlugin(pluginId, agentId: agentId) { $0.configGet(key: "token") } == nil)
            try asPlugin(pluginId, agentId: agentId) { $0.configSet(key: "token", value: "overwrite") }
            try asPlugin(pluginId, agentId: agentId) { $0.configDelete(key: "token") }
        }
        #expect(intelPluginConfigGet(pluginId: pluginId, key: "token") == "global")
        // A named agent falls back to it.
        #expect(try asPlugin(pluginId, agentId: UUID()) { $0.configGet(key: "token") } == "global")
    }

    @Test func hostConfigRejectsOversizedValues() throws {
        let pluginId = Self.freshPluginId()
        let agent = UUID()
        defer { ToolSecretsKeychain.deleteAllSecretsAllAgents(for: pluginId) }
        let big = String(repeating: "x", count: PluginHostContext.configValueMaxBytes + 1)
        try asPlugin(pluginId, agentId: agent) { $0.configSet(key: "blob", value: big) }
        #expect(try asPlugin(pluginId, agentId: agent) { $0.configGet(key: "blob") } == nil)
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

    /// A tool whose plugin echoes the payload it was invoked with.
    private func echoTool(pluginId: String) throws -> ExternalTool {
        let api = osr_plugin_api(
            free_string: { ptr in free(UnsafeMutableRawPointer(mutating: ptr)) },
            init: { nil },
            destroy: { _ in },
            get_manifest: { _ in nil },
            invoke: { _, _, _, payload in payload.map { UnsafePointer(strdup($0)) } ?? nil },
            version: 2, handle_route: nil, on_config_changed: nil, on_task_event: nil)
        let spec = PluginManifest.ToolSpec(
            id: "echo", description: "echo", parameters: nil, requirements: nil, permission_policy: nil)
        let manifest = PluginManifest(
            plugin_id: pluginId, description: nil,
            capabilities: .init(tools: [spec], routes: nil, config: nil, web: nil, artifact_handler: nil),
            instructions: nil, name: nil, version: nil, license: nil, authors: nil,
            min_macos: nil, min_osaurus: nil, secrets: nil, docs: nil)
        let plugin = ExternalPlugin(
            handle: try #require(dlopen(nil, RTLD_NOW)), api: api,
            ctx: UnsafeMutableRawPointer(bitPattern: 0x1)!, manifest: manifest,
            path: "/tmp/\(pluginId).dylib", abiVersion: 2)
        return ExternalTool(plugin: plugin, spec: spec)
    }

    private func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func secretsAreInjectedForANamedAgentOnly() async throws {
        let pluginId = Self.freshPluginId()
        let agent = UUID()
        defer { ToolSecretsKeychain.deleteAllSecretsAllAgents(for: pluginId) }
        ToolSecretsKeychain.saveSecret("global", id: "a", for: pluginId, agentId: Agent.defaultId)
        ToolSecretsKeychain.saveSecret("mine", id: "b", for: pluginId, agentId: agent)
        let tool = try echoTool(pluginId: pluginId)

        let injected = try await ChatExecutionContext.$currentAgentId.withValue(agent) {
            try await tool.execute(argumentsJSON: #"{"q":1}"#)
        }
        let echoed = try object(injected)
        #expect(echoed["q"] as? Int == 1)
        #expect(echoed["_secrets"] as? [String: String] == ["a": "global", "b": "mine"])

        // Anonymous and Default-agent calls get nothing (upstream).
        #expect(try await tool.execute(argumentsJSON: #"{"q":1}"#) == #"{"q":1}"#)
        let asDefault = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await tool.execute(argumentsJSON: #"{"q":1}"#)
        }
        #expect(asDefault == #"{"q":1}"#)
    }

    @Test func folderContextCarriesTheWorkingDirectory() async throws {
        let folder = URL(fileURLWithPath: "/tmp/intel-plugin-folder", isDirectory: true)
        let tool = try echoTool(pluginId: Self.freshPluginId())
        let injected = try await ChatExecutionContext.$currentFolderRoot.withValue(folder) {
            try await tool.execute(argumentsJSON: "{}")
        }
        #expect((try object(injected)["_context"] as? [String: String])?["working_directory"] == folder.path)
        #expect(try await tool.execute(argumentsJSON: "{}") == "{}")
    }

    /// Upstream's default: a plugin tool asks before it runs unless its
    /// manifest says otherwise. (Intel's own wrapper, before stage 2e, ran
    /// every plugin tool without asking.)
    @Test func pluginToolsAskByDefault() throws {
        let tool = try echoTool(pluginId: Self.freshPluginId())
        #expect(tool.defaultPermissionPolicy == .ask)
    }

    // MARK: - Load validation (upstream #2061)

    @Test func incompleteAbiTablesAreRejected() {
        let empty = osr_plugin_api(
            free_string: nil, init: nil, destroy: nil, get_manifest: nil, invoke: nil,
            version: 2, handle_route: nil, on_config_changed: nil, on_task_event: nil)
        let message = PluginManager.abiTableValidationFailure(empty)
        #expect(message?.contains("free_string, init, destroy, get_manifest, invoke") == true)
    }

    @Test func manifestIdentityIsCheckedAgainstTheFolder() throws {
        func manifest(_ json: String) throws -> PluginManifest {
            try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        }
        let mine = try manifest(#"{"plugin_id":"time-intel","capabilities":{"tools":[]}}"#)
        #expect(PluginManager.manifestIdentityValidationFailure(manifest: mine, directoryId: "time-intel") == nil)
        let other = try manifest(#"{"plugin_id":"other","capabilities":{"tools":[]}}"#)
        #expect(
            PluginManager.manifestIdentityValidationFailure(manifest: other, directoryId: "time-intel")?
                .contains("installed as 'time-intel'") == true)
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
