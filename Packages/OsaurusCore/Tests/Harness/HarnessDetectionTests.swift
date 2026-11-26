//
//  HarnessDetectionTests.swift
//  osaurusTests
//
//  Runtime detection: the Mach-O architecture check (Intel has no Rosetta),
//  command resolution with the chat environment, and the Test-button probe.
//  Nothing here starts a real harness process; the probe's collaborators are
//  fakes and the "binaries" are files that are never executed.
//

import Foundation
import Testing

@testable import OsaurusCore

private enum Header {
    static func thin(cpu: UInt32) -> Data {
        var data = Data([0xCF, 0xFA, 0xED, 0xFE])  // MH_MAGIC_64, little-endian
        withUnsafeBytes(of: cpu.littleEndian) { data.append(contentsOf: $0) }
        data.append(Data(repeating: 0, count: 24))
        return data
    }

    static func fat(cpus: [UInt32], sixtyFourBit: Bool = false) -> Data {
        var data = Data(sixtyFourBit ? [0xCA, 0xFE, 0xBA, 0xBF] : [0xCA, 0xFE, 0xBA, 0xBE])
        withUnsafeBytes(of: UInt32(cpus.count).bigEndian) { data.append(contentsOf: $0) }
        for cpu in cpus {
            withUnsafeBytes(of: cpu.bigEndian) { data.append(contentsOf: $0) }
            data.append(Data(repeating: 0, count: (sixtyFourBit ? 32 : 20) - 4))
        }
        return data
    }

    static let x86_64: UInt32 = 0x0100_0007
    static let arm64: UInt32 = 0x0100_000C
}

@Suite("Harness binary architecture")
struct HarnessBinaryArchitectureTests {

    @Test func readsThinAndFatHeaders() {
        #expect(HarnessBinaryArchitecture.slices(inHeader: Header.thin(cpu: Header.x86_64)) == ["x86_64"])
        #expect(HarnessBinaryArchitecture.slices(inHeader: Header.thin(cpu: Header.arm64)) == ["arm64"])
        #expect(
            HarnessBinaryArchitecture.slices(inHeader: Header.fat(cpus: [Header.x86_64, Header.arm64]))
                == ["x86_64", "arm64"]
        )
        #expect(
            HarnessBinaryArchitecture.slices(inHeader: Header.fat(cpus: [Header.arm64], sixtyFourBit: true))
                == ["arm64"]
        )
    }

    @Test func scriptsAndJunkAreNotMachO() {
        #expect(HarnessBinaryArchitecture.slices(inHeader: Data("#!/usr/bin/env node\n".utf8)) == nil)
        #expect(HarnessBinaryArchitecture.slices(inHeader: Data()) == nil)
        // A Java class file shares the fat magic but not a plausible slice count.
        #expect(HarnessBinaryArchitecture.slices(inHeader: Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 52, 0, 0, 0, 0])) == nil)
    }

    @Test func anIntelMacNeedsAnX86Slice() {
        let armOnly = Header.thin(cpu: Header.arm64)
        #expect(
            HarnessBinaryArchitecture.verdict(forHeader: armOnly, host: .x86_64) == .incompatible(slices: ["arm64"])
        )
        #expect(
            HarnessBinaryArchitecture.verdict(forHeader: Header.thin(cpu: Header.x86_64), host: .x86_64)
                == .compatible(slices: ["x86_64"])
        )
        let universal = Header.fat(cpus: [Header.x86_64, Header.arm64])
        #expect(HarnessBinaryArchitecture.verdict(forHeader: universal, host: .x86_64).isIncompatible == false)
        #expect(HarnessBinaryArchitecture.verdict(forHeader: Data("#!/bin/sh\n".utf8), host: .x86_64) == .notNative)
    }

    @Test func appleSiliconRunsArm64AndAssumesRosettaForX86() {
        #expect(HarnessBinaryArchitecture.verdict(forHeader: Header.thin(cpu: Header.arm64), host: .arm64).isIncompatible == false)
        #expect(HarnessBinaryArchitecture.verdict(forHeader: Header.thin(cpu: Header.x86_64), host: .arm64).isIncompatible == false)
    }

    @Test func readsTheFileAndFollowsSymlinks() throws {
        let dir = try HarnessFixtures.temporaryDirectory("arch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("claude-real")
        try Header.thin(cpu: Header.arm64).write(to: real)
        let link = dir.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(HarnessBinaryArchitecture.verdict(forFileAt: link.path, host: .x86_64) == .incompatible(slices: ["arm64"]))
        #expect(HarnessBinaryArchitecture.verdict(forFileAt: dir.appendingPathComponent("missing").path) == .notNative)
    }

    @Test func theMessageNamesTheCommandAndTheSlices() {
        let intel = HarnessBinaryArchitecture.incompatibleMessage(command: "claude", slices: ["arm64"], host: .x86_64)
        #expect(intel.contains("claude"))
        #expect(intel.contains("arm64"))
    }
}

@Suite("Harness command resolution")
struct HarnessControlCommandTests {

    @Test func childEnvironmentStripsTheReservedVariablesAndKeepsTheRest() {
        let env = HarnessControlCommand.childEnvironment(
            inherited: [
                "PATH": "/usr/bin",
                "CLAUDECODE": "1",
                "OSAURUS_MCP_BRIDGE_GRANT": "old-token",
                "ANTHROPIC_API_KEY": "sk-not-real",
                "HOME": "/Users/x",
            ],
            loginShellEntries: ["/opt/nvm/bin"],
            overlay: ["EXTRA": "1"],
            removing: HarnessEnvironment.alwaysRemoved.union(ClaudeCodeConfiguration.removedEnvironment)
        )
        #expect(env["CLAUDECODE"] == nil)
        #expect(env["OSAURUS_MCP_BRIDGE_GRANT"] == nil)
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["HOME"] == "/Users/x")
        #expect(env["EXTRA"] == "1")
        #expect(env["PATH"]?.hasPrefix("/opt/nvm/bin:/usr/bin") == true, "the login shell's entries lead")
    }

    @Test func resolvesABareNameOnTheLoginShellPathWithoutRunningIt() throws {
        let dir = try HarnessFixtures.temporaryDirectory("resolve")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("osaurus-fake-harness")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let found = HarnessControlCommand.resolve(
            "osaurus-fake-harness",
            overlay: [:],
            removing: [],
            inherited: ["PATH": "/usr/bin"],
            loginShellEntries: [dir.path]
        )
        #expect(found?.executable == tool.path)

        let missing = HarnessControlCommand.resolve(
            "osaurus-no-such-harness",
            overlay: [:],
            removing: [],
            inherited: ["PATH": "/usr/bin"],
            loginShellEntries: [dir.path]
        )
        #expect(missing == nil)
    }

    @Test func anEnvScriptPutsItsInterpreterDirectoryFirst() throws {
        let dir = try HarnessFixtures.temporaryDirectory("shebang")
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["node", "pi"] {
            let url = dir.appendingPathComponent(name)
            try Data((name == "pi" ? "#!/usr/bin/env node\n" : "#!/bin/sh\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let path = HarnessControlCommand.prependingShebangSibling(
            of: dir.appendingPathComponent("pi").path,
            to: "/usr/bin:/bin"
        )
        #expect(path == "\(dir.path):/usr/bin:/bin")
    }
}

@Suite("Harness runtime probe")
struct HarnessRuntimeProbeTests {

    private func fake(
        executable: String? = "/fake/bin/tool",
        state: ClaudeCodeSetupState = .signedOut,
        host: HarnessBinaryArchitecture.Host = .x86_64
    ) -> HarnessRuntimeProbe.Dependencies {
        HarnessRuntimeProbe.Dependencies(
            resolve: { _, _ in
                executable.map { HarnessControlCommand.Resolved(executable: $0, environment: [:]) }
            },
            claudeCodeState: { _, _ in state },
            host: host
        )
    }

    @Test func aMissingCommandFails() async {
        let result = await HarnessRuntimeProbe.run(
            HarnessRuntime(name: "Claude Code", kind: .claudeCode),
            dependencies: fake(executable: nil)
        )
        #expect(result.status == .failed)
        #expect(result.resolvedExecutable == nil)
        #expect(result.message.contains("claude"))
    }

    @Test func claudeCodeStatesMapToProbeStatuses() async {
        let runtime = HarnessRuntime(name: "Claude Code", kind: .claudeCode)
        let signedIn = await HarnessRuntimeProbe.run(
            runtime,
            dependencies: fake(state: .signedIn(ClaudeCodeAuthStatus(loggedIn: true, email: "me@example.com")))
        )
        #expect(signedIn.status == .ready)
        #expect(signedIn.message.contains("me@example.com"))
        #expect(signedIn.resolvedExecutable == "/fake/bin/tool")

        let signedOut = await HarnessRuntimeProbe.run(runtime, dependencies: fake(state: .signedOut))
        #expect(signedOut.status == .needsSetup)

        let old = await HarnessRuntimeProbe.run(runtime, dependencies: fake(state: .statusUnavailable(cliVersion: "1.0.0")))
        #expect(old.status == .needsSetup)
        #expect(old.message.contains("1.0.0"))
    }

    @Test func anArm64OnlyBinaryIsIncompatibleOnIntelAndIsNeverAskedForItsSignIn() async throws {
        let dir = try HarnessFixtures.temporaryDirectory("probe-arch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("claude")
        try Header.thin(cpu: Header.arm64).write(to: binary)

        let asked = AskedFlag()
        let dependencies = HarnessRuntimeProbe.Dependencies(
            resolve: { _, _ in HarnessControlCommand.Resolved(executable: binary.path, environment: [:]) },
            claudeCodeState: { _, _ in
                await asked.set()
                return .signedOut
            },
            host: .x86_64
        )
        for kind in HarnessKind.allCases {
            let result = await HarnessRuntimeProbe.run(
                HarnessRuntime(name: "T", kind: kind, executable: binary.path),
                dependencies: dependencies
            )
            #expect(result.status == .incompatible)
            #expect(result.message.contains("arm64"))
        }
        #expect(await asked.value == false)
    }

    @Test func aPiRuntimeIsOnlyChecked() async {
        let result = await HarnessRuntimeProbe.run(
            HarnessRuntime(name: "Pi", kind: .piRPC),
            dependencies: fake()
        )
        #expect(result.status == .ready)
        #expect(result.message.contains("/fake/bin/tool"))
    }
}

private actor AskedFlag {
    private(set) var value = false
    func set() { value = true }
}
