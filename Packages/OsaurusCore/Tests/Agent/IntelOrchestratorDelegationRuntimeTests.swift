import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel orchestrator delegation runtime", .serialized)
struct IntelOrchestratorDelegationRuntimeTests {
    @Test
    func successfulRunUsesOnlyBoundedTextRequestAndPreservesCallerSnapshots() async {
        let launcherID = UUID()
        let target = targetSnapshot(model: " cloud/child ", maxTokens: 80)
        let resolver = TargetResolverBox(targets: [target])
        let capture = RequestCapture()
        let factory = EngineFactoryCounter()
        let configuration = configuration(
            allowlist: [target.agentID],
            models: ["cloud/child"],
            maximumChildTokens: 24,
            maximumInputCharacters: 32,
            maximumOutputCharacters: 5,
            permission: .alwaysAllow,
            scope: .init(launcherAgentID: launcherID, targetAgentID: target.agentID)
        )
        let runtime = IntelOrchestratorDelegationRuntime(
            configuration: configuration,
            targetResolver: resolver.resolve,
            cloudModelValidator: { $0 == "cloud/child" },
            engineFactory: {
                factory.record()
                return CapturingEngine(capture: capture, responseText: "  abcdefghi  ")
            }
        )
        let parentSnapshot = ParentSnapshot(
            agentID: launcherID,
            model: "cloud/parent",
            systemPrompt: "Parent remains unchanged.",
            temperature: 0.1,
            maxTokens: 512
        )
        let originalParentSnapshot = parentSnapshot

        let outcome = await runtime.run(
            .init(launcherAgentID: launcherID, targetAgentID: target.agentID, text: "  hello  ")
        )

        guard case let .succeeded(success) = outcome else {
            Issue.record("Expected success, got \(outcome)")
            return
        }
        let requests = await capture.requests
        #expect(requests.count == 1)
        #expect(requests[0].model == "cloud/child")
        #expect(requests[0].messages.map(\.role) == ["system", "user"])
        #expect(requests[0].messages.map(\.content) == [target.systemPrompt, "hello"])
        #expect(requests[0].stream == false)
        #expect(requests[0].tools == nil)
        #expect(requests[0].tool_choice == nil)
        #expect(requests[0].max_tokens == 24)
        #expect(requests[0].session_id == success.childSessionID.uuidString)
        #expect(success.targetAgentID == target.agentID)
        #expect(success.modelID == "cloud/child")
        #expect(success.text == "abcde")
        #expect(success.artifact.text == "abcde")
        #expect(factory.count == 1)
        #expect(parentSnapshot == originalParentSnapshot)
        #expect(resolver.snapshot(for: target.agentID) == target)
    }

    @Test
    func askAlwaysAllowAndDenyAreScopedToTheExactLauncherTargetPair() async throws {
        let target = targetSnapshot(model: "cloud/child", maxTokens: 20)
        let launcher = UUID()
        let otherLauncher = UUID()
        let exactScope = OrchestratorDelegationPermissionScope(
            launcherAgentID: launcher,
            targetAgentID: target.agentID
        )
        let otherScope = OrchestratorDelegationPermissionScope(
            launcherAgentID: otherLauncher,
            targetAgentID: target.agentID
        )
        var policy = configuration(
            allowlist: [target.agentID],
            models: ["cloud/child"],
            permission: .ask,
            scope: exactScope
        )
        policy.setPermission(.alwaysAllow, for: exactScope)

        let capture = RequestCapture()
        let factory = EngineFactoryCounter()
        let askRuntime = makeRuntime(
            configuration: policy,
            targets: [target],
            capture: capture,
            factory: factory
        )

        guard case .succeeded = await askRuntime.run(
            .init(launcherAgentID: launcher, targetAgentID: target.agentID, text: "first")
        ) else {
            Issue.record("Always Allow should authorize only its exact scope")
            return
        }

        let mismatchedApproval = await askRuntime.run(
            .init(launcherAgentID: otherLauncher, targetAgentID: target.agentID, text: "second"),
            approval: .approved(exactScope)
        )
        guard case let .approvalRequired(required) = mismatchedApproval else {
            Issue.record("A token for another scope must not satisfy Ask")
            return
        }
        #expect(required.scope == otherScope)

        var deniedPolicy = policy
        deniedPolicy.setPermission(.deny, for: otherScope)
        let persistedDeniedPolicy = try JSONDecoder().decode(
            OrchestratorDelegationConfiguration.self,
            from: JSONEncoder().encode(deniedPolicy)
        )
        let deniedRuntime = makeRuntime(
            configuration: persistedDeniedPolicy,
            targets: [target],
            capture: capture,
            factory: factory
        )
        let denied = await deniedRuntime.run(
            .init(launcherAgentID: otherLauncher, targetAgentID: target.agentID, text: "third"),
            approval: .approved(otherScope)
        )
        #expect(denied == .denied(.permissionDenied))
        #expect(factory.count == 1)
        #expect((await capture.requests).count == 1)
    }

    @Test
    func allowlistModelAvailabilityAndResolverRemovalDenyBeforeEngineCreation() async {
        let launcher = UUID()
        let target = targetSnapshot(model: "cloud/child", maxTokens: 20)
        let capture = RequestCapture()
        let factory = EngineFactoryCounter()
        let resolver = TargetResolverBox(targets: [target])
        let base = configuration(
            allowlist: [target.agentID],
            models: ["cloud/child"],
            permission: .alwaysAllow,
            scope: .init(launcherAgentID: launcher, targetAgentID: target.agentID)
        )

        let unavailable = makeRuntime(
            configuration: base,
            targets: [target],
            capture: capture,
            factory: factory,
            modelAvailable: false
        )
        #expect(await unavailable.run(
            .init(launcherAgentID: launcher, targetAgentID: target.agentID, text: "unavailable")
        ) == .denied(.modelUnavailable))
        #expect(factory.count == 0)

        let notAllowlisted = makeRuntime(
            configuration: configuration(
                allowlist: [],
                models: ["cloud/child"],
                permission: .alwaysAllow,
                scope: .init(launcherAgentID: launcher, targetAgentID: target.agentID)
            ),
            targets: [target],
            capture: capture,
            factory: factory
        )
        #expect(await notAllowlisted.run(
            .init(launcherAgentID: launcher, targetAgentID: target.agentID, text: "not admitted")
        ) == .denied(.targetNotAllowlisted))
        #expect(factory.count == 0)

        resolver.remove(target.agentID)
        let removed = IntelOrchestratorDelegationRuntime(
            configuration: base,
            targetResolver: resolver.resolve,
            cloudModelValidator: { _ in true },
            engineFactory: {
                factory.record()
                return CapturingEngine(capture: capture, responseText: "should not run")
            }
        )
        #expect(await removed.run(
            .init(launcherAgentID: launcher, targetAgentID: target.agentID, text: "removed")
        ) == .denied(.missingTarget))
        #expect(factory.count == 0)
        #expect(await capture.requests.isEmpty)
    }

    @Test
    func inputLimitDeniesBeforeEngineAndOutputIsBounded() async {
        let launcher = UUID()
        let target = targetSnapshot(model: "cloud/child", maxTokens: 80)
        let capture = RequestCapture()
        let factory = EngineFactoryCounter()
        let runtime = makeRuntime(
            configuration: configuration(
                allowlist: [target.agentID],
                models: ["cloud/child"],
                maximumChildTokens: 24,
                maximumInputCharacters: 5,
                maximumOutputCharacters: 3,
                permission: .alwaysAllow,
                scope: .init(launcherAgentID: launcher, targetAgentID: target.agentID)
            ),
            targets: [target],
            capture: capture,
            factory: factory,
            responseText: "long output"
        )

        #expect(await runtime.run(
            .init(launcherAgentID: launcher, targetAgentID: target.agentID, text: "123456")
        ) == .denied(.inputTooLarge))
        #expect(factory.count == 0)

        let outcome = await runtime.run(
            .init(launcherAgentID: launcher, targetAgentID: target.agentID, text: " hello ")
        )
        guard case let .succeeded(success) = outcome else {
            Issue.record("Expected bounded success, got \(outcome)")
            return
        }
        #expect(success.text == "lon")
        #expect((await capture.requests).first?.max_tokens == 24)
        #expect((await capture.requests).first?.tools == nil)
        #expect((await capture.requests).first?.tool_choice == nil)
    }

    @Test
    func onlyOneChildRunsAtATime() async {
        let launcher = UUID()
        let target = targetSnapshot(model: "cloud/child", maxTokens: 20)
        let gate = CompletionGate()
        let runtime = makeRuntime(
            configuration: configuration(
                allowlist: [target.agentID],
                models: ["cloud/child"],
                permission: .alwaysAllow,
                scope: .init(launcherAgentID: launcher, targetAgentID: target.agentID)
            ),
            targets: [target],
            capture: RequestCapture(),
            factory: EngineFactoryCounter(),
            engine: BlockingEngine(gate: gate)
        )

        let first = Task {
            await runtime.run(
                .init(launcherAgentID: launcher, targetAgentID: target.agentID, text: "first")
            )
        }
        await gate.waitUntilStarted()
        #expect(await runtime.run(
            .init(launcherAgentID: launcher, targetAgentID: target.agentID, text: "second")
        ) == .denied(.concurrentChild))

        await gate.finish(with: "first complete")
        guard case .succeeded = await first.value else {
            Issue.record("The first child should finish after the gate opens")
            return
        }
    }

    @Test
    func separateRuntimesSharingChildSlotCannotOverlapAndCanRunAfterRelease() async {
        let launcher = UUID()
        let target = targetSnapshot(model: "cloud/child", maxTokens: 20)
        let slot = IntelOrchestratorDelegationChildSlot()
        let firstGate = CompletionGate()
        let firstRuntime = makeRuntime(
            configuration: configuration(
                allowlist: [target.agentID],
                models: ["cloud/child"],
                permission: .alwaysAllow,
                scope: .init(launcherAgentID: launcher, targetAgentID: target.agentID)
            ),
            targets: [target],
            capture: RequestCapture(),
            factory: EngineFactoryCounter(),
            engine: BlockingEngine(gate: firstGate),
            childSlot: slot
        )
        let secondCapture = RequestCapture()
        let secondFactory = EngineFactoryCounter()
        let secondRuntime = makeRuntime(
            configuration: configuration(
                allowlist: [target.agentID],
                models: ["cloud/child"],
                permission: .alwaysAllow,
                scope: .init(launcherAgentID: launcher, targetAgentID: target.agentID)
            ),
            targets: [target],
            capture: secondCapture,
            factory: secondFactory,
            childSlot: slot
        )

        let first = Task {
            await firstRuntime.run(
                .init(launcherAgentID: launcher, targetAgentID: target.agentID, text: "first")
            )
        }
        await firstGate.waitUntilStarted()

        #expect(await secondRuntime.run(
            .init(launcherAgentID: launcher, targetAgentID: target.agentID, text: "overlap")
        ) == .denied(.concurrentChild))
        #expect(secondFactory.count == 0)

        await firstGate.finish(with: "first complete")
        guard case .succeeded = await first.value else {
            Issue.record("The first child should finish after the gate opens")
            return
        }

        guard case .succeeded = await secondRuntime.run(
            .init(launcherAgentID: launcher, targetAgentID: target.agentID, text: "after release")
        ) else {
            Issue.record("A new run should succeed after the shared slot is released")
            return
        }
        #expect(secondFactory.count == 1)
        #expect((await secondCapture.requests).count == 1)
    }

    @Test
    func timeoutAndCancellationCannotTurnIntoLateSuccess() async {
        let launcher = UUID()
        let target = targetSnapshot(model: "cloud/child", maxTokens: 20)
        let timeoutGate = CompletionGate()
        let timeoutRuntime = makeRuntime(
            configuration: configuration(
                allowlist: [target.agentID],
                models: ["cloud/child"],
                timeoutSeconds: 1,
                permission: .alwaysAllow,
                scope: .init(launcherAgentID: launcher, targetAgentID: target.agentID)
            ),
            targets: [target],
            capture: RequestCapture(),
            factory: EngineFactoryCounter(),
            engine: BlockingEngine(gate: timeoutGate)
        )
        let timedOut = await timeoutRuntime.run(
            .init(launcherAgentID: launcher, targetAgentID: target.agentID, text: "timeout")
        )
        #expect(timedOut == .timedOut)
        await timeoutGate.finish(with: "too late")
        if case .succeeded = timedOut {
            Issue.record("A timed-out child must not become a late success")
        }

        let cancellationGate = CompletionGate()
        let cancellationRuntime = makeRuntime(
            configuration: configuration(
                allowlist: [target.agentID],
                models: ["cloud/child"],
                permission: .alwaysAllow,
                scope: .init(launcherAgentID: launcher, targetAgentID: target.agentID)
            ),
            targets: [target],
            capture: RequestCapture(),
            factory: EngineFactoryCounter(),
            engine: BlockingEngine(gate: cancellationGate)
        )
        let task = Task {
            await cancellationRuntime.run(
                .init(launcherAgentID: launcher, targetAgentID: target.agentID, text: "cancel")
            )
        }
        await cancellationGate.waitUntilStarted()
        task.cancel()
        #expect(await task.value == .cancelled)
        await cancellationGate.finish(with: "too late")
        #expect(await task.value == .cancelled)
    }

    private func targetSnapshot(
        id: UUID = UUID(),
        model: String?,
        maxTokens: Int?
    ) -> IntelOrchestratorDelegationRuntime.TargetSnapshot {
        .init(
            agentID: id,
            isBuiltIn: false,
            systemPrompt: "Child prompt.",
            effectiveModel: model,
            effectiveTemperature: 0.35,
            effectiveMaxTokens: maxTokens
        )
    }

    private func configuration(
        allowlist: Set<UUID>,
        models: Set<String>,
        maximumChildTokens: Int = 256,
        maximumInputCharacters: Int = 12_000,
        maximumOutputCharacters: Int = 8_192,
        timeoutSeconds: UInt64 = 30,
        permission: OrchestratorDelegationPermission,
        scope: OrchestratorDelegationPermissionScope
    ) -> OrchestratorDelegationConfiguration {
        var result = OrchestratorDelegationConfiguration(
            customAgentAllowlist: allowlist,
            admittedCloudModelIDs: models,
            maximumChildTokens: maximumChildTokens,
            maximumInputCharacters: maximumInputCharacters,
            maximumOutputCharacters: maximumOutputCharacters,
            timeoutSeconds: timeoutSeconds
        )
        result.setPermission(permission, for: scope)
        return result
    }

    private func makeRuntime(
        configuration: OrchestratorDelegationConfiguration,
        targets: [IntelOrchestratorDelegationRuntime.TargetSnapshot],
        capture: RequestCapture,
        factory: EngineFactoryCounter,
        modelAvailable: Bool = true,
        responseText: String = "child response",
        engine: (any ChatEngineProtocol)? = nil,
        childSlot: IntelOrchestratorDelegationChildSlot = .shared
    ) -> IntelOrchestratorDelegationRuntime {
        let resolver = TargetResolverBox(targets: targets)
        return IntelOrchestratorDelegationRuntime(
            configuration: configuration,
            targetResolver: resolver.resolve,
            cloudModelValidator: { _ in modelAvailable },
            engineFactory: {
                factory.record()
                return engine ?? CapturingEngine(capture: capture, responseText: responseText)
            },
            childSlot: childSlot
        )
    }
}

private struct ParentSnapshot: Equatable, Sendable {
    let agentID: UUID
    let model: String
    let systemPrompt: String
    let temperature: Double
    let maxTokens: Int
}

private final class TargetResolverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [UUID: IntelOrchestratorDelegationRuntime.TargetSnapshot]

    init(targets: [IntelOrchestratorDelegationRuntime.TargetSnapshot]) {
        self.targets = Dictionary(uniqueKeysWithValues: targets.map { ($0.agentID, $0) })
    }

    func resolve(_ id: UUID) -> IntelOrchestratorDelegationRuntime.TargetSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return targets[id]
    }

    func remove(_ id: UUID) {
        lock.lock()
        targets.removeValue(forKey: id)
        lock.unlock()
    }

    func snapshot(for id: UUID) -> IntelOrchestratorDelegationRuntime.TargetSnapshot? {
        resolve(id)
    }
}

private actor RequestCapture {
    private(set) var requests: [ChatCompletionRequest] = []

    func append(_ request: ChatCompletionRequest) {
        requests.append(request)
    }
}

private final class EngineFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
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
        result = .success(text)
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
        id: "delegation-\(UUID().uuidString)",
        object: "chat.completion",
        created: Int(Date().timeIntervalSince1970),
        model: model,
        choices: [
            .init(
                index: 0,
                message: .init(
                    role: "assistant",
                    content: text,
                    tool_calls: nil,
                    reasoning_content: nil
                ),
                finish_reason: "stop"
            )
        ],
        usage: nil
    )
}
