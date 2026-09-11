import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel delegation probe", .serialized)
struct IntelDelegationProbeTests {
    @Test
    func requestShapeReturnsBoundedInlineArtifactAndLeavesParentSnapshotUntouched() async {
        let capture = RequestCapture()
        let parent = parentSnapshot()
        let originalParent = parent
        let target = customAgent(prompt: "You are the bounded child.", model: "cloud/test", maxTokens: 640)
        let probe = makeProbe(target: target, capture: capture, responseText: "  child result  ")

        let outcome = await probe.run(
            parent: parent,
            child: childConfiguration(target),
            userMessage: "Do the bounded thing."
        )

        guard case let .succeeded(success) = outcome else {
            Issue.record("Expected success, got \(outcome)")
            return
        }
        let requests = await capture.requests
        #expect(requests.count == 1)
        #expect(requests[0].model == "cloud/test")
        #expect(requests[0].stream == false)
        #expect(requests[0].tools == nil)
        #expect(requests[0].tool_choice == nil)
        #expect(requests[0].messages.map(\.role) == ["system", "user"])
        #expect(requests[0].messages.map(\.content) == ["You are the bounded child.", "Do the bounded thing."])
        #expect(requests[0].session_id == success.child.sessionID.uuidString)
        #expect(success.child.toolsSuppressed)
        #expect(success.text == "child result")
        #expect(success.artifact.text == success.text)
        #expect(parent == originalParent)
    }

    @Test(arguments: [
        IntelDelegationProbe.Denial.missingTarget,
        .builtInTarget,
        .selfTarget,
        .targetNotAllowlisted,
        .missingModel,
        .modelNotAllowlisted,
        .missingOrInvalidTokenCap,
    ])
    func admissionDenialsNeverCreateAnEngineRequest(expected: IntelDelegationProbe.Denial) async {
        let capture = RequestCapture()
        let parent = parentSnapshot()
        let target = customAgent(prompt: "Child", model: "cloud/test", maxTokens: 64)
        var configuration = IntelDelegationProbe.Configuration(
            allowedTargetIDs: [target.id], allowedModelIDs: ["cloud/test"]
        )
        var child = childConfiguration(target)

        switch expected {
        case .missingTarget:
            child = IntelDelegationProbe.ChildConfiguration(
                agent: nil, effectiveModel: "cloud/test", effectiveTemperature: nil, effectiveMaxTokens: 64
            )
        case .builtInTarget:
            child = IntelDelegationProbe.ChildConfiguration(
                agent: Agent.default, effectiveModel: "cloud/test", effectiveTemperature: nil, effectiveMaxTokens: 64
            )
        case .selfTarget:
            let selfTarget = customAgent(id: parent.agentID, prompt: "Self", model: "cloud/test", maxTokens: 64)
            configuration = .init(allowedTargetIDs: [selfTarget.id], allowedModelIDs: ["cloud/test"])
            child = childConfiguration(selfTarget)
        case .targetNotAllowlisted:
            configuration = .init(allowedTargetIDs: [], allowedModelIDs: ["cloud/test"])
        case .missingModel:
            child = IntelDelegationProbe.ChildConfiguration(
                agent: target, effectiveModel: " ", effectiveTemperature: nil, effectiveMaxTokens: 64
            )
        case .modelNotAllowlisted:
            child = IntelDelegationProbe.ChildConfiguration(
                agent: target, effectiveModel: "cloud/other", effectiveTemperature: nil, effectiveMaxTokens: 64
            )
        case .missingOrInvalidTokenCap:
            child = IntelDelegationProbe.ChildConfiguration(
                agent: target, effectiveModel: "cloud/test", effectiveTemperature: nil, effectiveMaxTokens: 0
            )
        case .concurrentChild:
            Issue.record("Concurrency has a dedicated test.")
            return
        }

        let probe = IntelDelegationProbe(configuration: configuration) {
            CapturingEngine(capture: capture, responseText: "should not run")
        }
        let outcome = await probe.run(parent: parent, child: child, userMessage: "hello")
        #expect(outcome == .denied(expected))
        #expect(await capture.requests.isEmpty)
    }

    @Test
    func tokenAndOutputCapsAreClamped() async {
        let capture = RequestCapture()
        let target = customAgent(prompt: "Child", model: "cloud/test", maxTokens: 40)
        let probe = IntelDelegationProbe(
            configuration: .init(
                allowedTargetIDs: [target.id],
                allowedModelIDs: ["cloud/test"],
                spikeMaxTokens: 24,
                maxOutputCharacters: 5,
                timeoutNanoseconds: 1_000_000_000
            )
        ) { CapturingEngine(capture: capture, responseText: "abcdefgh") }

        let outcome = await probe.run(parent: parentSnapshot(), child: childConfiguration(target), userMessage: "hello")
        guard case let .succeeded(success) = outcome else {
            Issue.record("Expected success, got \(outcome)")
            return
        }
        #expect((await capture.requests).first?.max_tokens == 24)
        #expect(success.child.maxTokens == 24)
        #expect(success.text == "abcde")
        #expect(success.artifact.text == "abcde")
    }

    @Test
    func concurrentChildIsRejectedUntilTheFirstFinishes() async {
        let gate = CompletionGate()
        let target = customAgent(prompt: "Child", model: "cloud/test", maxTokens: 64)
        let probe = IntelDelegationProbe(
            configuration: .init(allowedTargetIDs: [target.id], allowedModelIDs: ["cloud/test"])
        ) { BlockingEngine(gate: gate) }

        let first = Task {
            await probe.run(parent: parentSnapshot(), child: childConfiguration(target), userMessage: "first")
        }
        await gate.waitUntilStarted()
        let second = await probe.run(parent: parentSnapshot(), child: childConfiguration(target), userMessage: "second")
        #expect(second == .denied(.concurrentChild))

        await gate.finish(with: "first complete")
        guard case .succeeded = await first.value else {
            Issue.record("Expected first run to complete.")
            return
        }
    }

    @Test
    func timeoutAndCallerCancellationCannotBecomeLateSuccess() async {
        let target = customAgent(prompt: "Child", model: "cloud/test", maxTokens: 64)

        let timeoutGate = CompletionGate()
        let timeoutProbe = IntelDelegationProbe(
            configuration: .init(
                allowedTargetIDs: [target.id], allowedModelIDs: ["cloud/test"], timeoutNanoseconds: 1_000_000)
        ) { BlockingEngine(gate: timeoutGate) }
        let timedOut = await timeoutProbe.run(
            parent: parentSnapshot(), child: childConfiguration(target), userMessage: "timeout"
        )
        #expect(timedOut == .timedOut)

        let cancellationGate = CompletionGate()
        let cancellationProbe = IntelDelegationProbe(
            configuration: .init(allowedTargetIDs: [target.id], allowedModelIDs: ["cloud/test"])
        ) { BlockingEngine(gate: cancellationGate) }
        let task = Task {
            await cancellationProbe.run(
                parent: parentSnapshot(), child: childConfiguration(target), userMessage: "cancel"
            )
        }
        await cancellationGate.waitUntilStarted()
        task.cancel()
        let cancelled = await task.value
        #expect(cancelled == .cancelled)

        // The engine receives cancellation and must never turn this terminal
        // outcome into a later success after its gate opens.
        await cancellationGate.finish(with: "too late")
        #expect(await task.value == .cancelled)
    }

    @Test
    func realIntelCloudEngineCompletesThroughAnInProcessProviderFixture() async {
        ProbeFixtureProtocol.configure(
            response: #"{"id":"probe_fixture","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"fixture child"},"finish_reason":"stop"}]}"#
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProbeFixtureProtocol.self]
        let provider = RemoteProvider(
            name: "Delegation Probe Fixture",
            host: "delegation-probe.invalid",
            providerProtocol: .https,
            port: nil,
            basePath: "/v1",
            customHeaders: [:],
            authType: .none,
            providerType: .openaiLegacy,
            enabled: true,
            autoConnect: false,
            timeout: 5
        )
        let engine = ChatEngine(
            provider: provider,
            session: URLSession(configuration: sessionConfiguration)
        )
        let target = customAgent(
            prompt: "Fixture child prompt",
            model: "fixture-model",
            maxTokens: 64
        )
        let probe = IntelDelegationProbe(
            configuration: .init(
                allowedTargetIDs: [target.id],
                allowedModelIDs: ["fixture-model"]
            )
        ) { engine }

        let outcome = await probe.run(
            parent: parentSnapshot(),
            child: childConfiguration(target),
            userMessage: "Use the real Intel adapter."
        )

        guard case let .succeeded(success) = outcome else {
            Issue.record("Expected fixture success, got \(outcome)")
            return
        }
        #expect(success.text == "fixture child")
        let request = ProbeFixtureProtocol.lastRequest
        #expect(request?.url?.host == "delegation-probe.invalid")
        let body = ProbeFixtureProtocol.lastBody
        let json = try? body.flatMap {
            try JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        #expect(json?["stream"] as? Bool == false)
        #expect(json?["tools"] == nil)
        let messages = json?["messages"] as? [[String: Any]]
        #expect(messages?.map { $0["role"] as? String } == ["system", "user"])
    }

    private func makeProbe(
        target: Agent,
        capture: RequestCapture,
        responseText: String
    ) -> IntelDelegationProbe {
        IntelDelegationProbe(
            configuration: .init(
                allowedTargetIDs: [target.id], allowedModelIDs: ["cloud/test"], spikeMaxTokens: 256
            )
        ) { CapturingEngine(capture: capture, responseText: responseText) }
    }

    private func parentSnapshot() -> IntelDelegationProbe.ParentSnapshot {
        .init(
            agentID: UUID(),
            model: "cloud/parent",
            systemPrompt: "Parent prompt remains outside the child.",
            temperature: 0.1,
            maxTokens: 512
        )
    }

    private func customAgent(
        id: UUID = UUID(),
        prompt: String,
        model: String,
        maxTokens: Int
    ) -> Agent {
        Agent(
            id: id,
            name: "Disposable probe agent \(id.uuidString)",
            systemPrompt: prompt,
            defaultModel: model,
            temperature: 0.35,
            maxTokens: maxTokens
        )
    }

    private func childConfiguration(_ target: Agent) -> IntelDelegationProbe.ChildConfiguration {
        .init(
            agent: target,
            effectiveModel: target.defaultModel,
            effectiveTemperature: target.temperature.map(Double.init),
            effectiveMaxTokens: target.maxTokens
        )
    }
}

private actor RequestCapture {
    private(set) var requests: [ChatCompletionRequest] = []

    func append(_ request: ChatCompletionRequest) {
        requests.append(request)
    }
}

private struct CapturingEngine: ChatEngineProtocol {
    let capture: RequestCapture
    let responseText: String

    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        await capture.append(request)
        return response(responseText, model: request.model)
    }
}

private actor CompletionGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var result: Result<String, Error>?

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForFinish() async throws -> String {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        while result == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return try result!.get()
    }

    func finish(with text: String) {
        let result: Result<String, Error> = .success(text)
        self.result = result
    }
}

private struct BlockingEngine: ChatEngineProtocol {
    let gate: CompletionGate

    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        try Task.checkCancellation()
        let text = try await gate.waitForFinish()
        try Task.checkCancellation()
        return response(text, model: request.model)
    }
}

private func response(_ text: String, model: String?) -> ChatCompletionResponse {
    ChatCompletionResponse(
        id: "probe-\(UUID().uuidString)",
        object: "chat.completion",
        created: Int(Date().timeIntervalSince1970),
        model: model,
        choices: [
            .init(
                index: 0,
                message: .init(role: "assistant", content: text, tool_calls: nil, reasoning_content: nil),
                finish_reason: "stop"
            ),
        ],
        usage: nil
    )
}

private final class ProbeFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseText = ""
    nonisolated(unsafe) private static var capturedRequest: URLRequest?
    nonisolated(unsafe) private static var capturedBody: Data?

    static func configure(response: String) {
        lock.lock()
        responseText = response
        capturedRequest = nil
        capturedBody = nil
        lock.unlock()
    }

    static var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequest
    }

    static var lastBody: Data? {
        lock.lock()
        defer { lock.unlock() }
        return capturedBody
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "delegation-probe.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4_096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                collected.append(contentsOf: bytes.prefix(count))
            }
            body = collected
        }

        Self.lock.lock()
        Self.capturedRequest = request
        Self.capturedBody = body
        let responseText = Self.responseText
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseText.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
