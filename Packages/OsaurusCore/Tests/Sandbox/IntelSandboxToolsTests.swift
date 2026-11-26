import Foundation
import Testing

@testable import OsaurusCore

/// Stage 3 of W-seatbelt-sandbox: the `sandbox_*` tools on the host backend.
/// Every command runs confined in a throwaway temp workspace; nothing touches
/// `~/.osaurus`, user files, the keychain or the network.
@Suite(.serialized)
struct IntelSandboxToolsTests {

    private struct Env {
        let manager: SandboxManager
        let root: URL
        let context: SandboxToolContext
    }

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-sbxtools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func withEnv(
        maxCommands: Int = 50,
        secrets: [String: String] = [:],
        _ body: @Sendable (Env) async throws -> Void
    ) async throws {
        guard SeatbeltSandbox.isSupported else { return }
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SandboxManager(workspaceRoot: root)
        try await manager.startContainer()
        let agentId = UUID()
        let name = SandboxToolRegistrar.hostAgentName(for: agentId.uuidString)
        let context = SandboxToolContext(
            agentId: agentId,
            agentName: name,
            home: OsaurusPaths.inContainerAgentHome(name),
            config: AutonomousExecConfig(enabled: true, maxCommandsPerTurn: maxCommands)
        )
        let env = Env(manager: manager, root: root, context: context)
        try await SandboxToolContext.$testingManager.withValue(manager) {
            try await SandboxToolContext.$testingContext.withValue(context) {
                try await SandboxExecSecrets.$testingSecrets.withValue(secrets) {
                    try await body(env)
                }
            }
        }
    }

    private func json(_ dict: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: dict), encoding: .utf8)!
    }

    private func payload(_ envelope: String) -> [String: Any]? {
        ToolEnvelope.successPayload(envelope) as? [String: Any]
    }

    // MARK: - Config defaults (owner policy)

    @Test func configDefaultsKeepTheSandboxOffAndNetworkOff() throws {
        #expect(AutonomousExecConfig.default.enabled == false)
        #expect(AutonomousExecConfig.default.sandboxNetworkEnabled == false)
        #expect(AutonomousExecConfig.default.backgroundProcessEnabled == false)
        let decoded = try JSONDecoder().decode(AutonomousExecConfig.self, from: Data("{}".utf8))
        #expect(decoded == AutonomousExecConfig.default)
        // Upstream's agent JSON may carry keys Intel ignores.
        let upstream = try JSONDecoder().decode(
            AutonomousExecConfig.self,
            from: Data(#"{"enabled":true,"sandboxAllowedDomains":["a.com"]}"#.utf8))
        #expect(upstream.enabled)
        #expect(upstream.sandboxNetworkEnabled == false)
    }

    // MARK: - Files

    @Test func writeThenReadRoundTripsAwkwardContent() async throws {
        try await withEnv { _ in
            let content = "line1 'quoted' \"double\" $HOME `tick`\n/workspace/agents/x\nüñí ✓\n"
            let write = await runTool(SandboxWriteFileTool(), ["path": "notes/a.txt", "content": content])
            #expect(ToolEnvelope.isError(write) == false, "\(write)")
            let read = await runTool(SandboxReadFileTool(), ["path": "notes/a.txt"])
            #expect(payload(read)?["content"] as? String == content)
            // append
            _ = await runTool(
                SandboxWriteFileTool(), ["path": "notes/a.txt", "content": "tail\n", "mode": "append"])
            let again = await runTool(SandboxReadFileTool(), ["path": "notes/a.txt"])
            #expect(payload(again)?["content"] as? String == content + "tail\n")
        }
    }

    @Test func largeWriteIsChunkedAndExact() async throws {
        try await withEnv { _ in
            let content = String(repeating: "abcdefghij0123456789\n", count: 20_000)  // ~420 KB
            let write = await runTool(SandboxWriteFileTool(), ["path": "big.txt", "content": content])
            #expect(ToolEnvelope.isError(write) == false, "\(write)")
            let read = await runTool(SandboxReadFileTool(), ["path": "big.txt", "max_chars": 0])
            #expect(payload(read)?["content"] as? String == content)
        }
    }

    @Test func editReplacesOneMatchAndRejectsAmbiguousOrMissing() async throws {
        try await withEnv { _ in
            _ = await runTool(SandboxWriteFileTool(), ["path": "e.txt", "content": "alpha beta alpha\n"])
            let ambiguous = await runTool(
                SandboxWriteFileTool(), ["path": "e.txt", "old_string": "alpha", "new_string": "X"])
            #expect(ToolEnvelope.isError(ambiguous))
            let missing = await runTool(
                SandboxWriteFileTool(), ["path": "e.txt", "old_string": "gamma", "new_string": "X"])
            #expect(ToolEnvelope.isError(missing))
            let unique = await runTool(
                SandboxWriteFileTool(), ["path": "e.txt", "old_string": "beta", "new_string": "B"])
            #expect(ToolEnvelope.isError(unique) == false, "\(unique)")
            let all = await runTool(
                SandboxWriteFileTool(),
                ["path": "e.txt", "old_string": "alpha", "new_string": "A", "replace_all": true])
            #expect(ToolEnvelope.isError(all) == false)
            let read = await runTool(SandboxReadFileTool(), ["path": "e.txt"])
            #expect(payload(read)?["content"] as? String == "A B A\n")
        }
    }

    @Test func searchFindsContentAndFileNames() async throws {
        try await withEnv { _ in
            _ = await runTool(SandboxWriteFileTool(), ["path": "src/one.py", "content": "# TODO fix\nprint(1)\n"])
            _ = await runTool(SandboxWriteFileTool(), ["path": "src/two.txt", "content": "nothing\n"])
            let content = await runTool(SandboxSearchFilesTool(), ["pattern": "TODO|FIXME", "path": "src"])
            #expect((payload(content)?["matches"] as? String)?.contains("one.py") == true, "\(content)")
            let files = await runTool(
                SandboxSearchFilesTool(), ["pattern": "*.py", "target": "files"])
            let matches = payload(files)?["matches"] as? String ?? ""
            #expect(matches.contains("one.py") && !matches.contains("two.txt"))
        }
    }

    @Test func pathsOutsideTheHomeAreRejected() async throws {
        try await withEnv { env in
            let home = env.context.home
            for bad in [
                "../escape.txt", "/etc/passwd", "/Users/someone/file", "\(home)-two/x.txt", "a;b", "a'b",
            ] {
                let result = await runTool(SandboxReadFileTool(), ["path": bad])
                #expect(ToolEnvelope.isError(result), "expected rejection for \(bad)")
            }
            // The shared folder and the home itself are fine.
            let shared = await runTool(
                SandboxWriteFileTool(), ["path": "/workspace/shared/ok.txt", "content": "ok"])
            #expect(ToolEnvelope.isError(shared) == false, "\(shared)")
        }
    }

    // MARK: - Exec

    @Test func execRunsConfinedInTheHome() async throws {
        try await withEnv { env in
            let result = await runTool(SandboxExecTool(), ["command": "echo hello && pwd"])
            let out = payload(result)
            #expect((out?["stdout"] as? String)?.contains("hello") == true, "\(result)")
            #expect(out?["exit_code"] as? Int == 0)
            // The working directory is the agent home on the temp workspace.
            let canonicalRoot = (env.root.path as NSString).resolvingSymlinksInPath
            #expect((out?["stdout"] as? String)?.contains(canonicalRoot) == true)
        }
    }

    @Test func execCannotWriteOutsideTheWorkspace() async throws {
        try await withEnv { _ in
            let outside = try tempRoot()
            defer { try? FileManager.default.removeItem(at: outside) }
            let target = outside.appendingPathComponent("escaped.txt").path
            let result = await runTool(SandboxExecTool(), ["command": "echo pwn > '\(target)'"])
            #expect((payload(result)?["exit_code"] as? Int) != 0, "\(result)")
            #expect(!FileManager.default.fileExists(atPath: target))
        }
    }

    @Test func execCannotReadTheUsersHome() async throws {
        try await withEnv { _ in
            let result = await runTool(SandboxExecTool(), ["command": "ls \"\(NSHomeDirectory())\""])
            #expect((payload(result)?["exit_code"] as? Int) != 0, "\(result)")
        }
    }

    @Test func perTurnCommandLimitApplies() async throws {
        try await withEnv(maxCommands: 2) { _ in
            let first = await runTool(SandboxExecTool(), ["command": "true"])
            let second = await runTool(SandboxExecTool(), ["command": "true"])
            let third = await runTool(SandboxExecTool(), ["command": "true"])
            #expect(ToolEnvelope.isError(first) == false)
            #expect(ToolEnvelope.isError(second) == false)
            #expect(ToolEnvelope.isError(third))
            #expect(ToolEnvelope.failureMessage(third).contains("limit"))
        }
    }

    @Test func storedSecretValuesAreScrubbedFromOutput() async throws {
        try await withEnv(secrets: ["MY_TOKEN": "supersecretvalue123"]) { _ in
            let result = await runTool(SandboxExecTool(), ["command": "echo $MY_TOKEN"])
            let stdout = payload(result)?["stdout"] as? String ?? ""
            #expect(stdout.contains("[REDACTED:MY_TOKEN]"), "\(result)")
            #expect(!stdout.contains("supersecretvalue123"))
        }
    }

    @Test func idleTimeoutStopsASilentCommand() async throws {
        try await withEnv { _ in
            let result = await runTool(SandboxExecTool(), ["command": "sleep 30", "timeout": 1])
            #expect(ToolEnvelope.isError(result), "\(result)")
        }
    }

    @Test func networkOffHintAppearsOnResolveFailure() {
        #expect(SandboxExecTool.looksLikeNetworkFailure("curl: (6) Could not resolve host: example.com"))
        #expect(!SandboxExecTool.looksLikeNetworkFailure("permission denied"))
    }

    // MARK: - Secrets

    @Test func secretSetReturnsOnlyThePromptMarker() async throws {
        try await withEnv { env in
            let result = await runTool(
                SandboxSecretSetTool(),
                ["key": "API_KEY", "description": "d", "instructions": "i"])
            let parsed = SecretPromptParser.parse(result)
            #expect(parsed?.key == "API_KEY")
            #expect(parsed?.agentId == env.context.agentId.uuidString)
            // No `value` argument exists, so a secret can never ride a tool call.
            let schema = SandboxSecretSetTool().parameters
            guard case .object(let root)? = schema, case .object(let props)? = root["properties"] else {
                Issue.record("schema shape")
                return
            }
            #expect(props["value"] == nil)
        }
    }

    // MARK: - Registry gates

    @Test func sandboxToolsAreHiddenFromAgentsThatDidNotOptIn() async throws {
        await MainActor.run { BuiltinSandboxTools.register() }
        defer { Task { @MainActor in ToolRegistry.shared.unregisterAllBuiltinSandboxTools() } }
        let registry = ToolRegistry.shared
        #expect(registry.builtInSandboxToolNames.contains("sandbox_exec"))
        for agent in [nil, Agent.defaultId, UUID()] {
            let names = Set(registry.openAISpecs(for: agent).map(\.function.name))
            #expect(names.isDisjoint(with: BuiltinSandboxTools.allToolNames), "leaked to \(String(describing: agent))")
        }
        #expect(
            Set(registry.openAISpecs(named: ["sandbox_exec", "sandbox_read_file"]).map(\.function.name)).isEmpty)
        // Not callable either, from any surface, without the agent's opt-in.
        let stranger = UUID()
        let denied = try await ChatExecutionContext.$currentAgentId.withValue(stranger) {
            try await registry.execute(name: "sandbox_exec", argumentsJSON: json(["command": "echo hi"]))
        }
        #expect(ToolEnvelope.isError(denied), "\(denied)")
        let noAgent = try await registry.execute(
            name: "sandbox_exec", argumentsJSON: json(["command": "echo hi"]))
        #expect(ToolEnvelope.isError(noAgent))
    }

    @Test func sandboxToolsAreDeniedToExternalSurfaces() {
        for name in BuiltinSandboxTools.allToolNames {
            #expect(ToolRegistry.externallyDeniedToolNames.contains(name), "\(name)")
        }
    }

    @Test func approvalDefaultsAskForWritesAndShell() {
        #expect((SandboxExecTool() as PermissionedTool).defaultPermissionPolicy == .ask)
        #expect((SandboxWriteFileTool() as PermissionedTool).defaultPermissionPolicy == .ask)
        #expect((SandboxReadFileTool() as PermissionedTool).defaultPermissionPolicy == .auto)
    }

    // MARK: - Prompt

    @Test func promptStatesNetworkAndConfinement() {
        let names = BuiltinSandboxTools.allToolNames
        let off = IntelSandboxPrompt.environment(home: "/workspace/agents/x", network: false, toolNames: names)
        #expect(off.contains("Network access is OFF"))
        #expect(off.contains("/workspace/agents/x"))
        #expect(off.contains("macOS sandbox environment"))
        let on = IntelSandboxPrompt.environment(home: "/workspace/agents/x", network: true, toolNames: names)
        #expect(on.contains("Network access is ON"))
        #expect(IntelSandboxPrompt.state(secretNames: []).isEmpty)
        #expect(IntelSandboxPrompt.state(secretNames: ["B", "A"]).contains("`A`"))
        #expect(IntelSandboxPrompt.secretHandling.contains("Never ask the user to paste a secret"))
    }

    // MARK: - Helpers

    private func runTool(_ tool: OsaurusTool, _ args: [String: Any]) async -> String {
        do {
            return try await tool.execute(argumentsJSON: json(args))
        } catch {
            return ToolEnvelope.failure(kind: .executionError, message: "\(error)", tool: tool.name)
        }
    }
}

struct SecretScrubberTests {

    @Test func replacesSecretValueWithKeyedMarker() {
        let out = SecretScrubber.scrub(
            "token is sk-abc123def and that's it",
            secrets: ["OPENAI_KEY": "sk-abc123def"]
        )
        #expect(out == "token is [REDACTED:OPENAI_KEY] and that's it")
    }

    @Test func replacesEveryOccurrence() {
        let out = SecretScrubber.scrub(
            "first=hunter2secret second=hunter2secret",
            secrets: ["PASS": "hunter2secret"]
        )
        #expect(!out.contains("hunter2secret"))
        #expect(out.components(separatedBy: "[REDACTED:PASS]").count == 3)
    }

    @Test func shortValuesAreNeverScrubbed() {
        let text = "dev environment on /dev/null"
        let out = SecretScrubber.scrub(text, secrets: ["ENV_NAME": "dev"])
        #expect(out == text)
    }

    @Test func longerValuesScrubFirstSoSubstringSecretsLeaveNoTail() {
        let out = SecretScrubber.scrub(
            "combined: secretAB-secretAB-extra",
            secrets: [
                "SHORT": "secretAB",
                "LONG": "secretAB-secretAB-extra",
            ]
        )
        #expect(out == "combined: [REDACTED:LONG]")
    }

    @Test func emptyInputsPassThrough() {
        #expect(SecretScrubber.scrub("", secrets: ["K": "longvalue"]) == "")
        #expect(SecretScrubber.scrub("text", secrets: [:]) == "text")
    }
}
