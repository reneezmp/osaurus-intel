//
//  IntelParallelToolBatchTests.swift
//  OsaurusCoreTests
//
//  Stage 5c row 17 (upstream Classic `runBatchInParallel`, `pathSerializationKey`):
//  the calls of one round run concurrently, same-path `file_write` / `file_edit`
//  calls run in order, results come back in call order, approvals resolve before
//  the batch, a refusal skips the rest, and a Stop ends the batch. The engine
//  talks to an in-process HTTP fixture and scripted probe tools, never a provider.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel parallel tool batches", .serialized)
struct IntelParallelToolBatchTests {
    // MARK: - Batch helper (no engine)

    @Test("Same-path file_write and file_edit calls run one after another; other paths overlap")
    func samePathCallsAreSerialised() async {
        let log = Timeline()
        let calls = [
            IntelBatchCall(callId: "1", toolName: "file_write", jsonArguments: #"{"path":"a.txt","content":"x"}"#),
            IntelBatchCall(callId: "2", toolName: "file_edit", jsonArguments: #"{"path":"./a.txt","old_string":"x","new_string":"y"}"#),
            IntelBatchCall(callId: "3", toolName: "file_write", jsonArguments: #"{"path":"b.txt","content":"z"}"#),
            IntelBatchCall(callId: "4", toolName: "file_read", jsonArguments: #"{"path":"a.txt"}"#),
        ]
        let executions = await AgentToolLoop.runBatchInParallel(calls) { call in
            await log.note("start:\(call.callId)")
            try await Task.sleep(nanoseconds: 120_000_000)
            await log.note("end:\(call.callId)")
            return "done:\(call.callId)"
        }
        #expect(executions.map(\.result) == ["done:1", "done:2", "done:3", "done:4"])
        let events = await log.events
        // 1 and 2 share a path: 2 starts only after 1 ended.
        #expect(events.firstIndex(of: "end:1")! < events.firstIndex(of: "start:2")!)
        // 3 (other path) and 4 (a read) do not wait for them.
        #expect(events.firstIndex(of: "start:3")! < events.firstIndex(of: "end:1")!)
        #expect(events.firstIndex(of: "start:4")! < events.firstIndex(of: "end:1")!)
    }

    @Test("Results come back in call order even when the first call finishes last")
    func resultsKeepCallOrder() async {
        let calls = (0..<4).map {
            IntelBatchCall(callId: "c\($0)", toolName: "probe", jsonArguments: "{}")
        }
        let executions = await AgentToolLoop.runBatchInParallel(calls) { call in
            // c0 slowest, c3 fastest.
            let index = Int(call.callId.dropFirst())!
            try await Task.sleep(nanoseconds: UInt64(4 - index) * 60_000_000)
            return call.callId
        }
        #expect(executions.map(\.result) == ["c0", "c1", "c2", "c3"])
    }

    @Test("A throwing call is its own error envelope and the others still run")
    func oneFailureDoesNotAbortTheBatch() async {
        struct Boom: Error {}
        let calls = ["a", "b", "c"].map { IntelBatchCall(callId: $0, toolName: "probe", jsonArguments: "{}") }
        let executions = await AgentToolLoop.runBatchInParallel(calls) { call in
            if call.callId == "b" { throw Boom() }
            return "ok:\(call.callId)"
        }
        #expect(executions[0].result == "ok:a" && !executions[0].isError)
        #expect(executions[1].isError && ToolEnvelope.isError(executions[1].result))
        #expect(executions[2].result == "ok:c")
    }

    @Test("serial: true runs the calls one by one in order")
    func serialModeRunsInOrder() async {
        let log = Timeline()
        let calls = ["a", "b", "c"].map { IntelBatchCall(callId: $0, toolName: "probe", jsonArguments: "{}") }
        _ = await AgentToolLoop.runBatchInParallel(calls, serial: true) { call in
            await log.note("start:\(call.callId)")
            try await Task.sleep(nanoseconds: 30_000_000)
            await log.note("end:\(call.callId)")
            return ""
        }
        #expect(await log.events == ["start:a", "end:a", "start:b", "end:b", "start:c", "end:c"])
    }

    @Test("A batch started on a cancelled task runs nothing; every call gets a cancelled envelope")
    func cancelledBatchRunsNothing() async {
        let log = Timeline()
        let calls = ["a", "b"].map { IntelBatchCall(callId: $0, toolName: "probe", jsonArguments: "{}") }
        let task = Task {
            // Wait until cancelled, then start the batch.
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            return await AgentToolLoop.runBatchInParallel(calls) { call in
                await log.note("start:\(call.callId)")
                return "ran"
            }
        }
        task.cancel()
        let executions = await task.value
        #expect(await log.events.isEmpty)
        #expect(executions.count == 2)
        #expect(executions.allSatisfy { $0.result.contains("Run cancelled before this call executed.") })
    }

    @Test("pathSerializationKey normalises equivalent paths and ignores other tools")
    func pathKeyNormalisation() {
        let write = AgentToolLoop.pathSerializationKey(
            toolName: "file_write", jsonArguments: #"{"path":" src/./a.txt ","content":""}"#)
        let edit = AgentToolLoop.pathSerializationKey(
            toolName: "file_edit", jsonArguments: #"{"path":"src//a.txt"}"#)
        #expect(write != nil && write == edit)
        #expect(AgentToolLoop.pathSerializationKey(toolName: "file_read", jsonArguments: #"{"path":"a"}"#) == nil)
        #expect(AgentToolLoop.pathSerializationKey(toolName: "file_write", jsonArguments: "{}") == nil)
        #expect(AgentToolLoop.pathSerializationKey(toolName: "file_write", jsonArguments: "not json") == nil)
    }

    @Test("Batch mode: one call and capability loads stay inline, control calls serial, the rest parallel")
    func batchModes() {
        #expect(AgentToolLoop.batchMode(forToolNames: ["a"]) == .inline)
        #expect(AgentToolLoop.batchMode(forToolNames: ["a", "b"]) == .parallel)
        #expect(AgentToolLoop.batchMode(forToolNames: ["a", "capabilities"]) == .inline)
        #expect(AgentToolLoop.batchMode(forToolNames: ["a", "complete"]) == .serial)
        #expect(AgentToolLoop.batchMode(forToolNames: ["clarify", "b"]) == .serial)
    }

    // MARK: - Engine, chat completions wire

    @Test("Calls of one round overlap, and their results reach the model in call order")
    func engineRunsCallsConcurrently() async throws {
        let names = ["pt_barrier_a", "pt_barrier_b"]
        try await Self.withTools(names, [.barrier(expect: 2)]) {
            let deltas = try await Self.run(
                [Self.callStream(names.enumerated().map { ("call_\($0.offset)", $0.element) }), Self.textStream()],
                tools: names)
            let done = deltas.compactMap(StreamingToolHint.decodeDone)
            #expect(done.map(\.callId) == ["call_0", "call_1"])
            // Each probe waits for the other: serial execution would time out.
            #expect(done.allSatisfy { $0.result.contains("overlapped") })
            #expect(Self.toolMessageIds(in: FixtureProtocol.requestBodies.last) == ["call_0", "call_1"])
        }
    }

    @Test("A slow first call does not reorder the results; a fast one finishes first")
    func engineKeepsCallOrderWhenTheFirstIsSlow() async throws {
        let names = ["pt_slow", "pt_fast"]
        try await Self.withTools(names, [.slow(ms: 200), .instant]) {
            let deltas = try await Self.run(
                [Self.callStream([("call_slow", "pt_slow"), ("call_fast", "pt_fast")]), Self.textStream()],
                tools: names)
            let done = deltas.compactMap(StreamingToolHint.decodeDone)
            #expect(done.map(\.callId) == ["call_slow", "call_fast"])
            #expect(done[0].result.contains("pt_slow") && done[1].result.contains("pt_fast"))
            let events = await ProbeTool.timeline.events
            #expect(events.firstIndex(of: "end:pt_fast")! < events.firstIndex(of: "end:pt_slow")!)
            #expect(Self.toolMessageIds(in: FixtureProtocol.requestBodies.last) == ["call_slow", "call_fast"])
        }
    }

    @Test("Start hints for every offered call come in call order before any result")
    func startHintsPrecedeResults() async throws {
        let names = ["pt_a", "pt_b", "pt_c"]
        try await Self.withTools(names, [.instant, .instant, .instant]) {
            let deltas = try await Self.run(
                [Self.callStream(names.enumerated().map { ("call_\($0.offset)", $0.element) } + [("call_x", "pt_unoffered")]),
                    Self.textStream()],
                tools: names, reportsToolStarts: true)
            let kinds = deltas.compactMap { delta -> String? in
                if let started = StreamingToolHint.decodeStarted(delta) { return "start:" + started.callId }
                if let done = StreamingToolHint.decodeDone(delta) { return "done:" + done.callId }
                return nil
            }
            // The unoffered call never starts; it only gets its refusal result.
            #expect(
                kinds == [
                    "start:call_0", "start:call_1", "start:call_2",
                    "done:call_0", "done:call_1", "done:call_2", "done:call_x",
                ])
        }
    }

    @Test("A Deny in the middle: earlier calls run, the refused one reports, later ones are skipped and never run")
    func denyInTheMiddleOfABatch() async throws {
        let names = ["pt_first", "pt_denied", "pt_last"]
        try await Self.withTools(names, [.instant, .instant, .instant]) {
            ToolRegistry.shared.setPolicy(.deny, for: "pt_denied")
            defer { ToolRegistry.shared.clearPolicy(for: "pt_denied") }
            let deltas = try await Self.run(
                [Self.callStream(names.enumerated().map { ("call_\($0.offset)", $0.element) }), Self.textStream()],
                tools: names, reportsToolStarts: true)
            let done = deltas.compactMap(StreamingToolHint.decodeDone)
            #expect(done.map(\.callId) == ["call_0", "call_1", "call_2"])
            #expect(done[0].result.contains("pt_first"))
            #expect(done[1].result.contains("was not run"))
            #expect(done[2].result.contains("Skipped: an earlier tool call in this batch was rejected"))
            #expect(deltas.compactMap(StreamingToolHint.decodeStarted).map(\.callId) == ["call_0", "call_1"])
            let events = await ProbeTool.timeline.events
            #expect(events.contains("start:pt_first"))
            #expect(!events.contains("start:pt_denied") && !events.contains("start:pt_last"))
            // Every call has its paired result in the next request.
            #expect(Self.toolMessageIds(in: FixtureProtocol.requestBodies.last) == ["call_0", "call_1", "call_2"])
        }
    }

    @Test("A call that throws is its own error result; the rest of the batch finishes")
    func engineOneFailureDoesNotAbortTheBatch() async throws {
        let names = ["pt_ok", "pt_throws", "pt_ok_too"]
        try await Self.withTools(names, [.instant, .throwing, .instant]) {
            let deltas = try await Self.run(
                [Self.callStream(names.enumerated().map { ("call_\($0.offset)", $0.element) }), Self.textStream()],
                tools: names)
            let done = deltas.compactMap(StreamingToolHint.decodeDone)
            #expect(done.count == 3)
            #expect(done[0].result.contains("pt_ok") && done[2].result.contains("pt_ok_too"))
            #expect(ToolEnvelope.isError(done[1].result))
        }
    }

    @Test("Stop in the middle of a batch cancels the running calls and sends no further request")
    func stopMidBatch() async throws {
        let names = ["pt_hang_a", "pt_hang_b"]
        try await Self.withTools(names, [.hang, .hang]) {
            FixtureProtocol.configure(responses: [
                Self.callStream(names.enumerated().map { ("call_\($0.offset)", $0.element) }), Self.textStream(),
            ])
            let engine = Self.makeEngine()
            var request = Self.makeRequest(tools: names, reportsToolStarts: false)
            request.tools = ToolRegistry.shared.openAISpecs().filter { names.contains($0.function.name) }
            let stream = try await engine.streamChat(request: request)
            let consumer = Task { () -> Void in
                for try await _ in stream {}
            }
            // Both calls are running at the same time.
            #expect(await ProbeTool.timeline.wait(for: ["start:pt_hang_a", "start:pt_hang_b"], seconds: 5))
            let stopped = Date()
            consumer.cancel()
            _ = await consumer.result
            // The tool bodies see the cancellation and the run goes no further.
            #expect(await ProbeTool.timeline.wait(for: ["cancelled:pt_hang_a", "cancelled:pt_hang_b"], seconds: 5))
            #expect(Date().timeIntervalSince(stopped) < 5)
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(FixtureProtocol.requestBodies.count == 1)
        }
    }

    // MARK: - Engine, Responses wire

    @Test("The Responses wire runs a round's calls concurrently and returns results in call order")
    func responsesWireRunsCallsConcurrently() async throws {
        let names = ["pt_barrier_c", "pt_barrier_d"]
        try await Self.withTools(names, [.barrier(expect: 2)]) {
            let deltas = try await Self.run(
                [Self.responsesCallStream(names.enumerated().map { ("call_\($0.offset)", $0.element) }), Self.responsesTextStream()],
                tools: names, responses: true)
            let done = deltas.compactMap(StreamingToolHint.decodeDone)
            #expect(done.map(\.callId) == ["call_0", "call_1"])
            #expect(done.allSatisfy { $0.result.contains("overlapped") })
            let body = try #require(FixtureProtocol.requestBodies.last)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let input = try #require(json["input"] as? [[String: Any]])
            let outputs = input.filter { $0["type"] as? String == "function_call_output" }.compactMap { $0["call_id"] as? String }
            #expect(outputs == ["call_0", "call_1"])
        }
    }

    @Test("The Responses wire skips the rest of a batch after a Deny")
    func responsesWireDenyInTheMiddle() async throws {
        let names = ["pt_r_first", "pt_r_denied", "pt_r_last"]
        try await Self.withTools(names, [.instant, .instant, .instant]) {
            ToolRegistry.shared.setPolicy(.deny, for: "pt_r_denied")
            defer { ToolRegistry.shared.clearPolicy(for: "pt_r_denied") }
            let deltas = try await Self.run(
                [Self.responsesCallStream(names.enumerated().map { ("call_\($0.offset)", $0.element) }), Self.responsesTextStream()],
                tools: names, responses: true, reportsToolStarts: true)
            let done = deltas.compactMap(StreamingToolHint.decodeDone)
            #expect(done.count == 3)
            #expect(done[0].result.contains("pt_r_first"))
            #expect(done[1].result.contains("was not run"))
            #expect(done[2].result.contains("Skipped:"))
            #expect(deltas.compactMap(StreamingToolHint.decodeStarted).map(\.callId) == ["call_0", "call_1"])
            let events = await ProbeTool.timeline.events
            #expect(!events.contains("start:pt_r_last"))
        }
    }

    // MARK: - Fixture plumbing

    private static func withTools(
        _ names: [String], _ behaviors: [ProbeTool.Behavior], _ body: () async throws -> Void
    ) async throws {
        await ProbeTool.timeline.reset()
        for (index, name) in names.enumerated() {
            let behavior = behaviors.count == 1 ? behaviors[0] : behaviors[index]
            ToolRegistry.shared.register(ProbeTool(name: name, behavior: behavior))
        }
        defer { ToolRegistry.shared.unregister(names: names) }
        try await body()
    }

    private static func toolMessageIds(in body: Data?) -> [String] {
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let messages = json["messages"] as? [[String: Any]]
        else { return [] }
        return messages.filter { $0["role"] as? String == "tool" }.compactMap { $0["tool_call_id"] as? String }
    }

    private static func callStream(_ calls: [(id: String, name: String)]) -> String {
        let entries = calls.enumerated().map { index, call in
            #"{"index":\#(index),"id":"\#(call.id)","type":"function","function":{"name":"\#(call.name)","arguments":"{}"}}"#
        }.joined(separator: ",")
        return """
            data: {"choices":[{"index":0,"delta":{"tool_calls":[\(entries)]},"finish_reason":null}]}

            data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """
    }

    private static func textStream() -> String {
        """
        data: {"choices":[{"index":0,"delta":{"content":"All done."},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
    }

    private static func responsesCallStream(_ calls: [(id: String, name: String)]) -> String {
        var text = ""
        var output: [String] = []
        for (index, call) in calls.enumerated() {
            text +=
                "data: {\"type\":\"response.output_item.added\",\"output_index\":\(index),\"item\":{\"type\":\"function_call\",\"call_id\":\"\(call.id)\",\"name\":\"\(call.name)\",\"arguments\":\"\"}}\n\n"
            text +=
                "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":\(index),\"delta\":\"{}\"}\n\n"
            output.append(
                "{\"type\":\"function_call\",\"call_id\":\"\(call.id)\",\"name\":\"\(call.name)\",\"arguments\":\"{}\"}")
        }
        text +=
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[\(output.joined(separator: ","))]}}\n\n"
        return text
    }

    private static func responsesTextStream() -> String {
        """
        data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"All done."}

        data: {"type":"response.completed","response":{"id":"resp_2","status":"completed","output":[{"id":"msg_1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"All done."}]}]}}

        """
    }

    private static func makeEngine(responses: Bool = false) -> ChatEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let provider = RemoteProvider(
            name: "Fixture", host: "parallel-fixture.invalid", providerProtocol: .https,
            port: nil, basePath: "/v1", customHeaders: [:], authType: .none,
            providerType: responses ? .openResponses : .openaiLegacy, enabled: true, autoConnect: false,
            timeout: 5)
        return ChatEngine(provider: provider, session: URLSession(configuration: configuration))
    }

    private static func makeRequest(tools: [String], reportsToolStarts: Bool) -> ChatCompletionRequest {
        var request = ChatCompletionRequest(
            model: "fixture-model", messages: [ChatMessage(role: "user", content: "Do the things")])
        request.reportsToolStarts = reportsToolStarts
        return request
    }

    private static func run(
        _ responses: [String], tools names: [String], responses isResponses: Bool = false,
        reportsToolStarts: Bool = false
    ) async throws -> [String] {
        FixtureProtocol.configure(responses: responses)
        let engine = makeEngine(responses: isResponses)
        var request = makeRequest(tools: names, reportsToolStarts: reportsToolStarts)
        request.tools = ToolRegistry.shared.openAISpecs().filter { names.contains($0.function.name) }
        var deltas: [String] = []
        for try await delta in try await engine.streamChat(request: request) { deltas.append(delta) }
        return deltas
    }
}

// MARK: - Probe tools

private actor Timeline {
    private(set) var events: [String] = []
    private var arrived = 0

    func reset() { events = []; arrived = 0 }
    func note(_ event: String) { events.append(event) }

    /// Wait until `expect` callers have arrived (a barrier), or `seconds` pass.
    func arrive(expect: Int, seconds: Double = 3) async -> Bool {
        arrived += 1
        let deadline = Date().addingTimeInterval(seconds)
        while arrived < expect, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        return arrived >= expect
    }

    func wait(for wanted: [String], seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !wanted.allSatisfy({ events.contains($0) }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return wanted.allSatisfy { events.contains($0) }
    }
}

private struct ProbeTool: OsaurusTool {
    enum Behavior: Sendable {
        case instant
        case slow(ms: UInt64)
        case barrier(expect: Int)
        case throwing
        case hang
    }

    struct Failure: Error {}

    static let timeline = Timeline()
    let name: String
    let behavior: Behavior
    let description = "Scripted probe tool for the parallel batch tests"
    let parameters: JSONValue? = nil

    func execute(argumentsJSON: String) async throws -> String {
        await Self.timeline.note("start:\(name)")
        switch behavior {
        case .instant:
            break
        case .slow(let ms):
            try await Task.sleep(nanoseconds: ms * 1_000_000)
        case .barrier(let expect):
            let met = await Self.timeline.arrive(expect: expect)
            await Self.timeline.note("end:\(name)")
            return met ? "overlapped" : "timed out waiting for the other call"
        case .throwing:
            await Self.timeline.note("end:\(name)")
            throw Failure()
        case .hang:
            do {
                try await Task.sleep(nanoseconds: 20_000_000_000)
            } catch {
                await Self.timeline.note("cancelled:\(name)")
                throw error
            }
        }
        await Self.timeline.note("end:\(name)")
        return name
    }
}

// MARK: - HTTP fixture

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [String] = []
    nonisolated(unsafe) private static var bodies: [Data] = []
    static var requestBodies: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
    static func configure(responses: [String]) {
        lock.lock(); defer { lock.unlock() }
        queue = responses; bodies = []
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "parallel-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        var sent = request.httpBody ?? Data()
        if sent.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                sent.append(buffer, count: n)
            }
            stream.close()
        }
        Self.bodies.append(sent)
        let text = Self.queue.isEmpty ? "data: [DONE]\n\n" : Self.queue.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
