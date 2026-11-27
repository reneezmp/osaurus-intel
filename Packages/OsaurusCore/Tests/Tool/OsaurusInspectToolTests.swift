//
//  OsaurusInspectToolTests.swift
//  OsaurusCoreTests
//
//  Intel (W-subagents stage 4): `osaurus_inspect`, upstream's read-only
//  configuration surface for the Orchestrator. Pins the contract (actions,
//  scope enum, gating), the teaching failures, the document-section read, and
//  the owner policy: reads never carry secrets and never touch the Keychain.
//

import Foundation
import Testing

@testable import OsaurusCore

struct OsaurusInspectToolTests {

    private func parse(_ envelope: String) throws -> [String: Any] {
        let data = try #require(envelope.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func run(_ json: String) async throws -> [String: Any] {
        let envelope = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await OsaurusInspectTool().execute(argumentsJSON: json)
        }
        return try parse(envelope)
    }

    // MARK: schema and gating

    @Test
    func schema_listsTheThreeActionsAndTheScopeRoster() throws {
        let tool = OsaurusInspectTool()
        #expect(tool.name == "osaurus_inspect")
        let data = try JSONEncoder().encode(try #require(tool.parameters))
        let schema = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let props = try #require(schema["properties"] as? [String: Any])
        let action = try #require(props["action"] as? [String: Any])
        #expect(Set(action["enum"] as? [String] ?? []) == ["status", "list", "describe"])
        let scopes = Set(try #require((props["scope"] as? [String: Any])?["enum"] as? [String]))
        for scope in ["agents", "providers", "mcp", "plugins", "schedules", "skills", "knowledge", "delegation", "harness_runtimes"] {
            #expect(scopes.contains(scope), "\(scope)")
        }
        // Scopes Intel lacks are not advertised.
        for scope in ["channels", "workspaces", "shared_agents"] {
            #expect(!scopes.contains(scope), "\(scope)")
        }
        #expect(schema["additionalProperties"] as? Bool == false)
    }

    @Test
    func execute_isGatedToTheOrchestrator() async throws {
        let asCustom = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await OsaurusInspectTool().execute(argumentsJSON: #"{"action": "status"}"#)
        }
        #expect(try parse(asCustom)["kind"] as? String == "unavailable")
        let noContext = try await OsaurusInspectTool().execute(argumentsJSON: #"{"action": "status"}"#)
        #expect(try parse(noContext)["kind"] as? String == "unavailable")
    }

    @Test
    func onlyTheOrchestratorIsOfferedTheTool() async {
        let orchestrator = await SystemPromptComposer.composeChatContext(agentId: Agent.defaultId, toolsDisabled: false)
        #expect(orchestrator.tools.contains { $0.function.name == OsaurusInspectTool.toolName })
        #expect(orchestrator.prompt.contains("osaurus_inspect"))
        #expect(ToolRegistry.orchestratorOnlyToolNames.contains(OsaurusInspectTool.toolName))
        #expect(ToolRegistry.shared.handlesOwnApproval(for: OsaurusInspectTool.toolName) == false)
    }

    @Test
    func unknownAction_isAnInvalidArgsFailure() async throws {
        let dict = try await run(#"{"action": "delete"}"#)
        #expect(dict["ok"] as? Bool == false)
    }

    // MARK: reads

    @Test
    func status_reportsTheSpawnPoolAndNextStep() async throws {
        let dict = try await run(#"{"action": "status"}"#)
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        let pool = try #require(result["spawn_pool"] as? [String: Any])
        #expect(["ready", "empty", "no_agents"].contains(pool["state"] as? String ?? ""))
        #expect(pool["runnable_targets"] is Int)
        #expect(pool["admitted_cloud_models"] is Int)
        #expect(result["new_chat_agent"] is [String: Any])
        #expect(result["suggestions"] is [String])
        #expect((result["next_step"] as? String)?.contains("osaurus_config") == true)
    }

    @Test
    func listAgents_carriesTheGate4Flag_andTheYamlShape() async throws {
        let dict = try await run(#"{"action": "list", "scope": "agents"}"#)
        let result = try #require(dict["result"] as? [String: Any])
        let items = try #require(result["items"] as? [[String: Any]])
        #expect(!items.isEmpty)
        for row in items { #expect(row["orchestrator_allowed"] is Bool) }
        #expect((result["yaml_shape"] as? String)?.contains("agents") == true)
    }

    @Test
    func filterNamingAScope_isTreatedAsTheScope() async throws {
        let dict = try await run(#"{"action": "list", "filter": "schedules"}"#)
        #expect(dict["ok"] as? Bool == true)
        #expect((dict["note"] as? String)?.contains("is a scope, not a filter") == true)
    }

    @Test
    func documentSection_isReadAsYaml() async throws {
        let dict = try await run(#"{"action": "describe", "scope": "delegation"}"#)
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["kind"] as? String == "document_section")
        #expect(result["yaml"] is String)
        #expect((result["yaml_shape"] as? String)?.contains("spawnable_agents") == true)
    }

    @Test
    func describeWithoutId_routesToList_andMissingItemIsNotFound() async throws {
        let noId = try await run(#"{"action": "describe", "scope": "agents"}"#)
        #expect(noId["ok"] as? Bool == false)
        #expect((noId["message"] as? String)?.contains("action: 'list'") == true)
        let missing = try await run(#"{"action": "describe", "scope": "agents", "id": "no-such-agent-xyz"}"#)
        #expect(missing["ok"] as? Bool == false)
        #expect((missing["message"] as? String)?.contains("No `agents` matched") == true)
    }

    // MARK: teaching failures

    @Test
    func scopesIntelLacks_areAnHonestUnavailable() async throws {
        for scope in ["channels", "workspaces", "shared_agents"] {
            let dict = try await run(#"{"action": "list", "scope": "\#(scope)"}"#)
            #expect(dict["ok"] as? Bool == false, "\(scope)")
            #expect(dict["kind"] as? String == "unavailable", "\(scope)")
        }
    }

    @Test
    func settingsUIOnlyScopes_sayNothingWasChanged() async throws {
        let dict = try await run(#"{"action": "list", "scope": "server"}"#)
        #expect(dict["ok"] as? Bool == false)
        #expect((dict["message"] as? String)?.contains("Settings UI") == true)
    }

    // MARK: owner policy: no secrets

    @Test
    func rows_neverCarrySecretFlagsOrUrlCredentials() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Tools/OsaurusInspectTool.swift"), encoding: .utf8)
        // Upstream reads the Keychain for these flags; Intel's reads never do.
        for banned in ["\"has_api_key\"", "\"has_token\"", "\"has_oauth\"", "hasAPIKey", "hasOAuthTokens", "hasToken"] {
            #expect(!source.contains(banned), "\(banned)")
        }
    }

    @Test
    func urlRedaction_dropsUserinfoQueryAndFragment() {
        #expect(
            InspectURLRedaction.redacted("https://user:pw@mcp.example.com:8443/v1/sse?token=abc#frag")
                == "https://mcp.example.com:8443/v1/sse")
        #expect(InspectURLRedaction.redacted("https://mcp.example.com/x") == "https://mcp.example.com/x")
        #expect(InspectURLRedaction.redacted("") == "")
    }

    @Test
    func readHint_stateTheWriteContractWithoutSecrets() {
        let hint = ConfigurationReadNextStep.hint(hasShape: true)
        #expect(hint.contains("osaurus_config"))
        #expect(hint.contains("never the key value") || hint.contains("never the key"))
        #expect(ConfigurationReadNextStep.shapeSections(forScope: "delegation") == [.delegation])
        #expect(ConfigurationReadNextStep.shapeSections(forScope: "skills") == nil)
        #expect(ConfigurationReadNextStep.secretScopes.contains("providers"))
    }
}

/// The Orchestrator addendum (folded into `IntelOrchestratorPrompt`) names the
/// read tool and states the delegation facts truthfully.
struct OrchestratorAddendumInspectTests {
    @Test
    func addendumNamesTheReadTool_andSpawnFactsAreTruthful() {
        let base = IntelOrchestratorPrompt.compose(agentID: Agent.defaultId, editablePrompt: "")
        #expect(base.contains("`osaurus_inspect`"))
        #expect(base.contains("never shows secrets"))
        let spawn = IntelOrchestratorPrompt.compose(
            agentID: Agent.defaultId, editablePrompt: "", spawnAgentAvailable: true)
        #expect(spawn.contains("`spawn_agent`"))
        #expect(spawn.contains("Creating an agent does not make it delegable"))
        #expect(!spawn.contains("tool-free"))
        // A custom agent's prompt is untouched.
        #expect(IntelOrchestratorPrompt.compose(agentID: UUID(), editablePrompt: "mine") == "mine")
    }
}
