//
//  HarnessTokenHTTPTests.swift
//  OsaurusCoreTests
//
//  `W-harness-runtimes` stage 4b (upstream #3175): the HTTP auth gate and the
//  `/mcp/*` handlers honour a harness agent token (`HarnessGrantStore`), over
//  physical loopback only. The token authenticates and attributes; it adds no
//  rights (tool permissions and "Ask" still apply), is confined to the
//  inference and MCP routes, and never bypasses the browser-origin guard.
//  Everything runs against an in-process NIO server and fake tools; no
//  harness process, network, keychain or `~/.osaurus`.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct HarnessTokenHTTPTests {
    private static let evilOrigin = "https://evil.example"

    private static func get(
        _ path: String, server: TokenTestServer, headers: [String: String] = [:]
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)\(path)")!)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
    }

    private static func call(
        _ tool: String, server: TokenTestServer, headers: [String: String]
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/mcp/call")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": tool, "arguments": [:]])
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
    }

    private static func withTools(_ body: @MainActor @Sendable () async throws -> Void) async throws {
        try await DynamicCatalogTestLock.shared.run {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-tests-\(UUID().uuidString)", isDirectory: true)
            ToolConfigurationStore.overrideDirectory = tempDir
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            for tool: any OsaurusTool in [TokenProbeTool(), TokenAskTool(), TokenOtherTool()] {
                ToolRegistry.shared.register(tool)
                ToolRegistry.shared.setEnabled(true, for: tool.name)
            }
            defer {
                ToolRegistry.shared.unregister(names: [
                    TokenProbeTool.toolName, TokenAskTool.toolName, TokenOtherTool.toolName,
                ])
            }
            try await body()
        }
    }

    private static func mint(_ agentId: UUID = UUID()) -> String {
        HarnessGrantStore.shared.mint(
            agentId: agentId,
            allowsConfigWrites: false,
            allowedToolNames: [TokenProbeTool.toolName, TokenAskTool.toolName]
        )
    }

    // MARK: - Gate

    /// What `osaurus mcp` sends for a harness agent: the bridge header alone,
    /// no access key, against a server that does not trust loopback.
    @Test func tokenAloneAuthenticatesWithoutLoopbackTrust() async throws {
        try await Self.withTools {
            let token = Self.mint()
            defer { HarnessGrantStore.shared.revoke(token) }
            let server = try await startTokenServer(trustLoopback: false)
            defer { Task { await server.shutdown() } }

            let list = try await Self.get(
                "/mcp/tools", server: server, headers: [HarnessGrantStore.headerName: token])
            #expect(list.status == 200, "\(list.body)")
            let json = try #require(try JSONSerialization.jsonObject(with: Data(list.body.utf8)) as? [String: Any])
            let names = Set((json["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
            #expect(names.isSubset(of: [TokenProbeTool.toolName, TokenAskTool.toolName]))
            #expect(names.contains(TokenProbeTool.toolName))
            #expect(!names.contains(TokenOtherTool.toolName), "a token lists only its agent's tools")

            // A harness token on `Authorization: Bearer` works the same way.
            let health = try await Self.get(
                "/mcp/health", server: server, headers: ["Authorization": "Bearer \(token)"])
            #expect(health.status == 200)

            let anonymous = try await Self.get("/mcp/tools", server: server)
            #expect(anonymous.status == 401)
        }
    }

    /// Upstream: a live token passes the gate whether "Require an access key
    /// for local apps" is on or off; a keyless caller still gets 401 when on.
    @Test func tokenPassesTheLocalKeySwitchAsUpstream() async throws {
        try await Self.withTools {
            let token = Self.mint()
            defer { HarnessGrantStore.shared.revoke(token) }
            for switchOn in [false, true] {
                let server = try await startTokenServer(trustLoopback: true, localKeyRequired: switchOn)
                defer { Task { await server.shutdown() } }
                let withToken = try await Self.get(
                    "/mcp/tools", server: server, headers: [HarnessGrantStore.headerName: token])
                #expect(withToken.status == 200, "switch \(switchOn): \(withToken.body)")
                let keyless = try await Self.get("/mcp/tools", server: server)
                #expect(keyless.status == (switchOn ? 401 : 200), "switch \(switchOn)")
            }
        }
    }

    @Test func tokenIsConfinedToInferenceAndMcpRoutes() async throws {
        let token = HarnessGrantStore.shared.mint(agentId: UUID(), allowsConfigWrites: false)
        defer { HarnessGrantStore.shared.revoke(token) }
        for switchOn in [false, true] {
            let server = try await startTokenServer(trustLoopback: true, localKeyRequired: switchOn)
            defer { Task { await server.shutdown() } }
            for path in ["/agents", "/sessions", "/admin/config/schema", "/tasks/abc", "/approvals"] {
                let result = try await Self.get(
                    path, server: server, headers: ["Authorization": "Bearer \(token)"])
                #expect(result.status == 403, "\(path) switch \(switchOn): \(result.status)")
                #expect(result.body.contains("harness_token_scope"), "\(path): \(result.body)")
            }
            let health = try await Self.get(
                "/mcp/health", server: server, headers: ["Authorization": "Bearer \(token)"])
            #expect(health.status == 200)
        }
    }

    @Test func revokedOrTamperedTokensAreRefusedAndNeverFallBackToLoopbackTrust() async throws {
        try await Self.withTools {
            let token = Self.mint()
            let server = try await startTokenServer(trustLoopback: true)
            let tampered = [HarnessGrantStore.headerName: "\(token)-tampered"]

            let list = try await Self.get("/mcp/tools", server: server, headers: tampered)
            #expect(list.status == 401)
            #expect(list.body.contains("harness_token_invalid"))
            let call = try await Self.call(TokenProbeTool.toolName, server: server, headers: tampered)
            #expect(call.body.contains("invalid or has been revoked"))
            #expect(call.body.contains(#""isError":true"#))

            HarnessGrantStore.shared.revoke(token)
            let revoked = try await Self.call(
                TokenProbeTool.toolName, server: server, headers: [HarnessGrantStore.headerName: token])
            #expect(revoked.body.contains("invalid or has been revoked"))
            // One server at a time: the test lock is not re-entrant.
            await server.shutdown()

            // A revoked Bearer is just a bad access key: no loopback bypass on a trust-less server.
            let strict = try await startTokenServer(trustLoopback: false)
            defer { Task { await strict.shutdown() } }
            let bearer = try await Self.get(
                "/mcp/tools", server: strict, headers: ["Authorization": "Bearer \(token)"])
            #expect(bearer.status == 401)
        }
    }

    /// A relayed (non-loopback) caller never gets a harness identity: the
    /// relay marker makes the connection non-physical-loopback for the gate.
    @Test func relayedRequestsDoNotHonourAHarnessToken() async throws {
        try await Self.withTools {
            let token = Self.mint()
            defer { HarnessGrantStore.shared.revoke(token) }
            let server = try await startTokenServer(trustLoopback: false)
            defer { Task { await server.shutdown() } }
            let result = try await Self.get(
                "/mcp/tools", server: server,
                headers: [HarnessGrantStore.headerName: token, HTTPHandler.relayOriginHeaderName: "1"])
            #expect(result.status == 401, "\(result.body)")
        }
    }

    // MARK: - Browser guard cannot be bypassed with a token

    @Test func browserGuardStillRefusesBrowsersThatPresentAToken() async throws {
        try await Self.withTools {
            let token = Self.mint()
            defer { HarnessGrantStore.shared.revoke(token) }
            for switchOn in [false, true] {
                let server = try await startTokenServer(
                    trustLoopback: true, localKeyRequired: switchOn, allowedOrigins: ["*"])
                defer { Task { await server.shutdown() } }
                let base = [HarnessGrantStore.headerName: token]

                // Unlisted Origin (a `*` entry does not admit it).
                let origin = try await Self.get(
                    "/mcp/tools", server: server, headers: base.merging(["Origin": Self.evilOrigin]) { $1 })
                #expect(origin.status == 403, "switch \(switchOn): \(origin.status)")
                #expect(origin.body.contains("browser_origin_refused"))
                let originCall = try await Self.call(
                    TokenProbeTool.toolName, server: server,
                    headers: base.merging(["Origin": Self.evilOrigin]) { $1 })
                #expect(originCall.status == 403)
                #expect(!originCall.body.contains("probe:"))

                // Cross-site fetch metadata.
                for site in ["cross-site", "same-site"] {
                    let fetched = try await Self.get(
                        "/mcp/tools", server: server, headers: base.merging(["Sec-Fetch-Site": site]) { $1 })
                    #expect(fetched.status == 403, "\(site): \(fetched.status)")
                }

                // DNS rebinding: loopback socket, attacker `Host`.
                let port = server.port
                // Blocking socket I/O must stay off the main actor: the
                // handler hops to it to list tools.
                let evil = try await Task.detached {
                    try Self.rawGet("/mcp/tools", host: "evil.example", port: port, token: token)
                }.value
                #expect(evil.hasPrefix("HTTP/1.1 403"), "\(evil.prefix(60))")
                let local = try await Task.detached {
                    try Self.rawGet("/mcp/tools", host: "localhost:\(port)", port: port, token: token)
                }.value
                #expect(local.hasPrefix("HTTP/1.1 200"), "\(local.prefix(60))")
            }
        }
    }

    // MARK: - No added rights

    @Test func tokenAddsNoRightsToolPermissionsAndAskStillApply() async throws {
        try await Self.withTools {
            let agentId = UUID()
            let token = Self.mint(agentId)
            defer { HarnessGrantStore.shared.revoke(token) }
            let server = try await startTokenServer(trustLoopback: true)
            defer { Task { await server.shutdown() } }
            let headers = [HarnessGrantStore.headerName: token]

            // An allowed Auto tool runs as an external surface, attributed to the token's agent.
            let probe = try await Self.call(TokenProbeTool.toolName, server: server, headers: headers)
            #expect(probe.body.contains("probe:\(agentId.uuidString):\(agentId.uuidString):external"), "\(probe.body)")

            // The same call with no token runs with no agent bound.
            let anonymous = try await Self.call(TokenProbeTool.toolName, server: server, headers: [:])
            #expect(anonymous.body.contains("probe:none:none:external"), "\(anonymous.body)")

            // An "Ask" tool is refused: an external caller can't answer the card.
            let ask = try await Self.call(TokenAskTool.toolName, server: server, headers: headers)
            #expect(ask.body.contains("needs approval"), "\(ask.body)")
            #expect(!ask.body.contains("ask-ran"))

            // A tool outside the token's list is refused before it runs.
            let other = try await Self.call(TokenOtherTool.toolName, server: server, headers: headers)
            #expect(other.body.contains("outside this agent token's scope"), "\(other.body)")
            #expect(!other.body.contains("other-ran"))

            // Agent-spawning and loop-only tools are never reachable.
            for tool in [SubagentCapabilityRegistry.spawnAgentToolName, "todo", "clarify"] {
                let result = try await Self.call(tool, server: server, headers: headers)
                #expect(result.body.contains(#""isError":true"#), "\(tool): \(result.body)")
            }
        }
    }

    /// Computer Use, Browser, AppleScript and Mac Query run Osaurus's own
    /// sub-loop; a harness agent's token is refused there with the typed
    /// message, and they are absent from its tool list.
    @Test func harnessAgentsCannotReachComputerUseOrAppleScript() async throws {
        try await ChatHistoryTestStorage.run {
            try await Self.withTools {
                let previousStoreDir = HarnessRuntimeStore.overrideDirectory
                HarnessRuntimeStore.overrideDirectory = OsaurusPaths.root()
                HarnessRuntimeStore.shared.resetForTests()
                DefaultAgentConfigurationStore.resetCacheForTests()
                defer {
                    HarnessRuntimeStore.overrideDirectory = previousStoreDir
                    HarnessRuntimeStore.shared.resetForTests()
                    DefaultAgentConfigurationStore.resetCacheForTests()
                }
                var custom = Agent(name: "Harness Tester")
                custom.runtime = .harness(UUID())
                AgentManager.shared.add(custom)

                let token = HarnessGrantStore.shared.mint(agentId: custom.id, allowsConfigWrites: true)
                defer { HarnessGrantStore.shared.revoke(token) }
                let server = try await startTokenServer(trustLoopback: true)
                defer { Task { await server.shutdown() } }
                let headers = [HarnessGrantStore.headerName: token]

                // Computer Use is also on Intel's external deny list (owner
                // policy), so it is refused before the harness check.
                let denied = try await Self.call("computer_use", server: server, headers: headers)
                #expect(denied.body.contains("tool_not_exposable"), "\(denied.body)")
                for tool in ["browser_use", "applescript", "mac_query"] {
                    let result = try await Self.call(tool, server: server, headers: headers)
                    #expect(result.body.contains(#""isError":true"#), "\(tool): \(result.body)")
                    #expect(result.body.contains("runs on an external harness"), "\(tool): \(result.body)")
                }
                let list = try await Self.get("/mcp/tools", server: server, headers: headers)
                for tool in ["computer_use", "browser_use", "applescript", "mac_query"] {
                    #expect(!list.body.contains("\"\(tool)\""), "\(tool) must not be listed")
                }
            }
        }
    }

    @Test func spawnTargetsOnAHarnessRuntimeAreNotRunnable() async throws {
        try await ChatHistoryTestStorage.run {
            let previousStoreDir = HarnessRuntimeStore.overrideDirectory
            HarnessRuntimeStore.overrideDirectory = OsaurusPaths.root()
            HarnessRuntimeStore.shared.resetForTests()
            DefaultAgentConfigurationStore.resetCacheForTests()
            defer {
                HarnessRuntimeStore.overrideDirectory = previousStoreDir
                HarnessRuntimeStore.shared.resetForTests()
                DefaultAgentConfigurationStore.resetCacheForTests()
            }
            var onHarness = Agent(name: "Harness Target")
            onHarness.runtime = .harness(UUID())
            let builtIn = Agent(name: "Built-in Target")
            AgentManager.shared.add(onHarness)
            AgentManager.shared.add(builtIn)
            // The Orchestrator's spawn pool names both agents.
            var config = DefaultAgentConfigurationStore.load()
            config.delegation.customAgentAllowlist = [onHarness.id, builtIn.id]
            DefaultAgentConfigurationStore.save(config)

            let snapshot = IntelSpawnAdmission.resolveTargets(launcherID: Agent.defaultId)
            let states = Dictionary(uniqueKeysWithValues: snapshot.agentTargets.map { ($0.descriptor.id, $0.state) })
            #expect(states[onHarness.id] == .harness)
            #expect(states[builtIn.id] != nil && states[builtIn.id] != .harness)
            #expect(!snapshot.runnableAgentIDs.contains(onHarness.id))
        }
    }

    // MARK: - Raw HTTP (URLSession cannot set `Host`)

    nonisolated private static func rawGet(_ path: String, host: String, port: Int, token: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw URLError(.cannotConnectToHost) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let request =
            "GET \(path) HTTP/1.1\r\nHost: \(host)\r\n\(HarnessGrantStore.headerName): \(token)\r\nConnection: close\r\n\r\n"
        _ = request.withCString { Darwin.send(fd, $0, strlen($0), 0) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            received.append(buffer, count: count)
        }
        return String(decoding: received, as: UTF8.self)
    }
}

// MARK: - Fake tools

/// Auto tool that reports the identity the handler bound.
private struct TokenProbeTool: OsaurusTool {
    static let toolName = "harness_token_probe"
    let name = TokenProbeTool.toolName
    let description = "Reports the bound agent identity"
    let parameters: JSONValue? = nil
    func execute(argumentsJSON: String) async throws -> String {
        let agent = ChatExecutionContext.currentAgentId?.uuidString ?? "none"
        let token = ChatExecutionContext.harnessTokenAgentId?.uuidString ?? "none"
        let surface = ChatExecutionContext.isExternalSurface ? "external" : "internal"
        return "probe:\(agent):\(token):\(surface)"
    }
}

/// A tool whose policy is Ask; it must never run for an external caller.
private struct TokenAskTool: OsaurusTool, PermissionedTool {
    static let toolName = "harness_token_ask"
    let name = TokenAskTool.toolName
    let description = "Needs approval"
    let parameters: JSONValue? = nil
    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }
    func execute(argumentsJSON: String) async throws -> String { "ask-ran" }
}

/// An Auto tool that is not in the test token's allow-list.
private struct TokenOtherTool: OsaurusTool {
    static let toolName = "harness_token_other"
    let name = TokenOtherTool.toolName
    let description = "Not in the token's list"
    let parameters: JSONValue? = nil
    func execute(argumentsJSON: String) async throws -> String { "other-ran" }
}

// MARK: - Server

private struct TokenTestServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let lease: HTTPServerTestLease
    let host: String
    let port: Int

    func shutdown() async {
        _ = try? await channel.close()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
    }
}

private func startTokenServer(
    trustLoopback: Bool,
    localKeyRequired: Bool = false,
    allowedOrigins: [String] = []
) async throws -> TokenTestServer {
    var config = ServerConfiguration.default
    config.allowedOrigins = allowedOrigins
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
                            apiKeyValidator: TestAuth.validator,
                            eventLoop: channel.eventLoop,
                            trustLoopback: trustLoopback,
                            localKeyRequiredProvider: { localKeyRequired }
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return TokenTestServer(
            group: group, channel: ch, lease: lease, host: "127.0.0.1", port: ch.localAddress?.port ?? 0)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
