//
//  IntelInsightsTests.swift
//  OsaurusCoreTests
//
//  Intel's half of the Insights catch-up (docs/INSIGHTS_INTEL.md): the
//  cloud engine's row carries the assistant turn, agent, chat, provider
//  endpoint and wire bytes (what upstream's `ChatEngine` + probe record),
//  HTTP failures are logged, inline images never reach the log, and the
//  activity log follows the storage key. The engine runs against an
//  in-process fixture, never a real provider; the shared store lives under
//  the test gate's `OSAURUS_TEST_ROOT`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel Insights catch-up", .serialized)
struct IntelInsightsTests {

    private static let textStream = """
        data: {"choices":[{"index":0,"delta":{"content":"Logged reply."},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """

    private static func provider() -> RemoteProvider {
        RemoteProvider(
            name: "Insights Fixture", host: "insights-fixture.invalid", providerProtocol: .https,
            port: nil, basePath: "/v1", customHeaders: [:], authType: .none,
            providerType: .openaiLegacy, enabled: true, autoConnect: false, timeout: 5)
    }

    /// Runs one streamed request inside the task-locals ChatView binds, and
    /// returns the row the engine logged for `turnId`.
    private func runLogged(
        status: Int,
        body: String,
        turnId: UUID,
        agentId: UUID,
        sessionId: UUID,
        provider: RemoteProvider = IntelInsightsTests.provider(),
        message: String = "Log this"
    ) async throws -> RequestLog? {
        InsightsFixtureProtocol.configure(status: status, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InsightsFixtureProtocol.self]
        let engine = ChatEngine(provider: provider, session: URLSession(configuration: configuration))
        let request = ChatCompletionRequest(
            model: "fixture-model",
            messages: [ChatMessage(role: "user", content: message)])
        do {
            let stream = try await ChatExecutionContext.$currentAgentId.withValue(agentId) {
                try await ChatExecutionContext.$currentSessionId.withValue(sessionId.uuidString) {
                    try await ChatExecutionContext.$currentAssistantTurnId.withValue(turnId) {
                        try await engine.streamChat(request: request)
                    }
                }
            }
            for try await _ in stream {}
        } catch {
            // HTTP failures surface as stream errors; the row is still logged.
        }
        // `logRequest` hops to the main actor; wait for the row to land.
        for _ in 0 ..< 100 {
            let row = await MainActor.run { InsightsService.shared.logs.first { $0.turnId == turnId } }
            if let row { return row }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    @Test("A cloud reply's row carries its turn, agent, chat, endpoint and wire bytes")
    func cloudRowAttribution() async throws {
        let turnId = UUID()
        let agentId = UUID()
        let sessionId = UUID()
        let provider = Self.provider()
        let row = try await runLogged(
            status: 200, body: Self.textStream, turnId: turnId, agentId: agentId, sessionId: sessionId,
            provider: provider)
        let log = try #require(row)
        #expect(log.agentId == agentId)
        #expect(log.sessionId == sessionId)
        #expect(log.category == .inference)
        #expect(log.locality == .remote)
        #expect(log.connection?.transport == .direct)
        #expect(log.connection?.mode == .remoteInference)
        #expect(log.connection?.providerId == provider.id)
        #expect(log.egress?.destinationHost == "insights-fixture.invalid")
        #expect(log.path == "/v1/chat/completions")
        #expect(log.wireRequestBody?.contains("\"fixture-model\"") == true)
        #expect(log.wireResponseBody?.contains("Logged reply.") == true)
        #expect(log.responseBody == "Logged reply.")
        #expect(log.isError == false)

        // Inspect response resolves this row by turn (upstream #1350).
        let found = await MainActor.run { InsightsService.shared.hasLog(turnId: turnId) }
        #expect(found)
    }

    @Test("A provider HTTP error is on the record with its body")
    func httpErrorIsLogged() async throws {
        let turnId = UUID()
        let row = try await runLogged(
            status: 401,
            body: #"{"error":{"message":"invalid api key"}}"#,
            turnId: turnId, agentId: UUID(), sessionId: UUID())
        let log = try #require(row)
        #expect(log.isError)
        #expect(log.finishReason == .error)
        #expect(log.errorMessage?.contains("invalid api key") == true)
        #expect(log.wireResponseBody?.contains("invalid api key") == true)
    }

    @Test("Inline images are replaced by a marker in the logged request")
    func inlineImageRedactedInLoggedBody() async throws {
        let payload = String(repeating: "Q", count: 400)
        let turnId = UUID()
        let row = try await runLogged(
            status: 200, body: Self.textStream, turnId: turnId, agentId: UUID(), sessionId: UUID(),
            message: "see data:image/png;base64,\(payload)")
        let log = try #require(row)
        #expect(log.requestBody?.contains(payload) == false)
        #expect(log.requestBody?.contains("[redacted 400-char image]") == true)
    }

    @Test("The activity log is a storage-key database and has upstream's paths")
    func activityLogStorageEnrollment() {
        let labels = StorageMigrator.databaseTargets().map(\.label)
        #expect(labels.contains("activity log"))
        #expect(OsaurusPaths.activityLogDatabaseFile().lastPathComponent == "activity.sqlite")
        #expect(OsaurusPaths.activityLogDatabaseFile().deletingLastPathComponent().lastPathComponent == "activity")
        #expect(OsaurusPaths.activityLogConfigFile().lastPathComponent == "activity-log.json")
    }

    @Test("Agent and provider names resolve off the main actor")
    @MainActor
    func nameCaches() {
        let defaultName = AgentManager.shared.agents.first?.name
        #expect(AgentManager.agentDisplayName(for: Agent.defaultId) == defaultName)
        for provider in RemoteProviderManager.shared.configuration.providers {
            #expect(RemoteProviderManager.providerDisplayName(for: provider.id) == provider.name)
        }
    }

    @Test("Activity Log settings are searchable under Data & Storage")
    func settingsSearchEntries() {
        let ids = Set(SettingsSearchIndex.entries.map(\.id))
        #expect(ids.isSuperset(of: [
            "privacy.activityLog.retention",
            "privacy.activityLog.storeContent",
            "privacy.activityLog.openInsights",
        ]))
    }
}

private final class InsightsFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = ""
    static func configure(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        Self.status = status
        Self.body = body
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "insights-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let status = Self.status
        let text = Self.body
        Self.lock.unlock()
        let contentType = status == 200 ? "text/event-stream" : "application/json"
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
