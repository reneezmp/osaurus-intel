import Foundation
import Testing

@testable import OsaurusCore

/// The agent home is writable by the sandbox, so the app's own reads of files
/// in it (SOUL.md) must not follow a planted symlink or leave the agent's
/// folder; and deleting an agent drops only that agent's plugin record.
@Suite(.serialized)
struct IntelSandboxSoulTests {

    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-soul-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func home(_ workspace: URL, _ name: String) throws -> URL {
        let dir = workspace.appendingPathComponent("agents/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aRegularSoulFileIsRendered() throws {
        let workspace = try temp()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "I prefer short answers.".write(
            to: try home(workspace, "a").appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        #expect(IntelSandboxPrompt.soul(agentName: "a", workspace: workspace).contains("I prefer short answers."))
    }

    @Test func aSymlinkedSoulFileIsRefused() throws {
        let workspace = try temp()
        let outside = try temp()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outside)
        }
        let secret = outside.appendingPathComponent("secret.txt")
        try "OUTSIDE-SECRET".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: try home(workspace, "a").appendingPathComponent("SOUL.md"), withDestinationURL: secret)
        let prompt = IntelSandboxPrompt.soul(agentName: "a", workspace: workspace)
        #expect(prompt.isEmpty)
        #expect(!prompt.contains("OUTSIDE-SECRET"))
    }

    @Test func aSymlinkedAgentFolderIsRefused() throws {
        let workspace = try temp()
        let outside = try temp()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outside)
        }
        try "OUTSIDE-SECRET".write(
            to: outside.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("agents/a"), withDestinationURL: outside)
        #expect(IntelSandboxPrompt.soul(agentName: "a", workspace: workspace).isEmpty)
    }

    @Test func dotDotNamesAndFilesAreRefused() throws {
        let workspace = try temp()
        defer { try? FileManager.default.removeItem(at: workspace) }
        // A SOUL.md one level above the agents folder.
        try "OUTSIDE-SECRET".write(
            to: workspace.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        _ = try home(workspace, "a")
        for name in ["..", "../a", "a/..", "", "."] {
            #expect(IntelSandboxPrompt.soul(agentName: name, workspace: workspace).isEmpty, "\(name)")
        }
        #expect(
            IntelSandboxPrompt.readConfined(workspace: workspace, agentName: "a", file: "../SOUL.md", maxBytes: 100)
                == nil)
    }

    @Test func theReadIsCapped() throws {
        let workspace = try temp()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let big = String(repeating: "line of notes\n", count: 5_000) + "BEYOND-THE-CAP"
        try big.write(
            to: try home(workspace, "a").appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        let prompt = IntelSandboxPrompt.soul(agentName: "a", workspace: workspace)
        #expect(!prompt.isEmpty)
        #expect(!prompt.contains("BEYOND-THE-CAP"))
        #expect(prompt.utf8.count < IntelSandboxPrompt.soulMaxBytes + 2_000)
    }

    @Test func deletingAnAgentDropsOnlyThatAgentsPluginRecord() async throws {
        guard SeatbeltSandbox.isSupported else { return }
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SandboxManager(workspaceRoot: root)
        try await manager.startContainer()
        let plugins = SandboxPluginManager(storeRoot: root.appendingPathComponent("store"), manager: manager)
        let a = UUID().uuidString
        let b = UUID().uuidString
        let plugin = SandboxPlugin(
            name: "demo", description: "d",
            tools: [SandboxToolSpec(id: "t", description: "T", run: "true")])
        try await plugins.install(plugin: plugin, for: a, networkEnabled: false)
        try await plugins.install(plugin: plugin, for: b, networkEnabled: false)
        #expect(plugins.removeAgentState(for: a))
        #expect(plugins.plugins(for: a).isEmpty)
        #expect(plugins.plugin(id: "demo", for: b)?.status == .ready)
        let reopened = SandboxPluginManager(storeRoot: root.appendingPathComponent("store"), manager: manager)
        #expect(reopened.plugins(for: a).isEmpty)
        #expect(reopened.plugin(id: "demo", for: b)?.status == .ready)
    }
}
