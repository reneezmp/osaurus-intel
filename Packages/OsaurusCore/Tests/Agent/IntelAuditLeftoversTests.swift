//
//  IntelAuditLeftoversTests.swift
//  OsaurusCoreTests
//
//  Leftovers from the 2026-09-25 upstream audit: #49 remainder (grounded
//  Settings lookup for the Orchestrator) and #25 (agent default working
//  folder).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel audit leftovers", .serialized)
struct IntelAuditLeftoversTests {
    // MARK: - #49 find_setting

    @Test("osaurus_help find returns grounded paths and admits when nothing matches")
    func findSetting() async throws {
        let found = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await OsaurusHelpTool().execute(argumentsJSON: #"{"action":"find","query":"spell check"}"#)
        }
        let envelope = try #require(try JSONSerialization.jsonObject(with: Data(found.utf8)) as? [String: Any])
        let result = try #require(envelope["result"] as? [String: Any])
        let matches = try #require(result["matches"] as? [[String: Any]])
        #expect(matches.first?["path"] as? String == "Conversation › Appearance › Check Spelling While Typing")
        #expect((matches.first?["open_with"] as? String)?.contains("⌘,") == true)

        let missing = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await OsaurusHelpTool().execute(argumentsJSON: #"{"action":"find","query":"zzqxv"}"#)
        }
        let noneEnvelope = try #require(try JSONSerialization.jsonObject(with: Data(missing.utf8)) as? [String: Any])
        let none = try #require(noneEnvelope["result"] as? [String: Any])
        #expect((none["matches"] as? [[String: Any]])?.isEmpty == true)
        #expect((none["note"] as? String)?.contains("Do not invent") == true)
    }

    @Test("The Orchestrator prompt tells it to look settings up, not guess")
    func promptMentionsFindSetting() {
        let prompt = IntelOrchestratorPrompt.compose(agentID: Agent.defaultId, editablePrompt: "")
        #expect(prompt.contains("action: \"find\""))
    }

    // MARK: - #25 agent default working folder

    @Test("Working folder keys round-trip and upstream's legacy keys still decode")
    func workingFolderCodable() throws {
        var agent = Agent(name: "Folders", systemPrompt: "x", agentAddress: nil)
        agent.workingFolderPath = "/Users/test/Projects"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(agent)
        #expect(String(decoding: data, as: UTF8.self).contains("workingFolderPath"))
        #expect(try decoder.decode(Agent.self, from: data).workingFolderPath == "/Users/test/Projects")

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "workingFolderPath")
        object["hostWorkspacePath"] = "/Users/test/Legacy"
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try decoder.decode(Agent.self, from: legacy).workingFolderPath == "/Users/test/Legacy")
    }

    @MainActor
    @Test("A new chat opens in the agent's default folder; a project folder wins")
    func newChatUsesAgentFolder() async throws {
        try await ChatHistoryTestStorage.run {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-agent-folder-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            let agent = Agent(name: "Worker", systemPrompt: "x", agentAddress: nil)
            AgentManager.shared.add(agent)
            AgentManager.shared.setWorkingFolder(path: folder.path, for: agent.id)
            #expect(AgentManager.shared.agent(for: agent.id)?.workingFolderPath == folder.path)

            let session = ChatSession()
            session.reset(for: agent.id)
            #expect(session.folderState.persistedPath == folder.path)

            // Switching to the built-in agent drops the custom agent's folder.
            session.reset(for: Agent.defaultId)
            #expect(session.folderState.persistedPath == nil)

            // A chat that already belongs to a project keeps the project's folder.
            session.reset(for: agent.id)
            session.projectId = UUID()
            session.applyAgentDefaultFolder()
            #expect(session.folderState.persistedPath == folder.path)  // unchanged: guard skipped

            AgentManager.shared.setWorkingFolder(path: nil, for: agent.id)
            #expect(AgentManager.shared.agent(for: agent.id)?.workingFolderPath == nil)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @MainActor
    @Test("The built-in agent never gets a default folder")
    func defaultAgentHasNoFolder() async throws {
        try await ChatHistoryTestStorage.run {
            AgentManager.shared.setWorkingFolder(path: "/tmp", for: Agent.defaultId)
            #expect(AgentManager.shared.agent(for: Agent.defaultId)?.workingFolderPath == nil)
        }
    }
}
