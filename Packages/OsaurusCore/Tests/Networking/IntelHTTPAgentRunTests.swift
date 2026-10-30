//
//  IntelHTTPAgentRunTests.swift
//  OsaurusCoreTests
//
//  `W-server-api` stage 4c (docs/SERVER_API_INTEL.md): `/agents/{id}/run` on
//  Intel's engine, and the `/runs/{id}/*` routes. Upstream's built-in loopback
//  case from `HTTPHandlerChatStreamingTests` (excluded on Intel: its fake
//  engines throw tool calls, upstream's engine contract), plus Intel cases.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelHTTPAgentRunTests {

    @Test func builtInAgentRun_overLoopback_bypassesGuard() async throws {
        let server = try await startRunTestServer(engine: ScriptedRunEngine(deltas: ["OK-BUILTIN"]))
        defer { Task { await server.shutdown() } }
        let result = try await server.post(
            "/agents/\(Agent.defaultId.uuidString)/run",
            #"{"model":"fake","stream":true,"messages":[{"role":"user","content":"hi"}]}"#)
        #expect(result.status == 200)
        #expect(!result.body.contains("built_in_agent_not_exposable"))
        #expect(result.body.contains("OK-BUILTIN"))
    }

    @Test func run_streamsTextAndToolTraceWithoutHints() async throws {
        let engine = ScriptedRunEngine(deltas: [
            "Hello ",
            StreamingToolHint.encodeStarted(callId: "call_1", name: "get_current_time", arguments: "{}"),
            StreamingToolHint.encodeDone(callId: "call_1", name: "get_current_time", arguments: "{}", result: "12:00"),
            "world",
            StreamingUsageHint.encode(promptTokens: 10, completionTokens: 5),
        ])
        let server = try await startRunTestServer(engine: engine)
        defer { Task { await server.shutdown() } }
        let result = try await server.post(
            "/agents/default/run",
            #"{"messages":[{"role":"user","content":"hi"}],"stream_options":{"include_usage":true}}"#)
        #expect(result.status == 200)
        #expect(result.body.contains("Hello "))
        #expect(result.body.contains("world"))
        #expect(result.body.contains(#""osaurus_agent_tool""#))
        #expect(result.body.contains(#""phase":"started""#))
        #expect(result.body.contains(#""phase":"completed""#))
        #expect(result.body.contains(#""call_id":"call_1""#))
        #expect(result.body.contains(#""prompt_tokens":10"#))
        #expect(!result.body.contains("OSX_TOOL"))
        #expect(result.body.hasSuffix("data: [DONE]\n\n"))
        let captured = try #require(await engine.captured)
        #expect(captured.request.reportsToolStarts)
        #expect(captured.request.reportsUsage)
        #expect(captured.request.maxToolRounds != nil)
        #expect(captured.external)
    }

    @Test func run_toolRoundLimitEndsWithUpstreamNotice() async throws {
        let engine = ScriptedRunEngine(deltas: ["partial"], failure: ChatEngine.ToolRoundLimitReached(rounds: 3))
        let server = try await startRunTestServer(engine: engine)
        defer { Task { await server.shutdown() } }
        let result = try await server.post("/agents/default/run", #"{"messages":[{"role":"user","content":"hi"}]}"#)
        #expect(result.body.contains("Tool-loop budget of"))
        #expect(!result.body.contains(#""error""#))
    }

    @Test func run_rejectsBadBodiesAndUnknownAgents() async throws {
        let server = try await startRunTestServer(engine: ScriptedRunEngine(deltas: []))
        defer { Task { await server.shutdown() } }
        let bad = try await server.post("/agents/default/run", "not json")
        #expect(bad.status == 400)
        let unknown = try await server.post(
            "/agents/0xdead000000000000000000000000000000000000/run", #"{"messages":[]}"#)
        #expect(unknown.status == 400)
        #expect(unknown.body.contains("invalid_agent_id"))
    }

    @Test func runs_routesAnswerRunNotFound() async throws {
        let server = try await startRunTestServer(engine: ScriptedRunEngine(deltas: []))
        defer { Task { await server.shutdown() } }
        let events = try await server.send("GET", "/runs/abc/events", nil)
        #expect(events.status == 404)
        #expect(events.body.contains("run_not_found"))
        let stop = try await server.post("/runs/abc/stop", "{}")
        #expect(stop.status == 404)
    }

    @Test func helpers_matchUpstream() {
        let patched = HTTPHandler.injectingEmptyModelIfMissing(Data(#"{"messages":[]}"#.utf8))
        let obj = (try? JSONSerialization.jsonObject(with: patched)) as? [String: Any]
        #expect(obj?["model"] as? String == "")
        let kept = Data(#"{"model":"m"}"#.utf8)
        #expect(HTTPHandler.injectingEmptyModelIfMissing(kept) == kept)
        #expect(HTTPHandler.interceptText(toolName: "complete", arguments: #"{"summary":"Did it"}"#) == "Did it")
        #expect(HTTPHandler.interceptText(toolName: "file_read", arguments: "{}") == nil)
    }
}

// MARK: - Fixtures

private actor ScriptedRunEngine: ChatEngineProtocol {
    struct Captured { let request: ChatCompletionRequest; let external: Bool }
    let deltas: [String]
    let failure: Error?
    private(set) var captured: Captured?

    init(deltas: [String], failure: Error? = nil) {
        self.deltas = deltas
        self.failure = failure
    }

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        captured = Captured(request: request, external: ChatExecutionContext.isExternalSurface)
        let deltas = deltas
        let failure = failure
        return AsyncThrowingStream { continuation in
            for delta in deltas { continuation.yield(delta) }
            if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
        }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw CancellationError()
    }
}

private struct RunResult { let status: Int; let body: String }

private struct RunTestServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let lease: HTTPServerTestLease
    let port: Int

    func send(_ method: String, _ path: String, _ body: String?) async throws -> RunResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        return RunResult(status: (resp as? HTTPURLResponse)?.statusCode ?? -1, body: String(decoding: data, as: UTF8.self))
    }

    func post(_ path: String, _ body: String) async throws -> RunResult { try await send("POST", path, body) }

    func shutdown() async {
        _ = try? await channel.close()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
    }
}

private func startRunTestServer(engine: any ChatEngineProtocol) async throws -> RunTestServer {
    let lease = await HTTPServerTestLock.shared.acquire()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            configuration: .default, eventLoop: channel.eventLoop, trustLoopback: true,
                            chatEngine: engine))
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return RunTestServer(group: group, channel: ch, lease: lease, port: ch.localAddress?.port ?? 0)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
