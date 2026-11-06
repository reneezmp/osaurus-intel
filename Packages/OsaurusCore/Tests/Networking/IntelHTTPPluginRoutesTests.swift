//
//  IntelHTTPPluginRoutesTests.swift
//  OsaurusCoreTests
//
//  `W-plugin-reliability` stage 2f (docs/UPSTREAM_SYNC.md, "Plugin routes,
//  web apps and the tunnel"): `/plugins/<id>/…` through Intel's real
//  `HTTPHandler` to a loaded plugin. Upstream's route tests pin matching,
//  decoding and containment as pure functions; these pin the handler on
//  Intel: the global key gate is skipped, an agent is required, owner auth,
//  path parameters reaching `handle_route`, the static web app with
//  `window.__osaurus`, and relay traffic reaching only tunnel-exposed
//  routes. The server binds loopback only.
//

import Darwin
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct IntelHTTPPluginRoutesTests {

    /// The fake plugin's `handle_route`: answers 200 with the request's
    /// route id, path parameters and agent, as JSON.
    nonisolated static func echoResponse(for requestJSON: String) -> String {
        let request =
            (try? JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any]) ?? [:]
        let echo: [String: Any] = [
            "route_id": request["route_id"] ?? "",
            "path_params": request["path_params"] ?? [:],
            "agent": PluginHostContext.activeAgentId()?.uuidString ?? "",
            "plugin_url": (request["osaurus"] as? [String: Any])?["plugin_url"] ?? "",
        ]
        let body = String(decoding: try! JSONSerialization.data(withJSONObject: echo), as: UTF8.self)
        let response: [String: Any] = [
            "status": 200, "headers": ["Content-Type": "application/json"], "body": body,
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: response), as: UTF8.self)
    }

    /// `nonisolated`: the C callbacks it builds run on plugin queues, never
    /// the main actor.
    private nonisolated func makePlugin(pluginId: String, dir: URL) throws -> PluginManager.LoadedPlugin {
        let manifestJSON = """
            {"plugin_id":"\(pluginId)","name":"Routes","capabilities":{
              "routes":[
                {"id":"hello","path":"/hello/:name","methods":["GET"],"auth":"none"},
                {"id":"secret","path":"/secret","methods":["GET"],"auth":"owner"},
                {"id":"hook","path":"/hook","methods":["POST"],"auth":"none","tunnel_exposed":true}
              ],
              "web":{"static_dir":"web","entry":"index.html","mount":"/app","auth":"none"}
            }}
            """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON.utf8))
        let api = osr_plugin_api(
            free_string: { ptr in free(UnsafeMutableRawPointer(mutating: ptr)) },
            init: { nil },
            destroy: { _ in },
            get_manifest: { _ in nil },
            invoke: { _, _, _, _ in nil },
            version: 2,
            handle_route: { _, requestPtr in
                let request = requestPtr.map { String(cString: $0) } ?? "{}"
                return IntelHTTPPluginRoutesTests.echoResponse(for: request).withCString { UnsafePointer(strdup($0)) }
            },
            on_config_changed: nil,
            on_task_event: nil
        )
        let plugin = ExternalPlugin(
            handle: try #require(dlopen(nil, RTLD_NOW)),
            api: api,
            ctx: UnsafeMutableRawPointer(bitPattern: 0x1)!,
            manifest: manifest,
            path: dir.appendingPathComponent("plugin.dylib").path,
            abiVersion: 2
        )
        return PluginManager.LoadedPlugin(
            plugin: plugin,
            handle: try #require(dlopen(nil, RTLD_NOW)),
            tools: [],
            skills: [],
            routes: manifest.capabilities.routes ?? [],
            webConfig: manifest.capabilities.web,
            readmePath: nil,
            changelogPath: nil
        )
    }

    @Test func pluginRoutes_overHTTP() async throws {
        let pluginId = "com.test.routes.\(UUID().uuidString.prefix(8).lowercased())"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-plugin-routes-\(UUID().uuidString)", isDirectory: true)
        let web = dir.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try Data("<html><head><title>t</title></head><body>app</body></html>".utf8)
            .write(to: web.appendingPathComponent("index.html"))
        defer { try? FileManager.default.removeItem(at: dir) }

        PluginManager.shared.injectLoadedPluginForTesting(try makePlugin(pluginId: pluginId, dir: dir))
        defer { PluginManager.shared.removeLoadedPluginForTesting(pluginId: pluginId) }

        let server = try await startPluginRoutesTestServer()
        defer { Task { await server.shutdown() } }
        let agent = UUID()
        let agentHeader = ["X-Osaurus-Agent-Id": agent.uuidString]

        // An agent context is required.
        #expect(try await server.send("GET", "/plugins/\(pluginId)/hello/ada").status == 401)

        // Path parameters reach handle_route, run as the agent.
        let hello = try await server.send("GET", "/plugins/\(pluginId)/hello/ada", headers: agentHeader)
        #expect(hello.status == 200)
        let echo = try #require(try JSONSerialization.jsonObject(with: Data(hello.body.utf8)) as? [String: Any])
        #expect(echo["route_id"] as? String == "hello")
        #expect((echo["path_params"] as? [String: String])?["name"] == "ada")
        #expect(echo["agent"] as? String == agent.uuidString)
        #expect((echo["plugin_url"] as? String)?.hasSuffix("/plugins/\(pluginId)") == true)

        // Owner routes need a valid access key.
        #expect(try await server.send("GET", "/plugins/\(pluginId)/secret", headers: agentHeader).status == 401)
        // No such route / plugin.
        #expect(try await server.send("GET", "/plugins/\(pluginId)/nope", headers: agentHeader).status == 404)
        #expect(try await server.send("GET", "/plugins/com.test.missing/x", headers: agentHeader).status == 404)

        // The static web app, with the agent from the query string.
        let app = try await server.send("GET", "/plugins/\(pluginId)/app/?osr_agent=\(agent.uuidString)")
        #expect(app.status == 200)
        #expect(app.body.contains("window.__osaurus"))
        #expect(app.body.contains(#"agentId: "\#(agent.uuidString)""#))

        // Relay traffic only reaches tunnel-exposed routes; the rest answer 404.
        var relay = agentHeader
        relay[HTTPHandler.relayOriginHeaderName] = "1"
        #expect(try await server.send("GET", "/plugins/\(pluginId)/hello/ada", headers: relay).status == 404)
        #expect(try await server.send("GET", "/plugins/\(pluginId)/app/", headers: relay).status == 404)
        #expect(try await server.send("POST", "/plugins/\(pluginId)/hook", headers: relay).status == 200)
    }
}

// MARK: - Server fixture

private struct PluginRouteResult {
    let status: Int
    let body: String
}

private struct PluginRoutesTestServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let lease: HTTPServerTestLease
    let port: Int

    func send(_ method: String, _ path: String, headers: [String: String] = [:]) async throws -> PluginRouteResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, resp) = try await URLSession.shared.data(for: request)
        return PluginRouteResult(
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

private func startPluginRoutesTestServer() async throws -> PluginRoutesTestServer {
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
        return PluginRoutesTestServer(group: group, channel: ch, lease: lease, port: ch.localAddress?.port ?? 0)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
