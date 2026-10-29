//
//  IntelHTTPAgentRoutesTests.swift
//  OsaurusCoreTests
//
//  `W-server-api` stage 4a (docs/SERVER_API_INTEL.md): the agent management
//  routes over a real NIO server. Upstream's `HTTPHandlerEndpointTests`
//  agent-metadata cases (its runtime-settings and DSV4 cases wait for
//  stage 7 and MLX), the `/agents` halves of two `HTTPAuthGateTests` cases
//  whose other halves need routes Intel doesn't have yet, and Intel cases
//  for the owner-only edits, dispatch and tasks (stage 4b).
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelHTTPAgentRoutesTests {

    // MARK: - Agent metadata resolution (upstream)

    /// A paired remote peer addresses agent metadata by the agent's crypto
    /// address; the host resolves it via `AgentIdentityRegistry`.
    @Test func getAgent_byCryptoAddress_resolvesMetadata() async throws {
        let server = try await startAgentTestServer()
        defer { Task { await server.shutdown() } }

        try await ChatHistoryTestStorage.run {
            let hostAgentId = UUID()
            let address = "0xfeed000000000000000000000000000000000099"
            let agent = Agent(
                id: hostAgentId,
                name: "Metadata Peer",
                defaultModel: "fake-metadata-model",
                isBuiltIn: false,
                agentIndex: 0,
                agentAddress: address,
                autonomousExec: AutonomousExecConfig(enabled: false)
            )
            await MainActor.run { AgentManager.shared.add(agent) }
            AgentIdentityRegistry.shared.update(
                addresses: [address],
                indices: [0],
                addressByAgentId: [hostAgentId: address]
            )
            defer {
                AgentIdentityRegistry.shared.update(addresses: [], indices: [], addressByAgentId: [:])
            }

            let single = try await server.send("GET", "/agents/\(address)")
            #expect(single.status == 200)
            let obj = try single.object()
            #expect(obj["id"] as? String == hostAgentId.uuidString)
            #expect(obj["default_model"] as? String == "fake-metadata-model")
            #expect(obj["description"] as? String == "")
            #expect(obj["description_required"] == nil)

            let list = try await server.send("GET", "/agents")
            #expect(list.status == 200)
            let rows = try list.object()["agents"] as? [[String: Any]]
            #expect(rows?.contains { $0["id"] as? String == hostAgentId.uuidString } == true)

            // An address with no registry mapping still fails closed.
            let unknown = try await server.send("GET", "/agents/0xdead000000000000000000000000000000000000")
            #expect(unknown.status == 400)
            #expect(unknown.body.contains("invalid_agent_id"))

            _ = await AgentManager.shared.delete(id: hostAgentId)
        }
    }

    /// The agent's own Action Bar is advertised on `GET /agents/{id}`.
    /// (Upstream also round-trips it through its remote-provider parser,
    /// which Intel doesn't have.)
    @Test func getAgent_advertisesActionBarQuickActions() async throws {
        let server = try await startAgentTestServer()
        defer { Task { await server.shutdown() } }

        try await ChatHistoryTestStorage.run {
            let hostAgentId = UUID()
            let actions = [
                AgentQuickAction(icon: "book", text: "Explain", prompt: "Explain "),
                AgentQuickAction(icon: "doc", text: "Summarize", prompt: "Summarize "),
            ]
            let agent = Agent(
                id: hostAgentId,
                name: "Action Bar Peer",
                description: "Explains and summarizes documents.",
                defaultModel: "fake-metadata-model",
                chatQuickActions: actions,
                isBuiltIn: false
            )
            await MainActor.run { AgentManager.shared.add(agent) }

            let result = try await server.send("GET", "/agents/\(hostAgentId.uuidString)")
            #expect(result.status == 200)
            let obj = try result.object()
            #expect(obj["description"] as? String == "Explains and summarizes documents.")
            let wireActions = obj["chat_quick_actions"] as? [[String: Any]]
            #expect(wireActions?.count == 2)
            #expect(wireActions?.first?["text"] as? String == "Explain")
            #expect(wireActions?.first?["prompt"] as? String == "Explain ")

            _ = await AgentManager.shared.delete(id: hostAgentId)
        }
    }

    /// Intel: the Orchestrator has no configure-oriented quick actions of its
    /// own, so every agent sends exactly its Action Bar (nil = chat defaults).
    @Test func clientQuickActions_sendsTheAgentsOwnActionBar() {
        let plain = Agent(id: UUID(), name: "Plain", description: "", isBuiltIn: false)
        #expect(HTTPHandler.clientQuickActions(for: plain) == nil)

        var hidden = Agent.default
        hidden.chatQuickActions = []
        #expect(HTTPHandler.clientQuickActions(for: hidden)?.isEmpty == true)

        let custom = [AgentQuickAction(icon: "book", text: "Read", prompt: "Read ")]
        let mine = Agent(id: UUID(), name: "Mine", chatQuickActions: custom, isBuiltIn: false)
        #expect(HTTPHandler.clientQuickActions(for: mine) == custom)
    }

    // MARK: - Owner edits (Intel)

    @Test func ownerOnLoopback_createsEditsRetunesAndDeletesAnAgent() async throws {
        let server = try await startAgentTestServer()
        defer { Task { await server.shutdown() } }

        try await ChatHistoryTestStorage.run {
            let created = try await server.send(
                "POST", "/agents", json: #"{"name":"  Phone Agent  ","description":"From the phone","model":"m-one"}"#)
            #expect(created.status == 201, "\(created.body)")
            let idString = try #require(try created.object()["id"] as? String)
            let agentId = try #require(UUID(uuidString: idString))
            #expect(try created.object()["name"] as? String == "Phone Agent")

            let made = try #require(await MainActor.run { AgentManager.shared.agent(for: agentId) })
            #expect(made.defaultModel == "m-one")
            #expect(made.description == "From the phone")

            // The owner reads the settings and the prompt.
            let detail = try await server.send("GET", "/agents/\(idString)")
            #expect(detail.status == 200)
            #expect(try detail.object()["settings"] != nil)
            #expect(try detail.object()["system_prompt"] != nil)

            let renamed = try await server.send("PATCH", "/agents/\(idString)", json: #"{"name":"Scout"}"#)
            #expect(renamed.status == 200, "\(renamed.body)")
            #expect(await MainActor.run { AgentManager.shared.agent(for: agentId)?.name } == "Scout")

            let refused = try await server.send("PATCH", "/agents/\(idString)", json: #"{"temperature":9}"#)
            #expect(refused.status == 400, "\(refused.body)")

            let retuned = try await server.send("PUT", "/agents/\(idString)/model", json: #"{"model":"m-two"}"#)
            #expect(retuned.status == 200, "\(retuned.body)")
            #expect(try retuned.object()["effective_model"] as? String == "m-two")

            let deleted = try await server.send("DELETE", "/agents/\(idString)")
            #expect(deleted.status == 200, "\(deleted.body)")
            #expect(await MainActor.run { AgentManager.shared.agent(for: agentId) } == nil)

            let gone = try await server.send("GET", "/agents/\(idString)")
            #expect(gone.status == 404)
        }
    }

    @Test func createAgent_needsAName() async throws {
        let server = try await startAgentTestServer()
        defer { Task { await server.shutdown() } }
        let blank = try await server.send("POST", "/agents", json: #"{"name":"   "}"#)
        #expect(blank.status == 400)
        let missing = try await server.send("POST", "/agents", json: #"{}"#)
        #expect(missing.status == 400)
    }

    @Test func builtInAgentIsNotEditable() async throws {
        let server = try await startAgentTestServer()
        defer { Task { await server.shutdown() } }
        let id = Agent.defaultId.uuidString
        let patch = try await server.send("PATCH", "/agents/\(id)", json: #"{"name":"Nope"}"#)
        #expect(patch.status == 403, "\(patch.body)")
        #expect(patch.body.contains("agent_not_editable"))
        let delete = try await server.send("DELETE", "/agents/\(id)")
        #expect(delete.status == 403, "\(delete.body)")
    }

    @Test func tools_listAndRefuseUnknownToolsAndEmptyPatches() async throws {
        let server = try await startAgentTestServer()
        defer { Task { await server.shutdown() } }

        let list = try await server.send("GET", "/agents/\(Agent.defaultId.uuidString)/tools")
        #expect(list.status == 200)
        let tools = try #require(try list.object()["tools"] as? [[String: Any]])
        #expect(!tools.isEmpty)
        for tool in tools {
            #expect(tool["name"] is String)
            #expect(["auto", "ask", "deny"].contains(tool["policy"] as? String ?? ""))
            #expect(tool["remote_safe"] is Bool)
        }
        // App-only tools are never remote-safe.
        for tool in tools where ToolRegistry.externallyDeniedToolNames.contains(tool["name"] as? String ?? "") {
            #expect(tool["remote_safe"] as? Bool == false, "\(tool["name"] ?? "")")
        }

        let unknown = try await server.send(
            "PATCH", "/agents/\(UUID().uuidString)/tools/no_such_tool", json: #"{"enabled":false}"#)
        #expect(unknown.status == 404, "\(unknown.body)")
        let empty = try await server.send(
            "PATCH", "/agents/\(UUID().uuidString)/tools/no_such_tool", json: #"{}"#)
        #expect(empty.status == 400)

        let badPreset = try await server.send(
            "POST", "/agents/\(UUID().uuidString)/tools/preset", json: #"{"preset":"most"}"#)
        #expect(badPreset.status == 400)
    }

    @Test func avatar_isNotFoundWithoutACustomOne() async throws {
        let server = try await startAgentTestServer()
        defer { Task { await server.shutdown() } }
        let result = try await server.send("GET", "/agents/\(Agent.defaultId.uuidString)/avatar")
        #expect(result.status == 404)
        #expect(result.body.contains("no_custom_avatar"))
    }

    // MARK: - Owner gate (Intel; upstream's rules)

    /// A remote owner key (relayed) may still list agents in plaintext, but
    /// every other owner route answers 426 until Intel has the Secure Channel.
    @Test func remoteOwnerKey_needsTheSecureChannelForOwnerRoutes() async throws {
        let server = try await startAgentTestServer(validator: .forAlice())
        defer { Task { await server.shutdown() } }
        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey, iss: TestKeys.aliceAddress, aud: TestKeys.aliceAddress
        )
        let relay = [HTTPHandler.relayOriginHeaderName: "1"]

        let list = try await server.send("GET", "/agents", token: token, headers: relay)
        #expect(list.status == 200, "\(list.body)")

        let create = try await server.send("POST", "/agents", json: #"{"name":"X"}"#, token: token, headers: relay)
        #expect(create.status == 426, "\(create.body)")
        #expect(create.body.contains("secure_channel_required"))

        let detail = try await server.send(
            "GET", "/agents/\(Agent.defaultId.uuidString)", token: token, headers: relay)
        #expect(detail.status == 426, "\(detail.body)")
    }

    /// A paired agent-scoped key (arriving through the relay, like a phone)
    /// is not the owner: no built-ins in the list, and no agent edits. Over
    /// loopback with the local-key setting off, upstream never reads the key.
    @Test func agentScopedKey_cannotSeeBuiltInsOrEditAgents() async throws {
        let agent = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 3)
        let agentKey = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 3)
        let validator = APIKeyValidator(
            agentAddresses: [agent],
            masterAddress: TestKeys.aliceAddress,
            effectiveWhitelist: [TestKeys.aliceAddress.lowercased(), agent.lowercased()],
            revocationSnapshot: RevocationSnapshot(revokedKeys: [], counterThresholds: [:]),
            hasKeys: true
        )
        let token = try TokenBuilder.build(privateKey: agentKey, iss: agent, aud: agent)
        let server = try await startAgentTestServer(validator: validator)
        defer { Task { await server.shutdown() } }

        let relay = [HTTPHandler.relayOriginHeaderName: "1"]
        let list = try await server.send("GET", "/agents", token: token, headers: relay)
        #expect(list.status == 200, "\(list.body)")
        let rows = try list.object()["agents"] as? [[String: Any]] ?? []
        #expect(!rows.contains { $0["is_built_in"] as? Bool == true })

        let create = try await server.send("POST", "/agents", json: #"{"name":"X"}"#, token: token, headers: relay)
        #expect(create.status == 403, "\(create.body)")
        let tools = try await server.send(
            "GET", "/agents/\(Agent.defaultId.uuidString)/tools", token: token, headers: relay)
        #expect(tools.status == 403, "\(tools.body)")
    }

    // MARK: - Dispatch and tasks (stage 4b)

    @Test func dispatch_validatesBeforeStartingAnything() async throws {
        let server = try await startAgentTestServer()
        defer { Task { await server.shutdown() } }
        let agentPath = "/agents/\(Agent.defaultId.uuidString)/dispatch"

        let missing = try await server.send("POST", agentPath, json: #"{"title":"x"}"#)
        #expect(missing.status == 400, "\(missing.body)")
        #expect(missing.body.contains("prompt"))

        let blank = try await server.send("POST", agentPath, json: #"{"prompt":"   "}"#)
        #expect(blank.status == 400, "\(blank.body)")
        #expect(blank.body.contains("Prompt is empty"))

        let unknown = try await server.send(
            "POST", "/agents/\(UUID().uuidString)/dispatch", json: #"{"prompt":"hi"}"#)
        #expect(unknown.status == 404, "\(unknown.body)")
    }

    /// Remote dispatch needs the Secure Channel, which Intel doesn't have yet.
    @Test func dispatch_fromARemoteOwnerKeyNeedsTheSecureChannel() async throws {
        let server = try await startAgentTestServer(validator: .forAlice())
        defer { Task { await server.shutdown() } }
        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey, iss: TestKeys.aliceAddress, aud: TestKeys.aliceAddress
        )
        let result = try await server.send(
            "POST", "/agents/\(UUID().uuidString)/dispatch", json: #"{"prompt":"hi"}"#, token: token,
            headers: [HTTPHandler.relayOriginHeaderName: "1"])
        #expect(result.status == 426, "\(result.body)")
    }

    @Test func tasks_statusCancelAndClarify() async throws {
        let server = try await startAgentTestServer()
        defer { Task { await server.shutdown() } }
        let id = UUID().uuidString

        let badId = try await server.send("GET", "/tasks/not-a-task")
        #expect(badId.status == 400)
        #expect(badId.body.contains("invalid_task_id"))

        let unknown = try await server.send("GET", "/v1/tasks/\(id)")
        #expect(unknown.status == 404)

        let cancel = try await server.send("DELETE", "/tasks/\(id)")
        #expect(cancel.status == 204)

        let clarify = try await server.send("POST", "/tasks/\(id)/clarify", json: #"{"response":"yes"}"#)
        #expect(clarify.status == 410, "\(clarify.body)")
        let clarifyBad = try await server.send("POST", "/tasks/\(id)/clarify", json: #"{}"#)
        #expect(clarifyBad.status == 400)
    }

    @Test func dispatchSessionKey_isScopedToTheCredential() {
        #expect(HTTPHandler.dispatchSessionKey(nil, audience: "0xabc", keyNonce: "n") == nil)
        #expect(HTTPHandler.dispatchSessionKey("chat-1", audience: nil, keyNonce: nil) == "chat-1")
        // An agent-scoped caller with no nonce can't reattach at all.
        #expect(HTTPHandler.dispatchSessionKey("chat-1", audience: "0xabc", keyNonce: nil) == nil)
        let mine = HTTPHandler.dispatchSessionKey("chat-1", audience: "0xABC", keyNonce: "n1")
        let other = HTTPHandler.dispatchSessionKey("chat-1", audience: "0xabc", keyNonce: "n2")
        #expect(mine?.hasPrefix("credential:") == true)
        #expect(mine != other)
        #expect(mine == HTTPHandler.dispatchSessionKey("chat-1", audience: "0xabc", keyNonce: "n1"))
    }

    /// Intel's engine asks before `execute`; an external run gets the
    /// refusal text instead of a card nobody there can answer.
    @Test func unapprovedReason_namesTheMissingApprovalUIForExternalRuns() {
        #expect(ChatEngine.unapprovedReason == "you declined to run it this time")
        let external = ChatExecutionContext.$isExternalSurface.withValue(true) { ChatEngine.unapprovedReason }
        #expect(external.contains("needs approval in the Osaurus app"))
        let headless = ChatExecutionContext.$denyUnapprovedToolPrompts.withValue(true) {
            ChatEngine.unapprovedReason
        }
        #expect(headless.contains("needs approval in the Osaurus app"))
    }

    // MARK: - Halves of HTTPAuthGateTests cases (upstream)

    /// `masterScopedKey_isNotConfinedByRoutePolicy`, `/agents` half (the
    /// `/admin/runtime-settings` half waits for stage 7).
    @Test func masterScopedKey_reachesAgents() async throws {
        let server = try await startAgentTestServer(validator: .forAlice())
        defer { Task { await server.shutdown() } }
        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey, iss: TestKeys.aliceAddress, aud: TestKeys.aliceAddress
        )
        let agents = try await server.send("GET", "/agents", token: token)
        #expect(agents.status == 200)
    }

    /// `localKeyPolicyOff_keepsKeylessLoopbackAccess`, `/agents` and
    /// `/mcp/tools` half (`/admin/config` comes with W-declarative-config).
    @Test func localKeyPolicyOff_keepsKeylessLoopbackAccessToAgentsAndMCP() async throws {
        let server = try await startAgentTestServer(validator: .forAlice())
        defer { Task { await server.shutdown() } }
        for path in ["/agents", "/mcp/tools"] {
            let result = try await server.send("GET", path)
            #expect(result.status == 200, "\(path) returned \(result.status): \(result.body)")
        }
        let browser = try await server.send("GET", "/agents", headers: ["Origin": "https://any.example"])
        #expect(browser.status == 200)
        #expect(browser.allowOrigin == "*")
    }
}

// MARK: - Test server

private struct AgentRouteResult {
    let status: Int
    let body: String
    let allowOrigin: String?

    func object() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }
}

private struct AgentTestServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let lease: HTTPServerTestLease
    let host: String
    let port: Int

    func send(
        _ method: String, _ path: String, json: String? = nil, token: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> AgentRouteResult {
        var request = URLRequest(url: URL(string: "http://\(host):\(port)\(path)")!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let json {
            request.httpBody = Data(json.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse
        return AgentRouteResult(
            status: http?.statusCode ?? -1,
            body: String(decoding: data, as: UTF8.self),
            allowOrigin: http?.value(forHTTPHeaderField: "Access-Control-Allow-Origin")
        )
    }

    func shutdown() async {
        _ = try? await channel.close()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
    }
}

private func startAgentTestServer(validator: APIKeyValidator = .empty) async throws -> AgentTestServer {
    let config = ServerConfiguration.default
    let lease = await HTTPServerTestLock.shared.acquire()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            configuration: config,
                            apiKeyValidator: validator,
                            eventLoop: channel.eventLoop,
                            trustLoopback: true
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)

        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        let port = ch.localAddress?.port ?? 0
        return AgentTestServer(group: group, channel: ch, lease: lease, host: "127.0.0.1", port: port)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
