//
//  IntelPhoneRunTests.swift
//  OsaurusCoreTests
//
//  `W-identity-mobile` stage 3a (docs/IDENTITY_MOBILE_INTEL.md): the paired
//  phone's runs over the Secure Channel. A run named with `osaurus_run_id`
//  outlives its connection and is rejoined (`/runs/{id}/events`) or stopped
//  (`/runs/{id}/stop`); a voice-call turn carries the spoken-reply note.
//  The phone is simulated as upstream's E2E tests do: a master-scoped key
//  inside a channel, from a relay-origin (so not loopback-trusted) request.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct IntelPhoneRunTests {

    @Test func detachedRun_outlivesItsConnection_andIsRejoined() async throws {
        let gate = PhoneRunGate()
        defer { gate.open() }
        let server = try await startPhoneRunServer(engine: PhoneRunEngine(early: ["early"], late: ["late"], gate: gate))
        defer { Task { await server.shutdown() } }
        let phone = try PhoneChannel()
        let runId = "run-\(UUID().uuidString)"

        // The phone starts the run, then iOS suspends it mid-reply.
        let urlSession = URLSession(configuration: .ephemeral)
        let (call, _) = try phone.seal(.run(runId: runId))
        let first = Task { try? await urlSession.data(for: server.secureCall(call, accept: "text/event-stream")) }
        let run = try await waitFor { DetachedPhoneRuns.shared.run(id: runId).flatMap { $0.frameCount >= 2 ? $0 : nil } }
        first.cancel()
        urlSession.invalidateAndCancel()
        _ = await first.value

        // The reply carries on without it.
        gate.open()
        _ = try await waitFor { run.finishedAt }

        // The phone comes back and replays the whole run.
        let (rejoin, seq) = try phone.seal(.get("/runs/\(runId)/events?after=0", accept: "text/event-stream"))
        let (data, response) = try await URLSession.shared.data(for: server.secureCall(rejoin, accept: "text/event-stream"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let sse = try phone.openStream(data, requestSeq: seq)
        #expect(sse.contains("early"))
        #expect(sse.contains("late"), "replayed: \(sse)")
        #expect(sse.hasSuffix("data: [DONE]\n\n"))

        // Past the end is gone, not a silent empty stream.
        let (past, pastSeq) = try phone.seal(.get("/runs/\(runId)/events?after=999"))
        let (pastData, _) = try await URLSession.shared.data(for: server.secureCall(past))
        let opened = try phone.openBuffered(pastData, requestSeq: pastSeq)
        #expect(opened.status == 410)
        #expect(opened.body.contains("run_gone"))
    }

    @Test func detachedRun_stopsOnlyWhenThePhoneSaysSo() async throws {
        let gate = PhoneRunGate()
        defer { gate.open() }
        let server = try await startPhoneRunServer(engine: PhoneRunEngine(early: ["early"], late: ["late"], gate: gate))
        defer { Task { await server.shutdown() } }
        let phone = try PhoneChannel()
        let runId = "run-\(UUID().uuidString)"

        let (call, _) = try phone.seal(.run(runId: runId))
        let first = Task { try? await URLSession.shared.data(for: server.secureCall(call, accept: "text/event-stream")) }
        let run = try await waitFor { DetachedPhoneRuns.shared.run(id: runId).flatMap { $0.frameCount >= 2 ? $0 : nil } }

        let (stop, stopSeq) = try phone.seal(.post("/runs/\(runId)/stop"))
        let (stopData, _) = try await URLSession.shared.data(for: server.secureCall(stop))
        let stopped = try phone.openBuffered(stopData, requestSeq: stopSeq)
        #expect(stopped.status == 200)
        #expect(stopped.body == #"{"ok":true}"#)
        _ = await first.value
        _ = try await waitFor { run.finishedAt }

        let (again, againSeq) = try phone.seal(.post("/runs/\(runId)/stop"))
        let (againData, _) = try await URLSession.shared.data(for: server.secureCall(again))
        #expect(try phone.openBuffered(againData, requestSeq: againSeq).body.contains(#""finished":true"#))
    }

    @Test func voiceCallTurn_asksForASpokenReply() async throws {
        let engine = PhoneRunEngine(early: ["ok"])
        let server = try await startPhoneRunServer(engine: engine)
        defer { Task { await server.shutdown() } }
        let phone = try PhoneChannel()

        let (call, seq) = try phone.seal(.run(runId: nil, voiceCall: true))
        let (data, _) = try await URLSession.shared.data(for: server.secureCall(call, accept: "text/event-stream"))
        #expect(try phone.openStream(data, requestSeq: seq).contains("ok"))
        let sent = try #require(await engine.lastRequest)
        let lastUser = try #require(sent.messages.last(where: { $0.role == "user" })?.content)
        #expect(lastUser.hasPrefix("hi\n\n[Voice call]"))
        #expect(lastUser.hasSuffix("[/Voice call]"))
    }

    /// Only the phone's runs detach: a loopback script's run id is ignored,
    /// and its run still ends with its connection.
    @Test func loopbackRunId_isNotDetached() async throws {
        let engine = PhoneRunEngine(early: ["ok"])
        let server = try await startPhoneRunServer(engine: engine)
        defer { Task { await server.shutdown() } }
        let runId = "run-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/agents/default/run")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(PhoneChannel.runBody(runId: runId, voiceCall: false).utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        #expect(String(decoding: data, as: UTF8.self).contains("ok"))
        #expect(DetachedPhoneRuns.shared.run(id: runId) == nil)
    }

    /// Stage 3b: the phone continues one of the Mac's chats. The chat is the
    /// run's context, and the run's turns land back in it: the phone's
    /// message as typed (no memory, no voice-call note), then the reply with
    /// its tool step, as the Mac's own window would have kept it.
    @Test func continuingAMacChat_readsItAndAppendsTheRun() async throws {
        let stored = ChatSessionData(
            title: "Earlier",
            turns: [
                ChatTurnData(id: UUID(), role: .user, content: "earlier question", createdAt: Date()),
                ChatTurnData(id: UUID(), role: .assistant, content: "earlier reply", createdAt: Date()),
            ],
            agentId: Agent.defaultId)
        await MainActor.run { ChatSessionsManager.shared.save(stored) }
        defer { Task { @MainActor in ChatSessionsManager.shared.delete(id: stored.id) } }
        let engine = PhoneRunEngine(early: [
            "Let me check. ",
            StreamingToolHint.encodeDone(callId: "c1", name: "get_current_time", arguments: "{}", result: "12:00"),
            "It's noon.",
        ])
        let server = try await startPhoneRunServer(engine: engine)
        defer { Task { await server.shutdown() } }
        let phone = try PhoneChannel()

        let (call, seq) = try phone.seal(
            .run(runId: nil, voiceCall: true, extra: [#""osaurus_session_id":"\#(stored.id.uuidString)""#]))
        let (data, _) = try await URLSession.shared.data(for: server.secureCall(call, accept: "text/event-stream"))
        #expect(try phone.openStream(data, requestSeq: seq).contains("noon"))

        // The model saw the chat before the phone's new message.
        let sent = try #require(await engine.lastRequest)
        let conversation = sent.messages.filter { $0.role != "system" }
        #expect(conversation.map(\.role) == ["user", "assistant", "user"])
        #expect(conversation[0].content == "earlier question")
        #expect(conversation[1].content == "earlier reply")
        #expect(sent.session_id == stored.id.uuidString)

        let turns = try await waitFor { () -> [ChatTurnData]? in
            let turns = ChatSessionsManager.shared.session(for: stored.id)?.turns ?? []
            return turns.count >= 6 ? turns : nil
        }
        #expect(turns.map(\.role) == [.user, .assistant, .user, .assistant, .tool, .assistant])
        #expect(turns[2].content == "hi")
        #expect(turns[3].content == "Let me check. ")
        #expect(turns[3].toolResults["c1"] == "12:00")
        #expect(turns[4].toolCallId == "c1")
        #expect(turns[5].content == "It's noon.")
        let replying = await MainActor.run { RemoteSessionContinuation.isPhoneReplying(stored.id) }
        #expect(!replying)
    }

    /// Only the paired phone's own key may start a chat; any other key's
    /// run goes ahead without one.
    @Test func startingAChat_needsThePairedKey() async throws {
        let server = try await startPhoneRunServer(engine: PhoneRunEngine(early: ["ok"]))
        defer { Task { await server.shutdown() } }
        let phone = try PhoneChannel()
        let id = UUID()
        let (call, seq) = try phone.seal(
            .run(
                runId: nil,
                extra: [#""osaurus_session_id":"\#(id.uuidString)""#, #""osaurus_create_session":true"#]))
        let (data, _) = try await URLSession.shared.data(for: server.secureCall(call, accept: "text/event-stream"))
        #expect(try phone.openStream(data, requestSeq: seq).contains("ok"))
        let created = await MainActor.run { ChatSessionsManager.shared.session(for: id) }
        #expect(created == nil)
    }

    // MARK: Stage 3c: image jobs

    /// A streamed image request from the phone, on a provider this Mac
    /// doesn't have: it fails at once, which is enough to see the job kept.
    private static func imageBody(jobId: String) -> String {
        #"{"prompt":"a cat","stream":true,"allow_remote_media_spend":true,"osaurus_job_id":"\#(jobId)","#
            + #""target":{"backend":"remote_provider","provider_id":"\#(UUID().uuidString)","model":"m"}}"#
    }

    @Test func phoneImageJob_isKeptRejoinedAndNeverRunTwice() async throws {
        let server = try await startPhoneRunServer(engine: PhoneRunEngine(early: []))
        defer { Task { await server.shutdown() } }
        let phone = try PhoneChannel()
        let jobId = "job-\(UUID().uuidString)"

        let (call, seq) = try phone.seal(.post("/images/generations", body: Self.imageBody(jobId: jobId)))
        let (data, _) = try await URLSession.shared.data(for: server.secureCall(call, accept: "text/event-stream"))
        let first = try phone.openStream(data, requestSeq: seq)
        #expect(first.contains(#""type":"queued""#))
        #expect(first.contains(#""job_id":"\#(jobId)""#), "the phone's own id names the job")
        #expect(first.contains(#""type":"error""#))
        let job = try await waitFor { DetachedPhoneRuns.images.run(id: jobId).flatMap { $0.finishedAt != nil ? $0 : nil } }
        #expect(job.frameCount == 2)

        // The phone comes back for it.
        let (rejoin, rejoinSeq) = try phone.seal(.get("/images/jobs/\(jobId)/events?after=1", accept: "text/event-stream"))
        let (rejoinData, _) = try await URLSession.shared.data(for: server.secureCall(rejoin, accept: "text/event-stream"))
        let replayed = try phone.openStream(rejoinData, requestSeq: rejoinSeq)
        #expect(!replayed.contains(#""type":"queued""#))
        #expect(replayed.contains(#""type":"error""#))
        #expect(replayed.hasSuffix("data: [DONE]\n\n"))

        // The same request again replays the job instead of running (and
        // billing) a second one.
        let (again, againSeq) = try phone.seal(.post("/images/generations", body: Self.imageBody(jobId: jobId)))
        let (againData, _) = try await URLSession.shared.data(for: server.secureCall(again, accept: "text/event-stream"))
        #expect(try phone.openStream(againData, requestSeq: againSeq) == first)
        #expect(DetachedPhoneRuns.images.run(id: jobId) === job)
    }

    /// Only the phone's jobs detach, and only the owner on the channel may
    /// stop one: a loopback script's cancel leaves it running.
    @Test func phoneImageJob_onlyThePhoneStartsOrStopsOne() async throws {
        let server = try await startPhoneRunServer(engine: PhoneRunEngine(early: []))
        defer { Task { await server.shutdown() } }
        let plainId = "job-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/images/generations")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.imageBody(jobId: plainId).utf8)
        let (plain, _) = try await URLSession.shared.data(for: request)
        #expect(!String(decoding: plain, as: UTF8.self).contains(plainId))
        #expect(DetachedPhoneRuns.images.run(id: plainId) == nil)

        let liveId = "job-\(UUID().uuidString)"
        let live = DetachedPhoneRuns.images.begin(id: liveId).run
        defer { live.finish() }
        let stopped = StopFlag()
        live.onStop { stopped.set() }

        var cancel = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/images/cancel")!)
        cancel.httpMethod = "POST"
        cancel.setValue("application/json", forHTTPHeaderField: "Content-Type")
        cancel.httpBody = Data(#"{"job_id":"\#(liveId)"}"#.utf8)
        _ = try await URLSession.shared.data(for: cancel)
        #expect(!stopped.value)

        let phone = try PhoneChannel()
        let (call, seq) = try phone.seal(.post("/images/cancel", body: #"{"job_id":"\#(liveId)"}"#))
        let (data, _) = try await URLSession.shared.data(for: server.secureCall(call))
        #expect(try phone.openBuffered(data, requestSeq: seq).status == 200)
        #expect(stopped.value)
    }

    @Test func phoneFields_areDecodedButNeverEncoded() throws {
        let json =
            #"{"model":"m","messages":[],"osaurus_session_id":"s","osaurus_create_session":true,"osaurus_voice_call":true}"#
        let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(request.osaurus_session_id == "s")
        #expect(request.osaurus_create_session == true)
        #expect(request.osaurus_voice_call == true)
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!encoded.contains("osaurus_"))
    }
}

// MARK: - The simulated phone

private struct PhoneChannel {
    enum Call {
        case run(runId: String?, voiceCall: Bool = false, extra: [String] = [])
        case get(String, accept: String = "application/json")
        case post(String, body: String = "{}")
    }

    struct Opened {
        let status: Int
        let body: String
    }

    let session: SecureChannelSession

    init() throws {
        let key = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 0)
        let address = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 0)
        let (clientKey, hello) = SecureChannel.makeClientHello(agentAddress: address)
        let (serverSession, serverHello) = try SecureChannel.establishServerSession(hello: hello) {
            try signSecureChannelPayload($0, privateKey: key)
        }
        SecureSessionStore.shared.register(serverSession)
        session = try SecureChannel.establishClientSession(
            hello: hello, ephemeralKey: clientKey, serverHello: serverHello, expectedAgentAddress: address)
    }

    static func runBody(runId: String?, voiceCall: Bool, extra: [String] = []) -> String {
        var fields = [#""model":"fake""#, #""stream":true"#, #""messages":[{"role":"user","content":"hi"}]"#]
        if let runId { fields.append(#""osaurus_run_id":"\#(runId)""#) }
        if voiceCall { fields.append(#""osaurus_voice_call":true"#) }
        return "{" + (fields + extra).joined(separator: ",") + "}"
    }

    func seal(_ call: Call) throws -> (SecureChannel.CallRequest, UInt64) {
        let bearer = "Bearer \(TestAuth.bearerToken)"
        let inner: SecureChannel.InnerRequest
        switch call {
        case .run(let runId, let voiceCall, let extra):
            inner = SecureChannel.InnerRequest(
                method: "POST", path: "/agents/default/run", authorization: bearer, accept: "text/event-stream",
                contentType: "application/json",
                body: Data(Self.runBody(runId: runId, voiceCall: voiceCall, extra: extra).utf8).base64urlEncoded)
        case .get(let path, let accept):
            inner = SecureChannel.InnerRequest(method: "GET", path: path, authorization: bearer, accept: accept)
        case .post(let path, let body):
            inner = SecureChannel.InnerRequest(
                method: "POST", path: path, authorization: bearer, accept: "application/json",
                contentType: "application/json", body: Data(body.utf8).base64urlEncoded)
        }
        return try session.sealCall(innerRequest: JSONEncoder().encode(inner))
    }

    func openStream(_ data: Data, requestSeq: UInt64) throws -> String {
        let decoder = SecureFrameStreamDecoder(opener: session.makeResponseOpener(requestSeq: requestSeq))
        let plaintext = try decoder.feed(data)
        try decoder.verifyCompleted()
        return String(decoding: plaintext, as: UTF8.self)
    }

    func openBuffered(_ data: Data, requestSeq: UInt64) throws -> Opened {
        let inner = try SecureChannelClient.openBufferedResponse(
            data, opener: session.makeResponseOpener(requestSeq: requestSeq))
        let body = inner.body.flatMap { Data(base64urlEncoded: $0) } ?? Data()
        return Opened(status: inner.status, body: String(decoding: body, as: UTF8.self))
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var value: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
}

/// Polls until `value` is non-nil (the run is registered, has finished…).
private func waitFor<T>(_ value: @escaping () -> T?) async throws -> T {
    for _ in 0..<400 {
        if let found = value() { return found }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    throw CancellationError()
}

// MARK: - Engine

/// Holds the second half of a reply until the test opens it.
private final class PhoneRunGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        resumed.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

private actor PhoneRunEngine: ChatEngineProtocol {
    let early: [String]
    let late: [String]
    let gate: PhoneRunGate?
    private(set) var lastRequest: ChatCompletionRequest?

    init(early: [String], late: [String] = [], gate: PhoneRunGate? = nil) {
        self.early = early
        self.late = late
        self.gate = gate
    }

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        lastRequest = request
        let early = early
        let late = late
        let gate = gate
        return AsyncThrowingStream { continuation in
            let producer = Task {
                for delta in early { continuation.yield(delta) }
                await gate?.wait()
                guard !Task.isCancelled else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                for delta in late { continuation.yield(delta) }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw CancellationError()
    }
}

// MARK: - Server

private struct PhoneRunServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let lease: HTTPServerTestLease
    let port: Int

    /// A `/secure/call` from off the Mac: relay origin, so loopback trust
    /// does not apply and the master key is what makes it the owner.
    func secureCall(_ call: SecureChannel.CallRequest, accept: String = "application/json") throws -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/secure/call")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: HTTPHandler.relayOriginHeaderName)
        request.httpBody = try JSONEncoder().encode(call)
        return request
    }

    func shutdown() async {
        _ = try? await channel.close()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
    }
}

private func startPhoneRunServer(engine: any ChatEngineProtocol) async throws -> PhoneRunServer {
    let lease = await HTTPServerTestLock.shared.acquire()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    let encryptor = SecureChannelResponseEncryptor()
                    return channel.pipeline.addHandlers([
                        encryptor,
                        HTTPHandler(
                            configuration: .default, apiKeyValidator: TestAuth.validator,
                            eventLoop: channel.eventLoop, trustLoopback: true, chatEngine: engine,
                            responseEncryptor: encryptor),
                    ])
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return PhoneRunServer(group: group, channel: ch, lease: lease, port: ch.localAddress?.port ?? 0)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
