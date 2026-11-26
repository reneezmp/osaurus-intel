import Foundation
import Testing

@testable import OsaurusCore

/// Stage 4 of W-seatbelt-sandbox: background processes (`sandbox_exec`
/// with `background:true`, `sandbox_process`) and sandbox plugins on the host
/// backend. Every command runs confined in a throwaway temp workspace;
/// nothing touches `~/.osaurus`, user files, the keychain or the network.
@Suite(.serialized)
struct IntelSandboxBackgroundTests {

    private struct Env {
        let manager: SandboxManager
        let root: URL
        let context: SandboxToolContext
        let plugins: SandboxPluginManager
    }

    private func withEnv(
        background: Bool = true,
        pluginCreate: Bool = true,
        secrets: [String: String] = [:],
        _ body: @Sendable (Env) async throws -> Void
    ) async throws {
        guard SeatbeltSandbox.isSupported else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-sbxbg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SandboxManager(workspaceRoot: root)
        try await manager.startContainer()
        let agentId = UUID()
        let name = SandboxToolRegistrar.hostAgentName(for: agentId.uuidString)
        try await manager.ensureAgentUser(name)
        let context = SandboxToolContext(
            agentId: agentId,
            agentName: name,
            home: OsaurusPaths.inContainerAgentHome(name),
            config: AutonomousExecConfig(
                enabled: true, pluginCreate: pluginCreate, backgroundProcessEnabled: background)
        )
        let plugins = SandboxPluginManager(
            storeRoot: root.appendingPathComponent("plugin-store", isDirectory: true), manager: manager)
        let env = Env(manager: manager, root: root, context: context, plugins: plugins)
        do {
            try await SandboxToolContext.$testingManager.withValue(manager) {
                try await SandboxToolContext.$testingContext.withValue(context) {
                    try await SandboxExecSecrets.$testingSecrets.withValue(secrets) {
                        try await SandboxPluginManager.$testing.withValue(plugins) {
                            try await body(env)
                        }
                    }
                }
            }
        } catch {
            await manager.backgroundJobs.stopEverything()
            throw error
        }
        await manager.backgroundJobs.stopEverything()
    }

    private func json(_ dict: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: dict), encoding: .utf8)!
    }

    private func payload(_ envelope: String) -> [String: Any]? {
        ToolEnvelope.successPayload(envelope) as? [String: Any]
    }

    private func run(_ tool: OsaurusTool, _ args: [String: Any]) async -> String {
        do {
            return try await tool.execute(argumentsJSON: json(args))
        } catch {
            return ToolEnvelope.failure(kind: .executionError, message: "\(error)", tool: tool.name)
        }
    }

    private func eventually(_ seconds: Double = 10, _ check: () async -> Bool) async -> Bool {
        var waited = 0.0
        while waited < seconds {
            if await check() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        return await check()
    }

    private func start(_ command: String, owner: String? = nil) async -> (pid: String, log: String)? {
        let envelope = await run(SandboxExecTool(), ["command": command, "background": true])
        guard let result = payload(envelope), let pid = result["pid"] as? String,
            let log = result["log_file"] as? String
        else { return nil }
        return (pid, log)
    }

    // MARK: - Defaults and schema

    @Test func backgroundIsOffByDefaultAndAbsentFromTheSchemaUnlessEnabled() throws {
        #expect(AutonomousExecConfig.default.backgroundProcessEnabled == false)
        let off = SandboxExecTool(backgroundEnabled: false)
        let on = SandboxExecTool(backgroundEnabled: true)
        func properties(_ tool: SandboxExecTool) -> [String: JSONValue] {
            guard case .object(let schema)? = tool.parameters, case .object(let props)? = schema["properties"]
            else { return [:] }
            return props
        }
        #expect(properties(off)["background"] == nil)
        #expect(!off.description.contains("background:true"))
        #expect(properties(on)["background"] != nil)
        #expect(on.description.contains("background:true"))
    }

    @Test func processToolIsOnlyForAgentsWithTheBackgroundSwitch() {
        // Unknown agent: no config, so nothing is allowed.
        #expect(!SandboxToolGate.allows(BuiltinSandboxTools.process, agentId: UUID()))
        #expect(!SandboxToolGate.allows(BuiltinSandboxTools.pluginRegister, agentId: nil))
        #expect(BuiltinSandboxTools.allToolNames.contains(BuiltinSandboxTools.process))
        #expect(ToolRegistry.externallyDeniedToolNames.contains(BuiltinSandboxTools.process))
        #expect(ToolRegistry.externallyDeniedToolNames.contains(BuiltinSandboxTools.pluginRegister))
        #expect((SandboxExecTool() as PermissionedTool).defaultPermissionPolicy == .ask)
        #expect((SandboxPluginRegisterTool() as PermissionedTool).defaultPermissionPolicy == .ask)
    }

    // MARK: - Lifecycle

    @Test func backgroundJobStartsPollsAndIsKilled() async throws {
        try await withEnv { env in
            let started = await start("echo started-marker; sleep 60")
            #expect(started != nil)
            guard let started else { return }
            let sawLog = await eventually {
                let poll = await run(
                    SandboxProcessTool(), ["action": "poll", "pid": started.pid])
                return (payload(poll)?["log_tail"] as? String)?.contains("started-marker") == true
            }
            #expect(sawLog)
            let poll = await run(SandboxProcessTool(), ["action": "poll", "pid": started.pid])
            #expect(payload(poll)?["alive"] as? Bool == true)
            let kill = await run(SandboxProcessTool(), ["action": "kill", "pid": started.pid])
            #expect(payload(kill)?["killed"] as? Bool == true, "\(kill)")
            let after = await run(SandboxProcessTool(), ["action": "poll", "pid": started.pid])
            #expect(payload(after)?["alive"] as? Bool == false)
            #expect(env.manager.backgroundJobs.runningCount(agentName: env.context.agentName) == 0)
        }
    }

    @Test func waitReturnsTheExitCodeOfAFinishedJob() async throws {
        try await withEnv { _ in
            let started = await start("echo done; exit 7")
            guard let started else { Issue.record("no job"); return }
            let wait = await run(
                SandboxProcessTool(), ["action": "wait", "pid": started.pid, "timeout": 20])
            let result = payload(wait)
            #expect(result?["exited"] as? Bool == true, "\(wait)")
            #expect(result?["exit_code"] as? Int == 7)
            #expect((result?["log_tail"] as? String)?.contains("done") == true)
        }
    }

    @Test func killTakesDownTheWholeProcessGroup() async throws {
        try await withEnv { env in
            let started = await start("sleep 120 & echo $! > child.pid; wait")
            guard let started else { Issue.record("no job"); return }
            let pidFile = env.root.appendingPathComponent(
                "agents/\(env.context.agentName)/child.pid")
            let sawChild = await eventually {
                (try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty == false
            }
            #expect(sawChild)
            let child = Int32(
                ((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            #expect(child > 1)
            _ = await run(SandboxProcessTool(), ["action": "kill", "pid": started.pid])
            let gone = await eventually(8) { Darwin.kill(child, 0) != 0 }
            #expect(gone, "descendant \(child) survived the group kill")
            if !gone { _ = Darwin.kill(child, SIGKILL) }
        }
    }

    @Test func endingARunStopsOnlyThatRunsJobs() async throws {
        try await withEnv { env in
            let mine = try await env.manager.execBackground(
                agentName: env.context.agentName, command: "sleep 60", cwd: env.context.home,
                logPath: "\(env.context.home)/a.log", owner: "run-A")
            let other = try await env.manager.execBackground(
                agentName: env.context.agentName, command: "sleep 60", cwd: env.context.home,
                logPath: "\(env.context.home)/b.log", owner: "run-B")
            #expect(mine.isRunning && other.isRunning)
            await env.manager.backgroundJobs.stopRun(owner: "run-A")
            let stopped = await eventually { !mine.isRunning }
            #expect(stopped)
            #expect(other.isRunning)
            await env.manager.backgroundJobs.stopRun(owner: "run-B")
            #expect(await eventually { !other.isRunning })
        }
    }

    @Test func stoppingTheSandboxStopsEveryJob() async throws {
        try await withEnv { env in
            let job = try await env.manager.execBackground(
                agentName: env.context.agentName, command: "sleep 60", cwd: env.context.home,
                logPath: "\(env.context.home)/s.log", owner: nil)
            #expect(job.isRunning)
            try await env.manager.stopContainer()
            #expect(await eventually { !job.isRunning })
        }
    }

    @Test func aJobNeverOutlivesTheLifetimeCeiling() async throws {
        guard SeatbeltSandbox.isSupported else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-sbxlife-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SandboxManager(workspaceRoot: root, maxJobLifetime: 1)
        try await manager.startContainer()
        try await manager.bootstrapAgent(agentName: "life", agentId: UUID(), soulSeedBody: "x")
        let job = try await manager.execBackground(
            agentName: "life", command: "sleep 60", cwd: "/workspace/agents/life",
            logPath: "/workspace/agents/life/l.log", owner: nil)
        #expect(await eventually(10) { !job.isRunning })
        await manager.backgroundJobs.stopEverything()
    }

    @Test func atMostFourJobsRunPerAgent() async throws {
        try await withEnv { env in
            for index in 0..<SandboxBackgroundJobs.maxJobsPerAgent {
                _ = try await env.manager.execBackground(
                    agentName: env.context.agentName, command: "sleep 60", cwd: env.context.home,
                    logPath: "\(env.context.home)/m\(index).log", owner: nil)
            }
            let fifth = await start("sleep 60")
            #expect(fifth == nil)
        }
    }

    // MARK: - Policy

    @Test func backgroundIsRefusedWhenTheAgentSwitchIsOff() async throws {
        try await withEnv(background: false) { env in
            let envelope = await run(SandboxExecTool(), ["command": "sleep 5", "background": true])
            #expect(ToolEnvelope.isError(envelope), "\(envelope)")
            #expect(env.manager.backgroundJobs.runningCount(agentName: env.context.agentName) == 0)
            let process = await run(SandboxProcessTool(), ["action": "poll", "pid": "1"])
            #expect(ToolEnvelope.isError(process))
        }
    }

    @Test func processToolOnlyTouchesJobsItStarted() async throws {
        try await withEnv { _ in
            let me = String(getpid())
            let kill = await run(SandboxProcessTool(), ["action": "kill", "pid": me])
            #expect(ToolEnvelope.isError(kill), "an arbitrary pid must be unknown: \(kill)")
            #expect(Darwin.kill(getpid(), 0) == 0)
            let notNumeric = await run(SandboxProcessTool(), ["action": "poll", "pid": "server"])
            #expect(ToolEnvelope.isError(notNumeric))
        }
    }

    @Test func backgroundJobsStayConfinedAndOffline() async throws {
        try await withEnv { env in
            let escape = "/private/tmp/osaurus-bg-escape-\(UUID().uuidString)"
            defer { try? FileManager.default.removeItem(atPath: escape) }
            let started = await start("touch '\(escape)'; ls ~ ; curl -sS -m 5 http://example.invalid/ ; true")
            guard let started else { Issue.record("no job"); return }
            let wait = await run(
                SandboxProcessTool(), ["action": "wait", "pid": started.pid, "timeout": 30])
            #expect(payload(wait)?["exited"] as? Bool == true, "\(wait)")
            #expect(!FileManager.default.fileExists(atPath: escape), "a background job wrote outside the workspace")
            let tail = (payload(wait)?["log_tail"] as? String) ?? ""
            #expect(tail.lowercased().contains("not permitted") || tail.lowercased().contains("denied")
                || tail.lowercased().contains("could not resolve"), "\(tail)")
            _ = env
        }
    }

    @Test func logTailsAreScrubbedOfStoredSecrets() async throws {
        let secret = "sup3rs3cret-token-value-123"
        try await withEnv(secrets: ["API_TOKEN": secret]) { _ in
            let started = await start("echo token=$API_TOKEN")
            guard let started else { Issue.record("no job"); return }
            let wait = await run(
                SandboxProcessTool(), ["action": "wait", "pid": started.pid, "timeout": 20])
            let tail = (payload(wait)?["log_tail"] as? String) ?? ""
            #expect(!tail.contains(secret), "\(tail)")
            #expect(tail.contains("token="))
        }
    }

    // MARK: - Executor

    @Test func backgroundProcessReportsExitAndSignalCodes() async throws {
        guard SeatbeltSandbox.isSupported else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-sbxexec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = SeatbeltSandbox.profile(
            workspaceRoot: root.path, tempDir: SeatbeltSandbox.scratchDir, network: .denied)
        func launch(_ command: String) async throws -> SeatbeltExecutor.BackgroundProcess {
            try await SeatbeltExecutor.launchBackground(
                SeatbeltExecutor.Request(
                    command: command, env: [:], cwd: root.path, timeout: nil, profile: profile,
                    stdoutTee: nil, stderrTee: nil, onProcessStarted: nil))
        }
        let quick = try await launch("exit 3")
        #expect(await eventually { quick.exitCode == 3 })
        let long = try await launch("sleep 60")
        #expect(long.isRunning)
        await long.terminate(graceSeconds: 1)
        #expect(long.exitCode == 128 + SIGTERM, "exit code was \(String(describing: long.exitCode))")
        // A NUL byte must be refused, not truncated.
        await #expect(throws: SandboxError.self) {
            _ = try await launch("echo a\0b")
        }
    }

    // MARK: - Plugins

    private func plugin(
        name: String = "demo", setup: String? = nil, files: [String: String]? = nil,
        run: String = "echo \"hello $PARAM_WHO\""
    ) -> SandboxPlugin {
        SandboxPlugin(
            name: name, description: "demo plugin", setup: setup, files: files,
            tools: [
                SandboxToolSpec(
                    id: "greet", description: "Greets",
                    parameters: ["who": SandboxParameterSpec(type: "string", description: "who")],
                    run: run)
            ])
    }

    @Test func pluginValidationRefusesUnsafeShapes() {
        #expect(SandboxPluginManager.validate(plugin()).isEmpty)
        #expect(!SandboxPluginManager.validate(plugin(files: ["../x": "a"])).isEmpty)
        #expect(!SandboxPluginManager.validate(plugin(files: ["/etc/x": "a"])).isEmpty)
        #expect(!SandboxPluginManager.validate(plugin(files: ["a b.txt": "a"])).isEmpty)
        #expect(!SandboxPluginManager.validate(plugin(name: "../evil")).isEmpty)
        var apk = plugin()
        apk.dependencies = ["curl"]
        #expect(SandboxPluginManager.validate(apk).joined().contains("Linux VM"))
        // A plugin cannot take the name of a built-in sandbox tool.
        var shadow = plugin(name: "sandbox")
        shadow.tools = [SandboxToolSpec(id: "exec", description: "x", run: "true")]
        #expect(SandboxPluginManager.validate(shadow).joined().contains("reserved"))
        let big = Dictionary(
            uniqueKeysWithValues: (0..<5).map { ("f\($0).txt", String(repeating: "x", count: 100_000)) })
        #expect(!SandboxPluginManager.validate(plugin(files: big)).isEmpty)
    }

    @Test func installSeedsFilesRunsSetupAndRunsToolsInTheSandbox() async throws {
        try await withEnv { env in
            let agentId = env.context.agentId.uuidString
            let demo = plugin(
                setup: "echo ready > setup-ran.txt", files: ["scripts/hi.sh": "echo 'from file' \"$1\"\n"],
                run: "sh scripts/hi.sh \"$PARAM_WHO\"")
            try await env.plugins.install(plugin: demo, for: agentId, networkEnabled: false)
            let dir = env.root.appendingPathComponent(
                "agents/\(env.context.agentName)/plugins/demo")
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("scripts/hi.sh").path))
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("setup-ran.txt").path))
            #expect(env.plugins.agentHasTool("demo_greet", agentId: agentId))
            #expect(!env.plugins.agentHasTool("demo_greet", agentId: UUID().uuidString))
            let tool = SandboxPluginTool(spec: demo.tools![0], plugin: demo)
            #expect((tool as PermissionedTool).defaultPermissionPolicy == .ask)
            let out = await run(tool, ["who": "world"])
            #expect(payload(out)?["stdout"] as? String == "from file world\n", "\(out)")
            // The record survives a reload from the private store.
            let reopened = SandboxPluginManager(storeRoot: env.root.appendingPathComponent("plugin-store"), manager: env.manager)
            #expect(reopened.plugin(id: "demo", for: agentId)?.status == .ready)
            try await env.plugins.uninstall(pluginId: "demo", from: agentId)
            #expect(!FileManager.default.fileExists(atPath: dir.path))
            #expect(env.plugins.plugins(for: agentId).isEmpty)
        }
    }

    @Test func pluginSetupHasNoNetworkAndAFailedSetupLeavesNothingReady() async throws {
        try await withEnv { env in
            let agentId = env.context.agentId.uuidString
            let bad = plugin(name: "net", setup: "curl -sS -m 5 http://example.invalid/")
            await #expect(throws: SandboxPluginError.self) {
                try await env.plugins.install(plugin: bad, for: agentId, networkEnabled: false)
            }
            #expect(env.plugins.plugin(id: "net", for: agentId)?.status == .failed)
            #expect(!env.plugins.agentHasTool("net_greet", agentId: agentId))
        }
    }

    @Test func registerToolReadsThePluginFolderAndInstalls() async throws {
        try await withEnv { env in
            let manifest = """
                {"name":"notes","description":"d","setup":"echo ok > ran.txt",
                 "permissions":{"network":"outbound"},
                 "tools":[{"id":"say","description":"Say","run":"cat msg.txt"}]}
                """
            let write1 = await run(
                SandboxWriteFileTool(), ["path": "plugins/notes/plugin.json", "content": manifest])
            #expect(!ToolEnvelope.isError(write1), "\(write1)")
            _ = await run(SandboxWriteFileTool(), ["path": "plugins/notes/msg.txt", "content": "hello\n"])
            let result = await run(SandboxPluginRegisterTool(), ["plugin_id": "notes"])
            #expect(!ToolEnvelope.isError(result), "\(result)")
            let installed = env.plugins.plugin(id: "notes", for: env.context.agentId.uuidString)
            #expect(installed?.status == .ready)
            // Agent-created plugins get upstream's restricted defaults.
            #expect(installed?.plugin.permissions?.network == "none")
            #expect(installed?.plugin.permissions?.inference == false)
            #expect(installed?.plugin.files?["msg.txt"] == "hello\n")
            let tool = SandboxPluginTool(spec: installed!.plugin.tools![0], plugin: installed!.plugin)
            #expect(payload(await run(tool, [:]))?["stdout"] as? String == "hello\n")
        }
    }

    @Test func registerToolRefusesSymlinkedManifestsAndSkipsSymlinkedFiles() async throws {
        try await withEnv { env in
            let dir = env.root.appendingPathComponent("agents/\(env.context.agentName)/plugins/evil")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // plugin.json -> a readable file outside the workspace.
            try FileManager.default.createSymbolicLink(
                atPath: dir.appendingPathComponent("plugin.json").path, withDestinationPath: "/etc/hosts")
            let refused = await run(SandboxPluginRegisterTool(), ["plugin_id": "evil"])
            #expect(ToolEnvelope.isError(refused), "\(refused)")
            #expect(env.plugins.plugins(for: env.context.agentId.uuidString).isEmpty)

            // A real manifest, plus a symlink to an outside file: not packaged.
            let good = """
                {"name":"ok","description":"d","tools":[{"id":"t","description":"T","run":"true"}]}
                """
            let okDir = env.root.appendingPathComponent("agents/\(env.context.agentName)/plugins/ok")
            try FileManager.default.createDirectory(at: okDir, withIntermediateDirectories: true)
            try good.write(to: okDir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(
                atPath: okDir.appendingPathComponent("leak.txt").path, withDestinationPath: "/etc/hosts")
            let result = await run(SandboxPluginRegisterTool(), ["plugin_id": "ok"])
            #expect(!ToolEnvelope.isError(result), "\(result)")
            let files = env.plugins.plugin(id: "ok", for: env.context.agentId.uuidString)?.plugin.files
            #expect(files?["leak.txt"] == nil, "a symlinked file was packaged: \(String(describing: files))")
        }
    }

    @Test func registerToolIsRefusedWhenPluginCreateIsOff() async throws {
        try await withEnv(pluginCreate: false) { env in
            let result = await run(SandboxPluginRegisterTool(), ["plugin_id": "x"])
            #expect(ToolEnvelope.isError(result), "\(result)")
            #expect(env.plugins.plugins(for: env.context.agentId.uuidString).isEmpty)
        }
    }

    @Test func registryNeverLetsAPluginShadowAnotherTool() {
        let registry = ToolRegistry.shared
        #expect(registry.canRegisterSandboxPluginTool(named: "brand_new_tool_\(UUID().uuidString.prefix(6))"))
        // A registered built-in is never replaceable by a plugin tool.
        registry.register(SandboxExecTool())
        defer { registry.unregister(names: ["sandbox_exec"]) }
        #expect(!registry.canRegisterSandboxPluginTool(named: "sandbox_exec"))
    }

    // MARK: - Prompt

    @Test func promptMentionsBackgroundAndPluginsOnlyWhenOffered() {
        let withBg = IntelSandboxPrompt.environment(
            home: "/workspace/agents/x", network: false,
            toolNames: [BuiltinSandboxTools.exec, BuiltinSandboxTools.process])
        #expect(withBg.contains("background:true"))
        let without = IntelSandboxPrompt.environment(
            home: "/workspace/agents/x", network: false, toolNames: [BuiltinSandboxTools.exec])
        #expect(!without.contains("background:true"))
        #expect(IntelSandboxPrompt.pluginCreator.contains("sandbox_plugin_register"))
        #expect(IntelSandboxPrompt.pluginCreator.contains("not supported"))
    }
}
