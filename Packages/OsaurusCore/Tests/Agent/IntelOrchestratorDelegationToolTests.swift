import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel Orchestrator delegation tool", .serialized)
struct IntelOrchestratorDelegationToolTests {
    @Test("live target discovery is read-only and built-in only")
    func targetDiscoveryIsScoped() async throws {
        let id = Self.targetID
        let tool = IntelOrchestratorTargetsTool(snapshotBuilder: {
            .init(targets: [.init(id: id, name: "Rosy Helper", modelID: "cloud/child")], blocked: [])
        })
        #expect(ToolEnvelope.isError(try await tool.execute(argumentsJSON: "{}")))
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await tool.execute(argumentsJSON: "{}")
        }
        #expect(!ToolEnvelope.isError(result))
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        let payload = try #require(envelope["result"] as? [String: Any])
        let targets = try #require(payload["targets"] as? [[String: String]])
        #expect(targets.first?["target_agent_id"] == id.uuidString)
        #expect(targets.first?["model"] == "cloud/child")
    }

    @Test("custom and unbound contexts fail before constructing a child")
    func contextFailsClosed() async throws {
        let builds = DelegationBuildCounter()
        let tool = IntelOrchestratorDelegationTool(runtimeBuilder: {
            await builds.record()
            return Self.runtime(permission: .alwaysAllow)
        })
        let arguments = Self.arguments(targetID: Self.targetID)

        #expect(ToolEnvelope.isError(try await tool.execute(argumentsJSON: arguments)))
        let custom = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await tool.execute(argumentsJSON: arguments)
        }
        #expect(ToolEnvelope.isError(custom))
        #expect(await builds.count == 0)
    }

    @Test("Ask pauses for exact approval and returns only bounded inline text")
    func askAllowsOneBoundedTurn() async throws {
        let approvals = DelegationApprovalCapture(decision: .allowOnce)
        let tool = IntelOrchestratorDelegationTool(
            runtimeBuilder: { Self.runtime(permission: .ask, outputLimit: 4) },
            approvalRequester: { request in await approvals.request(request) }
        )

        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await tool.execute(argumentsJSON: Self.arguments(targetID: Self.targetID))
        }

        #expect(!ToolEnvelope.isError(result))
        let envelope = try #require(
            JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        )
        let payload = try #require(envelope["result"] as? [String: Any])
        #expect(payload["text"] as? String == "chil")
        #expect(!result.contains("session_id"))
        #expect(await approvals.requests.count == 1)
        #expect(await approvals.requests.first?.scope == Self.scope)
    }

    @Test("Deny prevents child execution")
    func denyPreventsExecution() async throws {
        let engine = DelegationEngineCounter()
        let tool = IntelOrchestratorDelegationTool(
            runtimeBuilder: { Self.runtime(permission: .deny, engine: engine) }
        )

        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await tool.execute(argumentsJSON: Self.arguments(targetID: Self.targetID))
        }

        #expect(ToolEnvelope.isError(result))
        #expect(await engine.calls == 0)
    }

    @Test("Always Allow persists only the exact launcher and target pair")
    func alwaysAllowPersistsExactScope() async throws {
        let approvals = DelegationApprovalCapture(decision: .alwaysAllow)
        let persisted = DelegationScopeCapture()
        let tool = IntelOrchestratorDelegationTool(
            runtimeBuilder: { Self.runtime(permission: .ask) },
            approvalRequester: { request in await approvals.request(request) },
            alwaysAllowPersister: { scope in await persisted.record(scope) }
        )

        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await tool.execute(argumentsJSON: Self.arguments(targetID: Self.targetID))
        }

        #expect(!ToolEnvelope.isError(result))
        #expect(await persisted.scopes == [Self.scope])
    }

    private static let targetID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private static let scope = OrchestratorDelegationPermissionScope(
        launcherAgentID: Agent.defaultId,
        targetAgentID: targetID
    )

    private static func arguments(targetID: UUID) -> String {
        #"{"target_agent_id":"\#(targetID.uuidString)","request":"Do one thing."}"#
    }

    private static func runtime(
        permission: OrchestratorDelegationPermission,
        outputLimit: Int = 128,
        engine: DelegationEngineCounter = DelegationEngineCounter()
    ) -> IntelOrchestratorDelegationRuntime {
        var configuration = OrchestratorDelegationConfiguration(
            customAgentAllowlist: [targetID],
            admittedCloudModelIDs: ["cloud/child"],
            maximumChildTokens: 16,
            maximumInputCharacters: 100,
            maximumOutputCharacters: outputLimit,
            timeoutSeconds: 5
        )
        configuration.setPermission(permission, for: scope)
        let target = IntelOrchestratorDelegationRuntime.TargetSnapshot(
            agentID: targetID,
            isBuiltIn: false,
            systemPrompt: "Child role",
            effectiveModel: "cloud/child",
            effectiveTemperature: 0.2,
            effectiveMaxTokens: 32
        )
        return IntelOrchestratorDelegationRuntime(
            configuration: configuration,
            targetResolver: { $0 == targetID ? target : nil },
            cloudModelValidator: { $0 == "cloud/child" },
            engineFactory: { DelegationTestEngine(counter: engine) },
            // The live runtime deliberately uses a process-wide slot. Tests in
            // this suite use their own slot so another concurrency test cannot
            // reserve the live slot between this tool's Ask and approved retry.
            childSlot: IntelOrchestratorDelegationChildSlot()
        )
    }
}

private actor DelegationBuildCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor DelegationApprovalCapture {
    let decision: IntelOrchestratorDelegationTool.ApprovalDecision
    private(set) var requests: [IntelOrchestratorDelegationTool.ApprovalRequest] = []

    init(decision: IntelOrchestratorDelegationTool.ApprovalDecision) {
        self.decision = decision
    }

    func request(_ request: IntelOrchestratorDelegationTool.ApprovalRequest) -> IntelOrchestratorDelegationTool.ApprovalDecision {
        requests.append(request)
        return decision
    }
}

private actor DelegationScopeCapture {
    private(set) var scopes: [OrchestratorDelegationPermissionScope] = []
    func record(_ scope: OrchestratorDelegationPermissionScope) { scopes.append(scope) }
}

private actor DelegationEngineCounter {
    private(set) var calls = 0
    func record() { calls += 1 }
}

private struct DelegationTestEngine: ChatEngineProtocol {
    let counter: DelegationEngineCounter

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        await counter.record()
        return ChatCompletionResponse(
            id: "child",
            object: nil,
            created: nil,
            model: request.model,
            choices: [.init(
                index: 0,
                message: .init(role: "assistant", content: "child output", tool_calls: nil, reasoning_content: nil),
                finish_reason: "stop"
            )],
            usage: nil
        )
    }
}
