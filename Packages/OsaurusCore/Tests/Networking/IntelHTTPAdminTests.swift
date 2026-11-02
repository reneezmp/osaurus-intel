//
//  IntelHTTPAdminTests.swift
//  OsaurusCoreTests
//
//  `W-server-api` stage 7 (docs/SERVER_API_INTEL.md): the admin routes'
//  Intel shapes, and "Expose to Network" (bind rule, Bonjour rule, the
//  one-time reset of a saved "on"). Config writes go to a temp directory
//  and the test storage root; the server binds loopback only.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct IntelHTTPAdminTests {

    // MARK: - Admin bodies

    @Test func cacheStats_isUpstreamsColdShapeWithTheStorageAudit() throws {
        let body = HTTPHandler.cacheStatsBody()
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(object["status"] as? String == "ok")
        #expect((object["models"] as? [Any])?.isEmpty == true)
        let aggregate = try #require(object["aggregate"] as? [String: Int])
        #expect(aggregate.count == 16)
        #expect(aggregate.values.allSatisfy { $0 == 0 })
        #expect(object["memory_safety"] is NSNull)
        #expect(object["batch_diagnostics"] is NSNull)
        #expect((object["inference_activity"] as? [Any])?.isEmpty == true)
        let policy = try #require(object["context_policy"] as? [String: Any])
        #expect(policy["conversation_safety_margin"] as? Double == ContextBudgetManager.safetyMargin)
        // The test root comes from OSAURUS_TEST_ROOT: the audit says so and
        // doesn't judge it.
        let storage = try #require(object["storage_locations"] as? [String: Any])
        #expect(storage["active_root"] as? String == OsaurusPaths.root().path)
        #expect(storage["models_root"] as? String == StorageLocationStandards.intelModelsRootPath())
        #expect((storage["reason_codes"] as? [String])?.isEmpty == false)
    }

    @Test func generationSettings_isEmpty() throws {
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(HTTPHandler.generationSettingsBody().utf8))
                as? [String: Any])
        #expect(object["status"] as? String == "ok")
        #expect((object["models"] as? [Any])?.isEmpty == true)
        #expect((object["last_effective_generation_by_model"] as? [String: Any])?.isEmpty == true)
    }

    @Test func adminRoutes_overHTTP() async throws {
        let server = try await startAdminTestServer()
        defer { Task { await server.shutdown() } }
        #expect(try await server.send("GET", "/admin/cache-stats").status == 200)
        #expect(try await server.send("GET", "/v1/admin/generation-settings").status == 200)
        let runtime = try await server.send("GET", "/admin/runtime-settings")
        #expect(runtime.status == 501)
        #expect(runtime.body.contains("Apple Silicon"))
        #expect(try await server.send("PUT", "/admin/runtime-settings", json: "{}").status == 501)
        // Not served here (W-declarative-config) and unknown admin paths.
        #expect(try await server.send("GET", "/admin/nope").status == 404)
    }

    // MARK: - Expose to Network

    @Test func bindRule_followsUpstream() {
        var config = ServerConfiguration.default
        config.port = 4242
        let local = IntelNetworkExposure.serverConfig(for: config)
        #expect(local.host == "127.0.0.1")
        #expect(local.trustLoopback)
        #expect(local.port == 4242)
        config.exposeToNetwork = true
        let exposed = IntelNetworkExposure.serverConfig(for: config)
        #expect(exposed.host == "0.0.0.0")
        #expect(!exposed.trustLoopback)
    }

    @Test func bonjourAgent_requiresExposureButNeverTurnsItOff() {
        var agent = Agent(
            id: UUID(), name: "Lan", description: "", systemPrompt: "", isBuiltIn: false,
            createdAt: Date(), updatedAt: Date())
        let off = ServerConfiguration.default
        #expect(!IntelNetworkExposure.exposureRequired(by: [agent], current: off))
        agent.bonjourEnabled = true
        #expect(IntelNetworkExposure.exposureRequired(by: [agent], current: off))
        var on = off
        on.exposeToNetwork = true
        #expect(!IntelNetworkExposure.exposureRequired(by: [agent], current: on))
        #expect(!IntelNetworkExposure.exposureRequired(by: [], current: on))
    }

    @Test func savedExposure_isTurnedOffOnce() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("osaurus-expose-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        ServerConfigurationStore.overrideDirectory = dir
        let marker = IntelNetworkExposure.resetMarkerURL()
        try? fm.removeItem(at: marker)
        defer {
            ServerConfigurationStore.overrideDirectory = nil
            try? fm.removeItem(at: dir)
            try? fm.removeItem(at: marker)
        }

        var config = ServerConfiguration.default
        config.port = 5151
        config.exposeToNetwork = true
        ServerConfigurationStore.save(config)

        #expect(IntelNetworkExposure.resetSavedExposureOnce())
        let reset = try #require(ServerConfigurationStore.load())
        #expect(!reset.exposeToNetwork)
        #expect(reset.port == 5151)
        #expect(fm.fileExists(atPath: marker.path))

        // The user turns it on again: it stays on.
        config.exposeToNetwork = true
        ServerConfigurationStore.save(config)
        #expect(!IntelNetworkExposure.resetSavedExposureOnce())
        #expect(ServerConfigurationStore.load()?.exposeToNetwork == true)
    }

    @Test func freshInstall_justWritesTheMarker() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("osaurus-expose-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        ServerConfigurationStore.overrideDirectory = dir
        let marker = IntelNetworkExposure.resetMarkerURL()
        try? fm.removeItem(at: marker)
        defer {
            ServerConfigurationStore.overrideDirectory = nil
            try? fm.removeItem(at: dir)
            try? fm.removeItem(at: marker)
        }
        #expect(!IntelNetworkExposure.resetSavedExposureOnce())
        #expect(ServerConfigurationStore.load() == nil)
        #expect(fm.fileExists(atPath: marker.path))
    }
}

// MARK: - Server fixture

private struct AdminRouteResult {
    let status: Int
    let body: String
}

private struct AdminTestServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let lease: HTTPServerTestLease
    let port: Int

    func send(_ method: String, _ path: String, json: String? = nil) async throws -> AdminRouteResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let json {
            request.httpBody = Data(json.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        return AdminRouteResult(
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

private func startAdminTestServer() async throws -> AdminTestServer {
    let lease = await HTTPServerTestLock.shared.acquire()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(configuration: .default, eventLoop: channel.eventLoop, trustLoopback: true))
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return AdminTestServer(group: group, channel: ch, lease: lease, port: ch.localAddress?.port ?? 0)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
