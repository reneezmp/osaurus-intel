//
//  HarnessRuntimeModelTests.swift
//  osaurusTests
//
//  Persisted shapes (runtimes, per-agent runtime selection), the runtime
//  store's seeding rules. (The move of `claude-code/*` model agents onto the
//  Claude Code runtime is tested in HarnessAppIntegrationTests.)
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Harness runtime model")
struct HarnessRuntimeModelTests {

    @Test func newRuntimesGetTheirKindDefaults() {
        let pi = HarnessRuntime(name: "Pi", kind: .piRPC)
        #expect(pi.executable == "pi")
        #expect(pi.arguments == ["--mode", "rpc"])
        let claude = HarnessRuntime(name: "Claude", kind: .claudeCode)
        #expect(claude.executable == "claude")
        #expect(claude.arguments.isEmpty)
    }

    @Test func decodingFillsMissingFieldsFromTheKind() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","kind":"piRPC"}"#
        let runtime = try JSONDecoder().decode(HarnessRuntime.self, from: Data(json.utf8))
        #expect(runtime.id == id)
        #expect(runtime.executable == "pi")
        #expect(runtime.arguments == ["--mode", "rpc"])
        #expect(runtime.environment.isEmpty)
        #expect(runtime.displayName == "Pi (RPC)", "a blank name still displays")
    }

    @Test func runtimesRoundTrip() throws {
        let original = HarnessRuntime(
            name: "Splash",
            kind: .piRPC,
            executable: "~/.local/bin/splash",
            arguments: ["--mode", "rpc", "--session-dir", "~/.splash/{chat_id}"],
            environment: ["SPLASH_PROFILE": "work"]
        )
        let decoded = try JSONDecoder().decode(HarnessRuntime.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func placeholdersAreSubstitutedPerLaunch() {
        let runtime = HarnessRuntime(
            name: "Pi",
            kind: .piRPC,
            arguments: ["--mode", "rpc", "--session", "/s/{chat_id}.jsonl", "--who", "{agent_id}@{cwd}", "{system_prompt_file}"]
        )
        let chatId = UUID()
        let agentId = UUID()
        let args = runtime.resolvedArguments(
            chatId: chatId,
            agentId: agentId,
            workingDirectory: URL(fileURLWithPath: "/work"),
            systemPromptFile: URL(fileURLWithPath: "/private/prompt.md")
        )
        #expect(args == [
            "--mode", "rpc",
            "--session", "/s/\(chatId.uuidString.lowercased()).jsonl",
            "--who", "\(agentId.uuidString.lowercased())@/work",
            "/private/prompt.md",
        ])
        #expect(runtime.wantsSystemPromptFile)
    }

    @Test func onlyChatKeyedPiRuntimesResume() {
        #expect(HarnessRuntime(name: "C", kind: .claudeCode).resumesSessions)
        #expect(!HarnessRuntime(name: "P", kind: .piRPC).resumesSessions)
        #expect(HarnessRuntime(name: "P", kind: .piRPC, arguments: ["--mode", "rpc", "--session-dir", "/x/{chat_id}"]).resumesSessions)
    }

    @Test func agentRuntimeEncodingIsTaggedAndForgiving() throws {
        let id = UUID()
        let encoded = String(decoding: try JSONEncoder().encode(AgentRuntime.harness(id)), as: UTF8.self)
        #expect(encoded.contains(#""kind":"harness""#))
        #expect(try JSONDecoder().decode(AgentRuntime.self, from: Data(encoded.utf8)) == .harness(id))
        #expect(
            try JSONDecoder().decode(AgentRuntime.self, from: JSONEncoder().encode(AgentRuntime.builtIn)) == .builtIn
        )

        // A newer build's kind, or a malformed id, must not lose the agent.
        for json in [#"{"kind":"mcpHarness","id":"x"}"#, #"{"kind":"harness","id":"not-a-uuid"}"#, "{}"] {
            #expect(try JSONDecoder().decode(AgentRuntime.self, from: Data(json.utf8)) == .builtIn)
        }
    }

    @Test func agentsWithoutARuntimeKeyStillDecode() throws {
        let agent = Agent(name: "Legacy")
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(agent)) as? [String: Any]
        )
        object["runtime"] = nil
        object["claudeCode"] = nil
        let decoded = try JSONDecoder().decode(Agent.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.runtime == nil)
        #expect(decoded.claudeCode == nil)

        var harnessAgent = agent
        harnessAgent.runtime = .harness(HarnessRuntime.builtInClaudeCodeId)
        harnessAgent.claudeCode = ClaudeCodeAgentConfig(allowWrites: true, model: "opus")
        let roundTripped = try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(harnessAgent))
        #expect(roundTripped.runtime == .harness(HarnessRuntime.builtInClaudeCodeId))
        #expect(roundTripped.claudeCode?.model == "opus")
    }
}

@Suite("Harness runtime store", .serialized)
@MainActor
struct HarnessRuntimeStoreTests {

    private func withStore(_ body: (HarnessRuntimeStore, URL) throws -> Void) throws {
        let directory = try HarnessFixtures.temporaryDirectory("runtime-store")
        let previous = HarnessRuntimeStore.overrideDirectory
        HarnessRuntimeStore.overrideDirectory = directory
        defer {
            HarnessRuntimeStore.overrideDirectory = previous
            try? FileManager.default.removeItem(at: directory)
        }
        try body(HarnessRuntimeStore(), directory.appendingPathComponent("harness-runtimes.json"))
    }

    @Test func claudeCodeIsSeededOnFirstLaunchOnly() throws {
        try withStore { store, file in
            #expect(store.all() == [.builtInClaudeCode])
            #expect(FileManager.default.fileExists(atPath: file.path))

            store.remove(id: HarnessRuntime.builtInClaudeCodeId)
            let reloaded = HarnessRuntimeStore()
            #expect(reloaded.all().isEmpty, "a deleted Claude Code runtime stays deleted")
        }
    }

    @Test func upsertPersistsAndEnsureReusesAnyClaudeRuntime() throws {
        try withStore { store, _ in
            store.remove(id: HarnessRuntime.builtInClaudeCodeId)
            let pi = HarnessRuntime(name: "Spotlight", kind: .piRPC, executable: "~/.local/bin/spotlight")
            store.upsert(pi)
            var edited = pi
            edited.arguments += ["--session-dir", "~/.spotlight/{chat_id}"]
            store.upsert(edited)

            let reloaded = HarnessRuntimeStore()
            #expect(reloaded.all() == [edited])

            let custom = HarnessRuntime(name: "Work Claude", kind: .claudeCode, executable: "/opt/claude")
            reloaded.upsert(custom)
            #expect(reloaded.ensureClaudeCodeRuntime() == custom)
        }
    }

    @Test func anUnreadableFileIsPreserved() throws {
        try withStore { store, file in
            try Data("{ not json".utf8).write(to: file)
            #expect(store.all().isEmpty)
            #expect(try String(contentsOf: file, encoding: .utf8) == "{ not json")
        }
    }
}
