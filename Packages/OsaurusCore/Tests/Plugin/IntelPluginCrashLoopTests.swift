//
//  IntelPluginCrashLoopTests.swift
//  OsaurusCoreTests
//
//  `W-plugin-reliability` stage 2e-2 (docs/UPSTREAM_SYNC.md, "Plugin
//  loading, step 2"). Upstream's `PluginCrashLoopGuardTests` and
//  `PluginQuarantineUpgradeTests` pin the guard on upstream's
//  `Tools/<id>/<version>/` layout. These pin Intel's parts: the version's
//  `manifest.json` (the capability check and the stamp), the one-time move
//  of Intel's old flat installs into that layout (stage 2g-3), and the
//  agent lifecycle notifications Intel's `AgentManager` now posts.
//

import Foundation
import OsaurusRepository
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelPluginCrashLoopTests {

    /// A fresh tools root (Intel's `OsaurusPaths`, and `ToolsPaths` for
    /// upstream helpers) for the duration of `body`.
    private func withTempToolsRoot<T: Sendable>(
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try await StoragePathsTestLock.shared.run {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-intel-crashloop-\(UUID().uuidString)")
            let toolsRoot = tmp.appendingPathComponent("Tools", isDirectory: true)
            try FileManager.default.createDirectory(at: toolsRoot, withIntermediateDirectories: true)
            let previousOsaurus = OsaurusPaths.overrideRoot
            let previousTools = ToolsPaths.overrideRoot
            OsaurusPaths.overrideRoot = tmp
            ToolsPaths.overrideRoot = tmp
            defer {
                OsaurusPaths.overrideRoot = previousOsaurus
                ToolsPaths.overrideRoot = previousTools
                try? FileManager.default.removeItem(at: tmp)
            }
            return try await body(toolsRoot)
        }
    }

    /// An old Intel flat install: `manifest.json` and a (fake) dylib.
    private func installFlatPlugin(_ id: String, version: String, in toolsRoot: URL) throws {
        let dir = toolsRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = #"{"plugin_id":"\#(id)","name":"Flat","version":"\#(version)","capabilities":{"tools":[]}}"#
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("manifest.json"))
        try Data("not a real dylib".utf8).write(to: dir.appendingPathComponent("plugin.dylib"))
    }

    /// A plugin in upstream's layout, with Intel's `manifest.json` beside it.
    private func installVersionedPlugin(_ id: String, version: String, in toolsRoot: URL) throws {
        let dir = toolsRoot.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = #"{"plugin_id":"\#(id)","name":"Versioned","version":"\#(version)","capabilities":{"tools":[]}}"#
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("manifest.json"))
        try Data("not a real dylib".utf8).write(to: dir.appendingPathComponent("plugin.dylib"))
    }

    @Test func flatInstallsMoveToTheVersionedLayoutOnce() async throws {
        try await withTempToolsRoot { toolsRoot in
            try installFlatPlugin("flat-intel", version: "1.2.0", in: toolsRoot)
            let dataDir = toolsRoot.appendingPathComponent("flat-intel/data", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            try Data("db".utf8).write(to: dataDir.appendingPathComponent("data.db"))
            // Not a plugin install: no dylib.
            try FileManager.default.createDirectory(
                at: toolsRoot.appendingPathComponent("notes", isDirectory: true), withIntermediateDirectories: true)

            #expect(PluginManager.migrateFlatInstalls() == ["flat-intel"])
            let version = toolsRoot.appendingPathComponent("flat-intel/1.2.0", isDirectory: true)
            let fm = FileManager.default
            #expect(fm.fileExists(atPath: version.appendingPathComponent("plugin.dylib").path))
            #expect(fm.fileExists(atPath: version.appendingPathComponent("manifest.json").path))
            #expect(fm.fileExists(atPath: version.appendingPathComponent(".user_consent").path))
            #expect(!fm.fileExists(atPath: toolsRoot.appendingPathComponent("flat-intel/plugin.dylib").path))
            #expect(fm.fileExists(atPath: dataDir.appendingPathComponent("data.db").path), "data stays put")
            #expect(
                try fm.destinationOfSymbolicLink(atPath: toolsRoot.appendingPathComponent("flat-intel/current").path)
                    == "1.2.0")
            let receipt = try JSONDecoder().decode(
                PluginReceipt.self, from: Data(contentsOf: version.appendingPathComponent("receipt.json")))
            #expect(receipt.plugin_id == "flat-intel")
            #expect(receipt.version.description == "1.2.0")
            #expect(receipt.public_keys == nil, "the first signed install pins the key")
            // Upstream's store sees it installed; the scan finds its dylib.
            #expect(InstalledPluginsStore.shared.snapshot().latestVersion(for: "flat-intel")?.description == "1.2.0")
            #expect(PluginManager.scanToolsDirectory().candidates.map(\.pluginId) == ["flat-intel"])
            #expect(PluginManager.migrateFlatInstalls().isEmpty, "idempotent")
        }
    }

    @Test func quarantinedPluginIsHeldBackUntilRetry() async throws {
        try await withTempToolsRoot { toolsRoot in
            try installVersionedPlugin("ver-intel", version: "1.0.0", in: toolsRoot)
            #expect(PluginManager.toolsDirectoryURLs().map(\.lastPathComponent) == ["plugin.dylib"])

            // A crash while loading it left the marker behind.
            try Data("ver-intel".utf8).write(to: toolsRoot.appendingPathComponent(".currently_loading"))
            let scan = PluginManager.scanToolsDirectory()
            #expect(scan.candidates.isEmpty)
            #expect(scan.failures["ver-intel"]?.contains("quarantined") == true)
            #expect(scan.compatible.map(\.pluginId) == ["ver-intel"], "still listed as installed")
            #expect(PluginManager.quarantineEntries().first?.version == "1.0.0")

            PluginManager.removeFromQuarantine("ver-intel")
            #expect(PluginManager.scanToolsDirectory().candidates.map(\.pluginId) == ["ver-intel"])
        }
    }

    @Test func updatingAPluginReleasesItsQuarantine() async throws {
        try await withTempToolsRoot { toolsRoot in
            try installVersionedPlugin("ver-intel", version: "1.0.0", in: toolsRoot)
            try Data("ver-intel".utf8).write(to: toolsRoot.appendingPathComponent(".currently_loading"))
            #expect(PluginManager.scanToolsDirectory().candidates.isEmpty)
            // Same version: stays out.
            #expect(PluginManager.scanToolsDirectory().candidates.isEmpty)

            // The update installs a newer version folder.
            try installVersionedPlugin("ver-intel", version: "1.0.1", in: toolsRoot)
            #expect(PluginManager.installedVersion(forPluginId: "ver-intel") == "1.0.1")
            #expect(PluginManager.scanToolsDirectory().candidates.map(\.pluginId) == ["ver-intel"])
            #expect(PluginManager.quarantinedPluginIds().isEmpty)
        }
    }

    @Test func appleSiliconOnlyManifestIsSkipped() async throws {
        try await withTempToolsRoot { toolsRoot in
            let dir = toolsRoot.appendingPathComponent("arm-only/1.0.0", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(#"{"plugin_id":"arm-only","name":"Arm","version":"1.0.0","host_capabilities_required":["apple.silicon.only.test"]}"#.utf8)
                .write(to: dir.appendingPathComponent("manifest.json"))
            try Data("x".utf8).write(to: dir.appendingPathComponent("plugin.dylib"))
            let scan = PluginManager.scanToolsDirectory()
            #expect(scan.candidates.isEmpty)
            #expect(scan.incompatible.map(\.pluginId) == ["arm-only"])
        }
    }

    @MainActor
    @Test func registryIsTheIntelPluginRepo() {
        _ = PluginRepositoryService.shared
        #expect(CentralRepositoryManager.shared.central.url == "https://github.com/reneezmp/osaurus-intel-plugins.git")
        #expect(CentralRepositoryManager.shared.central.branch == "main")
        #expect(CPUArch.host == .arm64 || CPUArch.host == .x86_64)
    }

    @Test func pluginIdComesFromBothLayouts() {
        let tools = URL(fileURLWithPath: "/tmp/x/Tools", isDirectory: true)
        #expect(PluginManager.extractPluginId(from: tools.appendingPathComponent("time-intel/plugin.dylib")) == "time-intel")
        #expect(
            PluginManager.extractPluginId(from: tools.appendingPathComponent("osaurus.time/1.2.0/plugin.dylib"))
                == "osaurus.time")
    }

    @Test func retiredIntelSearchPluginIsSuperseded() {
        #expect(PluginManager.supersededPluginIds.contains("search-intel"))
        #expect(PluginManager.nativeSettingsTab(forSupersededPlugin: "search-intel") == .search)
        let tools = URL(fileURLWithPath: "/tmp/x/Tools", isDirectory: true)
        let result = PluginManager.excludeSupersededPlugins(
            urls: [
                tools.appendingPathComponent("search-intel/plugin.dylib"),
                tools.appendingPathComponent("time-intel/plugin.dylib"),
            ],
            failures: ["search-intel": "boom"]
        )
        #expect(result.urls.map { $0.deletingLastPathComponent().lastPathComponent } == ["time-intel"])
        #expect(result.failures.isEmpty)
    }

    /// Upstream's `AgentManagerLifecycleNotificationTests` also covers
    /// legacy-backup restore, which Intel's `AgentManager` doesn't have.
    @MainActor
    @Test func addingAndDeletingAnAgentIsAnnounced() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Agent(
                name: "Lifecycle-\(UUID().uuidString.prefix(6))",
                systemPrompt: "Test identity",
                autonomousExec: AutonomousExecConfig(enabled: false)
            )
            let added = NotificationRecorder(.agentAdded)
            let removed = NotificationRecorder(.agentRemoved)
            AgentManager.shared.add(agent)
            #expect(await added.ids() == [agent.id])
            #expect(await AgentManager.shared.delete(id: agent.id).deleted)
            #expect(await removed.ids() == [agent.id])
        }
    }
}

/// Collects `userInfo["agentId"]` from one notification name. Intel's
/// `AgentManager.delete` is not main-actor isolated, so `.agentRemoved` can
/// arrive on any thread.
private final class NotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [UUID] = []
    private var token: NSObjectProtocol?

    init(_ name: Notification.Name) {
        token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) {
            [weak self] note in
            guard let self, let id = note.userInfo?["agentId"] as? UUID else { return }
            self.lock.withLock { self.received.append(id) }
        }
    }

    func ids() async -> [UUID] {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        return lock.withLock { received }
    }
}
