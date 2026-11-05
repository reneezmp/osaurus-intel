//
//  IntelPluginInferenceTests.swift
//  OsaurusCoreTests
//
//  `W-plugin-reliability` stage 2d (docs/UPSTREAM_SYNC.md, "Plugin
//  inference"). Upstream's own suites for these callbacks drive its
//  Responses engine (`MockChatEngine`, not on Intel), so these pin the
//  plugin-facing contract on Intel's engine with a scripted one: the
//  `complete` envelope, the `complete_stream` chunks and endings,
//  `complete_cancel` by `stream_id`, the in-flight cap, `embed` /
//  `list_models`, the plugin's instructions, and the sidebar chat.
//
//  `PluginCompleteCancelTests` (upstream, un-excluded) pins the stream
//  registry itself.
//

import Foundation
import Testing

@testable import OsaurusCore

/// An engine that streams a fixed script of deltas (Intel's in-band markers
/// included), records the request it got, and can end by throwing or by
/// waiting until it is cancelled.
private final class ScriptedEngine: ChatEngineProtocol, @unchecked Sendable {
    enum Ending { case finish, throwing(Error), waitForCancel }

    private let lock = NSLock()
    private let deltas: [String]
    private let ending: Ending
    private var _requests: [ChatCompletionRequest] = []

    init(_ deltas: [String], ending: Ending = .finish) {
        self.deltas = deltas
        self.ending = ending
    }

    var requests: [ChatCompletionRequest] { lock.withLock { _requests } }

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        lock.withLock { _requests.append(request) }
        let deltas = deltas
        let ending = ending
        return AsyncThrowingStream { continuation in
            let task = Task {
                for delta in deltas { continuation.yield(delta) }
                switch ending {
                case .finish:
                    continuation.finish()
                case .throwing(let error):
                    continuation.finish(throwing: error)
                case .waitForCancel:
                    do {
                        try await Task.sleep(nanoseconds: 30_000_000_000)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw CancellationError()
    }
}

/// Chunks a `complete_stream` callback received. The C callback can't
/// capture, so `userData` points here; a chunk can also trigger a cancel.
private final class ChunkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _chunks: [[String: Any]] = []
    var cancelOnFirstContent: (context: PluginHostContext, streamId: String)?

    func record(_ json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        let first = lock.withLock { () -> Bool in
            _chunks.append(object)
            return _chunks.count == 1
        }
        if first, let cancel = cancelOnFirstContent {
            cancel.context.completeCancel(streamId: cancel.streamId)
        }
    }

    var chunks: [[String: Any]] { lock.withLock { _chunks } }

    var deltas: [[String: Any]] {
        chunks.compactMap { (($0["choices"] as? [[String: Any]])?.first?["delta"]) as? [String: Any] }
    }

    var finishReasons: [String] {
        chunks.compactMap { (($0["choices"] as? [[String: Any]])?.first?["finish_reason"]) as? String }
    }
}

private let recordChunk: osr_on_chunk_t = { json, userData in
    guard let json, let userData else { return }
    Unmanaged<ChunkRecorder>.fromOpaque(userData).takeUnretainedValue().record(String(cString: json))
}

private func parse(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
}

private func doneMarker(_ callId: String, _ name: String, _ arguments: String, _ result: String) -> String {
    StreamingToolHint.encodeDone(callId: callId, name: name, arguments: arguments, result: result)
}

@Suite(.serialized)
struct IntelPluginInferenceTests {

    private func makeContext(_ engine: ScriptedEngine) throws -> PluginHostContext {
        try PluginHostContext(
            pluginId: "com.test.inference.\(UUID().uuidString.prefix(8))",
            inferenceEngineFactory: { engine }
        )
    }

    /// Plugin chats are saved to the sidebar on the main actor after the
    /// call returns; wait for them and remove them.
    @MainActor
    private func savedChats(for pluginId: String, expecting count: Int) async -> [ChatSessionData] {
        for _ in 0..<100 {
            let found = ChatSessionsManager.shared.sessions.values.filter { $0.sourcePluginId == pluginId }
            if found.count >= count { return found }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return ChatSessionsManager.shared.sessions.values.filter { $0.sourcePluginId == pluginId }
    }

    @MainActor
    private func removeChats(for pluginId: String) {
        for session in ChatSessionsManager.shared.sessions.values where session.sourcePluginId == pluginId {
            ChatSessionsManager.shared.delete(id: session.id)
        }
    }

    // MARK: complete

    @Test func completeReturnsAChatCompletion() async throws {
        let engine = ScriptedEngine(["Hel", "lo", StreamingUsageHint.encode(promptTokens: 12, completionTokens: 3)])
        let ctx = try makeContext(engine)
        defer { ctx.teardown() }

        let reply = parse(ctx.complete(requestJSON: #"{"model":"m-1","messages":[{"role":"user","content":"hi"}]}"#))
        #expect(reply["object"] as? String == "chat.completion")
        #expect(reply["model"] as? String == "m-1")
        let choice = try #require((reply["choices"] as? [[String: Any]])?.first)
        #expect((choice["message"] as? [String: Any])?["content"] as? String == "Hello")
        #expect(choice["finish_reason"] as? String == "stop")
        let usage = try #require(reply["usage"] as? [String: Any])
        #expect(usage["prompt_tokens"] as? Int == 12)
        #expect(usage["completion_tokens"] as? Int == 3)
        #expect(usage["total_tokens"] as? Int == 15)
        #expect(reply["tool_calls_executed"] == nil)
        await MainActor.run { removeChats(for: ctx.pluginId) }
    }

    /// The engine gets upstream's loop settings, and the extension fields
    /// never reach it. With no chat agent there is no system prompt.
    @Test func engineRequestCarriesTheLoopSettings() async throws {
        let engine = ScriptedEngine(["ok"])
        let ctx = try makeContext(engine)
        defer { ctx.teardown() }

        _ = ctx.complete(
            requestJSON:
                #"{"model":"m-1","max_iterations":500,"agent_id":"x","messages":[{"role":"user","content":"hi"}]}"#)
        let request = try #require(engine.requests.first)
        #expect(request.stream == true)
        #expect(request.maxToolRounds == 120, "max_iterations is capped at upstream's 120")
        #expect(request.reportsToolStarts)
        #expect(request.reportsUsage)
        #expect(request.messages.map(\.role) == ["user"])
        await MainActor.run { removeChats(for: ctx.pluginId) }
    }

    @Test func toolCallsAreReportedAndTheAnswerIsTheLastText() async throws {
        let engine = ScriptedEngine([
            "Let me look.",
            StreamingToolHint.encodeStarted(callId: "c1", name: "file_read", arguments: #"{"path":"a"}"#),
            doneMarker("c1", "file_read", #"{"path":"a"}"#, ToolEnvelope.success(tool: "file_read", text: "body")),
            "Here it is.",
        ])
        let ctx = try makeContext(engine)
        defer { ctx.teardown() }

        let reply = parse(ctx.complete(requestJSON: #"{"model":"m","messages":[{"role":"user","content":"go"}]}"#))
        let choice = try #require((reply["choices"] as? [[String: Any]])?.first)
        #expect((choice["message"] as? [String: Any])?["content"] as? String == "Here it is.")
        let executed = try #require(reply["tool_calls_executed"] as? [[String: String]])
        #expect(executed == [["name": "file_read", "tool_call_id": "c1"]])
        await MainActor.run { removeChats(for: ctx.pluginId) }
    }

    @Test func iterationCapIsMaxIterationsReached() async throws {
        let engine = ScriptedEngine(
            [doneMarker("c1", "file_read", "{}", ToolEnvelope.success(tool: "file_read", text: "x"))],
            ending: .throwing(ChatEngine.ToolRoundLimitReached(rounds: 2)))
        let ctx = try makeContext(engine)
        defer { ctx.teardown() }

        let reply = parse(
            ctx.complete(requestJSON: #"{"model":"m","max_iterations":2,"messages":[{"role":"user","content":"go"}]}"#))
        #expect(reply["error"] as? String == "max_iterations_reached")
        #expect((reply["message"] as? String)?.contains("(2)") == true)
        #expect((reply["tool_calls_executed"] as? [[String: String]])?.count == 1)
        await MainActor.run { removeChats(for: ctx.pluginId) }
    }

    @Test func clarifyEndsWithTheQuestion() async throws {
        let args = #"{"question":"Which file?"}"#
        let engine = ScriptedEngine([doneMarker("c1", "clarify", args, ToolEnvelope.success(tool: "clarify", text: "ok"))])
        let ctx = try makeContext(engine)
        defer { ctx.teardown() }

        let reply = parse(ctx.complete(requestJSON: #"{"model":"m","messages":[{"role":"user","content":"go"}]}"#))
        #expect(reply["error"] as? String == "clarify_requested")
        #expect(reply["question"] as? String == "Which file?")
        await MainActor.run { removeChats(for: ctx.pluginId) }
    }

    @Test func completeToolGivesTheSummaryAsTheAnswer() async throws {
        let args = #"{"summary":"All done."}"#
        let engine = ScriptedEngine([
            "draft", doneMarker("c1", "complete", args, ToolEnvelope.success(tool: "complete", text: "ok")),
        ])
        let ctx = try makeContext(engine)
        defer { ctx.teardown() }

        let reply = parse(ctx.complete(requestJSON: #"{"model":"m","messages":[{"role":"user","content":"go"}]}"#))
        let choice = try #require((reply["choices"] as? [[String: Any]])?.first)
        #expect((choice["message"] as? [String: Any])?["content"] as? String == "All done.")
        #expect(choice["finish_reason"] as? String == "stop")
        await MainActor.run { removeChats(for: ctx.pluginId) }
    }

    @Test func engineFailureIsInferenceError() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "provider down" } }
        let engine = ScriptedEngine([], ending: .throwing(Boom()))
        let ctx = try makeContext(engine)
        defer { ctx.teardown() }

        let reply = parse(ctx.complete(requestJSON: #"{"model":"m","messages":[{"role":"user","content":"go"}]}"#))
        #expect(reply["error"] as? String == "inference_error")
        #expect(reply["message"] as? String == "provider down")
        await MainActor.run { removeChats(for: ctx.pluginId) }
    }

    @Test func malformedRequestIsInvalidRequest() throws {
        let ctx = try makeContext(ScriptedEngine([]))
        defer { ctx.teardown() }
        #expect(parse(ctx.complete(requestJSON: "not json"))["error"] as? String == "invalid_request")
    }

    /// Upstream's cap: two inference calls per plugin at once, the third
    /// refused straight away.
    @Test func thirdConcurrentCallIsPluginBusy() throws {
        let ctx = try makeContext(ScriptedEngine([]))
        defer { ctx.teardown() }
        #expect(ctx.tryEnterInflightInference())
        #expect(ctx.tryEnterInflightInference())
        defer {
            ctx.exitInflightInference()
            ctx.exitInflightInference()
        }
        let request = #"{"model":"m","messages":[{"role":"user","content":"go"}]}"#
        #expect(parse(ctx.complete(requestJSON: request))["error"] as? String == "plugin_busy")
        #expect(
            parse(ctx.completeStream(requestJSON: request, onChunk: nil, userData: nil))["error"] as? String
                == "plugin_busy")
        #expect(parse(ctx.embed(requestJSON: #"{"input":"x"}"#))["error"] as? String == "plugin_busy")
    }

    // MARK: complete_stream

    @Test func streamSendsUpstreamsChunks() async throws {
        let engine = ScriptedEngine([
            StreamingReasoningHint.encode("hmm"),
            "Look",
            StreamingToolHint.encodeStarted(callId: "c1", name: "file_read", arguments: #"{"path":"a"}"#),
            doneMarker("c1", "file_read", #"{"path":"a"}"#, "RESULT"),
            "Done",
        ])
        let ctx = try makeContext(engine)
        defer { ctx.teardown() }
        let recorder = ChunkRecorder()
        let userData = Unmanaged.passUnretained(recorder).toOpaque()

        let reply = parse(
            ctx.completeStream(
                requestJSON: #"{"model":"m","messages":[{"role":"user","content":"go"}]}"#,
                onChunk: recordChunk, userData: userData))
        withExtendedLifetime(recorder) {}

        let deltas = recorder.deltas
        #expect(deltas.count == 6)
        #expect(deltas[0]["reasoning_content"] as? String == "hmm")
        #expect(deltas[1]["content"] as? String == "Look")
        let call = try #require((deltas[2]["tool_calls"] as? [[String: Any]])?.first)
        #expect(call["id"] as? String == "c1")
        #expect((call["function"] as? [String: Any])?["name"] as? String == "file_read")
        #expect(deltas[3]["role"] as? String == "tool")
        #expect(deltas[3]["tool_call_id"] as? String == "c1")
        #expect(deltas[3]["content"] as? String == "RESULT")
        #expect(deltas[4]["content"] as? String == "Done")
        #expect(recorder.finishReasons == ["tool_calls", "stop"])

        let choice = try #require((reply["choices"] as? [[String: Any]])?.first)
        #expect((choice["message"] as? [String: Any])?["content"] as? String == "Done")
        #expect((reply["id"] as? String)?.hasPrefix("cmpl-") == true)
        #expect((reply["tool_calls_executed"] as? [[String: String]])?.count == 1)
        await MainActor.run { removeChats(for: ctx.pluginId) }
    }

    @Test func completeCancelStopsTheStream() async throws {
        let engine = ScriptedEngine(["partial"], ending: .waitForCancel)
        let ctx = try makeContext(engine)
        defer { ctx.teardown() }
        let recorder = ChunkRecorder()
        recorder.cancelOnFirstContent = (ctx, "s-1")
        let userData = Unmanaged.passUnretained(recorder).toOpaque()

        let started = Date()
        let reply = parse(
            ctx.completeStream(
                requestJSON: #"{"model":"m","stream_id":"  s-1 ","messages":[{"role":"user","content":"go"}]}"#,
                onChunk: recordChunk, userData: userData))
        withExtendedLifetime(recorder) {}

        #expect(Date().timeIntervalSince(started) < 10, "the cancel ends the run, not the engine's wait")
        #expect(reply["error"] as? String == "cancelled")
        #expect(reply["stream_id"] as? String == "s-1")
        #expect(reply["partial_content"] as? String == "partial")
        #expect(recorder.finishReasons.last == "cancelled")
        #expect(!ctx.isStreamCancelled("s-1"), "the stream id is released when the call returns")
        await MainActor.run { removeChats(for: ctx.pluginId) }
    }

    @Test func streamIterationCapIsHonest() async throws {
        let engine = ScriptedEngine(["thinking"], ending: .throwing(ChatEngine.ToolRoundLimitReached(rounds: 1)))
        let ctx = try makeContext(engine)
        defer { ctx.teardown() }
        let recorder = ChunkRecorder()
        let userData = Unmanaged.passUnretained(recorder).toOpaque()

        let reply = parse(
            ctx.completeStream(
                requestJSON: #"{"model":"m","messages":[{"role":"user","content":"go"}]}"#,
                onChunk: recordChunk, userData: userData))
        withExtendedLifetime(recorder) {}
        #expect(reply["error"] as? String == "max_iterations_reached")
        #expect(reply["partial_content"] as? String == "thinking")
        #expect(recorder.finishReasons.last == "max_iterations")
        await MainActor.run { removeChats(for: ctx.pluginId) }
    }

    // MARK: Sidebar chat

    /// Upstream saves plugin completions to the chat history: one chat per
    /// `session_id`, its turns replaced by the latest full conversation.
    @Test func sessionIdKeepsOneGrowingChat() async throws {
        let engine = ScriptedEngine(["Answer"])
        let ctx = try makeContext(engine)
        defer { ctx.teardown() }

        _ = ctx.complete(
            requestJSON: #"{"model":"m","session_id":"thread-9","messages":[{"role":"user","content":"first"}]}"#)
        let first = await savedChats(for: ctx.pluginId, expecting: 1)
        #expect(first.count == 1)
        #expect(first.first?.turns.map(\.content) == ["first", "Answer"])

        _ = ctx.complete(
            requestJSON: #"""
                {"model":"m","session_id":"thread-9","messages":[
                {"role":"user","content":"first"},{"role":"assistant","content":"Answer"},
                {"role":"user","content":"second"}]}
                """#)
        // The update lands on the same chat.
        var chats: [ChatSessionData] = []
        for _ in 0..<100 {
            chats = await savedChats(for: ctx.pluginId, expecting: 1)
            if chats.first?.turns.count == 4 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(chats.count == 1)
        let chat = try #require(chats.first)
        #expect(chat.source == .plugin)
        #expect(chat.externalSessionKey == "thread-9")
        #expect(chat.agentId == Agent.defaultId, "no chat agent: stored under the Default agent")
        #expect(chat.turns.map(\.content) == ["first", "Answer", "second", "Answer"])
        await MainActor.run { removeChats(for: ctx.pluginId) }
    }

    // MARK: embed / list_models

    @Test func embedNeedsAnInput() throws {
        let ctx = try makeContext(ScriptedEngine([]))
        defer { ctx.teardown() }
        let reply = parse(ctx.embed(requestJSON: #"{"model":"x"}"#))
        #expect(reply["error"] as? String == "invalid_request")
        #expect(reply["message"] as? String == "Missing or invalid 'input' field")
        #expect(parse(ctx.embed(requestJSON: "nope"))["error"] as? String == "invalid_request")
    }

    @Test func listModelsNamesIntelsEmbedder() throws {
        let ctx = try makeContext(ScriptedEngine([]))
        defer { ctx.teardown() }
        let models = try #require(parse(ctx.listModels())["models"] as? [[String: Any]])
        let embedder = try #require(models.first { $0["type"] as? String == "embedding" })
        #expect(embedder["id"] as? String == IntelAPIEmbedder.modelName)
        #expect(embedder["dimensions"] as? Int == 256)
        #expect(!models.contains { $0["provider"] as? String == "local" && $0["type"] as? String == "chat" })
    }

    // MARK: Plugin instructions

    /// The agent's override for the plugin reaches the end of the system
    /// prompt (upstream `prepareInference` → `appendSystemContent`).
    @Test func pluginInstructionsReachTheRequest() async throws {
        let pid = "com.test.inference.instructions.\(UUID().uuidString.prefix(6))"
        try await SandboxTestLock.runWithStoragePaths {
            let agent = Agent(
                name: "InferenceInstructions-\(UUID().uuidString.prefix(6))",
                agentAddress: "test-inference-instructions-\(UUID().uuidString)",
                pluginInstructions: [pid: "Reply with [reply_token]."]
            )
            AgentManager.shared.add(agent)
            let raw = #"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#
            let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(raw.utf8))
            let prep = await PluginHostContext.prepareInference(
                request: request, rawJSON: [:], pluginId: pid, activeAgentId: agent.id,
                engineFactory: { ScriptedEngine([]) })
            let system = prep.enriched.request.messages.first { $0.role == "system" }?.content ?? ""
            #expect(system.hasSuffix("Reply with [reply_token]."))
            #expect(prep.agentId == agent.id)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }
}
