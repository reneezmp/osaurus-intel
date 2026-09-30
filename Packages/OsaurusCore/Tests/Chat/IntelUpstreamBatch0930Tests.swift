//
//  IntelUpstreamBatch0930Tests.swift
//  OsaurusCoreTests
//
//  The Intel slices of upstream #2936 (2026-09-30 audit,
//  docs/UPSTREAM_AUDIT_2026-09-30.md): relaxed `find_setting`, the empty
//  delegation list, high-risk plans that empty it, and `new_chat_agent`.
//  #2937 and #2939 ship with their upstream tests
//  (`ClaudeCodePipePumpTests`, `OptionalDoubleFieldEditingTests`).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel upstream batch 2026-09-30", .serialized)
struct IntelUpstreamBatch0930Tests {

    // MARK: - Relaxed find_setting

    /// "please" appears in no Settings entry, so the strict pass is empty and
    /// the relaxed pass must find the Memory switch.
    @Test func findSettingDropsIntentWordsWhenTheStrictPassIsEmpty() {
        #expect(SettingsSearchIndex.search("please turn off memory").isEmpty)
        let lookup = IntelOrchestratorConfigurationTool.findSettings("please turn off memory")
        #expect(lookup.relaxedQuery == "memory")
        #expect(lookup.entries.contains { $0.title == "Enable memory" })

        let result = IntelOrchestratorConfigurationTool.findSettingResult(query: "please turn off memory")
        #expect(result["relaxed_query"] as? String == "memory")
        #expect((result["matches"] as? [[String: Any]])?.isEmpty == false)
    }

    @Test func findSettingKeepsTheStrictMatchAndReportsNoRelaxation() {
        let lookup = IntelOrchestratorConfigurationTool.findSettings("memory")
        #expect(lookup.relaxedQuery == nil)
        #expect(!lookup.entries.isEmpty)
        #expect(IntelOrchestratorConfigurationTool.findSettingResult(query: "memory")["relaxed_query"] == nil)
    }

    @Test func findSettingMadeOnlyOfIntentWordsFindsNothing() {
        let lookup = IntelOrchestratorConfigurationTool.findSettings("please turn it off")
        #expect(lookup.entries.isEmpty)
        #expect(lookup.relaxedQuery == nil)
    }

    // MARK: - Empty delegation list

    @Test func emptyAllowlistWithCustomAgentsNamesTheRepair() {
        var agent = Agent(name: "Chef", systemPrompt: "Cook", agentAddress: nil)
        agent.defaultModel = "deepseek-flash"
        var configuration = OrchestratorDelegationConfiguration()
        configuration.admittedCloudModelIDs = ["deepseek-flash"]
        let evaluation = IntelOrchestratorAdmission.evaluate(
            configuration: configuration, agents: [Agent.default, agent], effectiveModel: { _ in "deepseek-flash" })
        #expect(evaluation.targets.isEmpty)
        let message = try? #require(evaluation.blocked.first { $0.hasPrefix("No custom agent is allowed") })
        #expect(message?.contains("1 custom agent(s) exist") == true)
        #expect(message?.contains("Add all agents") == true)
        #expect(message?.contains("replaces the current one") == true)
    }

    @Test func emptyAllowlistWithoutCustomAgentsKeepsTheShortMessage() {
        let evaluation = IntelOrchestratorAdmission.evaluate(
            configuration: OrchestratorDelegationConfiguration(), agents: [Agent.default], effectiveModel: { _ in nil })
        #expect(evaluation.blocked.contains("No custom agent is allowed."))
    }

    @Test func addAllAgentsIsFindableInSettingsSearch() {
        let hits = SettingsSearchIndex.search("add all agents")
        #expect(hits.first?.tab == .orchestrator)
        #expect(hits.first?.title == "Add all agents")
    }

    // MARK: - High-risk plans

    @Test func planThatEmptiesTheAllowlistIsHighRisk() async throws {
        let agentID = UUID()
        let store = BatchTestStore(value: .init(delegation: .init(customAgentAllowlist: [agentID])))
        let service = IntelDeclarativeConfigurationService(store: store)
        let plan = try await service.plan(json: Data(#"{"version":1,"delegation":{"allowed_agent_ids":[]}}"#.utf8))
        #expect(plan.warnings.count == 1)
        #expect(plan.warnings.first?.hasPrefix("High risk") == true)

        let replacing = try await service.plan(
            json: Data(#"{"version":1,"delegation":{"allowed_agent_ids":["\#(UUID().uuidString)"]}}"#.utf8))
        #expect(replacing.warnings.isEmpty)
    }

    @Test func toolResultCarriesPlanWarnings() async throws {
        let store = BatchTestStore(value: .init(delegation: .init(customAgentAllowlist: [UUID()])))
        let tool = IntelOrchestratorConfigurationTool(service: .init(store: store)) { _ in .denied }
        let data = try JSONSerialization.data(withJSONObject: [
            "operation": "plan", "document": #"{"version":1,"delegation":{"allowed_agent_ids":[]}}"#,
        ])
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await tool.execute(argumentsJSON: String(decoding: data, as: UTF8.self))
        }
        #expect(!ToolEnvelope.isError(result))
        #expect(result.contains("High risk"))
        #expect(store.saveCount == 0)
    }

    // MARK: - new_chat_agent

    @Test func newChatAgentDecodesIdsOrchestratorAndNull() throws {
        let id = UUID()
        func decode(_ value: String) throws -> IntelDeclarativeField<UUID> {
            try IntelDeclarativeConfigurationDocument.decode(
                json: Data(#"{"version":1,"new_chat_agent":\#(value)}"#.utf8)
            ).newChatAgent
        }
        #expect(try decode("\"\(id.uuidString)\"") == .set(id))
        #expect(try decode("\"orchestrator\"") == .clear)
        #expect(try decode("null") == .clear)
        #expect(try decode("\"\(Agent.defaultId.uuidString)\"") == .clear)
        #expect(throws: IntelDeclarativeConfigurationError.self) { try decode("\"not-an-id\"") }
        #expect(throws: IntelDeclarativeConfigurationError.self) { try decode("42") }
    }

    @Test func newChatAgentPlansAppliesAndExports() async throws {
        let id = UUID()
        let store = BatchTestStore(value: .init())
        let service = IntelDeclarativeConfigurationService(store: store)
        let plan = try await service.plan(json: Data(#"{"version":1,"new_chat_agent":"\#(id.uuidString)"}"#.utf8))
        #expect(plan.changes.map(\.path) == ["new_chat_agent"])
        #expect(plan.changes.first?.before == "orchestrator")
        #expect(plan.changes.first?.after == id.uuidString)

        let approval = await service.approve(plan)
        _ = try await service.apply(plan, approval: approval)
        #expect(store.load().newChatAgentId == id)

        let exported = try await service.exportJSON()
        #expect(String(decoding: exported, as: UTF8.self).contains(id.uuidString))
    }

    @Test func toolRejectsANewChatAgentThatDoesNotExist() async throws {
        let store = BatchTestStore(value: .init())
        let tool = IntelOrchestratorConfigurationTool(service: .init(store: store)) { _ in .approved }
        let data = try JSONSerialization.data(withJSONObject: [
            "operation": "apply", "document": #"{"version":1,"new_chat_agent":"\#(UUID().uuidString)"}"#,
        ])
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await tool.execute(argumentsJSON: String(decoding: data, as: UTF8.self))
        }
        #expect(ToolEnvelope.isError(result))
        #expect(store.saveCount == 0)
    }

    @Test func newChatAgentFallsBackToTheOrchestrator() {
        let existing = UUID()
        #expect(AgentManager.resolveNewChatAgentId(configured: nil, existingAgentIds: [existing]) == Agent.defaultId)
        #expect(AgentManager.resolveNewChatAgentId(configured: UUID(), existingAgentIds: [existing]) == Agent.defaultId)
        #expect(AgentManager.resolveNewChatAgentId(configured: existing, existingAgentIds: [existing]) == existing)
    }

    /// Older `default-agent.json` files have no `newChatAgentId`; an unset
    /// value must not appear in the file, so existing fingerprints stay put.
    @Test func olderConfigurationDecodesWithoutANewChatAgent() throws {
        let decoded = try JSONDecoder().decode(
            DefaultAgentConfiguration.self, from: Data(#"{"displayName":"Legacy"}"#.utf8))
        #expect(decoded.newChatAgentId == nil)
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!encoded.contains("newChatAgentId"))

        let id = UUID()
        let roundTrip = try JSONDecoder().decode(
            DefaultAgentConfiguration.self,
            from: JSONEncoder().encode(DefaultAgentConfiguration(newChatAgentId: id)))
        #expect(roundTrip.newChatAgentId == id)
    }
}

private final class BatchTestStore: IntelDeclarativeDefaultAgentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: DefaultAgentConfiguration
    private(set) var saveCount = 0

    init(value: DefaultAgentConfiguration) { self.value = value }

    func load() -> DefaultAgentConfiguration { lock.withLock { value } }
    func loadFresh() throws -> DefaultAgentConfiguration { lock.withLock { value } }
    func save(_ configuration: DefaultAgentConfiguration) throws {
        lock.withLock {
            value = configuration
            saveCount += 1
        }
    }
}
