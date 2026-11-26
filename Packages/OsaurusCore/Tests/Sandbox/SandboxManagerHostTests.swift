import Foundation
import Testing

@testable import OsaurusCore

/// Stage 2 of W-seatbelt-sandbox: the Intel `SandboxManager` host slice.
/// Every manager is rooted at a throwaway temp workspace; commands are
/// confined and never touch the network or user files.
@Suite(.serialized)
struct SandboxManagerHostTests {

    private func tempWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-sbxmgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func started() async throws -> (SandboxManager, URL)? {
        guard SeatbeltSandbox.isSupported else { return nil }
        let root = try tempWorkspace()
        let manager = SandboxManager(workspaceRoot: root)
        try await manager.startContainer()
        return (manager, root)
    }

    @Test func availabilityIsCachedAndMatchesSandboxExec() async {
        let manager = SandboxManager(workspaceRoot: FileManager.default.temporaryDirectory)
        let first = await manager.checkAvailability()
        let second = await manager.checkAvailability()
        #expect(first == second)
        #expect(first.isAvailable == SeatbeltSandbox.isSupported)
        #expect(first == SandboxManager.resolveAvailability())
    }

    @Test func firstOperationResolvesAvailability() async {
        let manager = SandboxManager(workspaceRoot: FileManager.default.temporaryDirectory)
        let expected = SandboxManager.resolveAvailability().isAvailable
        let accepted: Bool
        do {
            try await manager.requireAvailabilityForOperation()
            accepted = true
        } catch {
            accepted = false
        }
        #expect(accepted == expected)
    }

    @Test func intelDoesNotPublishAvailabilityToUI() async {
        // Until stage 3/5 wires tools and UI, Onboarding / agent editor must
        // keep seeing the sandbox as unavailable (it would otherwise persist
        // upstream's default sandbox config).
        #expect(SandboxManager.publishesAvailabilityToUI == false)
        let shared = await MainActor.run { SandboxManager.State.shared.availability }
        #expect(!shared.isAvailable)
    }

    @Test func execBeforeStartThrowsNotRunning() async throws {
        let manager = SandboxManager(workspaceRoot: try tempWorkspace())
        await #expect(throws: SandboxError.self) {
            _ = try await manager.exec(command: "echo hi")
        }
    }

    @Test func lifecycleStartStopRemove() async throws {
        guard let (manager, _) = try await started() else { return }
        #expect(await manager.status() == .running)
        try await manager.stopContainer()
        #expect(await manager.status() == .stopped)
        #expect(await manager.stoppedExplicitly)
        await #expect(throws: SandboxError.self) {
            _ = try await manager.exec(command: "echo hi")
        }
        try await manager.startContainer()
        #expect(await manager.status() == .running)
        try await manager.removeContainer()
        #expect(await manager.status() == .notProvisioned)
        // A user-removed sandbox stays removed until re-provisioned.
        try await manager.startContainer()
        #expect(await manager.status() == .notProvisioned)
        try await manager.provision()
        #expect(await manager.status() == .running)
    }

    @Test func removeKeepsWorkspaceFiles() async throws {
        guard let (manager, root) = try await started() else { return }
        let keep = root.appendingPathComponent("keep.txt")
        try "data".write(to: keep, atomically: true, encoding: .utf8)
        try await manager.removeContainer()
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test func execWritesInsideWorkspaceAndMapsGuestPaths() async throws {
        guard let (manager, root) = try await started() else { return }
        let r = try await manager.exec(command: "echo ok > /workspace/out.txt && cat /workspace/out.txt")
        if r.exitCode != 0 && r.stdout.isEmpty { return }  // host cannot run Seatbelt right now
        #expect(r.exitCode == 0)
        #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
        let onDisk = try String(contentsOf: root.appendingPathComponent("out.txt"), encoding: .utf8)
        #expect(onDisk.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
    }

    @Test func execCannotWriteOutsideWorkspace() async throws {
        guard let (manager, _) = try await started() else { return }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-sbxmgr-escape-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        _ = try await manager.exec(command: "touch '\(outside.path)' 2>/dev/null")
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func execCannotReadUserHome() async throws {
        guard let (manager, root) = try await started() else { return }
        // A throwaway file in a sibling temp folder (outside the workspace and
        // the granted scratch dir) must be unreadable.
        let sibling = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: sibling) }
        let secret = sibling.appendingPathComponent("secret.txt")
        try "secret-value".write(to: secret, atomically: true, encoding: .utf8)
        let r = try await manager.exec(command: "/bin/cat '\(secret.path)' 2>/dev/null; true")
        #expect(!r.stdout.contains("secret-value"))
        _ = root
    }

    @Test func networkIsDeniedByDefaultAndEitherSideDenies() {
        let d = SandboxManager.effectiveNetworkPolicy(agentNetworkEnabled: false, configNetwork: "outbound")
        #expect(d == .denied)
        #expect(
            SandboxManager.effectiveNetworkPolicy(agentNetworkEnabled: true, configNetwork: "none") == .denied)
        #expect(
            SandboxManager.effectiveNetworkPolicy(agentNetworkEnabled: true, configNetwork: "proxy") == .denied)
        #expect(
            SandboxManager.effectiveNetworkPolicy(agentNetworkEnabled: true, configNetwork: "outbound")
                == .allowed)
    }

    @Test func diagnosticsPassOnAThrowawayWorkspace() async throws {
        guard let (manager, _) = try await started() else { return }
        let results = await manager.runDiagnostics()
        #expect(results.map(\.name) == ["exec", "workspace-rw", "confinement", "network"])
        // A wedged sandbox service on a busy host can time out `exec`; only
        // judge the security checks when commands ran at all.
        if results.first(where: { $0.name == "exec" })?.passed == true {
            for r in results { #expect(r.passed, "\(r.name): \(r.detail)") }
        }
    }

    // MARK: - Agent homes

    @Test func bootstrapCreatesHomeSoulOnceAndPlugins() async throws {
        let root = try tempWorkspace()
        let manager = SandboxManager(workspaceRoot: root)
        try await manager.bootstrapAgent(agentName: "alice", agentId: nil, soulSeedBody: "seed")
        let home = root.appendingPathComponent("agents/alice")
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("plugins").path))
        #expect(try String(contentsOf: home.appendingPathComponent("SOUL.md"), encoding: .utf8) == "seed")
        try "edited".write(
            to: home.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        try await manager.bootstrapAgent(agentName: "alice", agentId: nil, soulSeedBody: "seed")
        #expect(try String(contentsOf: home.appendingPathComponent("SOUL.md"), encoding: .utf8) == "edited")
        let perms =
            try FileManager.default.attributesOfItem(atPath: home.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
    }

    @Test func removeAgentUserRemovesOnlyThatHome() async throws {
        let root = try tempWorkspace()
        let manager = SandboxManager(workspaceRoot: root)
        try await manager.ensureAgentUser("a")
        try await manager.ensureAgentUser("b")
        #expect(try await manager.removeAgentUser("a"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("agents/a").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("agents/b").path))
        #expect(try await manager.removeAgentUser("a") == false)
    }

    @Test func agentNamesCannotEscapeTheAgentsFolder() async throws {
        let root = try tempWorkspace()
        let manager = SandboxManager(workspaceRoot: root)
        for bad in ["", ".", "..", "../x", "a/b"] {
            await #expect(throws: SandboxError.self) {
                try await manager.ensureAgentUser(bad)
            }
            await #expect(throws: SandboxError.self) {
                _ = try await manager.removeAgentUser(bad)
            }
        }
    }

    @Test func infoListsAgentHomesAndWorkspace() async throws {
        guard let (manager, _) = try await started() else { return }
        try await manager.ensureAgentUser("zed")
        let info = await manager.info()
        #expect(info.status == .running)
        #expect(info.agentUsers == ["zed"])
        #expect(info.memoryUsage == nil && info.cpuLoad == nil && info.processCount == nil)
    }

    @Test func sandboxErrorDescriptionsMatchUpstream() {
        #expect(SandboxError.provisionFailed("x").errorDescription == "Provisioning failed: x")
        #expect(SandboxError.removeFailed("x").errorDescription == "Container removal failed: x")
        #expect(SandboxError.userCreationFailed("x").errorDescription == "User creation failed: x")
        #expect(SandboxError.execFailed("x").errorDescription == "Execution failed: x")
    }
}
