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

extension IntelHTTPChatCompletionsTests {
    private func postPath(_ server: ChatTestServer, _ path: String, _ json: String) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(json.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: request)
        return ((resp as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
    }

    @Test func ollamaChatStreamsNDJSONAndClosesWithToolCalls() async throws {
        let call = StreamingToolHint.ProposedCall(callId: "c", name: "get_weather", arguments: #"{"city":"Rome"}"#)
        let engine = ScriptedChatEngine([StreamingReasoningHint.encode("hm"), "Hi", StreamingToolHint.encodeProposed([call])])
        let server = try await startChatTestServer(engine: engine)
        defer { Task { await server.shutdown() } }

        let (status, body) = try await postPath(server, "/api/chat",
            #"{"model":"venice/llama","messages":[{"role":"user","content":"hi"}],"options":{"num_predict":64,"temperature":0.2}}"#)
        #expect(status == 200)
        let frames = body.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let messages = frames.compactMap { $0["message"] as? [String: Any] }
        #expect(messages.compactMap { $0["thinking"] as? String }.joined() == "hm")
        #expect(messages.compactMap { $0["content"] as? String }.joined() == "Hi")
        let last = try #require(frames.last)
        #expect(last["done"] as? Bool == true)
        #expect(last["done_reason"] as? String == "stop")
        let calls = try #require((last["message"] as? [String: Any])?["tool_calls"] as? [[String: Any]])
        let function = try #require(calls.first?["function"] as? [String: Any])
        #expect(function["name"] as? String == "get_weather")
        #expect((function["arguments"] as? [String: Any])?["city"] as? String == "Rome", "Ollama sends arguments as an object")
        // Ollama options became the request's sampling fields.
        let sent = try #require(engine.requests.first)
        #expect(sent.max_tokens == 64)
        #expect(sent.temperature == 0.2)
        #expect(sent.stopAtToolCalls)
    }

    @Test func ollamaGenerateNonStreamingAnswersOneBody() async throws {
        let engine = ScriptedChatEngine(["Paris"])
        let server = try await startChatTestServer(engine: engine)
        defer { Task { await server.shutdown() } }

        let (status, body) = try await postPath(server, "/api/generate",
            #"{"model":"venice/llama","prompt":"Capital of France?","system":"Be brief.","stream":false}"#)
        #expect(status == 200, "\(body)")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(object["response"] as? String == "Paris")
        #expect(object["done"] as? Bool == true)
        #expect(object["done_reason"] as? String == "stop")
        let sent = try #require(engine.requests.first)
        #expect(sent.messages.map(\.role) == ["system", "user"])
        #expect(sent.messages.last?.content == "Capital of France?")
    }

    @Test func ollamaRejectsBadRequests() async throws {
        let engine = ScriptedChatEngine([])
        let server = try await startChatTestServer(engine: engine)
        defer { Task { await server.shutdown() } }
        let (status, _) = try await postPath(server, "/api/generate", #"{"prompt":"no model"}"#)
        #expect(status == 400)
        let (think, _) = try await postPath(server, "/api/chat",
            #"{"model":"m","messages":[{"role":"user","content":"x"}],"think":42}"#)
        #expect(think == 400)
        #expect(engine.requests.isEmpty)
    }
}

extension IntelHTTPChatCompletionsTests {
    @Test func measuredUsageReachesEveryProtocol() async throws {
        let usage = StreamingUsageHint.encode(promptTokens: 12, completionTokens: 3)
        #expect(IntelHTTPInference.classify(usage) == .usage(promptTokens: 12, completionTokens: 3))
        let engine = ScriptedChatEngine(["Hi", usage])
        let server = try await startChatTestServer(engine: engine)
        defer { Task { await server.shutdown() } }

        let (_, chat) = try await postPath(server, "/v1/chat/completions",
            #"{"model":"m","messages":[{"role":"user","content":"x"}]}"#)
        let chatObject = try #require(try JSONSerialization.jsonObject(with: Data(chat.utf8)) as? [String: Any])
        let reported = try #require(chatObject["usage"] as? [String: Int])
        #expect(reported == ["prompt_tokens": 12, "completion_tokens": 3, "total_tokens": 15])
        #expect(engine.requests.first?.reportsUsage == true)

        let (_, stream) = try await postPath(server, "/v1/chat/completions",
            #"{"model":"m","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"x"}]}"#)
        #expect(stream.contains(#""prompt_tokens":12"#), "include_usage chunk: \(stream)")

        let (_, ollama) = try await postPath(server, "/api/generate", #"{"model":"m","prompt":"x","stream":false}"#)
        let ollamaObject = try #require(try JSONSerialization.jsonObject(with: Data(ollama.utf8)) as? [String: Any])
        #expect(ollamaObject["prompt_eval_count"] as? Int == 12)
        #expect(ollamaObject["eval_count"] as? Int == 3)
    }

    @Test func anthropicMessagesAnswersWithBlocksAndUsage() async throws {
        let call = StreamingToolHint.ProposedCall(callId: "toolu_1", name: "get_weather", arguments: #"{"city":"Rome"}"#)
        let engine = ScriptedChatEngine([
            StreamingReasoningHint.encode("plan"), "Sure.", StreamingToolHint.encodeProposed([call]),
            StreamingUsageHint.encode(promptTokens: 20, completionTokens: 5),
        ])
        let server = try await startChatTestServer(engine: engine)
        defer { Task { await server.shutdown() } }
        let request = #"""
            {"model":"venice/llama","max_tokens":256,"system":"Be brief.",
             "messages":[{"role":"user","content":"Weather in Rome?"}],
             "tools":[{"name":"get_weather","input_schema":{"type":"object"}}]}
            """#
        let (status, body) = try await postPath(server, "/v1/messages", request)
        #expect(status == 200, "\(body)")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "message")
        #expect(object["stop_reason"] as? String == "tool_use")
        let blocks = try #require(object["content"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["thinking", "text", "tool_use"])
        #expect((blocks[2]["input"] as? [String: Any])?["city"] as? String == "Rome")
        let usage = try #require(object["usage"] as? [String: Any])
        #expect(usage["input_tokens"] as? Int == 20)
        #expect(usage["output_tokens"] as? Int == 5)
        let sent = try #require(engine.requests.first)
        #expect(sent.messages.first?.role == "system")
        #expect(sent.tools?.first?.function.name == "get_weather")

        let streamed = request.replacingOccurrences(of: #""max_tokens":256,"#, with: #""max_tokens":256,"stream":true,"#)
        let (_, events) = try await postPath(server, "/v1/messages", streamed)
        let names = events.components(separatedBy: "\n").filter { $0.hasPrefix("event: ") }.map { String($0.dropFirst(7)) }
        #expect(names.first == "message_start")
        #expect(names.last == "message_stop")
        #expect(names.contains("message_delta"))
        #expect(events.contains(#""input_tokens":20"#))
        #expect(events.contains("input_json_delta"))
    }

    @Test func anthropicWithoutMeasuredUsageIsRefusedLikeUpstream() async throws {
        let engine = ScriptedChatEngine(["Hi"])
        let server = try await startChatTestServer(engine: engine)
        defer { Task { await server.shutdown() } }
        let (status, body) = try await postPath(server, "/v1/messages",
            #"{"model":"m","max_tokens":16,"messages":[{"role":"user","content":"x"}]}"#)
        #expect(status == 502)
        #expect(body.contains("input and output token counts"))
    }
}

extension IntelHTTPChatCompletionsTests {
    /// Validation only: a valid request would download the embedding model.
    @Test func embeddingsValidateTheModelLikeUpstream() async throws {
        let server = try await startChatTestServer(engine: ScriptedChatEngine([]))
        defer { Task { await server.shutdown() } }

        let (status, body) = try await postPath(server, "/v1/embeddings", #"{"model":"potion-base-4M","input":"hi"}"#)
        #expect(status == 400)
        #expect(body.contains("unsupported_embedding_model"))
        #expect(body.contains(IntelAPIEmbedder.modelName))
        let (ollama, ollamaBody) = try await postPath(server, "/api/embed", #"{"model":"nope","input":["a"]}"#)
        #expect(ollama == 400)
        #expect(ollamaBody.hasPrefix(#"{"error":"Embedding model"#))
        let (bad, _) = try await postPath(server, "/v1/embeddings", "not json")
        #expect(bad == 400)
        #expect(throws: Never.self) { try IntelAPIEmbedder.validateAPIModel(StaticEmbeddingModel.modelId) }
    }

    @Test func legacyCompletionsValidateThenExplainLocalOnly() async throws {
        let server = try await startChatTestServer(engine: ScriptedChatEngine([]))
        defer { Task { await server.shutdown() } }
        let (fim, fimBody) = try await postPath(server, "/v1/completions", #"{"model":"m","prompt":"a","suffix":"b"}"#)
        #expect(fim == 400)
        #expect(fimBody.contains("'suffix'"))
        let (missing, _) = try await postPath(server, "/v1/completions", #"{"model":"m"}"#)
        #expect(missing == 400)
        let (local, localBody) = try await postPath(server, "/v1/completions", #"{"model":"m","prompt":"def f("}"#)
        #expect(local == 404)
        #expect(localBody.contains("Apple silicon"))
    }
}

extension IntelHTTPChatCompletionsTests {
    @Test func multipartParserReadsFieldsAndFileAndSurvivesGarbage() {
        let body = "--XB\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"
            + "--XB\r\nContent-Disposition: form-data; name=\"file\"; filename=\"clip.m4a\"\r\n"
            + "Content-Type: audio/mp4\r\n\r\nAUDIO\r\n--XB--\r\n"
        let parsed = HTTPHandler.parseMultipartFormData(data: Data(body.utf8), boundary: "XB")
        #expect(parsed.fields["model"] == "whisper-1")
        #expect(parsed.filename == "clip.m4a")
        #expect(parsed.file == Data("AUDIO".utf8))
        // Upstream's parser traps on a body without any boundary.
        #expect(HTTPHandler.parseMultipartFormData(data: Data("no parts here".utf8), boundary: "XB").file == nil)
        #expect(HTTPHandler.parseMultipartFormData(data: Data(), boundary: "").file == nil)
        #expect(HTTPHandler.extractBoundary(from: #"multipart/form-data; boundary="abc""#) == "abc")
    }

    /// Validation only: a real file would ask for speech-recognition access.
    @Test func transcriptionRejectsWhatItCannotRead() async throws {
        let server = try await startChatTestServer(engine: ScriptedChatEngine([]))
        defer { Task { await server.shutdown() } }
        let (json, _) = try await postPath(server, "/v1/audio/transcriptions", #"{"file":"x"}"#)
        #expect(json == 400)

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=XB", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("--XB\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nm\r\n--XB--\r\n".utf8)
        let (data, resp) = try await URLSession.shared.data(for: request)
        #expect((resp as? HTTPURLResponse)?.statusCode == 400)
        #expect(String(decoding: data, as: UTF8.self).contains("Missing audio file"))
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
