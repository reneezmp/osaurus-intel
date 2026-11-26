//
//  HarnessAppIntegrationTests.swift
//  osaurusTests
//
//  `W-harness-runtimes` stage 4: the per-agent runtime selection, the launch
//  migration of `claude-code/<alias>` agents (upstream #3175), and a chat that
//  runs a turn through a harness. Nothing here starts `claude` or `pi`: the
//  chat test drives a throwaway `/bin/sh` script in a temporary folder, and
//  every store points at a temporary root.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Claude Code model migration", .serialized)
@MainActor
struct ClaudeCodeHarnessMigrationTests {

    /// Temporary storage root plus an isolated runtime registry; restores the
    /// global chat configuration and the registry afterwards.
    private func withMigrationStorage(_ body: @MainActor @Sendable () async throws -> Void) async throws {
        try await ChatHistoryTestStorage.run {
            let previousStoreDir = HarnessRuntimeStore.overrideDirectory
            let originalChat = ChatConfigurationStore.load()
            HarnessRuntimeStore.overrideDirectory = OsaurusPaths.root()
            HarnessRuntimeStore.shared.resetForTests()
            DefaultAgentConfigurationStore.resetCacheForTests()
            AgentManager.shared.refresh()
            defer {
                ChatConfigurationStore.save(originalChat)
                HarnessRuntimeStore.overrideDirectory = previousStoreDir
                HarnessRuntimeStore.shared.resetForTests()
                DefaultAgentConfigurationStore.resetCacheForTests()
            }
            try await body()
        }
    }

    @Test func claudeCodeModelAgentsMoveOntoTheClaudeRuntime() async throws {
        try await withMigrationStorage {
            let otherRuntime = UUID()
            let explicit = Agent(name: "Explicit", defaultModel: "claude-code/opus")
            let local = Agent(name: "Local", defaultModel: "mlx/some-model")
            let inherits = Agent(name: "Inherits")
            var pinned = Agent(name: "Pinned", defaultModel: "claude-code/sonnet")
            pinned.runtime = .harness(otherRuntime)
            let manager = AgentManager.shared
            for agent in [explicit, local, inherits, pinned] { manager.add(agent) }
            var chat = ChatConfigurationStore.load()
            chat.defaultModel = "claude-code/haiku"
            ChatConfigurationStore.save(chat)

            manager.migrateClaudeCodeModelsToHarness()

            let claudeId = HarnessRuntime.builtInClaudeCodeId
            let movedExplicit = manager.agent(for: explicit.id)
            #expect(movedExplicit?.runtime == .harness(claudeId))
            #expect(movedExplicit?.claudeCode?.model == "opus")
            #expect(movedExplicit?.defaultModel == nil)

            let stayed = manager.agent(for: local.id)
            #expect(stayed?.runtime == nil)
            #expect(stayed?.defaultModel == "mlx/some-model")

            let inheriting = manager.agent(for: inherits.id)
            #expect(inheriting?.runtime == .harness(claudeId))
            #expect(inheriting?.claudeCode?.model == "haiku")

            let keptChoice = manager.agent(for: pinned.id)
            #expect(keptChoice?.runtime == .harness(otherRuntime), "an explicit runtime choice wins")
            #expect(keptChoice?.defaultModel == nil, "the dead model id is still cleared")

            #expect(ChatConfigurationStore.load().defaultModel == nil, "the dead global model id is cleared")
            #expect(HarnessRuntimeStore.shared.runtime(id: claudeId) != nil)
            #expect(manager.effectiveHarness(for: explicit.id) == .resolved(.builtInClaudeCode))
            #expect(manager.effectiveHarness(for: pinned.id) == .missing(otherRuntime))
            #expect(manager.harnessUnsupportedError(for: explicit.id) == .unsupportedPath(agentName: "Explicit"))
            #expect(manager.harnessUnsupportedError(for: local.id) == nil)

            // Idempotent: with nothing left to move, a second pass must not
            // re-seed a Claude Code runtime the user deleted.
            HarnessRuntimeStore.shared.remove(id: claudeId)
            manager.migrateClaudeCodeModelsToHarness()
            #expect(HarnessRuntimeStore.shared.runtime(id: claudeId) == nil)

            // An agent restored from an old backup still gets moved.
            let restored = Agent(name: "Restored", defaultModel: "claude-code/opus")
            manager.add(restored)
            manager.migrateClaudeCodeModelsToHarness()
            #expect(manager.agent(for: restored.id)?.runtime == .harness(claudeId))
            #expect(HarnessRuntimeStore.shared.runtime(id: claudeId) != nil)
        }
    }

    @Test func theDefaultAgentMovesWithItsOwnOrInheritedModel() async throws {
        try await withMigrationStorage {
            let manager = AgentManager.shared

            // The Orchestrator's own `claude-code/…` model.
            DefaultAgentConfigurationStore.save(DefaultAgentConfiguration(defaultModel: "claude-code/fable"))
            manager.migrateClaudeCodeModelsToHarness()
            var config = DefaultAgentConfigurationStore.load()
            #expect(config.runtime == .harness(HarnessRuntime.builtInClaudeCodeId))
            #expect(config.claudeCode?.model == "fable")
            #expect(config.defaultModel == nil)
            #expect(manager.effectiveRuntime(for: Agent.defaultId) == .harness(HarnessRuntime.builtInClaudeCodeId))
            #expect(manager.effectiveClaudeCodeConfig(for: Agent.defaultId).resolvedModel == "fable")

            // Inherited from the global default (Intel adaptation).
            DefaultAgentConfigurationStore.save(DefaultAgentConfiguration())
            var chat = ChatConfigurationStore.load()
            chat.defaultModel = "claude-code/opus"
            ChatConfigurationStore.save(chat)
            manager.migrateClaudeCodeModelsToHarness()
            config = DefaultAgentConfigurationStore.load()
            #expect(config.runtime == .harness(HarnessRuntime.builtInClaudeCodeId))
            #expect(config.claudeCode?.model == "opus")
            #expect(ChatConfigurationStore.load().defaultModel == nil)

            // A Default agent with no Claude Code model is left on the built-in loop.
            DefaultAgentConfigurationStore.save(DefaultAgentConfiguration(defaultModel: "mlx/some-model"))
            manager.migrateClaudeCodeModelsToHarness()
            #expect(DefaultAgentConfigurationStore.load().runtime == nil)
            #expect(manager.effectiveRuntime(for: Agent.defaultId) == .builtIn)
        }
    }

    @Test func updateRuntimeStoresOnlyANonBuiltInChoice() async throws {
        try await withMigrationStorage {
            let manager = AgentManager.shared
            let agent = Agent(name: "Chooser")
            manager.add(agent)

            manager.updateRuntime(.harness(HarnessRuntime.builtInClaudeCodeId), for: agent.id)
            #expect(manager.agent(for: agent.id)?.runtime == .harness(HarnessRuntime.builtInClaudeCodeId))
            manager.updateRuntime(.builtIn, for: agent.id)
            #expect(manager.agent(for: agent.id)?.runtime == nil)

            manager.updateRuntime(.harness(HarnessRuntime.builtInClaudeCodeId), for: Agent.defaultId)
            #expect(DefaultAgentConfigurationStore.load().runtime == .harness(HarnessRuntime.builtInClaudeCodeId))
            manager.updateRuntime(.builtIn, for: Agent.defaultId)
            #expect(DefaultAgentConfigurationStore.load().runtime == nil)

            var claude = manager.effectiveClaudeCodeConfig(for: Agent.defaultId)
            claude.allowWrites = true
            manager.updateClaudeCodeConfig(claude, for: Agent.defaultId)
            #expect(DefaultAgentConfigurationStore.load().claudeCode?.allowWrites == true)
        }
    }
}

@Suite("Default agent runtime persistence")
struct DefaultAgentRuntimePersistenceTests {
    @Test func olderFilesDecodeAndNilRuntimeIsNotWritten() throws {
        let legacy = try JSONDecoder().decode(DefaultAgentConfiguration.self, from: Data(#"{"displayName":"Rex"}"#.utf8))
        #expect(legacy.runtime == nil)
        #expect(legacy.claudeCode == nil)

        let encoded = try JSONEncoder().encode(legacy)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["runtime"] == nil, "a file written by this build stays readable by the previous one")
        #expect(object["claudeCode"] == nil)
    }

    @Test func runtimeAndClaudeCodeRoundTripAndAnUnreadableRuntimeIsTolerated() throws {
        var config = DefaultAgentConfiguration()
        config.runtime = .harness(HarnessRuntime.builtInClaudeCodeId)
        config.claudeCode = ClaudeCodeAgentConfig(allowWrites: true, model: "opus")
        let decoded = try JSONDecoder().decode(DefaultAgentConfiguration.self, from: JSONEncoder().encode(config))
        #expect(decoded.runtime == config.runtime)
        #expect(decoded.claudeCode?.model == "opus")

        let broken = try JSONDecoder().decode(
            DefaultAgentConfiguration.self,
            from: Data(#"{"displayName":"Rex","runtime":"nonsense"}"#.utf8)
        )
        #expect(broken.displayName == "Rex")
        #expect(broken.runtime == nil)
    }
}

@Suite("Harness chat integration", .serialized)
@MainActor
struct HarnessChatIntegrationTests {

    /// A fake harness (Pi RPC wire format) whose reply lists the NAMES of the
    /// variables it was started with, and the one it echoes for a probe.
    private static let envScript = #"""
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
          case "$line" in
            *'"type":"prompt"'*)
              printf '{"type":"response","command":"prompt","success":true,"id":"%s"}\n' "$id"
              printf '{"type":"agent_start"}\n'
              names=$(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | sort | tr '\n' ' ')
              printf '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"names=%s pid=%s"}}\n' "$names" "$$"
              printf '{"type":"agent_settled"}\n' ;;
          esac
        done
        exit 0
        """#

    private func waitUntil(timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { Issue.record("timed out waiting for the harness reply"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func aHarnessAgentsTurnRunsInItsProcessWithTheNarrowEnvironment() async throws {
        let scriptDir = try HarnessFixtures.temporaryDirectory("harness-chat")
        defer { try? FileManager.default.removeItem(at: scriptDir) }
        let script = try HarnessFixtures.writeExecutable(Self.envScript, named: "fake-harness", in: scriptDir)

        try await ChatHistoryTestStorage.run {
            let previousStoreDir = HarnessRuntimeStore.overrideDirectory
            let previousProbe = HarnessTurnDriver.serverProbe
            HarnessRuntimeStore.overrideDirectory = OsaurusPaths.root()
            HarnessRuntimeStore.shared.resetForTests()
            HarnessTurnDriver.serverProbe = { _ in false }
            defer {
                HarnessTurnDriver.serverProbe = previousProbe
                HarnessRuntimeStore.overrideDirectory = previousStoreDir
                HarnessRuntimeStore.shared.resetForTests()
            }

            let runtime = HarnessRuntime(
                name: "Fake harness",
                kind: .piRPC,
                executable: script.path,
                arguments: ["--mode", "rpc"]
            )
            HarnessRuntimeStore.shared.upsert(runtime)
            var agent = Agent(name: "On a harness")
            agent.runtime = .harness(runtime.id)
            AgentManager.shared.add(agent)

            let session = ChatSession()
            var builtInLoopStarted = false
            session.chatEngineFactory = {
                builtInLoopStarted = true
                return ThrowsAfterTextChatEngine(error: CancellationError(), delay: .milliseconds(10))
            }
            session.agentId = agent.id
            #expect(session.isHarnessAgentActive)

            session.send("hello")
            try await waitUntil { session.turns.last?.role == .assistant && session.turns.last?.content.contains("pid=") == true }

            let reply = try #require(session.turns.last?.content)
            #expect(!builtInLoopStarted, "a harness agent never runs the built-in loop")
            #expect(session.lastStreamError == nil)

            // The environment the harness process got: the narrow inherited
            // set, the OSAURUS_* contract, and the few variables a shell adds.
            let names = Set(
                try #require(reply.components(separatedBy: "names=").last)
                    .components(separatedBy: " pid=").first?
                    .split(separator: " ").map(String.init) ?? []
            )
            let narrow: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"]
            let contract: Set<String> = [
                "OSAURUS_CHAT_ID", "OSAURUS_AGENT_ID", "OSAURUS_AGENT_TOKEN", "OSAURUS_API_BASE",
                "OSAURUS_WORKING_DIRECTORY", "OSAURUS_MCP_BRIDGE_GRANT",
            ]
            let addedByTheShell: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]
            #expect(names.isSubset(of: narrow.union(contract).union(addedByTheShell)), "unexpected variables: \(names)")
            #expect(names.contains("PATH") && names.contains("HOME"))
            #expect(names.contains("OSAURUS_CHAT_ID") && names.contains("OSAURUS_AGENT_TOKEN"))

            // The tokens die with the chat's process.
            let chatId = try #require(session.sessionId)
            await HarnessSessionManager.shared.close(chatId: chatId)
            #expect(await HarnessSessionManager.shared.liveSessionCount() == 0)
        }
    }

    @Test func aMissingRuntimeFailsTheTurnWithoutLaunchingAnything() async throws {
        try await ChatHistoryTestStorage.run {
            let previousStoreDir = HarnessRuntimeStore.overrideDirectory
            HarnessRuntimeStore.overrideDirectory = OsaurusPaths.root()
            HarnessRuntimeStore.shared.resetForTests()
            defer {
                HarnessRuntimeStore.overrideDirectory = previousStoreDir
                HarnessRuntimeStore.shared.resetForTests()
            }
            var agent = Agent(name: "Dangling")
            agent.runtime = .harness(UUID())
            AgentManager.shared.add(agent)

            let session = ChatSession()
            session.agentId = agent.id
            session.send("hello")
            try await waitUntil { session.lastStreamError != nil }
            #expect(session.lastStreamError == HarnessError.runtimeMissing.localizedDescription)
            #expect(await HarnessSessionManager.shared.liveSessionCount() == 0)
        }
    }
}

@Suite("Harness environment policy")
struct HarnessEnvironmentPolicyTests {
    @Test func theInheritedEnvironmentIsTheNarrowOneWhateverTheAppHolds() {
        let allowed: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"]
        #expect(Set(HarnessProcess.defaultInheritedEnvironment().keys).isSubset(of: allowed))

        let poisoned = ClaudeCodeConfiguration.subprocessEnvironment(source: [
            "PATH": "/usr/bin", "HOME": "/h", "ANTHROPIC_BASE_URL": "https://example.invalid",
            "ANTHROPIC_API_KEY": "k", "AWS_SECRET_ACCESS_KEY": "s", "HTTPS_PROXY": "http://p",
            "CLAUDE_CONFIG_DIR": "/elsewhere", "NVM_DIR": "/nvm",
        ])
        #expect(Set(poisoned.keys).isSubset(of: allowed))
    }

    @Test func theResumeLookupIgnoresAConfigDirTheChildNeverSees() {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        #expect(ClaudeCodeSessionLocator.configDirectory(environment: [:]).path == home.path)
        #expect(
            ClaudeCodeSessionLocator.configDirectory(environment: ["CLAUDE_CONFIG_DIR": "/tmp/work-claude"]).path
                == "/tmp/work-claude"
        )
    }
}
