//
//  IntelHTTPConfigAdminTests.swift
//  OsaurusCoreTests
//
//  W-declarative-config stage 5: `/admin/config/*`. Pins the owner policy the
//  route keeps on Intel: physical loopback only, read-only export/schema/plan,
//  and an apply that NEVER lands without the user's approval in the app
//  (denied, timed out, cancelled and "no window to show it in" all apply
//  nothing; `confirm_high_risk` from the caller changes nothing).
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelHTTPConfigAdminTests {

    private static func budgetDocument(_ tokens: Int) -> String {
        "version: 1\ndelegation:\n  budget_max_tokens: \(tokens)\n"
    }

    private static func requestJSON(_ yaml: String, extra: [String: Any] = [:]) -> Data {
        var object: [String: Any] = ["yaml": yaml]
        for (key, value) in extra { object[key] = value }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    @MainActor
    private static func currentBudget() -> Int? { ConfigExporter.export().delegation?.budgetMaxTokens }

    /// A budget value different from the current one, so an apply is visible.
    @MainActor
    private static func otherBudget() -> Int { currentBudget() == 4096 ? 2048 : 4096 }

    private func object(_ body: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
    }

    // MARK: - Core: read-only actions

    @Test func exportAndSchemaAnswerInBothFormats() async throws {
        let yaml = await ConfigAdminEndpoint.handle(operation: .export, uri: "/admin/config/export", requestBody: Data())
        #expect(yaml.status == .ok)
        #expect(try object(yaml.body)["yaml"] is String)
        let json = await ConfigAdminEndpoint.handle(
            operation: .export, uri: "/admin/config/export?format=json", requestBody: Data())
        #expect(json.status == .ok)
        #expect(try object(json.body)["json"] is String)
        let bad = await ConfigAdminEndpoint.handle(
            operation: .export, uri: "/admin/config/export?format=toml", requestBody: Data())
        #expect(bad.status == .badRequest)

        let schema = await ConfigAdminEndpoint.handle(
            operation: .schema, uri: "/admin/config/schema", requestBody: Data())
        #expect(schema.status == .ok)
        let schemaObject = try object(schema.body)
        #expect(schemaObject["schema"] is String)
        #expect((schemaObject["sections"] as? [String])?.contains("delegation") == true)
        let jsonSchema = await ConfigAdminEndpoint.handle(
            operation: .schema, uri: "/admin/config/schema?format=json", requestBody: Data())
        #expect(try object(jsonSchema.body)["json_schema"] != nil)
    }

    @Test func exportCarriesNoSecretsAndNoCredentialPresence() async throws {
        let export = await ConfigAdminEndpoint.handle(
            operation: .export, uri: "/admin/config/export", requestBody: Data())
        let text = try #require(try object(export.body)["yaml"] as? String)
        for forbidden in ["api_key:", "apiKey", "Bearer ", "sk-"] {
            #expect(!text.contains(forbidden), "export leaked `\(forbidden)`")
        }
    }

    @Test func planChangesNothing() async throws {
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }
        let before = await Self.currentBudget()
        let target = await Self.otherBudget()
        let response = await ConfigAdminEndpoint.handle(
            operation: .plan, uri: "/admin/config/plan", requestBody: Self.requestJSON(Self.budgetDocument(target)))
        #expect(response.status == .ok, "\(response.body)")
        #expect(try object(response.body)["summary"] is String)
        #expect(await Self.currentBudget() == before)
    }

    @Test func invalidInputsAreRefusedBeforeAnythingRuns() async throws {
        for body in [Data(), Data("not json".utf8), Data(#"{"yaml": "  "}"#.utf8), Data(#"{"template": "x"}"#.utf8)] {
            let response = await ConfigAdminEndpoint.handle(
                operation: .apply, uri: "/admin/config/apply", requestBody: body,
                approve: { _, _ in
                    Issue.record("approval asked for an unusable request")
                    return .approved
                })
            #expect(response.status == .badRequest)
        }
        let unknownKey = await ConfigAdminEndpoint.handle(
            operation: .apply, uri: "/admin/config/apply",
            requestBody: Self.requestJSON("version: 1\nnot_a_section: true\n"),
            approve: { _, _ in
                Issue.record("approval asked for an invalid document")
                return .approved
            })
        #expect(unknownKey.status == .badRequest)
        #expect(unknownKey.body.contains("nothing was changed"))
    }

    // MARK: - Core: apply is always user-approved

    @Test func applyWithoutApprovalNeverLands() async throws {
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }
        let before = await Self.currentBudget()
        let target = await Self.otherBudget()
        let request = Self.requestJSON(Self.budgetDocument(target), extra: ["confirm_high_risk": true])

        let expectations: [(ConfigApprovalOutcome, HTTPResponseStatus)] = [
            (.denied, .forbidden), (.timedOut, .requestTimeout), (.cancelled, .conflict),
        ]
        for (outcome, status) in expectations {
            let response = await ConfigAdminEndpoint.handle(
                operation: .apply, uri: "/admin/config/apply", requestBody: request, approve: { _, _ in outcome })
            #expect(response.status == status, "\(outcome): \(response.body)")
            #expect(await Self.currentBudget() == before, "\(outcome) applied the change")
        }
    }

    @Test func applyNeedsTheRealApprovalSurface_andFailsClosedWithoutOne() async throws {
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }
        let before = await Self.currentBudget()
        let target = await Self.otherBudget()
        let hasSurface = await MainActor.run { ConfigApprovalQueue.shared.hasMountedSurface }
        try #require(!hasSurface, "a chat surface is mounted in this test process")
        let response = await ConfigAdminEndpoint.handle(
            operation: .apply, uri: "/admin/config/apply",
            requestBody: Self.requestJSON(Self.budgetDocument(target)))
        #expect(response.status == .conflict, "\(response.body)")
        #expect(response.body.contains("approval_unavailable"))
        #expect(await Self.currentBudget() == before)
    }

    @Test func approvedApplyLandsAndAnEmptyPlanAsksNobody() async throws {
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }
        let before = await Self.currentBudget()
        let target = await Self.otherBudget()
        let applied = await ConfigAdminEndpoint.handle(
            operation: .apply, uri: "/admin/config/apply",
            requestBody: Self.requestJSON(Self.budgetDocument(target)), approve: { _, _ in .approved })
        #expect(applied.status == .ok, "\(applied.body)")
        #expect(try object(applied.body)["status"] as? String == "applied")
        #expect(await Self.currentBudget() == target)

        let noChange = await ConfigAdminEndpoint.handle(
            operation: .apply, uri: "/admin/config/apply",
            requestBody: Self.requestJSON(Self.budgetDocument(target)),
            approve: { _, _ in
                Issue.record("approval asked for a no-op")
                return .approved
            })
        #expect(try object(noChange.body)["status"] as? String == "no_changes")

        if let before {
            _ = await ConfigAdminEndpoint.handle(
                operation: .apply, uri: "/admin/config/apply",
                requestBody: Self.requestJSON(Self.budgetDocument(before)), approve: { _, _ in .approved })
        }
    }

    // MARK: - HTTP: who may call

    @Test func loopbackCallerReadsExportAndGetsApplyRefusedWithoutAWindow() async throws {
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }
        let server = try await startConfigAdminTestServer(validator: .empty)
        defer { Task { await server.shutdown() } }
        let before = await Self.currentBudget()
        let target = await Self.otherBudget()

        let export = try await server.send("GET", "/admin/config/export")
        #expect(export.status == 200, "\(export.body)")
        let schema = try await server.send("GET", "/admin/config/schema")
        #expect(schema.status == 200)
        let plan = try await server.send("POST", "/admin/config/plan", json: String(decoding: Self.requestJSON(Self.budgetDocument(target)), as: UTF8.self))
        #expect(plan.status == 200, "\(plan.body)")
        let apply = try await server.send("POST", "/admin/config/apply", json: String(decoding: Self.requestJSON(Self.budgetDocument(target), extra: ["confirm_high_risk": true]), as: UTF8.self))
        #expect(apply.status == 409, "\(apply.body)")
        #expect(await Self.currentBudget() == before)

        let wrongType = try await server.send(
            "POST", "/admin/config/plan", json: "{}", contentType: "text/plain")
        #expect(wrongType.status == 415)
        let unknown = try await server.send("GET", "/admin/config/other")
        #expect(unknown.status == 404)
    }

    // MARK: - HTTP: a web page in the user's browser is not a local tool

    @Test func browserCallersAreRefused() {
        func refused(
            host: String? = "127.0.0.1:1337", origin: String? = nil, site: String? = nil,
            allowed: [String] = []
        ) -> Bool {
            ConfigAdminEndpoint.browserRefusal(
                host: host, origin: origin, secFetchSite: site, allowedOrigins: allowed) != nil
        }
        // Local tools.
        #expect(!refused())
        #expect(!refused(host: "localhost:1337"))
        #expect(!refused(host: "LOCALHOST"))
        #expect(!refused(host: "[::1]:1337"))
        #expect(!refused(site: "none"))
        // A page on another site, and `*` does not admit it.
        #expect(refused(origin: "https://evil.example"))
        #expect(refused(origin: "https://evil.example", allowed: ["*"]))
        #expect(refused(origin: "null"))
        #expect(refused(site: "cross-site"))
        #expect(refused(site: "same-site"))
        // DNS rebinding: the page's own name reaches this socket.
        #expect(refused(host: "evil.example:1337"))
        #expect(refused(host: "127.0.0.1.evil.example"))
        #expect(refused(host: "localhost.evil.example:1337"))
        #expect(refused(host: "127.0.0.1:1337@evil.example"))
        #expect(refused(host: "[::1].evil.example"))
        #expect(refused(host: nil))
        // An origin the owner listed by name is the one exception.
        #expect(!refused(origin: "https://tool.example", allowed: ["https://tool.example"]))
    }

    @Test func browserOriginGetsNoConfigOverHTTP() async throws {
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }
        let server = try await startConfigAdminTestServer(validator: .empty)
        defer { Task { await server.shutdown() } }
        let before = await Self.currentBudget()
        let target = await Self.otherBudget()
        let origin = ["Origin": "https://evil.example"]

        let export = try await server.send("GET", "/admin/config/export", headers: origin)
        #expect(export.status == 403)
        #expect(!export.body.contains("version"))
        let crossSite = try await server.send(
            "GET", "/admin/config/export", headers: ["Sec-Fetch-Site": "cross-site"])
        #expect(crossSite.status == 403)
        let apply = try await server.send(
            "POST", "/admin/config/apply",
            json: String(decoding: Self.requestJSON(Self.budgetDocument(target)), as: UTF8.self),
            headers: origin)
        #expect(apply.status == 403)
        #expect(await Self.currentBudget() == before)
    }

    /// A key-holding caller that arrives through the relay tunnel is not on
    /// the physical loopback address: refused, even with the owner's key.
    @Test func relayedCallerIsRefusedEvenWithTheOwnerKey() async throws {
        let validator = APIKeyValidator(
            agentAddresses: [],
            masterAddress: TestKeys.aliceAddress,
            effectiveWhitelist: [TestKeys.aliceAddress.lowercased()],
            revocationSnapshot: RevocationSnapshot(revokedKeys: [], counterThresholds: [:]),
            hasKeys: true
        )
        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey, iss: TestKeys.aliceAddress, aud: TestKeys.aliceAddress)
        let server = try await startConfigAdminTestServer(validator: validator)
        defer { Task { await server.shutdown() } }
        let relay = [HTTPHandler.relayOriginHeaderName: "1"]
        for (method, path) in [
            ("GET", "/admin/config/export"), ("GET", "/admin/config/schema"),
            ("POST", "/admin/config/plan"), ("POST", "/admin/config/apply"),
        ] {
            let result = try await server.send(
                method, path, json: method == "POST" ? #"{"yaml":"version: 1\n"}"# : nil, token: token, headers: relay)
            #expect(result.status == 403, "\(method) \(path): \(result.status) \(result.body)")
            #expect(result.body.contains("loopback"), "\(method) \(path): \(result.body)")
        }
    }

    /// Agent-scoped (paired peer) keys never reach `/admin/*`.
    @Test func agentScopedKeyIsRefused() async throws {
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
        let server = try await startConfigAdminTestServer(validator: validator)
        defer { Task { await server.shutdown() } }
        let relay = [HTTPHandler.relayOriginHeaderName: "1"]
        for (method, path) in [("GET", "/admin/config/export"), ("POST", "/admin/config/apply")] {
            let result = try await server.send(
                method, path, json: method == "POST" ? #"{"yaml":"version: 1\n"}"# : nil, token: token, headers: relay)
            #expect(result.status == 403, "\(method) \(path): \(result.body)")
        }
    }
}

// MARK: - Test server

private struct ConfigAdminResult {
    let status: Int
    let body: String
}

private struct ConfigAdminTestServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let lease: HTTPServerTestLease
    let port: Int

    func send(
        _ method: String, _ path: String, json: String? = nil, token: String? = nil,
        headers: [String: String] = [:], contentType: String = "application/json"
    ) async throws -> ConfigAdminResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let json {
            request.httpBody = Data(json.utf8)
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        return ConfigAdminResult(
            status: (resp as? HTTPURLResponse)?.statusCode ?? -1, body: String(decoding: data, as: UTF8.self))
    }

    func shutdown() async {
        _ = try? await channel.close()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
    }
}

private func startConfigAdminTestServer(validator: APIKeyValidator) async throws -> ConfigAdminTestServer {
    let lease = await HTTPServerTestLock.shared.acquire()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            configuration: .default, apiKeyValidator: validator, eventLoop: channel.eventLoop,
                            trustLoopback: true))
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return ConfigAdminTestServer(group: group, channel: ch, lease: lease, port: ch.localAddress?.port ?? 0)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
