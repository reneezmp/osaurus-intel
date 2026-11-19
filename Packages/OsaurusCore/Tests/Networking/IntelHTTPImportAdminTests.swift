//
//  IntelHTTPImportAdminTests.swift
//  OsaurusCoreTests
//
//  W-osaurus-bundles stage 3: `/admin/import/*`. Pins that the route keeps
//  EXACTLY the rules of `/admin/config/*` on Intel: physical loopback only,
//  no Secure Channel, no agent-scoped keys, browser callers refused, a JSON
//  Content-Type required on POST, a body cap, and an apply that never lands
//  without the user's review in the app (no window -> 409 and the request
//  stays queued; denied -> nothing changes; `--yes` changes nothing).
//  The queue lives in a temp root; no network, keychain or `~/.osaurus`.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import OsaurusRepository
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelHTTPImportAdminTests {

    // MARK: - Fixtures

    /// A bundle with one skill and no agent, so applying it touches only the skill store.
    private static func makeBundle() throws -> (root: URL, id: String, skill: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-import-http-\(suffix)", isDirectory: true)
        let id = "com.example.http\(suffix)"
        let skill = "probe-\(suffix)"
        func write(_ text: String, _ relative: String) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let manifest: [String: Any] = [
            "format": "osaurus.bundle", "format_version": 1, "id": id, "name": "HTTP Probe",
            "version": "1.0.0", "skills": [["name": skill, "path": "skills/\(skill)"]],
        ]
        try write(
            String(decoding: try JSONSerialization.data(withJSONObject: manifest), as: UTF8.self),
            "osaurus-bundle.json")
        try write(
            "---\nname: \(skill)\ndescription: A probe.\n---\n\n# Probe\n\nDo nothing.\n",
            "skills/\(skill)/SKILL.md")
        return (root, id, skill)
    }

    private func withQueueRoot(_ body: @MainActor () async throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let queueRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-import-http-queue-\(UUID().uuidString)", isDirectory: true)
            let previous = ToolsPaths.overrideRoot
            ToolsPaths.overrideRoot = queueRoot
            defer {
                ToolsPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: queueRoot)
            }
            try await body()
        }
    }

    private func body(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    @MainActor
    private func processor(_ answer: ConfigApprovalOutcome) -> PendingImportProcessor {
        let processor = PendingImportProcessor()
        processor.approver = { _ in answer }
        return processor
    }

    // MARK: - The endpoint core

    @Test func malformedAndOversizedBodiesAreRefused() async {
        for op in [ImportAdminEndpoint.Operation.plan, .apply] {
            let empty = await ImportAdminEndpoint.handle(operation: op, requestBody: Data())
            #expect(empty.status == .badRequest)
            let notObject = await ImportAdminEndpoint.handle(operation: op, requestBody: Data("[1]".utf8))
            #expect(notObject.status == .badRequest)
            let huge = Data(repeating: 0x20, count: ImportAdminEndpoint.requestLimit + 1)
            let tooBig = await ImportAdminEndpoint.handle(operation: op, requestBody: huge)
            #expect(tooBig.status == .badRequest)
        }
        let noPath = await ImportAdminEndpoint.handle(operation: .plan, requestBody: body(["x": 1]))
        #expect(noPath.body.contains("bundle_path"))
        let noId = await ImportAdminEndpoint.handle(operation: .apply, requestBody: body(["x": 1]))
        #expect(noId.status == .badRequest)
    }

    /// A request id names a folder under the queue; it must never point elsewhere.
    @Test func applyRefusesIdsThatCouldLeaveTheQueue() async {
        for id in ["../etc", "..", ".", "a/b", "a b", "", String(repeating: "a", count: 81), "x\u{0}y"] {
            let response = await ImportAdminEndpoint.handle(operation: .apply, requestBody: body(["id": id]))
            #expect(response.status == .badRequest, "\(id.debugDescription): \(response.body)")
        }
    }

    @Test func applyWithAnUnknownIdAnswers422() async throws {
        try await withQueueRoot {
            let response = await ImportAdminEndpoint.handle(
                operation: .apply, requestBody: body(["id": "no-such-request"]), processor: processor(.approved))
            #expect(response.status == .unprocessableEntity, "\(response.body)")
        }
    }

    @Test func planChecksTheBundleAndChangesNothing() async throws {
        try await withQueueRoot {
            let bundle = try Self.makeBundle()
            defer { try? FileManager.default.removeItem(at: bundle.root) }
            let ok = await ImportAdminEndpoint.handle(
                operation: .plan,
                requestBody: body([
                    "bundle_path": bundle.root.path,
                    "operations": [["action": "install", "kind": "skill", "name": bundle.skill]],
                ]), processor: processor(.approved))
            #expect(ok.status == .ok, "\(ok.body)")
            #expect(ok.body.contains("\"issues\":[]"), "\(ok.body)")
            #expect(ImportQueue.pending().isEmpty)
            #expect(await MainActor.run { SkillManager.shared.skill(named: bundle.skill) == nil })

            let bad = await ImportAdminEndpoint.handle(
                operation: .plan,
                requestBody: body(["bundle_path": bundle.root.appendingPathComponent("missing").path]),
                processor: processor(.approved))
            #expect(bad.status == .ok)
            #expect(!bad.body.contains("\"issues\":[]"), "\(bad.body)")
        }
    }

    @Test func applyWithNoWindowAnswers409_andTheRequestStaysQueued() async throws {
        try await withQueueRoot {
            let bundle = try Self.makeBundle()
            defer { try? FileManager.default.removeItem(at: bundle.root) }
            let loaded = try OsaurusBundle.load(from: bundle.root)
            let request = ImportRequest(
                bundleId: bundle.id, bundleName: "HTTP Probe", bundleVersion: "1.0.0",
                operations: [ImportOperation(action: .install, kind: .skill, name: bundle.skill, explicit: true)],
                confirmHighRisk: true)
            try ImportQueue.enqueue(request, bundle: loaded)

            // `.cancelled` is what `ConfigApprovalService` answers with no chat window.
            let response = await ImportAdminEndpoint.handle(
                operation: .apply, requestBody: body(["id": request.id, "confirm_high_risk": true, "yes": true]),
                processor: processor(.cancelled))
            #expect(response.status == .conflict, "\(response.body)")
            #expect(response.body.contains("approval_unavailable"))
            #expect(ImportQueue.pending().contains { $0.request.id == request.id })
            #expect(await MainActor.run { SkillManager.shared.skill(named: bundle.skill) == nil })

            let timedOut = await ImportAdminEndpoint.handle(
                operation: .apply, requestBody: body(["id": request.id]), processor: processor(.timedOut))
            #expect(timedOut.status == .requestTimeout)
            #expect(ImportQueue.pending().contains { $0.request.id == request.id })
        }
    }

    @Test func declinedApplyChangesNothingAndReportsFailedItems() async throws {
        try await withQueueRoot {
            let bundle = try Self.makeBundle()
            defer { try? FileManager.default.removeItem(at: bundle.root) }
            let loaded = try OsaurusBundle.load(from: bundle.root)
            let request = ImportRequest(
                bundleId: bundle.id, bundleName: "HTTP Probe", bundleVersion: "1.0.0",
                operations: [ImportOperation(action: .install, kind: .skill, name: bundle.skill, explicit: true)],
                confirmHighRisk: true)
            try ImportQueue.enqueue(request, bundle: loaded)

            let response = await ImportAdminEndpoint.handle(
                operation: .apply, requestBody: body(["id": request.id]), processor: processor(.denied))
            #expect(response.status == .ok, "\(response.body)")
            #expect(response.body.contains("Declined"))
            #expect(await MainActor.run { SkillManager.shared.skill(named: bundle.skill) == nil })
            #expect(ImportQueue.loadReceipts().isEmpty)
        }
    }

    @Test func browserRefusalNamesTheImportRoute() {
        let message = ConfigAdminEndpoint.browserRefusal(
            host: "127.0.0.1:1337", origin: "https://evil.example", secFetchSite: nil, allowedOrigins: ["*"],
            route: "/admin/import/*")
        #expect(message == "Browser requests to /admin/import/* are refused.")
        #expect(
            ConfigAdminEndpoint.browserRefusal(
                host: "127.0.0.1:1337", origin: nil, secFetchSite: nil, allowedOrigins: [], route: "/admin/import/*")
                == nil)
    }

    // MARK: - HTTP: who may call

    @Test func loopbackCallerReachesTheRouteAndGetsTheContractRules() async throws {
        let server = try await startImportAdminTestServer(validator: .empty)
        defer { Task { await server.shutdown() } }

        let noBundle = try await server.send("POST", "/admin/import/plan", json: "{\"operations\":[]}")
        #expect(noBundle.status == 400 && noBundle.body.contains("bundle_path"), "\(noBundle.body)")
        let noId = try await server.send("POST", "/admin/import/apply", json: "{\"x\":1}")
        #expect(noId.status == 400, "\(noId.body)")
        let traversal = try await server.send("POST", "/admin/import/apply", json: "{\"id\":\"../x\"}")
        #expect(traversal.status == 400, "\(traversal.body)")

        let wrongType = try await server.send(
            "POST", "/admin/import/plan", json: "{}", contentType: "text/plain")
        #expect(wrongType.status == 415)
        let noType = try await server.send(
            "POST", "/admin/import/apply", json: "{\"id\":\"x\"}", contentType: nil)
        #expect(noType.status == 415)

        let tooBig = try await server.send(
            "POST", "/admin/import/plan",
            json: "{\"bundle_path\":\"" + String(repeating: "a", count: ImportAdminEndpoint.requestLimit + 10) + "\"}")
        #expect(tooBig.status == 413, "\(tooBig.status)")

        // Only POST exists.
        let get = try await server.send("GET", "/admin/import/plan")
        #expect(get.status == 404)
    }

    @Test func browserOriginGetsNothingOverHTTP() async throws {
        let server = try await startImportAdminTestServer(validator: .empty)
        defer { Task { await server.shutdown() } }
        for headers in [["Origin": "https://evil.example"], ["Sec-Fetch-Site": "cross-site"]] {
            for path in ["/admin/import/plan", "/admin/import/apply"] {
                let result = try await server.send("POST", path, json: "{\"id\":\"x\",\"bundle_path\":\"/tmp\"}", headers: headers)
                #expect(result.status == 403, "\(path) \(headers): \(result.status) \(result.body)")
                #expect(result.body.contains("/admin/import/*"))
            }
        }
    }

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
        let server = try await startImportAdminTestServer(validator: validator)
        defer { Task { await server.shutdown() } }
        let relay = [HTTPHandler.relayOriginHeaderName: "1"]
        for path in ["/admin/import/plan", "/admin/import/apply"] {
            let result = try await server.send(
                "POST", path, json: "{\"id\":\"x\",\"bundle_path\":\"/tmp\"}", token: token, headers: relay)
            #expect(result.status == 403, "\(path): \(result.status) \(result.body)")
            #expect(result.body.contains("loopback"), "\(path): \(result.body)")
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
        let server = try await startImportAdminTestServer(validator: validator)
        defer { Task { await server.shutdown() } }
        let relay = [HTTPHandler.relayOriginHeaderName: "1"]
        for path in ["/admin/import/plan", "/admin/import/apply"] {
            let result = try await server.send(
                "POST", path, json: "{\"id\":\"x\",\"bundle_path\":\"/tmp\"}", token: token, headers: relay)
            #expect(result.status == 403, "\(path): \(result.body)")
        }
    }
}

// MARK: - Test server

private struct ImportAdminResult {
    let status: Int
    let body: String
}

private struct ImportAdminTestServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let lease: HTTPServerTestLease
    let port: Int

    func send(
        _ method: String, _ path: String, json: String? = nil, token: String? = nil,
        headers: [String: String] = [:], contentType: String? = "application/json"
    ) async throws -> ImportAdminResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let json {
            request.httpBody = Data(json.utf8)
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        return ImportAdminResult(
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

private func startImportAdminTestServer(validator: APIKeyValidator) async throws -> ImportAdminTestServer {
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
        return ImportAdminTestServer(group: group, channel: ch, lease: lease, port: ch.localAddress?.port ?? 0)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
