//
//  IntelHTTPApprovalsTests.swift
//  OsaurusCoreTests
//
//  `W-server-api` stage 4d (docs/SERVER_API_INTEL.md): the cards a run from
//  the owner's paired phone waits on, and the phone's answers. A card only
//  reaches these lists from a run with a remote reviewer, which Intel's
//  server can't start until the Secure Channel (`W-identity-mobile`), so the
//  cards here are raised directly, as such a run would raise them.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelHTTPApprovalsTests {

    // MARK: - Empty lists and validation

    @Test func lists_areEmptyWithoutAPhoneRun() async throws {
        let server = try await startApprovalsTestServer()
        defer { Task { await server.shutdown() } }
        let approvals = try await server.send("GET", "/approvals")
        #expect(approvals.status == 200)
        #expect(approvals.body == #"{"approvals":[]}"#)
        let config = try await server.send("GET", "/config/approvals")
        #expect(config.status == 200)
        #expect(config.body == #"{"approvals":[]}"#)
        let secrets = try await server.send("GET", "/secrets/prompts")
        #expect(secrets.body == #"{"prompts":[]}"#)
        let computerUse = try await server.send("GET", "/computer-use/prompts")
        #expect(computerUse.body == #"{"prompts":[]}"#)
    }

    @Test func answers_validateTheIdAndDecision() async throws {
        let server = try await startApprovalsTestServer()
        defer { Task { await server.shutdown() } }
        let id = UUID().uuidString

        let badId = try await server.send("POST", "/approvals/nope", json: #"{"decision":"deny"}"#)
        #expect(badId.status == 400)
        #expect(badId.body.contains("invalid_approval_id"))
        let badDecision = try await server.send("POST", "/approvals/\(id)", json: #"{"decision":"allow"}"#)
        #expect(badDecision.status == 400)
        let gone = try await server.send("POST", "/approvals/\(id)", json: #"{"decision":"deny"}"#)
        #expect(gone.status == 404)
        #expect(gone.body.contains("approval_not_pending"))

        let configBad = try await server.send("POST", "/config/approvals/\(id)", json: #"{"decision":"yes"}"#)
        #expect(configBad.status == 400)
        let configGone = try await server.send("POST", "/config/approvals/\(id)", json: #"{"decision":"apply"}"#)
        #expect(configGone.status == 404)

        let promptBadId = try await server.send("POST", "/secrets/prompts/x", json: #"{"value":"v"}"#)
        #expect(promptBadId.status == 400)
        #expect(promptBadId.body.contains("invalid_prompt_id"))
        let noDecision = try await server.send("POST", "/computer-use/prompts/\(id)", json: #"{}"#)
        #expect(noDecision.status == 400)
        let secretGone = try await server.send("POST", "/secrets/prompts/\(id)", json: #"{"value":"v"}"#)
        #expect(secretGone.status == 404)
        #expect(secretGone.body.contains("prompt_not_pending"))
    }

    /// A paired agent-scoped key is not the owner: every list and answer is
    /// refused (upstream).
    @Test func agentScopedKey_isRefused() async throws {
        let agent = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 3)
        let agentKey = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 3)
        let validator = APIKeyValidator(
            agentAddresses: [agent],
            masterAddress: TestKeys.aliceAddress,
            effectiveWhitelist: [TestKeys.aliceAddress.lowercased(), agent.lowercased()],
            revocationSnapshot: RevocationSnapshot(revokedKeys: [], counterThresholds: [:]),
            hasKeys: true
        )
        let token = try TokenBuilder.build(privateKey: agentKey, iss: agent, aud: agent)
        let server = try await startApprovalsTestServer(validator: validator)
        defer { Task { await server.shutdown() } }
        let relay = [HTTPHandler.relayOriginHeaderName: "1"]
        for path in ["/approvals", "/config/approvals", "/secrets/prompts", "/computer-use/prompts"] {
            let result = try await server.send("GET", path, token: token, headers: relay)
            #expect(result.status == 403, "\(path): \(result.body)")
        }
        let answer = try await server.send(
            "POST", "/approvals/\(UUID().uuidString)", json: #"{"decision":"allow_once"}"#, token: token,
            headers: relay)
        #expect(answer.status == 403)
    }

    /// A remote owner key reaches these routes only through the Secure
    /// Channel, reads included (upstream), which Intel doesn't have yet.
    @Test func remoteOwnerKey_needsTheSecureChannel() async throws {
        let server = try await startApprovalsTestServer(validator: .forAlice())
        defer { Task { await server.shutdown() } }
        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey, iss: TestKeys.aliceAddress, aud: TestKeys.aliceAddress)
        let relay = [HTTPHandler.relayOriginHeaderName: "1"]
        let list = try await server.send("GET", "/approvals", token: token, headers: relay)
        #expect(list.status == 426, "\(list.body)")
        let answer = try await server.send(
            "POST", "/approvals/\(UUID().uuidString)", json: #"{"decision":"deny"}"#, token: token, headers: relay)
        #expect(answer.status == 426, "\(answer.body)")
        let secret = try await server.send(
            "POST", "/secrets/prompts/\(UUID().uuidString)", json: #"{"value":"s"}"#, token: token, headers: relay)
        #expect(secret.status == 426, "\(secret.body)")
    }

    // MARK: - A phone run's cards, answered over HTTP

    @Test func toolCard_fromAPhoneRun_isListedAndAnswered() async throws {
        let server = try await startApprovalsTestServer()
        defer { Task { await server.shutdown() } }
        let presenter: ToolPermissionPromptService.TestPresenter = { _, _, _ in }
        let run = ToolPermissionPromptService.$presentationOverrideForTests.withValue(presenter) {
            ChatExecutionContext.$hasRemoteReviewer.withValue(true) {
                Task { @MainActor in
                    await ToolPermissionPromptService.requestApprovalOutcome(
                        toolName: "file_read", description: "Read a file", argumentsJSON: #"{"path":"a"}"#)
                }
            }
        }
        defer { Task { @MainActor in ToolPermissionPromptService.resetForTesting() } }
        let cardId = try await waitFor { await MainActor.run { ToolPermissionPromptService.remotePrompts.first?.id } }

        let list = try await server.send("GET", "/approvals")
        let rows = try #require(try list.object()["approvals"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows.first?["id"] as? String == cardId.uuidString)
        #expect(rows.first?["tool"] as? String == "file_read")
        #expect(rows.first?["arguments"] as? String == #"{"path":"a"}"#)
        #expect(rows.first?["offers_run_lease"] as? Bool == true)
        #expect(rows.first?["presented"] as? Bool == true)

        let answer = try await server.send(
            "POST", "/approvals/\(cardId.uuidString)", json: #"{"decision":"allow_once"}"#)
        #expect(answer.status == 200)
        #expect(await run.value == .allowOnce)
        let again = try await server.send(
            "POST", "/approvals/\(cardId.uuidString)", json: #"{"decision":"deny"}"#)
        #expect(again.status == 404)
    }

    @Test func toolCard_fromAMacChat_neverLeavesTheMac() async throws {
        let server = try await startApprovalsTestServer()
        defer { Task { await server.shutdown() } }
        let presenter: ToolPermissionPromptService.TestPresenter = { _, _, _ in }
        let run = ToolPermissionPromptService.$presentationOverrideForTests.withValue(presenter) {
            Task { @MainActor in
                await ToolPermissionPromptService.requestApprovalOutcome(
                    toolName: "file_read", description: "", argumentsJSON: "{}")
            }
        }
        let cardId = try await waitFor { await MainActor.run { ToolPermissionPromptService.presentedPromptIDForTesting } }
        let list = try await server.send("GET", "/approvals")
        #expect(list.body == #"{"approvals":[]}"#)
        let answer = try await server.send("POST", "/approvals/\(cardId.uuidString)", json: #"{"decision":"allow_once"}"#)
        #expect(answer.status == 404)
        await MainActor.run { ToolPermissionPromptService.resetForTesting() }
        #expect(await run.value == .denied)
    }

    @Test func secretPrompt_isListedWithoutAValueAndAnswered() async throws {
        let server = try await startApprovalsTestServer()
        defer { Task { await server.shutdown() } }
        let request = Task { @MainActor in
            await RemoteSecretPromptQueue.shared.request(
                key: "GITHUB_TOKEN", description: "GitHub token", instructions: "Paste it", timeout: .seconds(30))
        }
        let promptId = try await waitFor { await MainActor.run { RemoteSecretPromptQueue.shared.pending.first?.id } }

        let list = try await server.send("GET", "/secrets/prompts")
        let rows = try #require(try list.object()["prompts"] as? [[String: Any]])
        #expect(rows.first?["key"] as? String == "GITHUB_TOKEN")
        #expect(rows.first?["value"] == nil)

        let answer = try await server.send(
            "POST", "/secrets/prompts/\(promptId.uuidString)", json: #"{"value":"s3cret"}"#)
        #expect(answer.status == 200)
        #expect(await request.value == "s3cret")
        let after = try await server.send("GET", "/secrets/prompts")
        #expect(after.body == #"{"prompts":[]}"#)
    }

    @Test func secretPrompt_cancelSendsNoValue() async throws {
        let server = try await startApprovalsTestServer()
        defer { Task { await server.shutdown() } }
        let request = Task { @MainActor in
            await RemoteSecretPromptQueue.shared.request(
                key: "K", description: "", instructions: "", timeout: .seconds(30))
        }
        let promptId = try await waitFor { await MainActor.run { RemoteSecretPromptQueue.shared.pending.first?.id } }
        let answer = try await server.send(
            "POST", "/secrets/prompts/\(promptId.uuidString)", json: #"{"decision":"cancel","value":"ignored"}"#)
        #expect(answer.status == 200)
        #expect(await request.value == nil)
    }

    @Test func configPlan_fromAPhoneRun_isListedAndApplied() async throws {
        let server = try await startApprovalsTestServer()
        defer { Task { await server.shutdown() } }
        let plan = Self.plan()
        let review = Task { @MainActor in
            await IntelConfigApprovalQueue.shared.requestApproval(
                plan: plan, sessionID: "phone-run", fromPairedPhone: true, timeout: 30)
        }
        let id = try await waitFor { await MainActor.run { IntelConfigApprovalQueue.shared.pending.first?.id } }

        let list = try await server.send("GET", "/config/approvals")
        let rows = try #require(try list.object()["approvals"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows.first?["id"] as? String == id.uuidString)
        #expect(rows.first?["prune"] as? Bool == false)
        #expect(rows.first?["change_count"] as? Int == 1)
        #expect((rows.first?["summary"] as? String)?.contains("default_agent.name") == true)
        #expect(rows.first?["high_risk"] as? Bool == true)

        let apply = try await server.send("POST", "/config/approvals/\(id.uuidString)", json: #"{"decision":"apply"}"#)
        #expect(apply.status == 200)
        #expect(await review.value == .approved)
    }

    @Test func configPlan_fromAMacChat_isNotThePhones() async throws {
        let server = try await startApprovalsTestServer()
        defer { Task { await server.shutdown() } }
        let review = Task { @MainActor in
            await IntelConfigApprovalQueue.shared.requestApproval(plan: Self.plan(), sessionID: "mac-chat", timeout: 30)
        }
        let id = try await waitFor { await MainActor.run { IntelConfigApprovalQueue.shared.pending.first?.id } }
        let list = try await server.send("GET", "/config/approvals")
        #expect(list.body == #"{"approvals":[]}"#)
        let cancel = try await server.send("POST", "/config/approvals/\(id.uuidString)", json: #"{"decision":"cancel"}"#)
        #expect(cancel.status == 404)
        await MainActor.run { IntelConfigApprovalQueue.shared.resolve(id: id, outcome: .cancelled) }
        #expect(await review.value == .cancelled)
    }

    // MARK: - The remote reviewer outside the routes

    /// A phone run with no Mac chat open still parks its plan for the phone
    /// (upstream); any other caller without a chat surface fails closed.
    @Test func configService_parksAPhoneRunsPlan() async throws {
        let plan = Self.plan()
        let review = Task {
            await ChatExecutionContext.$hasRemoteReviewer.withValue(true) {
                await ChatExecutionContext.$currentSessionId.withValue("phone-run-2") {
                    await IntelConfigApprovalService.requestApproval(plan: plan)
                }
            }
        }
        let request = try await waitFor { await MainActor.run { IntelConfigApprovalQueue.shared.pending.first } }
        #expect(request.fromPairedPhone)
        #expect(await MainActor.run { IntelConfigApprovalQueue.shared.resolveFromPairedPhone(id: request.id, apply: false) })
        #expect(await review.value == .denied)

        let closed = await ChatExecutionContext.$currentSessionId.withValue("no-surface") {
            await IntelConfigApprovalService.requestApproval(plan: plan)
        }
        #expect(closed == .cancelled)
    }

    @Test func engineAndRegistry_speakToThePhone() {
        ChatExecutionContext.$isExternalSurface.withValue(true) {
            #expect(ChatEngine.unapprovedReason.contains("needs approval"))
            ChatExecutionContext.$hasRemoteReviewer.withValue(true) {
                #expect(ChatEngine.unapprovedReason == "you declined to run it this time")
                let envelope = ToolRegistry.externalSurfaceDenialEnvelope(tool: "shell_run")
                #expect(envelope.contains("Osaurus phone app"))
                #expect(envelope.contains("requires_mac"))
            }
            #expect(ToolRegistry.externalSurfaceDenialEnvelope(tool: "shell_run").contains("external callers"))
        }
    }

    // MARK: - Helpers

    private static func plan() -> IntelDeclarativeConfigurationPlan {
        var plan = IntelDeclarativeConfigurationPlan(
            id: UUID(),
            currentStateFingerprint: "current",
            targetStateFingerprint: "target",
            changes: [.init(path: "default_agent.name", before: "Before", after: "After")],
            target: DefaultAgentConfiguration(displayName: "After")
        )
        plan.warnings = ["Delegation list becomes empty."]
        return plan
    }
}

private func waitFor<T>(
    _ probe: @escaping @Sendable () async -> T?, timeout: TimeInterval = 5
) async throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let value = await probe() { return value }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw CancellationError()
}

private struct ApprovalsRouteResult {
    let status: Int
    let body: String
    func object() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
    }
}

private struct ApprovalsTestServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let lease: HTTPServerTestLease
    let port: Int

    func send(
        _ method: String, _ path: String, json: String? = nil, token: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> ApprovalsRouteResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let json {
            request.httpBody = Data(json.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        return ApprovalsRouteResult(
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

private func startApprovalsTestServer(validator: APIKeyValidator = .empty) async throws -> ApprovalsTestServer {
    let lease = await HTTPServerTestLock.shared.acquire()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            configuration: .default, apiKeyValidator: validator, eventLoop: channel.eventLoop,
                            trustLoopback: true))
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return ApprovalsTestServer(group: group, channel: ch, lease: lease, port: ch.localAddress?.port ?? 0)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
