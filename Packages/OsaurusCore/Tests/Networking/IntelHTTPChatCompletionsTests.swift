//
//  IntelHTTPChatCompletionsTests.swift
//  osaurus
//
//  `W-server-api` stage 2 (docs/SERVER_API_INTEL.md): `/chat/completions`
//  on Intel's engine. A scripted engine stands in for the provider, so
//  nothing leaves the machine; the server is a real NIO server on a random
//  loopback port.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

/// Replays scripted engine deltas and records each request.
private final class ScriptedChatEngine: ChatEngineProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let deltas: [String]
    private let failure: Error?
    private var _requests: [ChatCompletionRequest] = []

    init(_ deltas: [String], failure: Error? = nil) {
        self.deltas = deltas
        self.failure = failure
    }

    var requests: [ChatCompletionRequest] { lock.withLock { _requests } }

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        lock.withLock { _requests.append(request) }
        if let failure { throw failure }
        let deltas = self.deltas
        return AsyncThrowingStream { continuation in
            for delta in deltas { continuation.yield(delta) }
            continuation.finish()
        }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw CancellationError()
    }
}

@Suite(.serialized)
struct IntelHTTPChatCompletionsTests {
    private static let body = #"""
        {"model":"venice/llama","messages":[{"role":"user","content":"hi"}],
         "tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object"}}}],
         "tool_choice":"required"}
        """#

    private func post(_ server: ChatTestServer, _ json: String, accept: String? = nil) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = Data(json.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let (data, resp) = try await URLSession.shared.data(for: request)
        return ((resp as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
    }

    @Test func classifySplitsMarkersFromText() {
        #expect(IntelHTTPInference.classify("hello") == .content("hello"))
        #expect(IntelHTTPInference.classify(StreamingReasoningHint.encode("think")) == .reasoning("think"))
        let call = StreamingToolHint.ProposedCall(callId: "c1", name: "f", arguments: "{}")
        #expect(IntelHTTPInference.classify(StreamingToolHint.encodeProposed([call])) == .toolCalls([call]))
        #expect(IntelHTTPInference.classify(StreamingToolHint.encode("f")) == nil)
        let stats = StreamingStatsHint.encode(tokenCount: 7, tokensPerSecond: 1, stopReason: "length")
        #expect(IntelHTTPInference.classify(stats) == .stats(tokenCount: 7, tokensPerSecond: 1, stopReason: "length"))
        #expect(IntelHTTPInference.classify("") == nil)
    }

    @Test func toolChoiceDecodesAndTravelsInOpenAIForm() throws {
        let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(Self.body.utf8))
        #expect(request.tool_choice == .required)
        #expect(ChatEngine.wireToolChoice(nil) as? String == "auto")
        #expect(ChatEngine.wireToolChoice(ToolChoiceOption.none) as? String == "none")
        let named = try JSONDecoder().decode(
            ToolChoiceOption.self, from: Data(#"{"type":"function","function":{"name":"f"}}"#.utf8))
        let wire = ChatEngine.wireToolChoice(named) as? [String: Any]
        #expect((wire?["function"] as? [String: String])?["name"] == "f")
    }

    @Test func nonStreamingReturnsTheAnswerAndTheProposedCalls() async throws {
        let call = StreamingToolHint.ProposedCall(callId: "call_1", name: "get_weather", arguments: #"{"city":"Rome"}"#)
        let engine = ScriptedChatEngine([
            StreamingReasoningHint.encode("planning"), "Checking.", StreamingToolHint.encodeProposed([call]),
        ])
        let server = try await startChatTestServer(engine: engine)
        defer { Task { await server.shutdown() } }

        let (status, body) = try await post(server, Self.body)
        #expect(status == 200, "\(body)")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(object["object"] as? String == "chat.completion")
        #expect(object["model"] as? String == "venice/llama")
        #expect(object["usage"] == nil, "usage is only reported when measured")
        let choice = try #require((object["choices"] as? [[String: Any]])?.first)
        #expect(choice["finish_reason"] as? String == "tool_calls")
        let message = try #require(choice["message"] as? [String: Any])
        #expect(message["content"] as? String == "Checking.")
        #expect(message["reasoning_content"] as? String == "planning")
        let calls = try #require(message["tool_calls"] as? [[String: Any]])
        #expect(calls.first?["id"] as? String == "call_1")
        #expect((calls.first?["function"] as? [String: Any])?["arguments"] as? String == #"{"city":"Rome"}"#)

        // The engine got the client's request as one model round.
        let sent = try #require(engine.requests.first)
        #expect(sent.stopAtToolCalls)
        #expect(sent.tools?.map(\.function.name) == ["get_weather"])
        #expect(sent.tool_choice == .required)
    }

    @Test func streamingWritesOpenAIChunksThenDone() async throws {
        let engine = ScriptedChatEngine([
            StreamingReasoningHint.encode("hmm"), "Hel", "lo",
            StreamingStatsHint.encode(tokenCount: 2, tokensPerSecond: 10),
        ])
        let server = try await startChatTestServer(engine: engine)
        defer { Task { await server.shutdown() } }

        let streamBody = Self.body.replacingOccurrences(of: #""tool_choice":"required"}"#,
            with: #""tool_choice":"auto","stream":true}"#)
        let (status, body) = try await post(server, streamBody)
        #expect(status == 200)
        let events = body.components(separatedBy: "\n\n").filter { $0.hasPrefix("data: ") }
            .map { String($0.dropFirst(6)) }
        #expect(events.last == "[DONE]")
        let chunks = events.dropLast().compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let deltas = chunks.compactMap { ($0["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] }
        #expect(deltas.first?["role"] as? String == "assistant")
        #expect(deltas.compactMap { $0["content"] as? String }.joined() == "Hello")
        #expect(deltas.compactMap { $0["reasoning_content"] as? String }.joined() == "hmm")
        let finish = chunks.compactMap { ($0["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String }
        #expect(finish == ["stop"])
        #expect(chunks.allSatisfy { $0["object"] as? String == "chat.completion.chunk" })
    }

    @Test func streamedToolCallsArriveAsOpenAIDeltas() async throws {
        let call = StreamingToolHint.ProposedCall(callId: "", name: "get_weather", arguments: #"{"city":"Rome"}"#)
        let engine = ScriptedChatEngine([StreamingToolHint.encodeProposed([call])])
        let server = try await startChatTestServer(engine: engine)
        defer { Task { await server.shutdown() } }

        let (_, body) = try await post(server, Self.body, accept: "text/event-stream")
        let chunks = body.components(separatedBy: "\n\n").filter { $0.hasPrefix("data: {") }.compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8)) as? [String: Any]
        }
        let toolDeltas = chunks.compactMap {
            (($0["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]]
        }.flatMap { $0 }
        let start = try #require(toolDeltas.first)
        #expect((start["id"] as? String)?.hasPrefix("call_") == true, "a missing id gets a call_ id")
        #expect((start["function"] as? [String: Any])?["name"] as? String == "get_weather")
        let arguments = toolDeltas.compactMap { ($0["function"] as? [String: Any])?["arguments"] as? String }.joined()
        #expect(arguments == #"{"city":"Rome"}"#)
        let finish = chunks.compactMap { ($0["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String }
        #expect(finish == ["tool_calls"])
    }

    @Test func unknownModelIs404AndBadRequestsAre400() async throws {
        let engine = ScriptedChatEngine([], failure: ChatEngine.EngineError(message: "No endpoint for model \"x\"."))
        let server = try await startChatTestServer(engine: engine)
        defer { Task { await server.shutdown() } }

        let (status, body) = try await post(server, Self.body)
        #expect(status == 404)
        #expect(body.contains("invalid_request_error"))

        let (missing, _) = try await post(server, #"{"messages":[]}"#)
        #expect(missing == 400)
        let (many, manyBody) = try await post(
            server, #"{"model":"m","n":2,"messages":[{"role":"user","content":"hi"}]}"#)
        #expect(many == 400)
        #expect(manyBody.contains("'n' > 1"))
        #expect(engine.requests.count == 1, "rejected requests never reach the engine")
    }
}

// MARK: - Test server

private struct ChatTestServer {
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

private func startChatTestServer(engine: any ChatEngineProtocol) async throws -> ChatTestServer {
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
                            configuration: .default,
                            apiKeyValidator: .empty,
                            eventLoop: channel.eventLoop,
                            trustLoopback: true,
                            chatEngine: engine
                        )
                    )
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return ChatTestServer(group: group, channel: ch, lease: lease, host: "127.0.0.1", port: ch.localAddress?.port ?? 0)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
