//
//  IntelSpawnResultWireTests.swift
//  OsaurusCoreTests
//
//  Upstream #2936 on Intel: the launching model reads the compact
//  `spawn_result` (digest, continuation handles, deliverable paths, one
//  accounting line); the card keeps the full envelope.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelSpawnResultWireTests {

    private static func envelope() -> String {
        ToolEnvelope.success(
            tool: "spawn_agent",
            result: [
                "kind": "spawn_result",
                "agent": "Coder",
                "agent_id": UUID().uuidString,
                "model": "openai/gpt-test",
                "summary": String(repeating: "word ", count: 600),
                "session_id": UUID().uuidString,
                "needs_input": false,
                "iterations": 2,
                "elapsed_seconds": 12.5,
                "handoff": false,
                "residency_mode": "none",
                "artifact_paths": ["/Users/me/Reports/q3.md"],
                "usage": ["completion_tokens": 812, "tokens_per_second": 41.2],
                "context": ["worker_tokens_estimated": 6000, "digest_tokens": 300, "context_saved_tokens": 5700],
            ])
    }

    @Test
    func spawnResult_isCompactedForTheModel_keepingHandlesAndPaths() async throws {
        let full = Self.envelope()
        let wire = await IntelSpawnResultWire.modelVisible(name: "spawn_agent", result: full, modelID: nil)
        #expect(wire.count < full.count)
        let payload = try #require(ToolEnvelope.resultPayload(wire) as? [String: Any])
        #expect(payload["kind"] as? String == "spawn_result")
        #expect(payload["session_id"] is String)
        #expect(payload["artifact_paths"] as? [String] == ["/Users/me/Reports/q3.md"])
        #expect(payload["accounting"] is String)
        #expect(payload["context"] == nil && payload["usage"] == nil && payload["residency_mode"] == nil)
    }

    @Test
    func otherToolsAndFailuresPassThroughUnchanged() async {
        let full = Self.envelope()
        #expect(await IntelSpawnResultWire.modelVisible(name: "file_read", result: full, modelID: nil) == full)
        let failure = ToolEnvelope.failure(kind: .unavailable, message: "no", tool: "spawn_agent")
        #expect(await IntelSpawnResultWire.modelVisible(name: "spawn_agent", result: failure, modelID: nil) == failure)
    }

    @Test
    func compactLauncher_isASmallWindow() {
        #expect(IntelSpawnResultWire.prefersCompactPrompt(windowTokens: 8192))
        #expect(!IntelSpawnResultWire.prefersCompactPrompt(windowTokens: 128_000))
        #expect(!IntelSpawnResultWire.prefersCompactPrompt(windowTokens: nil))
    }

    @Test
    func engineAndKindAreWired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = try String(
            contentsOf: root.appendingPathComponent("Services/Chat/CloudChatEngine.swift"), encoding: .utf8)
        #expect(engine.contains("IntelSpawnResultWire.modelVisible("))
        // Both wires compact: Chat Completions and Responses / Codex (stage 6).
        #expect(engine.components(separatedBy: "IntelSpawnResultWire.modelVisible(").count - 1 == 2)
        #expect(engine.contains("results.append(.init(callID: call.callID, output: wireResult))"))
        let kind = try String(
            contentsOf: root.appendingPathComponent("Subagent/Kinds/TextSubagentKind.swift"), encoding: .utf8)
        #expect(kind.contains("SpawnResultCompaction.artifactPaths(forWorkerSession: outcome.sessionId)"))
        #expect(kind.contains("payload[\"artifact_paths\"] = artifactPaths"))
    }
}
