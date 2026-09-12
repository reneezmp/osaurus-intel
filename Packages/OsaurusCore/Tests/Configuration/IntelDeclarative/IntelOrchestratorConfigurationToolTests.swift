import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel Orchestrator configuration tool", .serialized)
struct IntelOrchestratorConfigurationToolTests {
    @Test("registry exposes the schema only to the built-in Orchestrator")
    func registryVisibilityIsScoped() async {
        let unbound = ToolRegistry.shared.openAISpecs().map(\.function.name)
        let custom = ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            ToolRegistry.shared.openAISpecs().map(\.function.name)
        }
        let orchestrator = ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            ToolRegistry.shared.openAISpecs().map(\.function.name)
        }

        #expect(!unbound.contains(IntelOrchestratorConfigurationTool.toolName))
        #expect(!custom.contains(IntelOrchestratorConfigurationTool.toolName))
        #expect(orchestrator.contains(IntelOrchestratorConfigurationTool.toolName))
        #expect(ToolRegistry.shared.handlesOwnApproval(for: IntelOrchestratorConfigurationTool.toolName))
    }

    @Test("unbound and custom agents cannot execute the tool")
    func scopeFailsClosed() async throws {
        let tool = IntelOrchestratorConfigurationTool()
        let unbound = try await tool.execute(argumentsJSON: #"{"operation":"schema"}"#)
        #expect(ToolEnvelope.isError(unbound))

        let custom = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await tool.execute(argumentsJSON: #"{"operation":"schema"}"#)
        }
        #expect(ToolEnvelope.isError(custom))
    }

    @Test("planning is read-only and does not return private current values")
    func planningIsPrivateAndReadOnly() async throws {
        let store = ToolTestStore(value: .init(displayName: "private-before-value"))
        let tool = IntelOrchestratorConfigurationTool(service: .init(store: store)) { _ in .denied }
        let result = try await run(tool, operation: "plan", document: #"{"version":1,"default_agent":{"name":"After"}}"#)

        #expect(!ToolEnvelope.isError(result))
        #expect(!result.contains("private-before-value"))
        #expect(result.contains("default_agent.name"))
        #expect(store.saveCount == 0)
    }

    @Test("denied apply cannot mint a receipt or mutate")
    func deniedApplyDoesNotMutate() async throws {
        let store = ToolTestStore(value: .init(displayName: "Before"))
        let tool = IntelOrchestratorConfigurationTool(service: .init(store: store)) { _ in .denied }
        let result = try await run(tool, operation: "apply", document: #"{"version":1,"default_agent":{"name":"After"}}"#)

        #expect(ToolEnvelope.isError(result))
        #expect(store.load().displayName == "Before")
        #expect(store.saveCount == 0)
    }

    @Test("approved exact plan applies once")
    func approvedApplyMutates() async throws {
        let store = ToolTestStore(value: .init(displayName: "Before"))
        let tool = IntelOrchestratorConfigurationTool(service: .init(store: store)) { _ in .approved }
        let result = try await run(tool, operation: "apply", document: #"{"version":1,"default_agent":{"name":"After"}}"#)

        #expect(!ToolEnvelope.isError(result))
        #expect(store.load().displayName == "After")
        #expect(store.saveCount == 1)
    }

    private func run(
        _ tool: IntelOrchestratorConfigurationTool,
        operation: String,
        document: String
    ) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["operation": operation, "document": document])
        return try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await tool.execute(argumentsJSON: String(decoding: data, as: UTF8.self))
        }
    }
}

private final class ToolTestStore: IntelDeclarativeDefaultAgentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: DefaultAgentConfiguration
    private(set) var saveCount = 0

    init(value: DefaultAgentConfiguration) { self.value = value }

    func load() -> DefaultAgentConfiguration {
        lock.withLock { value }
    }

    func loadFresh() throws -> DefaultAgentConfiguration {
        lock.withLock { value }
    }

    func save(_ configuration: DefaultAgentConfiguration) throws {
        lock.withLock {
            value = configuration
            saveCount += 1
        }
    }
}
